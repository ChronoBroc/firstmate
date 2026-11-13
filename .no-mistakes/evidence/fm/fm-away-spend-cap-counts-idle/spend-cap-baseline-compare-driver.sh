#!/usr/bin/env bash
# Live driver: real fm-afk-contract.sh / fm-crew-state.sh / fm-spawn.sh over a
# disposable lab FM_HOME and real worker endpoints on a private tmux server.
set -u
ROOT=$1
. "$ROOT/tests/lib.sh" >/dev/null 2>&1 || true
. "$ROOT/bin/fm-backend.sh"; fm_backend_source tmux
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR=$TD; unset TMUX
mkdir -p -m 700 "$TD/tmux-$(id -u)"; SOCK="$TD/tmux-$(id -u)/default"
cleanup(){ [ -S "$SOCK" ] && tmux -S "$SOCK" kill-server >/dev/null 2>&1; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
for v in NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE; do unset $v; done
export FM_HOME=$LAB
ST="$LAB/state"; W="$LAB/work"; mkdir -p "$W/bin" "$W/fakebin"
STANDIN=$(fm_agent_standin "$W/standin") || { echo "no standin"; exit 1; }
ln -s "$STANDIN" "$W/bin/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/no-mistakes"; chmod +x "$W/fakebin/no-mistakes"
export PATH="$W/fakebin:$PATH"
tmux -S "$SOCK" new-session -d -s crew -n keep
worker() { # id kind busy|idle|corrupt [status]
  local wt="$W/wt-$1" i=0 ident gen
  git init -q -b "fm/$1" "$wt"; git -C "$wt" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m init
  tmux -S "$SOCK" new-window -d -t crew: -n "fm-$1" "$W/bin/claude 600"
  while [ "$(fm_backend_agent_state tmux "crew:fm-$1")" != alive ]; do i=$((i+1)); [ $i -lt 50 ] || { echo "never alive $1"; exit 1; }; sleep 0.1; done
  ident=$(fm_backend_tmux_server_identity "crew:fm-$1")
  fm_write_meta "$ST/$1.meta" "window=crew:fm-$1" "worktree=$wt" "project=$wt" "harness=claude" "kind=$2" "branch=fm/$1" "tmux_socket=${ident%%$'\t'*}" "tmux_server=${ident#*$'\t'}"
  setbusy "$1" "$3"
  [ -z "${4:-}" ] || printf '%s\n' "$4" > "$ST/$1.status"
}
setbusy() { local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$ST" "$1")
  case "$2" in
    busy) "$ROOT/bin/fm-busy-event.sh" apply "$ST" "$1" busy --gen "$gen" --source claude-hook --event user-prompt-submit >/dev/null ;;
    idle) "$ROOT/bin/fm-busy-event.sh" apply "$ST" "$1" idle --gen "$gen" --source claude-hook --event stop >/dev/null ;;
    corrupt) printf 'not a busy record\n' > "$ST/$1.busy-state" ;;
  esac; }
readings(){ for m in "$ST"/*.meta; do id=${m##*/}; id=${id%.meta}; printf '  %-12s kind=%-10s %s\n' "$id" "$(grep ^kind= "$m"|cut -d= -f2)" "$("$ROOT/bin/fm-crew-state.sh" "$id" 2>&1 | head -1)"; done; }
spawn(){ FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-spawn.sh" "$1" --mode no-mistakes --yolo off 2>&1; echo "  [fm-spawn exit=$?]"; }
export FM_CREW_STATE_NO_FORGE=1
now=$(date +%s)
echo "=== S1: incident reproduction - 5 idle builders + 1 board-hosting idle scout, then /afk with no --spend ==="
for i in 1 2 3 4 5; do worker "builder-$i" ship idle "blocked [at=$now]: PR https://github.com/o/r/pull/$i ready"; done
worker board-scout scout idle "working [at=$now]: hosting the board"
echo "crew-state readings:"; readings
echo "\$ fm-afk-contract.sh enter --words 'review the open PRs' --spend 4"
"$ROOT/bin/fm-afk-contract.sh" enter --words 'review the open PRs' --spend 4 2>&1 | sed 's/^/  /'
echo "\$ fm-afk-contract.sh field spend_max_concurrent_workers -> $("$ROOT/bin/fm-afk-contract.sh" field spend_max_concurrent_workers)"
echo "\$ fm-afk-contract.sh readback (spend line):"; "$ROOT/bin/fm-afk-contract.sh" readback 2>&1 | grep -i 'spend cap' | sed 's/^/  /'
echo "\$ fm-afk-contract.sh live-workers -> $("$ROOT/bin/fm-afk-contract.sh" live-workers)"
echo "\$ fm-spawn.sh reviewer-1 --mode no-mistakes --yolo off"; spawn reviewer-1
echo
echo "=== S2: cap still binds - 4 workers turn busy (harness busy) ==="
for i in 1 2 3; do setbusy "builder-$i" busy; done; setbusy board-scout busy
printf 'working [at=%s]: under way\n' "$now" > "$ST/builder-1.status"
echo "crew-state readings:"; readings
echo "\$ fm-afk-contract.sh live-workers -> $("$ROOT/bin/fm-afk-contract.sh" live-workers)"
echo "\$ fm-spawn.sh reviewer-2 --mode no-mistakes --yolo off"; spawn reviewer-2
echo
echo "=== S3: adversarial - one busy worker idles -> slot frees; unreadable busy record re-fills it ==="
setbusy builder-3 idle
echo "\$ (builder-3 harness idles) live-workers -> $("$ROOT/bin/fm-afk-contract.sh" live-workers)"
echo "\$ fm-spawn.sh reviewer-3"; spawn reviewer-3
setbusy builder-4 corrupt
echo "\$ (builder-4 busy record corrupted -> unreadable) live-workers -> $("$ROOT/bin/fm-afk-contract.sh" live-workers)"
echo "\$ fm-spawn.sh reviewer-4"; spawn reviewer-4
echo
echo "=== S4: adversarial - blocked-status worker with busy harness counts; secondmate never; killed endpoint frees slot ==="
setbusy builder-4 idle
setbusy builder-5 busy   # status still says blocked/PR ready
worker mate secondmate busy
echo "crew-state readings:"; readings
echo "\$ live-workers -> $("$ROOT/bin/fm-afk-contract.sh" live-workers)   (expect 4: builder-1,2,5 + board-scout; secondmate excluded)"
tmux -S "$SOCK" kill-window -t crew:fm-builder-5
echo "\$ (builder-5 window killed, confirmed missing) live-workers -> $("$ROOT/bin/fm-afk-contract.sh" live-workers)   (expect 3)"
echo
echo "=== S5: quiet-mode record never caps ==="
"$ROOT/bin/fm-afk-contract.sh" archive >/dev/null
setbusy builder-3 busy; setbusy builder-4 busy
echo "\$ live-workers -> $("$ROOT/bin/fm-afk-contract.sh" live-workers)"
FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null 2>&1; echo "\$ mode -> $("$ROOT/bin/fm-afk-contract.sh" mode)"
echo "\$ fm-spawn.sh reviewer-5"; spawn reviewer-5
