#!/usr/bin/env bash
# Live lab driver for fm-teardown freeze-then-decide.
# usage: lab-drive.sh <repo-root-with-bin> <scenario>
set -u
ROOT=$1; SCEN=$2
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null 2>&1 || "$(pwd)/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/fakebin" "$LAB/repos"
echo "== lab: $LAB  root: $ROOT  scenario: $SCEN"
# external boundaries only: treehouse pool (logged), gh lookups, no-mistakes runs
cat > "$LAB/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf 'treehouse %s\n' "\$*" >> "$LAB/treehouse.log"; exit 0
SH
cat > "$LAB/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []";; "pr view") exit 1;; esac; exit 0
SH
cp "$LAB/fakebin/gh-axi" "$LAB/fakebin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/fakebin/no-mistakes"
chmod +x "$LAB/fakebin/"*
R=$LAB/repos
git init -q --bare "$R/origin.git"; git -C "$R/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$R/origin.git" "$R/seed" 2>/dev/null
printf 'base\n' > "$R/seed/worker.txt"; git -C "$R/seed" add worker.txt
git -C "$R/seed" -c user.email=t@t -c user.name=t commit -q -m base; git -C "$R/seed" push -q origin main; rm -rf "$R/seed"
git clone -q "$R/origin.git" "$R/project"; git -C "$R/project" remote set-head origin main
git -C "$R/project" worktree add -q -b fm/task-x1 "$R/wt" main
WT=$R/wt
printf 'shipped\n' > "$WT/shipped.txt"; git -C "$WT" add shipped.txt
git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m "shipped work"
git -C "$WT" push -q origin fm/task-x1; git -C "$R/project" fetch -q origin
cat > "$LAB/state/task-x1.meta" <<M
window=firstmate:fm-task-x1
endpoint_task_id=task-x1
worktree=$WT
project=$R/project
kind=ship
mode=no-mistakes
spawn_gen=lab-task-x1
M
touch "$LAB/state/.last-watcher-beat"
export TMUX_TMPDIR="$LAB/tmux"
TM() { tmux -L fm-lab "$@"; }
env -u NO_MISTAKES_GATE tmux -L fm-lab new-session -d -s firstmate -n primary -c "$LAB" 
# worker pane: interactive shell in the copy (like `treehouse get`'s shell) running a foreground worker job
case "$SCEN" in
  term-writer) WORKER="trap 'echo late-term-edit >> worker.txt' TERM; while :; do sleep 0.2; done" ;;
  late-writer|tty-reader|claude-tui) WORKER="until [ -e $LAB/lsof-called ]; do sleep 0.02; done; echo late-scan-edit >> worker.txt; touch $LAB/late-written; while :; do if [ \"$SCEN\" = tty-reader ]; then read -t 1 line; date +%s > $LAB/heartbeat; else sleep 0.2; fi; done"
    REAL_LSOF=$(command -v lsof)
    cat > "$LAB/fakebin/lsof" <<SH
#!/usr/bin/env bash
# timing hook only: on teardown's first process scan, let the live worker write, then run the real lsof
if [ ! -e "$LAB/lsof-called" ]; then : > "$LAB/lsof-called"; for i in \$(seq 150); do [ -e "$LAB/late-written" ] && break; sleep 0.02; done; fi
exec "$REAL_LSOF" "\$@"
SH
    chmod +x "$LAB/fakebin/lsof" ;;
  *)           WORKER="while :; do date +%s > /dev/null; sleep 0.2; done" ;;
esac
printf '%s\n' "$WORKER" > "$LAB/worker.sh"
TM new-window -d -t firstmate -n fm-task-x1 -c "$WT" "bash -i"
sleep 0.5
if [ "$SCEN" = claude-tui ]; then
  TM send-keys -t firstmate:fm-task-x1 "claude" Enter
  sleep 12
  ( cd "$WT" && exec nohup bash "$LAB/worker.sh" >/dev/null 2>&1 ) &
  sleep 1
else
  TM send-keys -t firstmate:fm-task-x1 "bash $LAB/worker.sh" Enter
  sleep 1
fi
SOCK="$LAB/tmux/tmux-$(id -u)/fm-lab"
SHELLPID=$(TM display -p -t firstmate:fm-task-x1 '#{pane_pid}')
procs() { echo "-- processes rooted in the copy (lsof cwd):"; lsof -a -d cwd -Fp +D "$WT" 2>/dev/null | sed -n 's/^p//p' | while read p; do ps -o pid=,ppid=,stat=,command= -p "$p"; done; }
case "$SCEN" in
  dirty|dirty-then-commit) printf 'uncommitted edit\n' >> "$WT/worker.txt" ;;
esac
echo "-- git status before:"; git -C "$WT" status --short
procs
run_td() {
  local path=$PATH
  [ "${1:-}" = nolsof ] && { shift; path=$NOLSOF; }
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      FM_HOME="$LAB" TMUX="$SOCK,$(TM display -p '#{pid}'),0" PATH="$LAB/fakebin:$path" \
      "$ROOT/bin/fm-teardown.sh" task-x1 "$@"
}
if [ "$SCEN" = no-lsof ]; then
  NOLSOF=$LAB/nolsof; mkdir -p "$NOLSOF"
  IFS=:; for d in $PATH; do [ -d "$d" ] || continue; for f in "$d"/*; do b=${f##*/}; [ "$b" = lsof ] && continue; [ -e "$NOLSOF/$b" ] || ln -s "$f" "$NOLSOF/$b" 2>/dev/null; done; done; unset IFS
  echo "-- lsof on stripped PATH: $(PATH=$NOLSOF command -v lsof || echo absent)"
fi
echo; echo "===== fm-teardown.sh task-x1 (checked) ====="
if [ "$SCEN" = no-lsof ]; then run_td nolsof; else run_td; fi; rc=$?
echo "===== exit $rc"
echo "-- after: pane shell $SHELLPID alive? $(kill -0 $SHELLPID 2>/dev/null && echo yes || echo NO)"
procs
sleep 2; echo "-- 2s later, worker states:"; procs; echo "-- worker heartbeat age: $(( $(date +%s) - $(cat $LAB/heartbeat 2>/dev/null || echo 0) ))s"; echo "-- pane screen:"; TM capture-pane -p -t firstmate:fm-task-x1 | grep -v "^ *$" | tail -25
if [ "$SCEN" = claude-tui ]; then
  echo "-- probe: type a line into the worker pane, as a supervisor message would be"
  TM send-keys -t firstmate:fm-task-x1 "echo PANE-INPUT-RAN-IN-SHELL-NOT-WORKER" Enter; sleep 3
  echo "-- worker states after probe:"; procs
  echo "-- pane screen after probe:"; TM capture-pane -p -t firstmate:fm-task-x1 | grep -v "^ *$" | tail -8
fi
echo "-- tmux windows: $(TM list-windows -t firstmate -F '#W' 2>/dev/null | tr '\n' ' ')"
echo "-- worktree present? $([ -d "$WT" ] && echo yes || echo no); git status:"; git -C "$WT" status --short 2>/dev/null
echo "-- worker.txt: $(cat "$WT/worker.txt" 2>/dev/null | tr '\n' '|')"
echo "-- meta present? $([ -f "$LAB/state/task-x1.meta" ] && echo yes || echo no)"
echo "-- treehouse.log: $(cat "$LAB/treehouse.log" 2>/dev/null || echo '<none: copy never returned>')"
case "$SCEN" in
  dirty-then-commit)
    echo; echo "== worker resumes; operator commits+pushes the edit, then reruns cleanup"
    sleep 1; procs
    git -C "$WT" -c user.email=t@t -c user.name=t commit -qam "commit the edit"; git -C "$WT" push -q origin fm/task-x1; git -C "$R/project" fetch -q origin
    echo "===== fm-teardown.sh task-x1 (second run) ====="; run_td; rc=$?; echo "===== exit $rc"
    echo "-- after: pane shell alive? $(kill -0 $SHELLPID 2>/dev/null && echo yes || echo no)"; procs
    echo "-- tmux windows: $(TM list-windows -t firstmate -F '#W' 2>/dev/null | tr '\n' ' ')"
    echo "-- treehouse.log: $(cat "$LAB/treehouse.log" 2>/dev/null || echo '<none>')"
    echo "-- meta present? $([ -f "$LAB/state/task-x1.meta" ] && echo yes || echo no)" ;;
  no-lsof)
    echo; echo "===== fm-teardown.sh task-x1 --force (no lsof) ====="; run_td nolsof --force; rc=$?; echo "===== exit $rc"
    sleep 0.5
    echo "-- after: pane shell alive? $(kill -0 $SHELLPID 2>/dev/null && echo yes || echo no)"; procs
    echo "-- treehouse.log: $(cat "$LAB/treehouse.log" 2>/dev/null || echo '<none>')" ;;
esac
# teardown of the lab
TM kill-server 2>/dev/null
pkill -f "$LAB/worker.sh" 2>/dev/null; for p in $(lsof -a -d cwd -Fp +D "$WT" 2>/dev/null | sed -n "s/^p//p"); do kill -KILL $p 2>/dev/null; done
rm -rf "$LAB"
echo "== lab removed: $([ -e "$LAB" ] && echo NO || echo yes)"
