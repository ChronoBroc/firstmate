#!/usr/bin/env bash
# fm-idle-stop.sh: stop idle worker sessions, bring them back on demand.
#
# Hermetic: a stubbed tmux endpoint (the pane's foreground command, its typed
# input, its pane pid) plus REAL process trees for the running-command proof,
# driven through the executables firstmate and the watcher actually call:
#   1. The sweep stops a done worker's idle session through fm-control exit,
#      records the stop, and leaves the window and worktree alone.
#   2. A worker whose agent holds a running shell, whose harness reads busy,
#      or whose inbox holds an unread steer is never stopped.
#   3. A paused worker is stopped only past idle_after and only when the
#      configured memory check reports short; fine memory, no answer, or no
#      check at all keeps it up. The off switch and done=off are honored.
#   4. A secondmate is never stopped.
#   5. Current state reports a stopped worker as its declared state with the
#      stop named, the away spend cap does not count it, and a stale record
#      (agent back) is ignored and then removed.
#   6. A steer to a stopped worker relaunches it: fm-send and the watcher's
#      inbox check start the relaunch instead of escalating, the stale path
#      emits no wake for it, and a refused relaunch is recorded as a wait that
#      is reported once.
#   7. fm-control exit --only-if-idle refuses a busy agent without typing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-idle-stop.sh"
CONTROL="$ROOT/bin/fm-control.sh"
SEND="$ROOT/bin/fm-send.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-idle-stop)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TREE_PIDS=()
cleanup() {
  local p
  for p in "${TREE_PIDS[@]:-}"; do
    [ -n "$p" ] || continue
    pkill -P "$p" 2>/dev/null || true
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# --- fake endpoint ------------------------------------------------------------
# A tmux stub whose state is files under $FM_FAKE_DIR: `command` is the pane's
# foreground process (the agent-state classifier's input), `pane_pid` the root
# of a real process tree, `literal` every typed payload. Typing /exit flips the
# command to a shell, as a harness that exits leaves its pane.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in -t) shift 2 ;; -l) literal=1; shift ;; *) break ;; esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "$D/literal"
      case "${1:-}" in /exit|/quit) printf 'zsh' > "$D/command" ;; esac
    else
      printf '%s\n' "${1:-}" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_pid*) cat "$D/pane_pid" 2>/dev/null; printf '\n'; exit 0 ;;
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│ >  │\n╰────╯\n'; exit 0 ;;
  list-windows) cat "$D/windows" 2>/dev/null; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  # fm-control's bounded waits call sleep; keep them instant.
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  # crew-state asks no-mistakes about a ship; there is never a run here.
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fb/no-mistakes"
}

# A real process tree standing in for the pane: a pane shell whose child is an
# agent process named claude (a bash reached through a symlink of that name),
# optionally holding a shell of its own - the running command under test.
start_tree() {  # <case-dir> idle|running
  local dir=$1 shape=$2 inner
  ln -sf "$(command -v bash)" "$dir/claude"
  case "$shape" in
    idle) inner='/bin/sleep 600; :' ;;
    running) inner='/bin/sh -c "/bin/sleep 600; :"; :' ;;
  esac
  # shellcheck disable=SC2016  # Expanded by the child bash.
  /bin/bash -c '"$1" -c "$2"; :' _ "$dir/claude" "$inner" >/dev/null 2>&1 &
  TREE_PIDS+=("$!")
  printf '%s' "$!" > "$dir/fake/pane_pid"
  # Wait until the tree's leaf sleep is running, three or four levels down.
  local i=0 root=$! frontier kids p depth
  while [ "$i" -lt 50 ]; do
    frontier=$root depth=0
    while [ -n "$frontier" ] && [ "$depth" -lt 5 ]; do
      kids=
      for p in $frontier; do kids="$kids $(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')"; done
      frontier=$(printf '%s' "$kids" | tr -s ' ')
      frontier=${frontier# }
      depth=$((depth + 1))
      if [ -n "$frontier" ] && ps -o comm= -p "$(printf '%s' "$frontier" | tr ' ' ',')" 2>/dev/null | grep -q 'sleep$'; then return 0; fi
    done
    /bin/sleep 0.1
    i=$((i + 1))
  done
}

new_case() {  # <name> -> case dir
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

# add_task <case> <id> <kind> <status-line> [busy-state]
add_task() {
  local dir=$1 id=$2 kind=$3 status=$4 busy=${5:-idle} home="$1/home" wt="$1/wt-$2"
  fm_git_worktree "$dir/proj-$id" "$wt" "task-$id" >/dev/null 2>&1
  mkdir -p "$home/data/$id"
  printf '# brief for %s\n' "$id" > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$dir/proj-$id"
    echo "harness=claude"
    echo "kind=$kind"
    [ "$kind" != ship ] || { echo "mode=no-mistakes"; echo "yolo=off"; }
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  [ -z "$status" ] || printf '%s\n' "$status" > "$home/state/$id.status"
  "$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id" --state "$busy" --source claude-hook --event stop >/dev/null
}

config() {  # <case> <lines...>
  local dir=$1
  shift
  printf '%s\n' "$@" > "$dir/home/config/idle-session-stop"
  chmod 600 "$dir/home/config/idle-session-stop"
}

memory_cmd() {  # <case> <exit-code> -> absolute path of a check exiting that code
  printf '#!/bin/sh\nexit %s\n' "$2" > "$1/memcheck-$2"
  chmod 700 "$1/memcheck-$2"
  printf '%s' "$1/memcheck-$2"
}

run_env() {  # <case> <command...>
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 FM_CONTROL_EXIT_WAIT=0.2 \
    "$@" 2>&1
}

sweep() { run_env "$1" "$SWEEP" sweep; }
check() { run_env "$1" "$SWEEP" check "$2"; }
crew_state() { run_env "$1" env FM_CREW_STATE_NO_FORGE=1 "$CREW_STATE" "$2"; }

# --- 1. a done worker's idle session is stopped -------------------------------

test_done_worker_is_stopped_and_window_kept() {
  local dir out
  dir=$(new_case 'done')
  add_task "$dir" t1 scout "done [at=$(date +%s)]: report written"
  config "$dir" 'done_after=0'
  start_tree "$dir" idle
  out=$(check "$dir" t1)
  assert_equals "eligible done" "$out" "a done idle worker should be eligible"
  sweep "$dir" >/dev/null
  assert_equals "/exit" "$(cat "$dir/fake/literal")" "the sweep must stop it through the harness exit command"
  assert_present "$dir/home/state/t1.session-stopped"
  assert_grep 'reason=done' "$dir/home/state/t1.session-stopped" "the stop record names why"
  assert_present "$dir/wt-t1/README.md"
  assert_present "$dir/home/state/t1.meta"
  out=$(crew_state "$dir" t1)
  assert_contains "$out" "state: done · source: status-log" "a stopped done worker still reads done"
  assert_contains "$out" "session stopped (done and idle)" "current state names the stop"
  pass "sweep: a done worker's idle session exits through fm-control, its window, record and worktree stay, and current state names the stop"
}

test_opt_in_done_after_and_done_off() {
  local dir out
  dir=$(new_case done-after)
  add_task "$dir" t1 scout "done [at=$(date +%s)]: report written"
  start_tree "$dir" idle
  assert_equals "skip idle-session stop is off" "$(check "$dir" t1)" "a home without the config file never stops anything"
  sweep "$dir" >/dev/null
  [ ! -s "$dir/fake/literal" ] || fail "a home that never opted in had a worker stopped: $(cat "$dir/fake/literal")"
  config "$dir" '# opted in with every default'
  out=$(check "$dir" t1)
  case "$out" in "skip idle "*"of 120s") ;; *) fail "a just-finished worker should wait the default done_after, got: $out" ;; esac
  config "$dir" 'done=off' 'done_after=0'
  out=$(check "$dir" t1)
  assert_equals "skip done stopping is off" "$out" "done=off keeps done workers up"
  config "$dir" 'off' 'done_after=0'
  sweep "$dir" >/dev/null
  [ ! -s "$dir/fake/literal" ] || fail "the off switch must stop nothing, typed: $(cat "$dir/fake/literal")"
  pass "sweep: nothing stops without the config file, done_after delays a fresh done, and done=off and off keep sessions up"
}

# --- 2. never a worker that is not idle ----------------------------------------

test_running_command_busy_and_unread_steer_stay_up() {
  local dir out
  dir=$(new_case running)
  add_task "$dir" t1 scout "done [at=$(date +%s)]: report written"
  config "$dir" 'done_after=0'
  start_tree "$dir" running
  out=$(check "$dir" t1)
  case "$out" in "skip agent holds a running command"*) ;; *) fail "a shell under the agent must keep it up, got: $out" ;; esac
  sweep "$dir" >/dev/null
  [ ! -s "$dir/fake/literal" ] || fail "a worker holding a running command was sent: $(cat "$dir/fake/literal")"

  dir=$(new_case busy)
  add_task "$dir" t1 scout "paused [at=$(date +%s)]: waiting on CI inside a foreground wait" busy
  config "$dir" 'idle_after=0' "memory_check=$(memory_cmd "$dir" 1)"
  start_tree "$dir" idle
  out=$(check "$dir" t1)
  case "$out" in "skip harness is not proven idle (busy "*) ;; *) fail "a busy paused worker must stay up, got: $out" ;; esac

  dir=$(new_case steer)
  add_task "$dir" t1 scout "done [at=$(date +%s)]: report written"
  config "$dir" 'done_after=0'
  start_tree "$dir" idle
  mkdir -p "$dir/home/state/t1.inbox/handled"
  printf 'schema=fm-task-inbox.v1\n--\nplease look again\n' > "$dir/home/state/t1.inbox/001.msg"
  out=$(check "$dir" t1)
  assert_equals "skip an unread steer waits in its inbox" "$out" "an unread steer keeps the worker up"
  pass "sweep: a running shell under the agent, a busy harness, or an unread steer keeps the session up"
}

# --- 3. paused and parked workers need short memory ----------------------------

test_paused_needs_short_memory() {
  local dir out
  dir=$(new_case paused)
  add_task "$dir" t1 scout "paused [at=$(date +%s)]: waiting on an external review"
  start_tree "$dir" idle
  config "$dir" 'idle_after=0'
  assert_equals "skip no memory_check configured" "$(check "$dir" t1)" "no memory check never stops a paused worker"
  config "$dir" 'idle_after=0' "memory_check=$(memory_cmd "$dir" 0)"
  assert_equals "skip host memory is fine" "$(check "$dir" t1)" "fine memory keeps it up"
  config "$dir" 'idle_after=0' "memory_check=$(memory_cmd "$dir" 127)"
  out=$(check "$dir" t1)
  case "$out" in "skip memory check: unknown"*) ;; *) fail "a check with no answer must not stop anything, got: $out" ;; esac
  config "$dir" 'idle_after=3600' "memory_check=$(memory_cmd "$dir" 1)"
  out=$(check "$dir" t1)
  case "$out" in "skip idle "*"of 3600s") ;; *) fail "idle_after must hold, got: $out" ;; esac
  config "$dir" 'idle_after=0' "memory_check=$(memory_cmd "$dir" 1)"
  assert_equals "eligible idle-memory" "$(check "$dir" t1)" "short memory past idle_after makes it eligible"
  sweep "$dir" >/dev/null
  assert_equals "/exit" "$(cat "$dir/fake/literal")" "the paused worker is stopped through exit"
  assert_grep 'reason=idle-memory' "$dir/home/state/t1.session-stopped" "the record names memory"
  assert_contains "$(crew_state "$dir" t1)" "state: paused · source: status-log · session stopped (idle while host memory was short)" "it still reads paused"
  pass "sweep: a paused worker stops only past idle_after with memory reported short, never on fine memory or no answer"
}

test_parked_and_secondmate() {
  local dir
  dir=$(new_case parked)
  add_task "$dir" t1 scout "needs-decision [at=$(date +%s)] [key=k1]: pick a layout"
  start_tree "$dir" idle
  config "$dir" 'idle_after=0' "memory_check=$(memory_cmd "$dir" 1)"
  assert_equals "eligible idle-memory" "$(check "$dir" t1)" "a parked worker waits on firstmate's answer, which arrives as a steer"
  dir=$(new_case mate)
  add_task "$dir" t1 secondmate ""
  config "$dir" 'done_after=0' 'idle_after=0' "memory_check=$(memory_cmd "$dir" 1)"
  assert_equals "skip a secondmate is never stopped" "$(check "$dir" t1)" "secondmates are out of scope"
  pass "sweep: a parked worker is eligible under memory pressure, a secondmate never"
}

# --- 5. stale records and the spend cap -----------------------------------------

test_stale_record_ignored_and_removed() {
  local dir out
  dir=$(new_case stale)
  add_task "$dir" t1 scout "done [at=$(date +%s)]: report written"
  config "$dir" 'off'
  start_tree "$dir" idle
  printf 'schema=fm-session-stopped.v1\nat=1\nreason=done\nendpoint=fmses:fm-t1\n' > "$dir/home/state/t1.session-stopped"
  out=$(crew_state "$dir" t1)
  assert_not_contains "$out" "session stopped" "an agent that is back makes the record stale"
  sweep "$dir" >/dev/null
  assert_absent "$dir/home/state/t1.session-stopped"
  pass "a stop record whose agent is back is ignored and removed"
}

test_spend_cap_does_not_count_a_stopped_worker() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-afk-contract.sh"
  if fm_afk_contract_reading_counts "state: unknown · source: status-log · session stopped (done and idle) at 2026-11-13T00:00Z; relaunches on demand; no recognized status declaration"; then
    fail "a stopped worker must not count toward the away spend cap"
  fi
  pass "the away spend cap does not count a stopped worker"
}

# --- 6. relaunch on demand -------------------------------------------------------

stopped_case() {  # <name> -> case dir with t1 stopped
  local dir
  dir=$(new_case "$1")
  add_task "$dir" t1 scout "done [at=$(date +%s)]: report written"
  config "$dir" 'done_after=0'
  start_tree "$dir" idle
  sweep "$dir" >/dev/null
  [ -f "$dir/home/state/t1.session-stopped" ] || fail "setup: t1 was not stopped: $(cat "$dir/home/state/.idle-stop.log" 2>/dev/null)"
  # A control-plane stand-in records each call and answers as told.
  cat > "$dir/control" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_DIR/control-calls"
case "${FM_FAKE_RELAUNCH:-ok}" in
  ok) printf 'claude' > "$FM_FAKE_DIR/command"; echo "relaunched $1"; exit 0 ;;
  cap) echo "deferred: the away spend cap is full" >&2; exit 75 ;;
esac
SH
  chmod +x "$dir/control"
  printf '%s' "$dir"
}

wait_for() {  # <file> <pattern>
  local i=0
  while [ "$i" -lt 100 ]; do
    grep -q -- "$2" "$1" 2>/dev/null && return 0
    /bin/sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_steer_relaunches_a_stopped_worker() {
  local dir out
  dir=$(stopped_case steer-revive)
  out=$(run_env "$dir" env FM_IDLE_STOP_CONTROL="$dir/control" "$SEND" t1 'please add the missing section')
  assert_contains "$out" "session was stopped while idle; it is being relaunched" "fm-send says the worker is coming back"
  wait_for "$dir/fake/control-calls" 'relaunch --note-file' || fail "the steer did not relaunch the worker"
  assert_present "$dir/home/state/t1.inbox/001.msg"
  i=0
  while [ -e "$dir/home/state/t1.session-stopped" ] && [ "$i" -lt 50 ]; do /bin/sleep 0.1; i=$((i + 1)); done
  assert_absent "$dir/home/state/t1.session-stopped"
  pass "fm-send: a steer to a stopped worker is recorded and relaunches it"
}

test_typed_command_to_stopped_worker_refused() {
  local dir out rc=0
  dir=$(stopped_case typed)
  : > "$dir/fake/literal"
  out=$(run_env "$dir" "$SEND" t1 '/compact') || rc=$?
  [ "$rc" -ne 0 ] || fail "a typed command to a stopped worker must be refused"
  assert_contains "$out" "stopped while idle" "the refusal names why"
  [ ! -s "$dir/fake/literal" ] || fail "a typed command reached the bare shell: $(cat "$dir/fake/literal")"
  pass "fm-send: a typed harness command to a stopped worker is refused, never typed into its shell"
}

test_watcher_inbox_relaunches_without_wake() {
  local dir
  dir=$(stopped_case watch-revive)
  mkdir -p "$dir/home/state/t1.inbox/handled"
  printf 'schema=fm-task-inbox.v1\nat=x\n--\nplease look again\n' > "$dir/home/state/t1.inbox/001.msg"
  # shellcheck disable=SC2016  # Expanded by the child bash.
  run_env "$dir" env FM_IDLE_STOP_CONTROL="$dir/control" \
    bash -c '. "$1" && inbox_steer_check fmses:fm-t1 t1' _ "$WATCH" >/dev/null
  wait_for "$dir/fake/control-calls" 'relaunch' || fail "the watcher's inbox check did not relaunch the stopped worker"
  [ ! -s "$dir/home/state/.wake-queue" ] || fail "a steer to a stopped worker woke firstmate: $(cat "$dir/home/state/.wake-queue")"
  pass "watcher: a steer waiting for a stopped worker relaunches it without escalating"
}

test_refused_relaunch_is_a_wait_reported_once() {
  local dir rc=0 out
  dir=$(stopped_case refused)
  out=$(run_env "$dir" env FM_IDLE_STOP_CONTROL="$dir/control" FM_FAKE_RELAUNCH=cap "$SWEEP" revive t1) || rc=$?
  expect_code 75 "$rc" "a refused relaunch is a wait: $out"
  assert_present "$dir/home/state/t1.session-stopped"
  assert_grep 'surfaced=0' "$dir/home/state/t1.session-revive" "the refusal is waiting to be reported"
  assert_grep 'spend cap' "$dir/home/state/t1.session-revive" "the notice keeps the refusal's words"
  # shellcheck disable=SC2016  # Expanded by the child bash.
  out=$(run_env "$dir" bash -c '. "$1"; wake() { printf "WAKE %s\n" "$1"; exit 0; }; idle_stop_notice_surface; echo no-wake' _ "$WATCH")
  assert_contains "$out" "WAKE check: idle-stop: t1 relaunch waits: deferred: the away spend cap is full" "the refusal is reported"
  # shellcheck disable=SC2016  # Expanded by the child bash.
  out=$(run_env "$dir" bash -c '. "$1"; wake() { printf "WAKE %s\n" "$1"; exit 0; }; idle_stop_notice_surface; echo no-wake' _ "$WATCH")
  assert_equals "no-wake" "$out" "one refusal is reported once"
  run_env "$dir" env FM_IDLE_STOP_CONTROL="$dir/control" FM_FAKE_RELAUNCH=cap "$SWEEP" revive t1 >/dev/null
  assert_grep 'surfaced=1' "$dir/home/state/t1.session-revive" "the same refusal again stays reported"
  pass "revive: a refused relaunch keeps the record and steer, is recorded as a wait, and is reported once"
}

test_stale_path_skips_a_stopped_worker() {
  local dir
  dir=$(stopped_case stale-skip)
  # shellcheck disable=SC2016  # Expanded by the child bash.
  run_env "$dir" bash -c '. "$1"; idle_stop_session_stopped t1' _ "$WATCH" >/dev/null \
    || fail "the watcher must read t1 as stopped"
  printf 'claude' > "$dir/fake/command"
  # shellcheck disable=SC2016  # Expanded by the child bash.
  if run_env "$dir" bash -c '. "$1"; idle_stop_session_stopped t1' _ "$WATCH" >/dev/null; then
    fail "an agent that came back must not read as stopped"
  fi
  pass "watcher: a stopped worker reads as stopped only while its pane holds no agent"
}

# --- 7. exit --only-if-idle -------------------------------------------------------

test_exit_only_if_idle_refuses_busy() {
  local dir rc=0 out
  dir=$(new_case only-idle)
  add_task "$dir" t1 scout "" busy
  out=$(run_env "$dir" "$CONTROL" t1 exit --only-if-idle) || rc=$?
  expect_code 75 "$rc" "a busy agent must be deferred: $out"
  assert_contains "$out" "deferred:" "the refusal is a deferral"
  [ ! -s "$dir/fake/literal" ] && [ ! -s "$dir/fake/keys" ] \
    || fail "--only-if-idle sent input to a busy agent: $(cat "$dir/fake/literal" "$dir/fake/keys")"
  pass "fm-control exit --only-if-idle defers a busy agent with nothing sent"
}

test_done_worker_is_stopped_and_window_kept
test_opt_in_done_after_and_done_off
test_running_command_busy_and_unread_steer_stay_up
test_paused_needs_short_memory
test_parked_and_secondmate
test_stale_record_ignored_and_removed
test_spend_cap_does_not_count_a_stopped_worker
test_steer_relaunches_a_stopped_worker
test_typed_command_to_stopped_worker_refused
test_watcher_inbox_relaunches_without_wake
test_refused_relaunch_is_a_wait_reported_once
test_stale_path_skips_a_stopped_worker
test_exit_only_if_idle_refuses_busy
