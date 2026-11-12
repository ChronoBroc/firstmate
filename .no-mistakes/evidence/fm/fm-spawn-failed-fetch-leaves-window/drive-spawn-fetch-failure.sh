#!/usr/bin/env bash
# drive-spawn-fetch-failure.sh <fm-root> <lab-home> <project> <id> <label> <out>
# Runs inside a pane of the lab's private tmux server: real fm-spawn.sh, real
# treehouse, real tmux. Spawns once (fetch fails: origin host unresolvable),
# records windows/state, then retries the same id.
set -u
ROOT=$1 LAB=$2 PROJ=$3 ID=$4 LABEL=$5 OUT=$6
{
  echo "=== [$LABEL] fm-root=$ROOT  lab=$LAB  project origin=$(git -C "$PROJ" remote get-url origin)"
  echo "=== [$LABEL] windows before spawn:"; tmux list-windows -F '  #{window_name}'
  echo "=== [$LABEL] attempt 1: bin/fm-spawn.sh $ID <project> --mode no-mistakes --yolo off"
  s=$(date +%s)
  FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" --mode no-mistakes --yolo off 2>&1
  echo "=== [$LABEL] attempt 1 exit=$? after $(( $(date +%s) - s ))s"
  echo "=== [$LABEL] windows after failed spawn:"; tmux list-windows -F '  #{window_name}'
  echo "=== [$LABEL] state/$ID.meta: $([ -e "$LAB/state/$ID.meta" ] && echo present || echo absent)"
  echo "=== [$LABEL] data/$ID/launch-brief.md: $([ -e "$LAB/data/$ID/launch-brief.md" ] && echo present || echo absent)"
  echo "=== [$LABEL] treehouse status:"; (cd "$PROJ" && treehouse status 2>&1 | sed 's/^/  /')
  echo "=== [$LABEL] attempt 2 (retry, cause NOT cleared)"
  s=$(date +%s)
  FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" --mode no-mistakes --yolo off 2>&1
  echo "=== [$LABEL] attempt 2 exit=$? after $(( $(date +%s) - s ))s"
  echo "=== [$LABEL] windows after retry:"; tmux list-windows -F '  #{window_name}'
  echo "=== [$LABEL] DONE"
} > "$OUT" 2>&1
