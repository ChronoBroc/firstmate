#!/usr/bin/env bash
# tests/fm-settled-wait.test.sh - a wait the supervision session recorded as a
# captain outcome must reach main as settled once the worker's status log ends
# it (bin/fm-captain-wait-lib.sh owns the record and the settle rule).
#
# The reported shape: a designer worker appends a keyed `paused` line, the
# supervision session records "waiting for the captain's answers" as a captain
# outcome and main relays it, the captain answers the board, and the worker -
# woken by the delivered answer and already drawing the next round - appends
# `resolved` with the same key. That resolved line is ordinary progress to the
# watcher, and with the worker provably busy the watcher absorbed it before any
# session saw it, so main kept reporting the board as waiting.
#
# Each case drives the real bin/fm-watch.sh, bin/fm-branch-outcome.sh (the
# store the supervision session's report writes through), and
# bin/fm-wake-drain.sh. The supervision session's own report is stood in for by
# the store append it performs; a real Lavish board is stood in for by the
# worker's resolved line the armed listener's delivery leads to.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-settled-wait-tests)
OUTCOME="$ROOT/bin/fm-branch-outcome.sh"
PAUSE_LINE='paused [key=board-review] [at=1794686615]: round 7 waits for the owner on the Lavish board - until 2026-11-21T20:00Z'
ANSWER_LINE='resolved [key=board-review] [at=1794687324]: round 7 answered, all four as recommended; drawing round 8'
DECISION_LINE='needs-decision [key=board-review] [at=1794686615]: round 7 waits for the owner'

# Wait up to 10s for the watcher to either exit (it surfaced a wake) or record
# an absorbed signal. Prints exit or absorbed.
watch_verdict() {  # <state> <pid>
  local state=$1 pid=$2 i=0
  while [ "$i" -lt 100 ]; do
    if grep -Fq "absorbed benign signal:" "$state/.watch-triage.log" 2>/dev/null; then
      printf 'absorbed'
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      printf 'exit'
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  printf 'timeout'
}

# A designer task whose keyed wait was surfaced, recorded as a captain outcome,
# relayed, and acknowledged by main. Prints the outcome's seq.
setup_recorded_wait() {  # <dir> [<wait-line>]
  local dir=$1 wait_line=${2:-$PAUSE_LINE} state fakebin out pid seq
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/first.out"
  printf 'window=test:fm-designer\nkind=scout\nharness=claude\n' > "$state/designer.meta"
  printf 'working [at=1794686610]: round 7 is on the board\n' > "$state/designer.status"
  printf '%s' "$(seen_sig "$state/designer.status")" > "$state/.seen-designer_status"
  printf '%s\n' "$wait_line" >> "$state/designer.status"
  # The worker ended its turn to wait, so it is not provably working and the
  # watcher surfaces the pause, as it did for the reported round.
  export FM_FAKE_CREW_STATE='state: idle · source: pane · waiting at its prompt'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  [ "$(watch_verdict "$state" "$pid")" = exit ] \
    || { reap "$pid"; fail "setup: the keyed wait did not surface"; }
  ack_stopped_cycle "$state" >/dev/null 2>&1 || fail "setup: could not acknowledge the pause wake"
  seq=$(FM_STATE_OVERRIDE="$state" "$OUTCOME" append --task designer --verdict captain \
    --summary "Round 7 is on the Lavish board with four questions. Waiting for the captain's answers." \
    --wake "signal: $state/designer.status") || fail "setup: the captain outcome was not stored"
  # Main presented the outcome, relayed it to the captain, and acknowledged it.
  FM_STATE_OVERRIDE="$state" "$OUTCOME" mark-read --through "$seq" >/dev/null \
    && FM_STATE_OVERRIDE="$state" "$OUTCOME" mark-processed --through "$seq" >/dev/null \
    || fail "setup: the captain outcome could not be marked relayed"
  printf '%s' "$seq"
}

drain_and_ack() {  # <state> <out>
  local state=$1 out=$2 err sequence generation
  err="$out.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -z "$sequence" ] || FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" >/dev/null 2>&1
}

test_answer_to_a_recorded_wait_reaches_main_while_the_worker_is_busy() {
  local dir state fakebin out drain_out seq pid verdict
  dir=$(make_case answered-busy); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  seq=$(setup_recorded_wait "$dir") || fail "setup of the recorded wait failed"
  # The answer arrives; the worker is already busy drawing the next round.
  printf '%s\n' "$ANSWER_LINE" >> "$state/designer.status"
  export FM_FAKE_CREW_STATE='state: working · source: pane · busy drawing round 8'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  verdict=$(watch_verdict "$state" "$pid")
  [ "$verdict" = exit ] || reap "$pid"
  [ "$verdict" = exit ] \
    || fail "the answer settling recorded outcome $seq was $verdict by the watcher instead of reaching a session"
  grep -F "signal: $state/designer.status" "$out" >/dev/null \
    || fail "the watcher exited without the answer's signal: $(cat "$out")"
  grep -F "$(printf '\tneeds-decision: ')" "$state/.wake-queue" | grep -F designer.status >/dev/null \
    || fail "the answer's queued row is not main-owned, so a supervision session could keep it from main: $(cat "$state/.wake-queue")"
  # The attended supervision host asks this offer rule whether its session may
  # take the close; the answer must go to main instead.
  if command -v node >/dev/null 2>&1; then
    head -n 1 "$out" | FM_STATE_OVERRIDE="$state" node "$ROOT/bin/fm-branch-dispatch.mjs" offer \
      | grep -qx 'eligible=0' \
      || fail "the attended supervision host's offer rule would let its session take the answer"
  fi
  drain_and_ack "$state" "$drain_out" || fail "main's drain failed"
  grep -F 'SETTLED WAITS' "$drain_out" >/dev/null \
    || fail "main's drain did not present the recorded wait as settled: $(cat "$drain_out")"
  grep -F "designer outcome $seq" "$drain_out" | grep -F "$ANSWER_LINE" >/dev/null \
    || fail "the settled entry is not tied to outcome $seq and the answer: $(cat "$drain_out")"
  drain_and_ack "$state" "$drain_out.2" || fail "main's second drain failed"
  ! grep -F 'SETTLED WAITS' "$drain_out.2" >/dev/null \
    || fail "a settled wait was presented again after main saw it"
  unset FM_FAKE_CREW_STATE
  pass "an answer settling a recorded captain wait reaches main as settled even while the worker is busy"
}

test_answer_to_a_recorded_board_decision_reaches_main_while_the_worker_is_busy() {
  local dir state fakebin out drain_out seq pid verdict
  dir=$(make_case decision-busy); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  seq=$(setup_recorded_wait "$dir" "$DECISION_LINE") || fail "setup of the recorded decision failed"
  printf '%s\n' "$ANSWER_LINE" >> "$state/designer.status"
  export FM_FAKE_CREW_STATE='state: working · source: pane · busy drawing round 8'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  verdict=$(watch_verdict "$state" "$pid")
  [ "$verdict" = exit ] || reap "$pid"
  [ "$verdict" = exit ] \
    || fail "the answer closing recorded decision outcome $seq was $verdict by the watcher instead of reaching a session"
  grep -F "$(printf '\tneeds-decision: ')" "$state/.wake-queue" | grep -F designer.status >/dev/null \
    || fail "the answer's queued row is not main-owned: $(cat "$state/.wake-queue")"
  drain_and_ack "$state" "$drain_out" || fail "main's drain failed"
  grep -F 'SETTLED WAITS' "$drain_out" >/dev/null \
    || fail "main's drain did not present the recorded decision as settled: $(cat "$drain_out")"
  grep -F "designer outcome $seq" "$drain_out" | grep -F "$ANSWER_LINE" >/dev/null \
    || fail "the settled entry is not tied to outcome $seq and the answer: $(cat "$drain_out")"
  unset FM_FAKE_CREW_STATE
  pass "an answer closing a recorded keyed needs-decision reaches main as settled even while the worker is busy"
}

test_unrelated_resolve_leaves_a_recorded_decision_open() {
  local dir state drain_out
  dir=$(make_case decision-unrelated); state="$dir/state"; drain_out="$dir/drain.out"
  setup_recorded_wait "$dir" "$DECISION_LINE" >/dev/null || fail "setup of the recorded decision failed"
  printf 'resolved [key=render-job] [at=1794687000]: my background render finished\n' >> "$state/designer.status"
  printf 'working [at=1794687010]: tidying the round 7 notes\n' >> "$state/designer.status"
  drain_and_ack "$state" "$drain_out" || fail "main's drain failed"
  ! grep -F 'SETTLED WAITS' "$drain_out" >/dev/null \
    || fail "events that do not close the board decision were presented as settling it: $(cat "$drain_out")"
  pass "only a close of the decision's own key settles a recorded needs-decision"
}

# Append <line> while the worker is busy; the watcher must absorb it as routine
# and main's drain must present nothing settled.
assert_absorbed_and_unsettled() {  # <dir> <line> <what>
  local dir=$1 line=$2 what=$3 state pid verdict
  state="$dir/state"
  printf '%s\n' "$line" >> "$state/designer.status"
  export FM_FAKE_CREW_STATE='state: working · source: pane · busy'
  watch_bg "$state" "$dir/fakebin" "$dir/watch.out"
  pid=$!
  verdict=$(watch_verdict "$state" "$pid")
  [ "$verdict" = exit ] || reap "$pid"
  unset FM_FAKE_CREW_STATE
  [ "$verdict" = absorbed ] || fail "$what was $verdict instead of absorbed as routine progress"
  drain_and_ack "$state" "$dir/drain.out" || fail "main's drain failed"
  ! grep -F 'SETTLED WAITS' "$dir/drain.out" >/dev/null \
    || fail "$what was presented as settling the recorded wait: $(cat "$dir/drain.out")"
}

assert_settles_on_answer() {  # <dir> <seq>
  local dir=$1 seq=$2 state
  state="$dir/state"
  printf '%s\n' "$ANSWER_LINE" >> "$state/designer.status"
  drain_and_ack "$state" "$dir/drain.answer.out" || fail "main's drain after the answer failed"
  grep -F "designer outcome $seq" "$dir/drain.answer.out" | grep -F "$ANSWER_LINE" >/dev/null \
    || fail "the same-key answer did not settle the recorded wait: $(cat "$dir/drain.answer.out")"
}

test_captain_held_wait_ignores_another_key_and_settles_on_its_own() {
  local dir seq
  dir=$(make_case held-other-key)
  seq=$(setup_recorded_wait "$dir" 'captain-held [key=board-review] [at=1794686615]: round 7 is held for the owner') \
    || fail "setup of the recorded hold failed"
  assert_absorbed_and_unsettled "$dir" 'resolved [key=other] [at=1794687000]: my background render finished' \
    "a resolve of another key after a recorded hold"
  assert_settles_on_answer "$dir" "$seq"
  pass "a recorded captain-held wait settles only on a resolve of its own key"
}

test_paused_wait_ignores_routine_progress_and_settles_on_its_own_key() {
  local dir seq
  dir=$(make_case paused-progress)
  seq=$(setup_recorded_wait "$dir") || fail "setup of the recorded wait failed"
  assert_absorbed_and_unsettled "$dir" 'working [at=1794687000]: sketching round 8 while the board waits' \
    "routine progress after a recorded pause"
  assert_settles_on_answer "$dir" "$seq"
  pass "a recorded pause settles only on a resolve of its own key, never on routine progress"
}

test_settled_entry_keeps_its_settling_line_under_a_long_summary() {
  local dir state drain_out seq summary
  dir=$(make_case long-summary); state="$dir/state"; drain_out="$dir/drain.out"
  setup_recorded_wait "$dir" >/dev/null || fail "setup of the recorded wait failed"
  summary=$(printf 'Round 7 board question detail. %.0s' $(seq 1 20))
  seq=$(FM_STATE_OVERRIDE="$state" "$OUTCOME" append --task designer --verdict captain \
    --summary "$summary" --wake "signal: $state/designer.status") || fail "the long captain outcome was not stored"
  printf '%s\n' "$ANSWER_LINE" >> "$state/designer.status"
  drain_and_ack "$state" "$drain_out" || fail "main's drain failed"
  grep -F "designer outcome $seq" "$drain_out" | grep -F "settled by: $ANSWER_LINE" >/dev/null \
    || fail "a long summary cut the settling line out of the entry: $(cat "$drain_out")"
  pass "a settled entry keeps its outcome seq and settling line however long its summary"
}

test_unrelated_resolve_neither_settles_nor_surfaces() {
  local dir state fakebin out drain_out pid verdict
  dir=$(make_case unrelated-resolve); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  setup_recorded_wait "$dir" >/dev/null || fail "setup of the recorded wait failed"
  # A resolved line for a different key does not end the board wait.
  printf 'resolved [key=render-job] [at=1794687000]: my background render finished\n' >> "$state/designer.status"
  export FM_FAKE_CREW_STATE='state: working · source: pane · busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  verdict=$(watch_verdict "$state" "$pid")
  [ "$verdict" = exit ] || reap "$pid"
  [ "$verdict" = absorbed ] \
    || fail "a resolve of another key was $verdict instead of absorbed as routine progress"
  drain_and_ack "$state" "$drain_out" || fail "main's drain failed"
  ! grep -F 'SETTLED WAITS' "$drain_out" >/dev/null \
    || fail "a resolve of another key was presented as settling the board wait: $(cat "$drain_out")"
  unset FM_FAKE_CREW_STATE
  pass "a resolve of another key leaves the recorded wait open and stays routine"
}

test_resolve_without_a_recorded_wait_stays_routine() {
  local dir state fakebin out pid verdict
  dir=$(make_case no-recorded-wait); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'window=test:fm-builder\nkind=ship\nharness=claude\n' > "$state/builder.meta"
  printf 'paused [key=board-review] [at=1794686615]: waiting on my own render\n' > "$state/builder.status"
  printf '%s' "$(seen_sig "$state/builder.status")" > "$state/.seen-builder_status"
  printf 'resolved [key=board-review] [at=1794687324]: render finished\n' >> "$state/builder.status"
  export FM_FAKE_CREW_STATE='state: working · source: pane · busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  verdict=$(watch_verdict "$state" "$pid")
  [ "$verdict" = exit ] || reap "$pid"
  [ "$verdict" = absorbed ] \
    || fail "a resolve no captain outcome was recorded against was $verdict instead of absorbed"
  unset FM_FAKE_CREW_STATE
  pass "a resolve with no recorded captain wait stays routine for a busy worker"
}

test_drain_presents_settlement_without_the_wake_and_waits_out_away() {
  local dir state drain_out seq
  dir=$(make_case drain-only); state="$dir/state"; drain_out="$dir/drain.out"
  seq=$(setup_recorded_wait "$dir") || fail "setup of the recorded wait failed"
  printf '%s\n' "$ANSWER_LINE" >> "$state/designer.status"
  # Away: the outcome waits for the captain's return, like BRANCH OUTCOMES.
  printf 'mode: away\n' > "$state/.afk-contract"
  drain_and_ack "$state" "$drain_out" || fail "main's away drain failed"
  ! grep -F 'SETTLED WAITS' "$drain_out" >/dev/null \
    || fail "a settled wait was presented while the captain is away"
  rm -f "$state/.afk-contract"
  drain_and_ack "$state" "$drain_out.back" || fail "main's return drain failed"
  grep -F "designer outcome $seq" "$drain_out.back" | grep -F "$ANSWER_LINE" >/dev/null \
    || fail "the return drain did not present the settled wait from the records alone: $(cat "$drain_out.back")"
  pass "the drain derives the settlement from durable records and holds it while the captain is away"
}

record_captain_outcome() {  # <state> <summary>
  FM_STATE_OVERRIDE="$1" "$OUTCOME" append --task designer --verdict captain \
    --summary "$2" --wake "signal: $1/designer.status"
}

test_outcome_on_another_key_leaves_the_board_wait_to_settle_visibly() {
  local dir state fakebin out drain_out seq pid verdict
  dir=$(make_case other-key-outcome); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  seq=$(setup_recorded_wait "$dir") || fail "setup of the recorded wait failed"
  printf 'blocked [key=credential] [at=1794686700]: need the store API credential\n' >> "$state/designer.status"
  record_captain_outcome "$state" "Blocked on the store API credential." >/dev/null \
    || fail "the credential captain outcome was not stored"
  printf 'resolved [key=credential] [at=1794686800]: credential received\n' >> "$state/designer.status"
  printf '%s' "$(seen_sig "$state/designer.status")" > "$state/.seen-designer_status"
  printf '%s\n' "$ANSWER_LINE" >> "$state/designer.status"
  export FM_FAKE_CREW_STATE='state: working · source: pane · busy drawing round 8'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  verdict=$(watch_verdict "$state" "$pid")
  [ "$verdict" = exit ] || reap "$pid"
  unset FM_FAKE_CREW_STATE
  [ "$verdict" = exit ] \
    || fail "the board answer after an outcome on another key was $verdict by the watcher instead of reaching a session"
  grep -F "$(printf '\tneeds-decision: ')" "$state/.wake-queue" | grep -F designer.status >/dev/null \
    || fail "the board answer's queued row is not main-owned: $(cat "$state/.wake-queue")"
  drain_and_ack "$state" "$drain_out" || fail "main's drain failed"
  grep -F "designer outcome $seq (" "$drain_out" | grep -F "$ANSWER_LINE" >/dev/null \
    || fail "the board wait recorded by outcome $seq was not presented as settled: $(cat "$drain_out")"
  pass "a captain outcome on another key leaves the board wait to settle visibly"
}

test_newer_captain_outcome_without_a_wait_leaves_the_open_wait() {
  local dir state drain_out seq
  dir=$(make_case no-wait-outcome); state="$dir/state"; drain_out="$dir/drain.out"
  seq=$(setup_recorded_wait "$dir") || fail "setup of the recorded wait failed"
  printf 'working [at=1794687100]: sketching round 8 while the board waits\n' >> "$state/designer.status"
  record_captain_outcome "$state" "Sketching round 8 while the board waits." >/dev/null \
    || fail "the newer captain outcome was not stored"
  printf '%s\n' "$ANSWER_LINE" >> "$state/designer.status"
  drain_and_ack "$state" "$drain_out" || fail "main's drain failed"
  grep -F "designer outcome $seq (" "$drain_out" | grep -F "$ANSWER_LINE" >/dev/null \
    || fail "a newer outcome with no wait in force cancelled the recorded wait: $(cat "$drain_out")"
  pass "a newer captain outcome with no wait in force leaves the recorded wait to settle visibly"
}

test_unpresented_settlement_survives_a_new_same_key_wait() {
  local dir state drain_out seq next round8
  dir=$(make_case same-key-settled); state="$dir/state"; drain_out="$dir/drain.out"
  round8='resolved [key=board-review] [at=1794688000]: round 8 answered'
  seq=$(setup_recorded_wait "$dir") || fail "setup of the recorded wait failed"
  printf '%s\n' "$ANSWER_LINE" >> "$state/designer.status"
  printf 'paused [key=board-review] [at=1794687400]: round 8 waits for the owner\n' >> "$state/designer.status"
  next=$(record_captain_outcome "$state" "Round 8 is on the board. Waiting for the captain's answers.") \
    || fail "the round 8 captain outcome was not stored"
  drain_and_ack "$state" "$drain_out" || fail "main's drain failed"
  grep -F "designer outcome $seq (" "$drain_out" | grep -F "$ANSWER_LINE" >/dev/null \
    || fail "the round 7 settlement was lost to the round 8 wait: $(cat "$drain_out")"
  ! grep -F "designer outcome $next (" "$drain_out" >/dev/null \
    || fail "the open round 8 wait was presented before its answer: $(cat "$drain_out")"
  printf '%s\n' "$round8" >> "$state/designer.status"
  drain_and_ack "$state" "$drain_out.2" || fail "main's second drain failed"
  grep -F "designer outcome $next (" "$drain_out.2" | grep -F "$round8" >/dev/null \
    || fail "the round 8 wait did not settle on its own answer: $(cat "$drain_out.2")"
  pass "an unpresented settlement survives a new same-key wait, which settles on its own answer"
}

test_wait_whose_status_log_was_replaced_is_presented_once_as_unconfirmable() {
  local dir state drain_out seq
  dir=$(make_case replaced-log); state="$dir/state"; drain_out="$dir/drain.out"
  seq=$(setup_recorded_wait "$dir") || fail "setup of the recorded wait failed"
  printf 'working [at=1794688000]: a fresh log after a relaunch\n' > "$state/designer.status.new"
  mv -f "$state/designer.status.new" "$state/designer.status"
  drain_and_ack "$state" "$drain_out" || fail "main's drain failed"
  grep -F "designer outcome $seq's wait" "$drain_out" | grep -F 'can no longer be confirmed' >/dev/null \
    || fail "a wait whose status log was replaced vanished silently: $(cat "$drain_out")"
  drain_and_ack "$state" "$drain_out.2" || fail "main's second drain failed"
  ! grep -F 'SETTLED WAITS' "$drain_out.2" >/dev/null \
    || fail "an unconfirmable wait was presented again after main saw it"
  pass "a wait whose status log was replaced is presented once as unconfirmable"
}

fm_test_run \
  test_answer_to_a_recorded_wait_reaches_main_while_the_worker_is_busy \
  test_answer_to_a_recorded_board_decision_reaches_main_while_the_worker_is_busy \
  test_unrelated_resolve_leaves_a_recorded_decision_open \
  test_captain_held_wait_ignores_another_key_and_settles_on_its_own \
  test_paused_wait_ignores_routine_progress_and_settles_on_its_own_key \
  test_settled_entry_keeps_its_settling_line_under_a_long_summary \
  test_unrelated_resolve_neither_settles_nor_surfaces \
  test_resolve_without_a_recorded_wait_stays_routine \
  test_drain_presents_settlement_without_the_wake_and_waits_out_away \
  test_outcome_on_another_key_leaves_the_board_wait_to_settle_visibly \
  test_newer_captain_outcome_without_a_wait_leaves_the_open_wait \
  test_unpresented_settlement_survives_a_new_same_key_wait \
  test_wait_whose_status_log_was_replaced_is_presented_once_as_unconfirmable
