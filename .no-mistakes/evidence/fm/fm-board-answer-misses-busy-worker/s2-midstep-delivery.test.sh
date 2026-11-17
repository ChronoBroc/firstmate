#!/usr/bin/env bash
# Variant of tests/fm-claude-board-answer-handoff-live.test.sh: the board round is
# delivered WHILE the real claude worker is inside a long (8s) tool call, i.e. mid-turn,
# then the hook must hand it over at that step's end; a second unrelated task gets nothing.
set -eu
ROOT=$1
. "$ROOT/tests/fixtures.sh"
. "$ROOT/bin/fm-timeout-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-s2-midstep)
STUB_PID=''
trap '[ -z "$STUB_PID" ] || kill "$STUB_PID" 2>/dev/null; fm_test_cleanup' EXIT
ID=board-midstep
SRC=lavish-fedcba9876543210
H="$TMP_ROOT/home"; PROJ="$TMP_ROOT/project"; WT="$TMP_ROOT/wt"; STATE="$H/state"
CAPTURE="$TMP_ROOT/after-tool-call.jsonl"
fm_test_spawn_home "$H" claude
fm_git_worktree "$PROJ" "$WT" board-midstep
fm_test_spawn_brief "$H" "$ID"
FAKEBIN=$(make_spawn_fakebin "$TMP_ROOT/fake" claude)
fm_test_run_spawn "$H" "$WT" "$FAKEBIN" "$ID" "$PROJ" --mode no-mistakes --yolo off >/dev/null 2>&1 || fail spawn
echo "--- PostToolUse hook fm-spawn installed:"; jq '.hooks.PostToolUse' "$WT/.claude/settings.local.json"
python3 "$ROOT/tests/fixtures/fm-claude-tool-call-stub.py" "$TMP_ROOT/port" "python3 -c 'import time; time.sleep(8)'; echo step-done" "$CAPTURE" &
STUB_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP_ROOT/port" ] && break; sleep 0.1; done
port=$(cat "$TMP_ROOT/port")
( cd "$WT"; fm_run_timed 90 env -i PATH="$PATH" HOME="$TMP_ROOT/user-home" TERM=dumb \
    CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-config" ANTHROPIC_API_KEY=sk-ant-synthetic-stub-only \
    ANTHROPIC_BASE_URL="http://127.0.0.1:$port" DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    claude -p "run the check" --max-turns 3 --dangerously-skip-permissions </dev/null >"$TMP_ROOT/claude.out" 2>&1 ) &
CL=$!
# wait until the tool call is actually running (sleep 8 child exists under claude)
for _ in $(seq 1 300); do [ -e "$STATE/$ID.progress" ] && break; sleep 0.1; done
[ -e "$STATE/$ID.progress" ] || fail "tool call never started (no PreToolUse progress marker): $(cat $TMP_ROOT/claude.out 2>/dev/null)"
sleep 1; echo "tool call started (PreToolUse progress marker present); claude processes: $(pgrep -f "claude -p" | wc -l)"
echo "--- $(date +%T) worker is inside its tool call; captain answers the board now"
FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" bash -c '
  set -e
  . "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-procevent-lib.sh"
  . "$1/bin/fm-task-inbox-lib.sh"; . "$1/bin/fm-board-receipt-lib.sh"
  record=$(fm_task_inbox_write "$2" "$3" "Lavish review feedback is captured for task $3 at $2/procevent-inbox/$4.1.result. Read it with bin/fm-procevent-lavish.sh read $2/procevent-inbox/$4.1.result, apply the round, and re-arm the board with the reply.")
  fm_board_receipt_delivered "$2" "$4" 1 "$3" feedback "$record"
' _ "$ROOT" "$STATE" "$ID" "$SRC"
[ ! -e "$STATE/board-receipts/$SRC.1.midturn" ] || fail "handed before step ended"
echo "--- receipt while step still running:"; cat "$STATE/board-receipts/$SRC.1.receipt"
wait $CL || true
kill $STUB_PID; STUB_PID=''
echo "--- $(date +%T) claude finished"
[ -s "$CAPTURE" ] || fail "no post-tool request captured: $(tail -5 "$TMP_ROOT/claude.out")"
echo "--- midturn marker:"; cat "$STATE/board-receipts/$SRC.1.midturn"
echo "--- text Claude Code sent the model after the tool call (non-tool_result parts of last user turn):"
tail -1 "$CAPTURE" | jq -r '[.. | strings | select(test("review-board answer"))] | unique | .[]' || fail "handoff not in request"
grep -q 'A review-board answer reached your steering inbox as 001.msg while you were working' "$CAPTURE" || fail "handoff text absent"
n=$(grep -o 'A review-board answer reached your steering inbox' "$CAPTURE" | wc -l | tr -d ' ')
echo "--- handoff occurrences in final request: $n"
# adversarial: another task's hook / repeated hook must print nothing
o1=$(printf '{"hook_event_name":"PostToolUse"}' | "$ROOT/bin/fm-board-receipt-hook.sh" claude "$STATE" "$ID")
[ -z "$o1" ] || fail "handed twice"
echo "--- repeat hook after claim: '(empty)'"
pass "answer delivered mid-step reaches real claude at that step's end"
