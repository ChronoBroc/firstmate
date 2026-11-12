#!/usr/bin/env bash
# Token-free installed Claude Code guard for the busy-state hooks fm-spawn writes.
#
# A Claude worker in one long healthy turn posts no UserPromptSubmit or Stop
# between its tool calls, so the watcher's busy-turn bound would age it from the
# turn's start and wedge-escalate it. The PreToolUse hook bin/fm-spawn.sh writes
# is the mid-turn signal that prevents that: it refreshes the task's native
# progress marker (bin/fm-busy-event.sh progress) without changing busy state.
# Whether Claude Code actually fires that hook inside a turn is vendor behavior,
# so only the real binary can prove it.
#
# The guard runs the real fm-spawn (behind a fake tmux) to write the worker's
# .claude/settings.local.json, then runs the installed `claude -p` in that
# worktree against tests/fixtures/fm-claude-tool-call-stub.py, a local stand-in
# for the API that asks for one Bash tool call and then ends the turn, so no
# model is called and no tokens are spent. The tool call itself snapshots the
# busy record and the progress marker, which shows PreToolUse refreshed progress
# while the turn was still busy; Stop must then close the turn.
#
# The launch gets a clean environment, a private config directory and a
# synthetic API key, so it needs no Claude Code login and reaches no endpoint but
# the stub. Enabled by default wherever claude, python3 and jq are installed;
# FM_CLAUDE_BUSY_PROGRESS_LIVE=1 makes an absent tool or a claude that never
# reaches the tool call a failure, and =0 skips.
set -eu

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_CLAUDE_BUSY_PROGRESS_LIVE claude python3 jq

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-busy-progress)
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
STUB_PID=''
stop_stub() {
  [ -z "$STUB_PID" ] || kill "$STUB_PID" 2>/dev/null || true
  STUB_PID=''
}
# lib.sh's own EXIT trap is fm_test_cleanup; this one replaces it, so it must run it too.
trap 'stop_stub; fm_test_cleanup' EXIT

# unusable <reason>: skip when the host cannot run the check, fail when it was requested.
unusable() {
  if [ "${FM_CLAUDE_BUSY_PROGRESS_LIVE:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
    fail "$1"
  fi
  printf 'skip: live: %s\n' "$1"
  exit 0
}

ID=busy-progress-live
H="$TMP_ROOT/home"
PROJ="$TMP_ROOT/project"
WT="$TMP_ROOT/wt"
STATE="$H/state"
SNAP="$TMP_ROOT/tool-snapshot"
fm_test_spawn_home "$H" claude
fm_git_worktree "$PROJ" "$WT" busy-progress-live
fm_test_spawn_brief "$H" "$ID"
FAKEBIN=$(make_spawn_fakebin "$TMP_ROOT/fake" claude)
out=$(fm_test_run_spawn "$H" "$WT" "$FAKEBIN" "$ID" "$PROJ" --mode no-mistakes --yolo off 2>&1) \
  || fail "fm-spawn could not write the claude worker hooks: $out"
SETTINGS="$WT/.claude/settings.local.json"
[ -f "$SETTINGS" ] || fail "fm-spawn wrote no $SETTINGS"
rm -f "$STATE/$ID.progress" "$STATE/$ID.turn-ended"

python3 "$ROOT/tests/fixtures/fm-claude-tool-call-stub.py" "$TMP_ROOT/port" \
  "{ cat '$STATE/$ID.busy-state'; if [ -e '$STATE/$ID.progress' ]; then echo progress=present; else echo progress=absent; fi; } > '$SNAP'" &
STUB_PID=$!
for _ in $(seq 1 50); do
  [ -s "$TMP_ROOT/port" ] && break
  sleep 0.1
done
[ -s "$TMP_ROOT/port" ] || fail "the API stub did not start"
port=$(cat "$TMP_ROOT/port")
(
  cd "$WT" || exit 1
  fm_run_timed 60 env -i PATH="$PATH" HOME="$TMP_ROOT/user-home" TERM=dumb \
    CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-config" \
    ANTHROPIC_API_KEY=sk-ant-synthetic-stub-only \
    ANTHROPIC_BASE_URL="http://127.0.0.1:$port" \
    DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    claude -p "run the check" --max-turns 3 --dangerously-skip-permissions \
    </dev/null >"$TMP_ROOT/claude.out" 2>&1 || true
)
stop_stub

[ -s "$SNAP" ] || unusable "claude $CLAUDE_VERSION never ran the stub's tool call: $(tail -5 "$TMP_ROOT/claude.out")"
grep -q 'state=busy source=claude-hook event=user-prompt-submit' "$SNAP" \
  || fail "claude $CLAUDE_VERSION did not open the turn through UserPromptSubmit before its tool call: $(cat "$SNAP")"
grep -qx 'progress=present' "$SNAP" \
  || fail "claude $CLAUDE_VERSION ran a tool call without firing the PreToolUse progress hook"
[ -f "$STATE/$ID.turn-ended" ] || fail "claude $CLAUDE_VERSION ended the turn without the Stop notification"
verdict=$(fm_busy_classify tmux fake:w claude "$ID" "$STATE")
[ "$verdict" = "idle claude-hook" ] || fail "claude $CLAUDE_VERSION did not close the turn through Stop, got '$verdict'"
pass "Claude Code $CLAUDE_VERSION: a tool call inside a busy turn refreshes native progress, and Stop still closes the turn"
