#!/usr/bin/env bash
# tests/fm-idle-stop-live-e2e.test.sh - the idle-session stop, end to end, on
# real Claude Code sessions (live-harness-optin family, token-free).
#
# Whether a worker's session is idle, holding a running command, or gone is a
# harness-dependent verdict: it comes from the real binary's hooks, its process
# tree, and how its pane looks once /exit ends it. So this guard runs the real
# path in a scratch firstmate home on a PRIVATE tmux server (an explicit -S
# socket in the lab directory; the user's own server is never addressed):
# bin/fm-spawn.sh launches real interactive `claude` scouts against
# tests/fixtures/fm-claude-scripted-stub.py, a local stand-in for the API that
# plays each worker from its own brief, so no model is called and no tokens are
# spent. The real watcher then supervises the home, with its idle-stop sweep on
# a short cadence and a memory check the test switches between fine and short.
# It proves:
#   - a done worker's session exits, and its window and worktree remain;
#   - a paused idle worker exits only once the memory check reports short, and
#     stays up while it reports fine;
#   - a paused worker waiting inside a foreground command stays up, and so does
#     one whose turn ended over a background job;
#   - a steer to a stopped worker relaunches it in the same window and worktree,
#     and the relaunched worker reads the steer and acknowledges it;
#   - the watcher raises no stale, wedge, or dead-worker wake for a stopped one.
#
# Default-on wherever claude, python3, git, and tmux are installed, because it
# spends no tokens; FM_IDLE_STOP_LIVE=1 makes an absent tool a failure, and =0
# skips. FM_IDLE_STOP_LIVE_KEEP=1 keeps the lab directory for inspection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_IDLE_STOP_LIVE claude python3 git tmux
unset NO_MISTAKES_GATE TMUX_PANE

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-idle-live.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
SOCK="$LAB/tmux.sock"
REAL_TMUX=$(command -v tmux)
H="$LAB/home"
STATE="$H/state"
PROJ="$LAB/project"
CFG="$LAB/claude-config"
STUB_PID=
WATCH_PID=
note() { printf '# %s\n' "$1"; }

kill_tree() {  # <pid>
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done
  kill "$1" 2>/dev/null || true
}

cleanup() {
  [ -z "$WATCH_PID" ] || kill_tree "$WATCH_PID"
  [ -z "$STUB_PID" ] || kill "$STUB_PID" 2>/dev/null || true
  "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null || true
  if [ "${FM_IDLE_STOP_LIVE_KEEP:-}" = 1 ]; then
    printf '# lab kept at %s\n' "$LAB"
  else
    fm_test_remove_tree "$LAB"
  fi
}
trap cleanup EXIT

die_with() {  # <message>
  local w
  {
    printf '%s\n' "--- stub log"; cat "$LAB/stub.log" 2>/dev/null | tail -20
    printf '%s\n' "--- idle-stop log"; cat "$STATE/.idle-stop.log" 2>/dev/null | tail -20
    printf '%s\n' "--- watcher reasons"; cat "$LAB/reasons" 2>/dev/null
    for w in $("$REAL_TMUX" -S "$SOCK" list-windows -t fmlab -F '#{window_name}' 2>/dev/null); do
      printf -- '--- pane %s\n' "$w"
      "$REAL_TMUX" -S "$SOCK" capture-pane -p -t "fmlab:$w" 2>/dev/null | grep -v '^$' | tail -8
    done
  } >&2
  fail "claude $CLAUDE_VERSION: $1"
}

# Every bare `tmux` any firstmate script runs reaches the private server only.
FAKEBIN="$LAB/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -S "$SOCK" "\$@"
SH
# treehouse get: enter the next prepared worktree in a subshell, as the real
# one does; every other subcommand is a no-op here.
cat > "$FAKEBIN/treehouse" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  get)
    for wt in "$LAB"/wt-*; do
      [ -e "\$wt/.claimed" ] && continue
      : > "\$wt/.claimed"
      cd "\$wt" && exec /bin/bash --norc -i
    done
    exit 1 ;;
esac
exit 0
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 1
SH
# The host memory signal the test controls: exit 0 = fine, 1 = short.
cat > "$LAB/memory-check" <<SH
#!/bin/sh
[ "\$(cat "$LAB/memory")" = fine ]
SH
chmod 700 "$FAKEBIN/tmux" "$FAKEBIN/treehouse" "$FAKEBIN/no-mistakes" "$LAB/memory-check"
printf 'fine' > "$LAB/memory"

# The project, its origin, and one prepared worktree per worker. The
# worktree's ignore file keeps the claim marker out of every git status read.
fm_git_init_commit "$PROJ" >/dev/null
fm_git_add_origin "$PROJ" "$LAB/origin.git"
IDS="w-done w-paused w-busy w-bg"
for id in $IDS; do
  git -C "$PROJ" worktree add --quiet -b "lab-$id" "$LAB/wt-$id" >/dev/null 2>&1 \
    || fail "could not prepare a worktree for $id"
  printf '.claimed\n' >> "$(git -C "$LAB/wt-$id" rev-parse --git-path info)/exclude" 2>/dev/null \
    || { mkdir -p "$(git -C "$LAB/wt-$id" rev-parse --git-common-dir)/info"; printf '.claimed\n' >> "$(git -C "$LAB/wt-$id" rev-parse --git-common-dir)/info/exclude"; }
done

# The scratch home.
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects"
printf 'claude\n' > "$H/config/crew-harness"
printf '%s\n' 'done_after=0' 'idle_after=0' "memory_check=$LAB/memory-check" > "$H/config/idle-session-stop"
chmod 600 "$H/config/idle-session-stop"
brief() {  # <id> <stub lines...>
  local id=$1
  shift
  mkdir -p "$H/data/$id"
  {
    printf '# Task\n## Captain'"'"'s intent\nPlay the %s worker for the idle-stop guard.\n\n' "$id"
    printf '## Firstmate spec\nFollow the scripted steps.\n\n'
    printf '%s\n' "$@"
  } > "$H/data/$id/brief.md"
}
brief w-done "STUB-RUN: echo \"done [at=\$(date +%s)]: report written\" >> '$STATE/w-done.status'"
brief w-paused "STUB-RUN: echo \"paused [at=\$(date +%s)]: waiting on an external review\" >> '$STATE/w-paused.status'"
brief w-busy "STUB-RUN: echo \"paused [at=\$(date +%s)]: waiting inside a CI wait\" >> '$STATE/w-busy.status'; /bin/sleep 1800"
brief w-bg "STUB-RUN: echo \"paused [at=\$(date +%s)]: waiting on my background job\" >> '$STATE/w-bg.status'" \
  "STUB-BG: /bin/sleep 1800"

# Claude Code's own first-run screens are answered in its private config dir.
mkdir -p "$CFG"
KEY=sk-ant-synthetic-idle-stop-stub-only-0000
printf '{"hasCompletedOnboarding":true,"bypassPermissionsModeAccepted":true,"theme":"dark","customApiKeyResponses":{"approved":["%s"],"rejected":[]}}\n' \
  "${KEY: -20}" > "$CFG/.claude.json"

python3 "$ROOT/tests/fixtures/fm-claude-scripted-stub.py" "$LAB/port" "$LAB/stub.log" &
STUB_PID=$!
for _ in $(seq 1 50); do [ -s "$LAB/port" ] && break; sleep 0.1; done
[ -s "$LAB/port" ] || fail "the API stub did not start"

# The private server's panes inherit this environment, so every worker reaches
# the stub, uses the private config, and finds the fake treehouse.
env -u TMUX PATH="$FAKEBIN:$PATH" HOME="$LAB/user-home" CLAUDE_CONFIG_DIR="$CFG" \
  ANTHROPIC_API_KEY="$KEY" ANTHROPIC_BASE_URL="http://127.0.0.1:$(cat "$LAB/port")" \
  DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  "$REAL_TMUX" -S "$SOCK" new-session -d -s fmlab -x 200 -y 50 -c "$LAB"
mkdir -p "$LAB/user-home"
SERVER_PID=$("$REAL_TMUX" -S "$SOCK" display-message -p -t fmlab '#{pid}')
SESSION_ID=$("$REAL_TMUX" -S "$SOCK" display-message -p -t fmlab '#{session_id}')

fm() {  # <command...>: run a firstmate command against the scratch home
  env PATH="$FAKEBIN:$PATH" HOME="$LAB/user-home" FM_HOME="$H" FM_ROOT_OVERRIDE='' \
    TMUX="$SOCK,$SERVER_PID,${SESSION_ID#\$}" CLAUDE_CONFIG_DIR="$CFG" \
    FM_SPAWN_NO_GUARD=1 FM_IDLE_STOP_INTERVAL=3 FM_POLL=2 FM_STALE_ESCALATE_SECS=20 \
    "$@"
}

wait_until() {  # <seconds> <description> <command...>
  local limit=$1 what=$2 i=0
  shift 2
  while ! "$@" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le "$limit" ] || die_with "timed out waiting for $what"
    sleep 1
  done
}

status_has() { grep -q "$2" "$STATE/$1.status" 2>/dev/null; }
busy_is() { grep -q "state=$2 " "$STATE/$1.busy-state" 2>/dev/null; }
handled_any() { [ -n "$(ls "$STATE/$1.inbox/handled/" 2>/dev/null)" ]; }
# shellcheck disable=SC2016  # Expanded by the child bash.
agent_state() { fm bash -c '. "$1/bin/fm-backend.sh"; m="$2/$3.meta"; fm_backend_agent_state tmux "$(fm_backend_target_of_meta "$m")" "$m"' _ "$ROOT" "$STATE" "$1"; }
agent_is() { [ "$(agent_state "$1")" = "$2" ]; }
stopped() { [ -f "$STATE/$1.session-stopped" ] && agent_is "$1" dead; }

# --- launch the four workers through the real spawn path ----------------------
for id in $IDS; do
  out=$(fm "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" --scout --harness claude 2>&1) \
    || die_with "fm-spawn could not launch $id: $out"
done
wait_until 120 "the done worker's done status" status_has w-done '^done'
wait_until 120 "the paused worker's pause" status_has w-paused '^paused'
wait_until 120 "the busy worker's pause" status_has w-busy '^paused'
wait_until 120 "the background worker's pause" status_has w-bg '^paused'
wait_until 60 "the done worker's turn to end" busy_is w-done idle
wait_until 60 "the paused worker's turn to end" busy_is w-paused idle
wait_until 60 "the background worker's turn to end" busy_is w-bg idle
busy_is w-busy busy || die_with "the worker inside a foreground wait does not read busy"
note "four claude $CLAUDE_VERSION workers launched and settled"

meta_field() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$STATE/$1.meta"; }
WT_DONE=$(meta_field w-done worktree)
WIN_DONE=$(meta_field w-done window)

# --- supervise with the real watcher ------------------------------------------
# Run the watcher the way the supervision loop does: one cycle until a wake,
# record its reason, drain and acknowledge, start the next cycle.
supervise() {
  local out ack
  : > "$LAB/reasons"
  while :; do
    out=$(fm "$ROOT/bin/fm-watch.sh" 2>/dev/null | tail -n 5)
    printf '%s\n' "$out" | sed "s/^/$(date +%s) /" >> "$LAB/reasons"
    ack=$(fm "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null | sed -n 's/^WAKE_ACK_REQUIRED: //p' | tail -n 1)
    [ -z "$ack" ] || fm bash -c "$ack" >/dev/null 2>&1 || true
    [ -e "$LAB/stop-supervising" ] && break
    sleep 1
  done
}
supervise &
WATCH_PID=$!

# A done worker's session exits; its window and worktree stay.
wait_until 90 "the done worker's session to stop" stopped w-done
T_DONE_STOP=$(date +%s)
agent_is w-done dead || die_with "the done worker's record stands but its agent reads $(agent_state w-done)"
"$REAL_TMUX" -S "$SOCK" list-windows -t fmlab -F '#{window_name}' | grep -qx fm-w-done \
  || die_with "the done worker's window is gone"
[ -d "$WT_DONE" ] && [ -f "$WT_DONE/README.md" ] || die_with "the done worker's worktree is gone"
fm "$ROOT/bin/fm-crew-state.sh" w-done | grep -q 'state: done .*session stopped (done and idle)' \
  || die_with "current state does not name the stop: $(fm "$ROOT/bin/fm-crew-state.sh" w-done)"
pass "claude $CLAUDE_VERSION: a done worker's session exits through fm-control, its window and worktree stay"

# Memory fine: the paused workers stay up through several sweeps.
sleep 12
agent_is w-paused alive || die_with "the paused worker stopped while memory was fine"
! stopped w-paused || die_with "the paused worker was recorded stopped while memory was fine"
pass "claude $CLAUDE_VERSION: a paused idle worker stays up while the memory check reports fine"

# Memory short: the idle paused worker exits, the busy and background ones stay.
printf 'short' > "$LAB/memory"
wait_until 90 "the paused worker's session to stop" stopped w-paused
T_PAUSED_STOP=$(date +%s)
agent_is w-paused dead || die_with "the paused worker's record stands but its agent reads $(agent_state w-paused)"
sleep 12
if ! agent_is w-busy alive || stopped w-busy; then die_with "the worker inside a foreground wait was stopped"; fi
if ! agent_is w-bg alive || stopped w-bg; then die_with "the worker holding a background job was stopped"; fi
# Each stayed up for its own reason, not by luck of timing.
verdict=$(fm "$ROOT/bin/fm-idle-stop.sh" check w-busy)
case "$verdict" in "skip harness is not proven idle (busy "*) ;; *) die_with "the foreground-wait worker's verdict is '$verdict'" ;; esac
verdict=$(fm "$ROOT/bin/fm-idle-stop.sh" check w-bg)
case "$verdict" in "skip agent holds a running command"*) ;; *) die_with "the background-job worker's verdict is '$verdict'" ;; esac
pass "claude $CLAUDE_VERSION: short memory stops the idle paused worker, never the one in a foreground wait or holding a background job"

# A steer relaunches the stopped done worker, which reads it. A long
# done_after keeps the sweep from stopping it again while this is checked.
printf '%s\n' 'done_after=3600' 'idle_after=0' "memory_check=$LAB/memory-check" > "$H/config/idle-session-stop"
T_STEER=$(date +%s)
out=$(fm "$ROOT/bin/fm-send.sh" w-done 'Please add one more section to the report.' 2>&1) \
  || die_with "fm-send failed: $out"
case "$out" in *"stopped while idle"*) ;; *) die_with "fm-send did not say the worker is coming back: $out" ;; esac
wait_until 120 "the relaunched worker to read its steer" test -s "$STATE/w-done.inbox.read"
grep -q 'one more section' "$STATE/w-done.inbox.read" || die_with "the relaunched worker read something else"
wait_until 30 "the steer's acknowledgement" handled_any w-done
if [ -e "$STATE/w-done.session-stopped" ] || ! agent_is w-done alive; then
  die_with "the relaunched worker is not running, or still has its stop record"
fi
[ "$(meta_field w-done window)" = "$WIN_DONE" ] \
  || die_with "the relaunch moved the worker to another window"
[ "$(meta_field w-done worktree)" = "$WT_DONE" ] \
  || die_with "the relaunch moved the worker to another worktree"
pass "claude $CLAUDE_VERSION: a steer relaunches a stopped worker in its window and worktree, and it reads and acknowledges the steer"

# Let a few more watcher cycles run over the stopped paused worker, then stop.
sleep 15
: > "$LAB/stop-supervising"
kill_tree "$WATCH_PID"
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=

# While stopped: w-done from its stop to its steer, w-paused from its stop on.
if awk -v d0="$T_DONE_STOP" -v d1="$T_STEER" -v p0="$T_PAUSED_STOP" '
    $2 ~ /^stale:/ && (($0 ~ /fm-w-done/ && $1 >= d0 && $1 < d1) || ($0 ~ /fm-w-paused/ && $1 >= p0)) { print; bad = 1 }
    END { exit !bad }' "$LAB/reasons"; then
  die_with "the watcher raised a stale wake for a stopped worker"
fi
pass "claude $CLAUDE_VERSION: the watcher raised no stale or dead-worker wake for a stopped worker"

# Cleanup treats a stopped worker as any other: a finished scout tears down.
stopped w-paused || die_with "the paused worker is no longer stopped before its cleanup"
printf '# report\n' > "$H/data/w-paused/report.md"
out=$(fm "$ROOT/bin/fm-captain-hold.sh" complete w-paused --none 2>&1) \
  || die_with "the scout's captain-call inventory could not be recorded: $out"
out=$(fm "$ROOT/bin/fm-teardown.sh" w-paused 2>&1) || die_with "teardown of a stopped scout failed: $out"
[ ! -e "$STATE/w-paused.meta" ] && [ ! -e "$STATE/w-paused.session-stopped" ] \
  || die_with "teardown left the stopped scout's records: $(printf '%s ' "$STATE"/w-paused.*)"
! "$REAL_TMUX" -S "$SOCK" list-windows -t fmlab -F '#{window_name}' | grep -qx fm-w-paused \
  || die_with "teardown left the stopped scout's window"
pass "claude $CLAUDE_VERSION: cleanup of a stopped scout runs as for any finished scout and removes its stop record"
