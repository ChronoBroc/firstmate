#!/usr/bin/env bash
# Live lab: real fm-control.sh / fm-spawn.sh / fm-afk-contract.sh / fm-crew-state.sh on a private tmux server.
set -u
W={run-worktree}
cd "$W"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_AFK_CONTRACT_CREW_STATE_BIN
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null; LAB=$(cd "$LAB" && pwd -P)
mkdir -p "$LAB/tmux" "$LAB/uhome"
export FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" HOME_ORIG="$HOME"
T() { tmux -L fm-lab "$@"; }
T new-session -d -s fmlab -n fm-ctl -c "$W" zsh
SOCK=$(T display -p '#{socket_path}'); SPID=$(T display -p '#{pid}')
export TMUX="$SOCK,$SPID,0"
echo "lab=$LAB socket=$SOCK"
PROJ="$LAB/proj"; git init -q "$PROJ"; git -C "$PROJ" commit -q --allow-empty -m init
mk_task() {  # id cmd
  local id=$1 cmd=$2 wt="$LAB/wt-$1"
  git -C "$PROJ" worktree add -q -b "task-$id" "$wt"
  T new-window -d -t fmlab -n "fm-$id" -c "$wt" "$cmd"
  mkdir -p "$LAB/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nLab task %s.\n\n## Firstmate spec\nKeep work.\n' "$id" > "$LAB/data/$id/brief.md"
  printf 'window=fmlab:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=no-mistakes\nyolo=off\ntasktmp=/tmp/fm-%s\nmodel=default\neffort=default\ntmux_socket=%s\ntmux_server=%s\n' \
    "$id" "$id" "$wt" "$PROJ" "$id" "$SOCK" "$(T display -p "#{pid}:#{start_time}")" > "$LAB/state/$id.meta"
}
# four workers whose harness is busy (real busy-event record, real pane)
for i in 1 2 3 4; do mk_task "w$i" "sleep 3600"; bin/fm-busy-event.sh arm "$LAB/state" "w$i" --state busy --source claude-hook --event prompt >/dev/null; done
# one dead worker: pane is a bare shell, harness record idle, unlanded work
mk_task dead zsh
echo unlanded > "$LAB/wt-dead/wip.txt"
bin/fm-busy-event.sh arm "$LAB/state" dead --state idle --source claude-hook --event stop >/dev/null
snap() { cat "$LAB/state/dead.meta" "$LAB/data/dead/brief.md" "$LAB/wt-dead/wip.txt"; git -C "$LAB/wt-dead" status --porcelain; ls -A "$LAB/state"; T list-windows -t fmlab -F '#{window_name} #{pane_current_command}'; }
echo "== real crew-state readings"; for id in w1 w2 w3 w4 dead; do printf '%s: ' $id; FM_STATE_OVERRIDE="$LAB/state" FM_CREW_STATE_NO_FORGE=1 bin/fm-crew-state.sh $id | head -1; done
echo "== enter away, cap 4"; bin/fm-afk-contract.sh enter --spend 4 2>&1 | tail -3
echo "live-workers=$(bin/fm-afk-contract.sh live-workers)"
echo; echo "### S1: cap full (4 working) -> relaunch of dead worker via fm-control"
before=$(snap)
out=$(HOME="$LAB/uhome" bin/fm-control.sh dead relaunch --note "continue after crash" 2>&1); rc=$?
echo "rc=$rc"; echo "$out"
[ "$before" = "$(snap)" ] && echo "SNAPSHOT UNCHANGED" || { echo "SNAPSHOT CHANGED"; diff <(echo "$before") <(snap); }
echo "live-workers after=$(bin/fm-afk-contract.sh live-workers)"
echo; echo "### S2: cap full -> direct fm-spawn --relaunch of dead worker"
out=$(HOME="$LAB/uhome" FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh dead --relaunch 2>&1); rc=$?
echo "rc=$rc"; echo "$out" | tail -3
[ "$before" = "$(snap)" ] && echo "SNAPSHOT UNCHANGED" || { echo "SNAPSHOT CHANGED"; diff <(echo "$before") <(snap); }
echo; echo "### S3: decision CLI: counted worker w1 relaunch at full cap (exempt) vs dead / fresh"
bin/fm-afk-contract.sh spend-cap-admits w1 --relaunch; echo "w1 --relaunch rc=$?"
bin/fm-afk-contract.sh spend-cap-admits dead --relaunch 2>&1; echo "dead --relaunch rc=$?"
bin/fm-afk-contract.sh spend-cap-admits newtask 2>&1; echo "fresh rc=$?"
echo; echo "### S4: one worker finishes (w4 harness idle + pane shell) -> dead relaunch admitted by decision"
T respawn-pane -k -t fmlab:fm-w4 zsh; bin/fm-busy-event.sh arm "$LAB/state" w4 --state idle --source claude-hook --event stop >/dev/null
echo "live-workers=$(bin/fm-afk-contract.sh live-workers)"
bin/fm-afk-contract.sh spend-cap-admits dead --relaunch 2>&1; echo "dead --relaunch rc=$?"
echo; echo "### S5: room under cap but another launch holds the task-set lock -> relaunch defers 75"
( . bin/fm-wake-lib.sh; fm_lock_try_acquire "$LAB/state/.task-set.lock" && sleep 20 ) & H=$!
for i in $(seq 50); do [ -s "$LAB/state/.task-set.lock/pid" ] && break; sleep 0.1; done
before=$(snap)
out=$(HOME="$LAB/uhome" bin/fm-control.sh dead relaunch --note "continue after crash" 2>&1); rc=$?; echo "fm-control rc=$rc"; echo "$out"
out=$(HOME="$LAB/uhome" FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh dead --relaunch 2>&1); rc=$?; echo "fm-spawn rc=$rc"; echo "$out" | tail -2
[ "$before" = "$(snap)" ] && echo "SNAPSHOT UNCHANGED" || { echo "SNAPSHOT CHANGED"; diff <(echo "$before") <(snap); }
kill $H; wait $H 2>/dev/null
echo; echo "### S6: no away record (archive) at 4 working -> relaunch cap not applied"
for i in 1 2 3 4; do :; done
T respawn-pane -k -t fmlab:fm-w4 "sleep 3600"; bin/fm-busy-event.sh arm "$LAB/state" w4 --state busy --source claude-hook --event prompt >/dev/null
bin/fm-afk-contract.sh archive >/dev/null; echo "record present: $([ -f "$LAB/state/.afk-contract" ] && echo yes || echo no)"
bin/fm-afk-contract.sh spend-cap-admits dead --relaunch 2>&1; echo "dead --relaunch (no record) rc=$?"
echo; echo "== teardown"
T kill-server; rm -rf "$LAB"; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
