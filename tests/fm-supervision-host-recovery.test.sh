#!/usr/bin/env bash
# Behavior tests for the supervision host's attended downtime recovery closes
# (`check: rearm-resurface`): when the host keeps one off main, retires its
# episode, or hands it to main, and the bin/fm-wake-drain.sh --pending-for-main
# query it asks (bin/fm-supervision-host.sh, docs/supervision-host.md). Shared
# fixtures live in tests/supervision-host-helpers.sh.
#
# The loop cases run the real host, arm, watcher, wake grant, drain, outcome
# store, and lease scripts in a fixture home. The host runs as a child of a fake
# harness (a bash symlink named "claude") whose pid is the home's session lock,
# and its engine is a stub named by FM_SUPERVISION_ENGINE_CLAUDE_BIN that does
# what a branch turn does through the same scripts, so the real argument
# construction, bounding, and reaping are exercised without a model. A real
# status append drives each wake through the real watcher.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

# The absorbed recovery episode is retired: the marker the host acknowledges
# after parking reads acked.
recovery_retired() {  # <home>
  case "$(cat "$1/state/.watcher-down" 2>/dev/null)" in acked:*) return 0 ;; *) return 1 ;; esac
}

# Claude ends the async Stop hook that runs a parked host whenever main starts
# a turn, so the next Stop's host finds watcher downtime and its first cycle
# closes with the generic `check: rearm-resurface`. With nothing queued and
# nothing waiting for main, that recovery is routine: the host retires the
# episode and stays parked, so main is not woken for an empty drain. The
# watcher may run its own cleanup (TERM) or die holding its lock (KILL).

test_attended_recovery_with_nothing_for_main_stays_off_main() {
  local home sig drained
  for sig in KILL TERM; do
    home=$(make_home "attended-empty-recovery-$sig" attended)
    start_host "$home"
    wait_until 150 watcher_live "$home" || fail "empty recovery ($sig): the host never started a watcher cycle"
    append_status "$home" 'step one'
    wait_until 250 handled_at_least "$home" 1 \
      || fail "empty recovery ($sig): the routine wake was not handled: $(cat "$home/state/.supervision-host.log")"
    tear_down_parked_host "$home" "$sig"
    [ ! -s "$home/state/.wake-queue" ] || fail "fixture ($sig): the queue was not empty after the teardown"
    start_host "$home"
    wait_until 150 grep -qs '	no-op	' "$home/state/.supervision-host.log" \
      || fail "empty recovery ($sig): the next host did not absorb its recovery close: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
    wait_until_deadline 30 recovery_retired "$home" \
      || fail "empty recovery ($sig): the absorbed recovery episode was left open: $(cat "$home/state/.watcher-down" 2>/dev/null)"
    host_exited "$home" && fail "empty recovery ($sig): an empty recovery woke main: $(cat "$home/host.out")"
    assert_no_re 'pass-through	attended	main-only	check: rearm-resurface' "$home/state/.supervision-host.log" \
      "empty recovery ($sig): the recovery close must not reach main"
    [ "$(engine_calls "$home")" -eq 1 ] || fail "empty recovery ($sig): an empty recovery ran an engine turn"
    watcher_live "$home" || fail "empty recovery ($sig): the host is not parked on a live watcher"
    drained=$(main_drain "$home") || fail "main's drain failed: $drained"
    assert_not_contains "$drained" "WAKE_ACK_REQUIRED" "empty recovery ($sig): main's next drain must owe no acknowledgement"
    stop_home_processes "$home"
  done
  pass "host: an attended recovery with nothing queued and nothing waiting for main stays off main"
}


# A first park torn down before any row was written leaves no queue file at
# all. That is an empty queue, so its recovery close stays off main too.

test_attended_first_park_recovery_without_a_queue_file_stays_off_main() {
  local home
  home=$(make_home attended-first-park-recovery attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "first park: the host never started a watcher cycle"
  tear_down_parked_host "$home" KILL
  [ ! -e "$home/state/.wake-queue" ] || fail "fixture: the first park wrote a queue file: $(cat "$home/state/.wake-queue")"
  start_host "$home"
  wait_until 150 grep -qs '	no-op	' "$home/state/.supervision-host.log" \
    || fail "first park: the next host did not absorb its recovery close: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  wait_until_deadline 30 recovery_retired "$home" \
    || fail "first park: the absorbed recovery episode was left open: $(cat "$home/state/.watcher-down" 2>/dev/null)"
  host_exited "$home" && fail "first park: a recovery with no queue file woke main: $(cat "$home/host.out")"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "first park: an empty recovery ran an engine turn"
  watcher_live "$home" || fail "first park: the host is not parked on a live watcher"
  stop_home_processes "$home"
  pass "host: an attended first-park recovery with no queue file yet stays off main"
}

# The host's idle retirement acknowledges only the handling episode it
# absorbed. A watcher that stopped since then republishes downtime under the
# same generation (bin/fm-wake-lib.sh cleanup), and that outage must stay
# pending for the next park; a queued row also leaves the marker alone.

retire_idle() {  # <home> <marker-token> [queue-row]; prints rc and resulting token
  local home=$1
  printf '%s\n' "$2" > "$home/state/.watcher-down"
  if [ -n "${3:-}" ]; then printf '%s\n' "$3" > "$home/state/.wake-queue"; else rm -f "$home/state/.wake-queue"; fi
  FM_HOME="$home" bash -c '
    . "$1"
    rc=0
    fm_recovery_marker_retire_idle "$STATE/.watcher-down" "$2" || rc=$?
    printf "%s %s\n" "$rc" "$(cat "$STATE/.watcher-down")"
  ' _ "$ROOT/bin/fm-wake-lib.sh" g1
}

test_idle_retirement_acknowledges_only_its_handling_episode() {
  local home
  home=$(make_home idle-retirement attended)
  [ "$(retire_idle "$home" pending:handling:g1)" = "0 acked:handling:g1" ] \
    || fail "idle retirement: an absorbed handling episode was not retired"
  [ "$(retire_idle "$home" announced:handling:g1)" = "0 acked:handling:g1" ] \
    || fail "idle retirement: an announced handling episode was not retired"
  [ "$(retire_idle "$home" pending:downtime:g1)" = "3 pending:downtime:g1" ] \
    || fail "idle retirement: a later outage under the same generation was acknowledged"
  [ "$(retire_idle "$home" pending:handling:g2)" = "3 pending:handling:g2" ] \
    || fail "idle retirement: another generation's episode was touched"
  [ "$(retire_idle "$home" pending:handling:g1 $'1\t1\tsignal\tdemo.status\tsignal: demo.status')" = "0 pending:handling:g1" ] \
    || fail "idle retirement: an episode with a queued row was retired"
  pass "wake lib: idle retirement acknowledges only the handling episode it absorbed, never a later outage"
}

# The offer judges a recovery close by every record its queue holds. A blank
# record is malformed, and only main's drain retires it, so a queue holding
# one stays main's even beside routine rows. A zero-byte queue and the final
# newline of a well-formed one are not records.

recovery_offer_eligible() {  # <home> <queue-bytes>; prints the offer's eligible value
  printf '%b' "$2" > "$1/state/.wake-queue"
  printf 'check: rearm-resurface\n' | FM_HOME="$1" node "$ROOT/bin/fm-branch-dispatch.mjs" offer | sed -n 's/^eligible=//p'
}

test_recovery_offer_leaves_a_blank_queue_record_to_main() {
  local home row
  home=$(make_home recovery-blank-record attended)
  : > "$home/state/demo.turn-ended"
  row="1\t1\tsignal\tdemo.turn-ended\tsignal: $home/state/demo.turn-ended"
  [ "$(recovery_offer_eligible "$home" '')" = 1 ] || fail "blank record: a zero-byte queue must be an empty one"
  [ "$(recovery_offer_eligible "$home" "$row\n")" = 1 ] || fail "fixture: a routine turn-ended row was not branch-claimable"
  [ "$(recovery_offer_eligible "$home" '\n')" = 0 ] || fail "blank record: a queue holding only a blank record was offered as empty"
  [ "$(recovery_offer_eligible "$home" "$row\n\n")" = 0 ] || fail "blank record: a blank record beside a routine row was left behind"
  pass "offer: a recovery close whose queue holds a blank record stays main's"
}

# Asking whether anything waits for main reads the outcome store under its
# lock. A lock held elsewhere must not hold the successor watcher's start past
# the host's fixed 5-second bound (docs/supervision-host.md): the unanswered
# query leaves the empty recovery close main's instead of absorbing it.

test_attended_recovery_with_a_held_outcome_lock_reaches_main_within_the_bound() {
  local home holder started elapsed
  home=$(make_home attended-locked-recovery attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "locked recovery: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "locked recovery: the routine wake was not handled: $(cat "$home/state/.supervision-host.log")"
  tear_down_parked_host "$home" KILL
  [ ! -s "$home/state/.wake-queue" ] || fail "fixture: the queue was not empty after the teardown"
  [ -s "$home/state/branch-outcomes.jsonl" ] || fail "fixture: the handled wake left no outcome row to read under the lock"
  FM_HOME="$home" bash -c '
    . "$1"
    fm_lock_try_acquire "$STATE/.branch-outcomes.lock" || exit 1
    trap "fm_lock_release \"$STATE/.branch-outcomes.lock\"" EXIT
    sleep 120
  ' _ "$ROOT/bin/fm-wake-lib.sh" &
  holder=$!
  wait_until 50 test -e "$home/state/.branch-outcomes.lock" \
    || { kill "$holder" 2>/dev/null || true; fail "fixture: the lock holder did not take the outcome lock"; }
  started=$SECONDS
  FM_STATUS_PRESENTATION_LOCK_TIMEOUT=60 start_host "$home"
  wait_until_deadline 30 host_exited "$home" \
    || { kill "$holder" 2>/dev/null || true; fail "locked recovery: a held outcome lock kept the recovery close from main: $(cat "$home/state/.supervision-host.log")"; }
  elapsed=$((SECONDS - started))
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$elapsed" -lt 20 ] || fail "locked recovery: the close took ${elapsed}s to reach main, past the 5s bound plus host start and successor verification, against a 120s lock hold"
  assert_re '^check: rearm-resurface$' "$home/host.out" "locked recovery: main must get the recovery close"
  assert_re '	pass-through	attended	main-only	check: rearm-resurface' "$home/state/.supervision-host.log" \
    "locked recovery: the ledger must record the unanswered recovery as main's"
  watcher_live "$home" || fail "locked recovery: the successor watcher is not running after the pass-through"
  stop_home_processes "$home"
  pass "host: an empty recovery whose pending query cannot take the outcome lock reaches main within the bound"
}


# The query counts only what main's drain has not yet presented. A blocker
# whose malformed key keeps it out of the decision fold reaches main only
# through the drain's status outcome backstop
# (tests/fm-wake-drain-outcome-backstop.test.sh), so it waits until a main drain
# presents it once. An open decision counts until main's drain has presented
# it through OPEN DECISIONS, whatever routine progress follows it, and not
# after. It answers for main only, and a status log or outcome store it cannot read is
# unknown (2), never "nothing waiting". A readable log whose latest event the
# backstop deliberately omits (one longer than its 64 KiB window, or only
# blank lines) holds nothing for main, so it never wakes main on every
# recovery.

query_pending() {  # <home> [env assignments...]; prints the exit status
  local home=$1 rc=0
  shift
  env FM_HOME="$home" "$@" "$FAKE_CLAUDE" -c '"$0" --pending-for-main' "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

test_pending_for_main_query_counts_only_what_main_has_not_seen() {
  local home drained
  home=$(make_home pending-query attended)
  append_status "$home" 'step one'
  expect_code 1 "$(query_pending "$home")" "pending query: a routine status line must report nothing waiting"
  printf 'blocked [key=bad/value]: credential missing\n' >> "$home/state/demo.status"
  expect_code 0 "$(query_pending "$home")" "pending query: an unpresented captain-facing blocker must report something waiting"
  expect_code 0 "$(query_pending "$home")" "pending query: asking must not consume the blocker's presentation"
  drained=$(main_drain "$home") || fail "pending query: main's drain failed: $drained"
  assert_contains "$drained" 'demo blocked [key=bad/value]: credential missing' \
    "fixture: main's drain did not present the blocker through its backstop"
  expect_code 1 "$(query_pending "$home")" "pending query: a blocker main's drain presented must no longer count"
  printf 'needs-decision [key=format]: which export format?\n' >> "$home/state/demo.status"
  expect_code 0 "$(query_pending "$home")" "pending query: an open decision main's drain has not yet presented must report something waiting"
  append_status "$home" 'step two'
  expect_code 0 "$(query_pending "$home")" "pending query: routine progress after an unpresented decision must not hide it"
  drained=$(main_drain "$home") || fail "pending query: main's drain failed: $drained"
  assert_contains "$drained" 'demo [key=format] needs-decision: which export format?' "fixture: main's drain did not present the open decision"
  expect_code 1 "$(query_pending "$home")" "pending query: an open decision main's drain presented must not count again"
  append_status "$home" 'step three'
  expect_code 1 "$(query_pending "$home")" "pending query: routine progress after a presented decision must not make it count again"
  mkdir "$home/state/branch-outcomes.jsonl"
  expect_code 2 "$(query_pending "$home")" "pending query: an outcome store that is not a file must report unknown"
  rmdir "$home/state/branch-outcomes.jsonl"
  mkdir "$home/state/other.status"
  expect_code 2 "$(query_pending "$home")" "pending query: a worker status log that is not a file must report unknown"
  drained=$(main_drain "$home") || fail "main's drain failed: $drained"
  assert_contains "$drained" 'OPEN DECISIONS' "pending query: an ordinary drain must still present the healthy task beside an unreadable log"
  assert_not_contains "$drained" 'STATUS PRESENTATION INCOMPLETE' "pending query: an unreadable log must not break the ordinary drain's status presentation"
  rmdir "$home/state/other.status"
  awk 'BEGIN { printf "working: "; for (i = 0; i < 70000; i++) printf "x"; printf "\n" }' > "$home/state/long.status"
  expect_code 1 "$(query_pending "$home")" "pending query: a readable log whose last event exceeds the backstop window must report nothing waiting"
  rm -f "$home/state/long.status"
  printf '  \n\n\t\n' > "$home/state/blank.status"
  expect_code 1 "$(query_pending "$home")" "pending query: a whitespace-only log must report nothing waiting"
  rm -f "$home/state/blank.status"
  printf 'v=fm-captain-wait-v1\nseq=1\nendpoint=10\nident=replaced-log\nwait=needs-decision [key=fmt]: which export format?\nsummary=asked the captain\n' \
    > "$home/state/.demo.captain-wait.1.fmt"
  expect_code 0 "$(query_pending "$home")" "pending query: a captain wait its status log can no longer confirm must report something waiting"
  expect_code 0 "$(query_pending "$home")" "pending query: asking must not consume the wait record"
  drained=$(main_drain "$home") || fail "pending query: main's drain failed: $drained"
  assert_contains "$drained" 'SETTLED WAITS' "fixture: main's drain did not present the unconfirmable wait"
  expect_code 1 "$(query_pending "$home")" "pending query: a wait main's drain presented and dropped must no longer count"
  expect_code 2 "$(query_pending "$home" FM_SUPERVISION_ACTOR=branch)" "pending query: a branch actor must be refused"
  pass "drain: the pending-for-main query counts only what main has not seen, and unreadable sources as unknown"
}

# The same teardown while an engine turn handles a worker's turn end leaves
# only that routine row queued. The recovery close carries nothing main must
# see, so the supervision session takes it like the routine wake it holds.

test_attended_recovery_holding_only_routine_rows_is_handled_on_the_engine() {
  local home
  home=$(make_home attended-routine-recovery attended)
  echo held > "$home/stub-mode"
  mkfifo "$home/stub-release"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "routine recovery: the host never started a watcher cycle"
  : > "$home/state/demo.turn-ended"
  wait_until 250 test -e "$home/stub-ready" || fail "routine recovery: the engine turn never started"
  tear_down_parked_host "$home" KILL
  assert_grep 'demo.turn-ended' "$home/state/.wake-queue" "fixture: the routine row was not left queued by the teardown"
  echo handle > "$home/stub-mode"
  start_host "$home"
  wait_until 250 grep -qs '	handled	.*check: rearm-resurface' "$home/state/.supervision-host.log" \
    || fail "routine recovery: the recovery close was not handled on the engine: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  sleep 1
  host_exited "$home" && fail "routine recovery: a routine recovery woke main: $(cat "$home/host.out")"
  assert_no_grep 'demo.turn-ended' "$home/state/.wake-queue" "routine recovery: the engine did not acknowledge the routine row"
  watcher_live "$home" || fail "routine recovery: the host is not parked on a live watcher"
  pass "host: an attended recovery holding only routine rows is handled on the engine and stays off main"
}


# A recovery is main's whenever main has something it has not yet seen: a
# queued main-owned row (covered by the killed-at-the-turn-end case above) or
# a captain outcome it has not yet processed. An open decision main's drain
# already presented does not wake main again; its drain keeps listing it.

test_attended_recovery_reaches_main_only_for_work_main_has_not_seen() {
  local home kind drained
  for kind in decision captain; do
    home=$(make_home "attended-waiting-recovery-$kind" attended)
    [ "$kind" = decision ] || echo captain > "$home/stub-mode"
    start_host "$home"
    wait_until 150 watcher_live "$home" || fail "waiting recovery ($kind): the host never started a watcher cycle"
    if [ "$kind" = decision ]; then
      append_status "$home" 'which export format?' needs-decision
    else
      append_status "$home" 'ready for review'
    fi
    wait_until_deadline 60 host_exited "$home" || fail "waiting recovery ($kind): the first close did not reach main"
    # Main drains and acknowledges the close but leaves the decision open or
    # the captain outcome unprocessed; the next Stop parks again and that park
    # is torn down in turn.
    main_drain "$home" >/dev/null || fail "main's drain failed"
    [ -n "$MAIN_ACK" ] || fail "waiting recovery ($kind): main's drain printed no acknowledgement"
    # shellcheck disable=SC2086 # the printed acknowledgement arguments
    FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@"' "$ROOT/bin/fm-wake-drain.sh" $MAIN_ACK >/dev/null 2>&1 \
      || fail "waiting recovery ($kind): main's acknowledgement was refused"
    rm -f "$home/host.rc"
    start_host "$home"
    wait_until 150 watcher_live "$home" || fail "waiting recovery ($kind): the next park never started"
    sleep 2
    host_exited "$home" && fail "fixture ($kind): the next park did not stay parked: $(cat "$home/host.out")"
    tear_down_parked_host "$home" KILL
    start_host "$home"
    if [ "$kind" = decision ]; then
      wait_until 150 grep -qs '	no-op	' "$home/state/.supervision-host.log" \
        || fail "waiting recovery (decision): the host did not absorb a recovery whose decision main had seen: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
      wait_until_deadline 30 recovery_retired "$home" \
        || fail "waiting recovery (decision): the absorbed recovery episode was left open: $(cat "$home/state/.watcher-down" 2>/dev/null)"
      host_exited "$home" && fail "waiting recovery (decision): a decision main had seen woke main again: $(cat "$home/host.out")"
      watcher_live "$home" || fail "waiting recovery (decision): the host is not parked on a live watcher"
      drained=$(main_drain "$home") || fail "main's drain failed: $drained"
      assert_contains "$drained" "OPEN DECISIONS" "waiting recovery: main's drain must keep listing the open decision"
    else
      wait_until_deadline 60 host_exited "$home" \
        || fail "waiting recovery (captain): the recovery did not reach main: $(cat "$home/state/.supervision-host.log")"
      assert_re '^check: rearm-resurface$' "$home/host.out" "waiting recovery (captain): main must get the recovery close"
      assert_re '	pass-through	attended	main-only	check: rearm-resurface' "$home/state/.supervision-host.log" \
        "waiting recovery (captain): the ledger must record the recovery as main's"
      drained=$(main_drain "$home") || fail "main's drain failed: $drained"
      assert_contains "$drained" "BRANCH OUTCOMES (captain outcomes" "waiting recovery: main's drain must present the captain outcome"
    fi
    stop_home_processes "$home"
  done
  pass "host: an attended recovery reaches main for an unprocessed captain outcome, not for a decision main has seen"
}

# Another worker's routine row queued during the downtime must not hide that
# work: the recovery close that holds it still reaches main while an
# unprocessed captain outcome waits, and goes to the engine when the only
# other work is a decision main has already seen.

test_attended_recovery_with_a_routine_row_reaches_main_only_for_unseen_work() {
  local home kind drained
  for kind in decision captain; do
    home=$(make_home "attended-routine-waiting-recovery-$kind" attended)
    printf 'project=demo\nwindow=fm-beta\nharness=claude\n' > "$home/state/beta.meta"
    [ "$kind" = decision ] || echo captain > "$home/stub-mode"
    start_host "$home"
    wait_until 150 watcher_live "$home" || fail "routine waiting recovery ($kind): the host never started a watcher cycle"
    if [ "$kind" = decision ]; then
      append_status "$home" 'which export format?' needs-decision
    else
      append_status "$home" 'ready for review'
    fi
    wait_until_deadline 60 host_exited "$home" || fail "routine waiting recovery ($kind): the first close did not reach main"
    main_drain "$home" >/dev/null || fail "main's drain failed"
    [ -n "$MAIN_ACK" ] || fail "routine waiting recovery ($kind): main's drain printed no acknowledgement"
    # shellcheck disable=SC2086 # the printed acknowledgement arguments
    FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@"' "$ROOT/bin/fm-wake-drain.sh" $MAIN_ACK >/dev/null 2>&1 \
      || fail "routine waiting recovery ($kind): main's acknowledgement was refused"
    rm -f "$home/host.rc"
    echo held > "$home/stub-mode"
    mkfifo "$home/stub-release"
    start_host "$home"
    wait_until 150 watcher_live "$home" || fail "routine waiting recovery ($kind): the next park never started"
    : > "$home/state/beta.turn-ended"
    wait_until 250 test -e "$home/stub-ready" || fail "routine waiting recovery ($kind): the engine turn never started"
    tear_down_parked_host "$home" KILL
    assert_grep 'beta.turn-ended' "$home/state/.wake-queue" "fixture ($kind): the routine row was not left queued by the teardown"
    echo handle > "$home/stub-mode"
    start_host "$home"
    if [ "$kind" = decision ]; then
      wait_until 250 grep -qs '	handled	.*check: rearm-resurface' "$home/state/.supervision-host.log" \
        || fail "routine waiting recovery (decision): the recovery was not handled on the engine: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
      sleep 1
      host_exited "$home" && fail "routine waiting recovery (decision): a decision main had seen woke main again: $(cat "$home/host.out")"
    else
      wait_until_deadline 60 host_exited "$home" \
        || fail "routine waiting recovery (captain): the recovery did not reach main: $(cat "$home/state/.supervision-host.log")"
      assert_re '^check: rearm-resurface$' "$home/host.out" "routine waiting recovery (captain): main must get the recovery close"
      assert_re '	pass-through	attended	main-only	check: rearm-resurface' "$home/state/.supervision-host.log" \
        "routine waiting recovery (captain): the ledger must record the recovery as main's"
      drained=$(main_drain "$home") || fail "main's drain failed: $drained"
      assert_contains "$drained" "BRANCH OUTCOMES (captain outcomes" "routine waiting recovery: main's drain must present the captain outcome"
    fi
    stop_home_processes "$home"
  done
  pass "host: an attended recovery holding a routine row reaches main for an unprocessed captain outcome only"
}

fm_test_run \
  test_attended_recovery_with_nothing_for_main_stays_off_main \
  test_attended_first_park_recovery_without_a_queue_file_stays_off_main \
  test_idle_retirement_acknowledges_only_its_handling_episode \
  test_recovery_offer_leaves_a_blank_queue_record_to_main \
  test_attended_recovery_with_a_held_outcome_lock_reaches_main_within_the_bound \
  test_pending_for_main_query_counts_only_what_main_has_not_seen \
  test_attended_recovery_holding_only_routine_rows_is_handled_on_the_engine \
  test_attended_recovery_reaches_main_only_for_work_main_has_not_seen \
  test_attended_recovery_with_a_routine_row_reaches_main_only_for_unseen_work
