#!/bin/bash
set -eu
ROOT=$PWD
E=~/.no-mistakes/evidence/01M75B3W5MHG8SWSN4T0B4ZMXC
LAB=$ROOT/.test-tmux/home
S=$ROOT/.s
F=$ROOT/.t
cleanup() {
  tmux -S "$S" kill-server 2>/dev/null || true
  tmux -S "$F" kill-server 2>/dev/null || true
}
trap cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export FM_HOME=$LAB
export DISABLE_AUTOUPDATER=1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/data/recover" "$ROOT/.test-tmux/tmp"
export TMPDIR=$ROOT/.test-tmux/tmp
P=$ROOT/.test-tmux/project
W=$ROOT/.test-tmux/worker
git init -q "$P"
git -C "$P" -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m initial
git -C "$P" worktree add -q -b task-recover "$W"
printf 'uncommitted recovery sentinel\n' > "$W/precious.txt"
cat > "$LAB/data/recover/brief.md" <<'EOF'
# Task
## Captain's intent
This is an isolated lifecycle validation. Read precious.txt and respond RECOVERY_READY. Do not modify any files, invoke any other tool, or start other work.
## Firstmate spec
Preserve the existing uncommitted file. After responding, remain idle.
EOF
printf 'manual\n' > "$LAB/config/backlog-backend"
tmux -S "$S" -f /dev/null new-session -d -s original -n keep -x 120 -y 40 -c "$ROOT"
export TMUX="$S,$(tmux -S "$S" display-message -p '#{pid}'),0"
tmux -S "$S" new-window -d -t original: -n fm-recover -c "$W"
. bin/fm-backend.sh
fm_backend_source tmux
identity=$(fm_backend_tmux_server_identity original:fm-recover)
socket=${identity%%$'\t'*}
server=${identity#*$'\t'}
cat > "$LAB/state/recover.meta" <<EOF
window=original:fm-recover
endpoint_task_id=recover
worktree=$W
project=$P
harness=codex
kind=ship
mode=no-mistakes
branch=task-recover
yolo=off
tasktmp=$ROOT/.test-tmux/tasktmp
model=default
effort=default
tmux_socket=$socket
tmux_server=$server
EOF
cp "$LAB/state/recover.meta" "$ROOT/.test-tmux/original.meta"
control() { echo "> bin/fm-control.sh recover $*"; bin/fm-control.sh recover "$@"; }
refuse() {
  local rc=0
  control "$@" || rc=$?
  echo "exit_status=$rc"
  test "$rc" != 0
  cmp "$LAB/state/recover.meta" "$ROOT/.test-tmux/original.meta"
}
echo 'SCENARIO renamed session retains its running pane'
pane=$(tmux -S "$S" display-message -p -t original:fm-recover '#{pane_pid}')
tmux -S "$S" rename-session -t original renamed
refuse exit
refuse relaunch --note 'must not duplicate renamed session'
kill -0 "$pane"
echo "surviving_pane_pid=$pane"
tmux -S "$S" rename-session -t renamed original
echo 'SCENARIO moved window retains its running pane'
tmux -S "$S" new-session -d -s elsewhere -n keep
tmux -S "$S" move-window -s original:fm-recover -t elsewhere:
refuse exit
refuse relaunch --note 'must not duplicate moved window'
kill -0 "$pane"
tmux -S "$S" move-window -s elsewhere:fm-recover -t original:
echo 'SCENARIO recorded endpoint survives on another server'
tmux -S "$F" -f /dev/null new-session -d -s seat -n keep -x 120 -y 40
export TMUX="$F,$(tmux -S "$F" display-message -p '#{pid}'),0"
refuse exit
refuse relaunch --note 'must not duplicate foreign endpoint'
echo 'SCENARIO unreachable recorded socket while its server lives'
mv "$S" "$ROOT/.u"
refuse exit
refuse relaunch --note 'must not duplicate unconfirmed server'
mv "$ROOT/.u" "$S"
echo 'SCENARIO legacy record without identity'
sed '/^tmux_/d' "$ROOT/.test-tmux/original.meta" > "$LAB/state/recover.meta"
cp "$ROOT/.test-tmux/original.meta" "$ROOT/.test-tmux/saved.meta"
cp "$LAB/state/recover.meta" "$ROOT/.test-tmux/original.meta"
refuse exit
refuse relaunch --note 'must not infer old identity'
cp "$ROOT/.test-tmux/saved.meta" "$LAB/state/recover.meta"
cp "$ROOT/.test-tmux/saved.meta" "$ROOT/.test-tmux/original.meta"
echo 'SCENARIO server loss and existing replacement collision'
tmux -S "$S" kill-server
# Waiting for the exited server PID to leave the process table is owned by this bounded check.
python3 - "${identity#*$'\t'}" <<'PY'
import os,sys,time
pid=int(sys.argv[1].split(':')[0])
for _ in range(100):
 try: os.kill(pid,0)
 except ProcessLookupError: break
 time.sleep(.05)
else: raise SystemExit('old tmux server did not exit')
PY
control exit
tmux -S "$F" new-window -d -t seat: -n fm-recover -c "$W"
refuse relaunch --note 'must not adopt colliding bare shell'
tmux -S "$F" kill-window -t seat:fm-recover
echo 'SCENARIO reclaim lost server into fresh window'
control relaunch --note 'Resume after verified tmux server loss; preserve precious.txt.'
sleep 8
echo 'PERSISTED RECORD'
cat "$LAB/state/recover.meta"
echo 'WINDOW INVENTORY'
tmux -S "$F" list-windows -a -F '#S:#W #{pane_current_path} #{pane_current_command}'
echo 'WORKTREE SENTINEL'
cat "$W/precious.txt"
cp "$LAB/state/recover.meta" "$E/reclaimed-record.txt"
tmux -S "$F" capture-pane -p -t seat:fm-recover -S -100 > "$E/reclaimed-pane.txt"
echo 'PANE CAPTURE'
cat "$E/reclaimed-pane.txt"
test "$(cat "$W/precious.txt")" = 'uncommitted recovery sentinel'
test "$(git -C "$W" branch --show-current)" = task-recover
test "$(tmux -S "$F" list-windows -t seat -F '#W' | grep -cx fm-recover)" = 1
. bin/fm-control-lib.sh
new_identity=$(fm_backend_tmux_server_identity seat:fm-recover)
recorded_socket=$(sed -n 's/^tmux_socket=//p' "$LAB/state/recover.meta")
recorded_server=$(sed -n 's/^tmux_server=//p' "$LAB/state/recover.meta")
test "$recorded_socket" = "${new_identity%%$'\t'*}"
test "$recorded_server" = "${new_identity#*$'\t'}"
echo "verified: one replacement, correct live server identity, original branch and uncommitted sentinel preserved"
echo 'ALL REQUESTED CONTROL CHECKS COMPLETED' 
