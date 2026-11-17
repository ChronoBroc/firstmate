#!/usr/bin/env bash
# Token-free installed Claude Code guard for the mid-turn board-answer handoff.
#
# A review-board answer that reaches a Claude worker's steering inbox while the
# worker is in the middle of a turn is handed to it at its next step by the
# PostToolUse hook bin/fm-spawn.sh writes (bin/fm-board-receipt-hook.sh;
# bin/fm-board-receipt-lib.sh "Mid-turn handoff"). Whether Claude Code runs that
# hook after a tool call and puts its additionalContext in front of the model is
# vendor behavior, so only the real binary can prove it.
#
# The guard runs the real fm-spawn (behind a fake tmux) to write the worker's
# .claude/settings.local.json, records one board round as delivered to that
# worker, then runs the installed `claude -p` in the worktree against
# tests/fixtures/fm-claude-tool-call-stub.py, a local stand-in for the API that
# asks for one Bash tool call, captures the request Claude Code sends after it,
# and then ends the turn, so no model is called and no tokens are spent. The
# captured request must carry the round's instruction.
#
# The launch gets a clean environment, a private config directory and a
# synthetic API key, so it needs no Claude Code login and reaches no endpoint but
# the stub. Enabled by default wherever claude, python3 and jq are installed;
# FM_CLAUDE_BOARD_HANDOFF_LIVE=1 makes an absent tool or a claude that never
# reaches the tool call a failure, and =0 skips.
set -eu

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_CLAUDE_BOARD_HANDOFF_LIVE claude python3 jq

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-board-handoff)
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
  if [ "${FM_CLAUDE_BOARD_HANDOFF_LIVE:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
    fail "$1"
  fi
  printf 'skip: live: %s\n' "$1"
  exit 0
}

ID=board-handoff-live
SRC=lavish-0123456789abcdef
H="$TMP_ROOT/home"
PROJ="$TMP_ROOT/project"
WT="$TMP_ROOT/wt"
STATE="$H/state"
CAPTURE="$TMP_ROOT/after-tool-call.jsonl"
fm_test_spawn_home "$H" claude
fm_git_worktree "$PROJ" "$WT" board-handoff-live
fm_test_spawn_brief "$H" "$ID"
FAKEBIN=$(make_spawn_fakebin "$TMP_ROOT/fake" claude)
out=$(fm_test_run_spawn "$H" "$WT" "$FAKEBIN" "$ID" "$PROJ" --mode no-mistakes --yolo off 2>&1) \
  || fail "fm-spawn could not write the claude worker hooks: $out"
SETTINGS="$WT/.claude/settings.local.json"
[ -f "$SETTINGS" ] || fail "fm-spawn wrote no $SETTINGS"

# One answered round delivered to the worker, as the runner records it.
FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" bash -c '
  set -e
  . "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-procevent-lib.sh"
  . "$1/bin/fm-task-inbox-lib.sh"; . "$1/bin/fm-board-receipt-lib.sh"
  record=$(fm_task_inbox_write "$2" "$3" "Lavish review feedback is captured for task $3 at $2/procevent-inbox/$4.1.result. Read it with bin/fm-procevent-lavish.sh read $2/procevent-inbox/$4.1.result, apply the round, and re-arm the board with the reply.")
  fm_board_receipt_delivered "$2" "$4" 1 "$3" feedback "$record"
' _ "$ROOT" "$STATE" "$ID" "$SRC" || fail "the board round could not be recorded as delivered"

python3 "$ROOT/tests/fixtures/fm-claude-tool-call-stub.py" "$TMP_ROOT/port" true "$CAPTURE" &
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

[ -s "$CAPTURE" ] || unusable "claude $CLAUDE_VERSION never ran the stub's tool call: $(tail -5 "$TMP_ROOT/claude.out")"
[ -f "$STATE/board-receipts/$SRC.1.midturn" ] \
  || fail "claude $CLAUDE_VERSION ran a tool call without running the PostToolUse handoff hook"
grep -q 'A review-board answer reached your steering inbox as 001.msg' "$CAPTURE" \
  || fail "claude $CLAUDE_VERSION ran the handoff hook but did not put its additionalContext in front of the model"
grep -q "bin/fm-procevent-lavish.sh read $STATE/procevent-inbox/$SRC.1.result" "$CAPTURE" \
  || fail "claude $CLAUDE_VERSION delivered the handoff without the round's instruction"
pass "Claude Code $CLAUDE_VERSION: a board answer waiting on a busy worker reaches the model after its next tool call"
