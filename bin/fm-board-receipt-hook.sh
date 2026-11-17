#!/usr/bin/env bash
# fm-board-receipt-hook.sh - a worker's after-each-step hook that hands it a
# review-board answer which reached its steering inbox while it was in the
# middle of a turn.
#
# Usage: fm-board-receipt-hook.sh claude <state-dir> <task-id>
#
# bin/fm-spawn.sh installs this as a Claude Code PostToolUse hook for every
# Claude worker, so it runs as that worker's own process after each tool call.
# The hook payload on stdin is read and discarded. When a delivered board round
# is still waiting on <task-id>, it prints one PostToolUse JSON object whose
# additionalContext carries that round's steering-inbox instruction, which
# Claude Code adds to the worker's context before its next step; otherwise it
# prints nothing. bin/fm-board-receipt-lib.sh ("Mid-turn handoff") owns which
# rounds qualify and the once-per-round claim.
#
# It always exits 0, so it can never fail or block the worker's step. A worker
# with no round waiting on it pays a directory scan per step.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1-}" in -h|--help|help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;; esac
cat >/dev/null 2>&1 || true
[ "${1-}" = claude ] && [ -n "${2-}" ] && [ -n "${3-}" ] || exit 0
STATE=$2
TASK=$3
# Fast path: load the libraries only for a round still waiting on this worker
# and not yet handed over or read.
waiting=0
for receipt in "$STATE"/board-receipts/*.receipt; do
  [ -f "$receipt" ] || continue
  [ -e "${receipt%.receipt}.midturn" ] && continue
  [ -e "${receipt%.receipt}.read" ] && continue
  if grep -qx "task=$TASK" "$receipt" 2>/dev/null && grep -qx 'state=delivered' "$receipt" 2>/dev/null; then
    waiting=1
    break
  fi
done
[ "$waiting" -eq 1 ] || exit 0

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh" || exit 0
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh" || exit 0
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh" || exit 0
# shellcheck source=/dev/null # Analyzed separately as a canonical lint root.
. "$SCRIPT_DIR/fm-task-inbox-lib.sh" || exit 0
# shellcheck source=bin/fm-board-receipt-lib.sh
. "$SCRIPT_DIR/fm-board-receipt-lib.sh" || exit 0

handoff=$(fm_board_receipt_mid_turn "$STATE" "$TASK" 2>/dev/null)
[ -n "$handoff" ] || exit 0
printf '%s' "$handoff" | perl -MJSON::PP -e '
  local $/;
  my $text = <STDIN>;
  print JSON::PP->new->canonical->encode({ hookSpecificOutput => {
    hookEventName => "PostToolUse", additionalContext => $text } }), "\n";
' 2>/dev/null || true
exit 0
