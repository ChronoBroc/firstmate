#!/usr/bin/env bash
# watch-drive.sh <firstmate-root> <label>
# Lab run: real fm-spawn writes a Claude worker's hooks (fake tmux only for the spawn),
# a real `claude -p` runs that worker in a real lab-private tmux pane against a local
# API stub that keeps one turn going with a Bash `sleep 5` tool call every few seconds,
# and the real bin/fm-watch.sh polls the lab home with FM_BUSY_TURN_MAX_SECS=30 and
# FM_STALE_ESCALATE_SECS=10. Prints each watcher wake reason with a timestamp.
set -u
FMROOT=$1; LABEL=$2
. "$FMROOT/tests/fixtures.sh"
say() { printf '%s [%s] %s\n' "$(date -u +%H:%M:%S)" "$LABEL" "$*"; }
TMP_ROOT=$(fm_test_tmproot fm-watch-drive)
LAB="$TMP_ROOT/lab"; ID=long-turn; PROJ="$TMP_ROOT/proj"; WT="$TMP_ROOT/wt"
"$FMROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
TD=$("$FMROOT/bin/fm-lab-home.sh" tmux-dir "$LAB"); export TMUX_TMPDIR="$TD"
SOCK="$TD/tmux-$(id -u)/default"; mkdir -p "$(dirname "$SOCK")"; chmod 700 "$(dirname "$SOCK")"
STUB=''; WPID=''
cleanup() { [ -n "$WPID" ] && kill "$WPID" 2>/dev/null; [ -n "$STUB" ] && kill "$STUB" 2>/dev/null
  tmux -S "$SOCK" kill-server >/dev/null 2>&1; "$FMROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; chmod -R u+w "$TMP_ROOT" 2>/dev/null; rm -rf "$LAB"; fm_test_cleanup; }
trap cleanup EXIT
STATE="$LAB/state"
fm_test_spawn_home "$LAB" claude
fm_git_worktree "$PROJ" "$WT" long-turn
fm_test_spawn_brief "$LAB" "$ID"
FAKEBIN=$(make_spawn_fakebin "$TMP_ROOT/fake" claude)
out=$(fm_test_run_spawn "$LAB" "$WT" "$FAKEBIN" "$ID" "$PROJ" --mode no-mistakes --yolo off 2>&1) || { echo "spawn failed: $out"; exit 1; }
say "hooks fm-spawn wrote: $(jq -c '.hooks|keys' "$WT/.claude/settings.local.json")"
rm -f "$STATE/$ID.progress" "$STATE/$ID.turn-ended"
python3 "$(dirname "$0")/loop-stub.py" "$TMP_ROOT/port" "${STUB_N:-40}" "${STUB_SECS:-5}" & STUB=$!
for _ in $(seq 1 50); do [ -s "$TMP_ROOT/port" ] && break; sleep 0.1; done
port=$(cat "$TMP_ROOT/port")
cat > "$TMP_ROOT/run-claude.sh" <<RUN
cd '$WT' && exec env -i PATH="$PATH" HOME='$TMP_ROOT/user-home' TERM=xterm CLAUDE_CONFIG_DIR='$TMP_ROOT/claude-config' ANTHROPIC_API_KEY=sk-ant-synthetic-stub-only ANTHROPIC_BASE_URL=http://127.0.0.1:$port DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude -p 'long healthy turn' --max-turns 100 --dangerously-skip-permissions
RUN
tmux -S "$SOCK" new-session -d -s lab -n worker -x 160 -y 40 "bash '$TMP_ROOT/run-claude.sh'; echo CLAUDE-EXITED; sleep 600"
# Record the real lab window in the task meta the spawn wrote.
sed -i '' -e "s|^window=.*|window=lab:worker|" -e "s|^backend=.*|backend=tmux|" "$STATE/$ID.meta"
grep -q '^backend=' "$STATE/$ID.meta" || echo backend=tmux >> "$STATE/$ID.meta"
printf 'working: implementing\n' > "$STATE/$ID.status"
FM_HOME="$LAB" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$FMROOT/bin/fm-wake-lib.sh" "$LAB" "$ID.status"
START=$(date +%s)
say "claude started in lab:worker at $START; meta: $(tr '\n' ' ' < "$STATE/$ID.meta" | cut -c1-200)"
# Watcher runs continuously; whenever it exits with a wake, log it, drain, restart.
end=$((START + 150)); wakes=0; wedges=0
while [ "$(date +%s)" -lt "$end" ]; do
  FM_HOME="$LAB" FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_BUSY_TURN_MAX_SECS=30 FM_STALE_ESCALATE_SECS=10 \
    "$FMROOT/bin/fm-watch.sh" > "$TMP_ROOT/w.out" 2>&1 & WPID=$!
  while kill -0 "$WPID" 2>/dev/null && [ "$(date +%s)" -lt "$end" ]; do sleep 1; done
  kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WPID=''
  r=$(head -1 "$TMP_ROOT/w.out")
  if [ -n "$r" ]; then
    wakes=$((wakes+1)); case "$r" in *"possible wedge"*) wedges=$((wedges+1));; esac
    say "t+$(( $(date +%s) - START ))s WAKE: $r"
  fi
  FM_HOME="$LAB" "$FMROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
done
now=$(date +%s)
say "t+$((now-START))s busy record: $(cat "$STATE/$ID.busy-state")"
say "classify: $(fm_busy_classify tmux lab:worker claude "$ID" "$STATE" 2>/dev/null || (. "$FMROOT/bin/fm-busy-lib.sh"; fm_busy_classify tmux lab:worker claude "$ID" "$STATE"))"
if [ -e "$STATE/$ID.progress" ]; then say "progress marker age: $((now - $(stat -f %m "$STATE/$ID.progress")))s"; else say "progress marker: absent"; fi
say "meta (turn start proxy) age: $((now - $(stat -f %m "$STATE/$ID.meta")))s"
say "crew-state: $(FM_HOME="$LAB" "$FMROOT/bin/fm-crew-state.sh" "$ID" 2>&1 | head -3 | tr '\n' ' ')"
say "pane: $(tmux -S "$SOCK" capture-pane -p -t lab:worker | grep -v '^$' | tail -2 | tr '\n' ' ')"
say "RESULT wakes=$wakes possible_wedge=$wedges over 150s of one claude turn"
