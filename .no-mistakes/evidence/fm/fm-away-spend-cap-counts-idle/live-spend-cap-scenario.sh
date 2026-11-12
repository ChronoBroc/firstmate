#!/usr/bin/env bash
# Live lab scenario: away spend cap counts only actively working workers.
# Real tmux panes on a private lab socket, real fm-crew-state readings,
# real fm-afk-contract entry, real fm-spawn admission.
set -u
REPO=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1; LAB=$(cd "$LAB" && pwd -P)
TD=$("$REPO/bin/fm-lab-home.sh" tmux-dir "$LAB") || exit 1
mkdir -m 700 "$TD/tmux-$(id -u)"; SOCK="$TD/tmux-$(id -u)/default"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-work.XXXXXX")
cleanup() { [ -S "$SOCK" ] && tmux -S "$SOCK" kill-server >/dev/null 2>&1; "$REPO/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "$WORK"; }
trap cleanup EXIT
export TMUX_TMPDIR=$TD FM_HOME=$LAB; unset TMUX FM_STATE_OVERRIDE FM_ROOT_OVERRIDE NO_MISTAKES_GATE
ST=$LAB/state
mkdir -p "$WORK/bin" "$WORK/fakebin"
printf '#include <unistd.h>\nint main(void){int i;for(i=0;i<900;i++)sleep(1);return 0;}\n' > "$WORK/s.c"
cc -o "$WORK/standin" "$WORK/s.c" || exit 1
ln -s "$WORK/standin" "$WORK/bin/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/fakebin/no-mistakes"; chmod +x "$WORK/fakebin/no-mistakes"
export PATH="$WORK/fakebin:$PATH"
. "$REPO/bin/fm-backend.sh"; fm_backend_source tmux
tmux -S "$SOCK" new-session -d -s crew -n keep
ROOT="$WORK/root"; git init -q -b main "$ROOT"; git -C "$ROOT" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m init; ln -s "$REPO/bin" "$ROOT/bin"
now=$(date +%s)
worker() {  # id kind busy|idle|corrupt [status]
  local wt="$WORK/wt-$1" i=0 ident gen
  git init -q -b "fm/$1" "$wt"; git -C "$wt" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m init
  tmux -S "$SOCK" new-window -d -t crew: -n "fm-$1" "$WORK/bin/claude"
  while [ "$(fm_backend_agent_state tmux "crew:fm-$1")" != alive ]; do i=$((i+1)); [ $i -lt 50 ] || { echo "no alive $1"; exit 1; }; sleep 0.1; done
  ident=$(fm_backend_tmux_server_identity "crew:fm-$1")
  printf '%s\n' "window=crew:fm-$1" "worktree=$wt" "project=$wt" "harness=claude" "kind=$2" "branch=fm/$1" "tmux_socket=${ident%%$'\t'*}" "tmux_server=${ident#*$'\t'}" > "$ST/$1.meta"
  gen=$("$REPO/bin/fm-busy-event.sh" arm "$ST" "$1")
  set_activity "$1" "$3" "$gen"
  [ -z "${4:-}" ] || printf '%s\n' "$4" > "$ST/$1.status"
}
set_activity() {  # id busy|idle|corrupt [gen]
  local gen=${3:-}
  [ -n "$gen" ] || gen=$("$REPO/bin/fm-busy-event.sh" arm "$ST" "$1")
  case "$2" in
    busy) "$REPO/bin/fm-busy-event.sh" apply "$ST" "$1" busy --gen "$gen" --source claude-hook --event user-prompt-submit >/dev/null ;;
    idle) "$REPO/bin/fm-busy-event.sh" apply "$ST" "$1" idle --gen "$gen" --source claude-hook --event stop >/dev/null ;;
    corrupt) printf 'not a busy record\n' > "$ST/$1.busy-state" ;;
  esac
}
readings() { for m in "$ST"/*.meta; do id=${m##*/}; id=${id%.meta}; printf '  %-12s %s\n' "$id" "$(FM_CREW_STATE_NO_FORGE=1 FM_STATE_OVERRIDE="$ST" "$REPO/bin/fm-crew-state.sh" "$id" | head -1)"; done; }
spawn() { FM_SUPERVISION_ACTOR=branch "$REPO/bin/fm-spawn.sh" "$1" --mode no-mistakes --yolo off 2>&1 | grep -v "^  *note: new-task spawn" ; }
CAPMSG='caps actively working workers'

echo "=== S1: reported failure - 5 idle builders (PRs ready) + 1 idle board-hosting scout, away entry with no --spend ==="
for n in 1 2 3 4 5; do worker "builder-$n" ship idle "blocked [at=$now]: PR https://github.com/o/r/pull/$n ready"; done
worker scout-board scout idle
worker mate secondmate busy
echo "worker readings (real fm-crew-state.sh):"; readings
echo "\$ fm-afk-contract.sh enter --words 'start reviewers for the open PRs'"
"$REPO/bin/fm-afk-contract.sh" enter --words 'start reviewers for the open PRs' 2>&1 | grep -i 'spend cap'
cap=$("$REPO/bin/fm-afk-contract.sh" field spend_max_concurrent_workers); echo "recorded cap: $cap"
lw=$("$REPO/bin/fm-afk-contract.sh" live-workers); echo "live-workers: $lw  (records: $(ls "$ST"/*.meta | wc -l | tr -d ' '))"
echo "\$ fm-spawn.sh reviewer-1 ... (supervision branch, away)"; out=$(spawn reviewer-1); echo "$out" | sed 's/^/  /'
s1=FAIL; [ "$cap" = 4 ] && [ "$lw" = 0 ] && ! grep -q "$CAPMSG" <<<"$out" && grep -q "queued unblocked work" <<<"$out" && s1=PASS; echo "S1: $s1"
rm -rf "$ST/reviewer-1".* 2>/dev/null

echo; echo "=== S2: adversarial - 4 actively working workers alongside the 6 idle ones must still refuse ==="
for n in 1 2 3 4; do worker "busy-$n" ship busy "working [at=$now]: implementing"; done
echo "worker readings:"; readings
lw=$("$REPO/bin/fm-afk-contract.sh" live-workers); echo "live-workers: $lw"
echo "\$ fm-spawn.sh reviewer-2 ..."; out=$(spawn reviewer-2); echo "$out" | sed 's/^/  /'
s2=FAIL; [ "$lw" = 4 ] && grep -q "$CAPMSG at 4 and 4 ordinary worker(s) are actively working" <<<"$out" && s2=PASS; echo "S2: $s2"

echo; echo "=== S3: a busy worker goes idle (turn ends, PR ready) -> room under the cap reopens ==="
set_activity busy-4 idle; printf '%s\n' "blocked [at=$now]: PR https://github.com/o/r/pull/9 ready" > "$ST/busy-4.status"
echo "busy-4: $(FM_CREW_STATE_NO_FORGE=1 "$REPO/bin/fm-crew-state.sh" busy-4 | head -1)"
lw=$("$REPO/bin/fm-afk-contract.sh" live-workers); echo "live-workers: $lw"
out=$(spawn reviewer-3); echo "$out" | sed 's/^/  /'
s3=FAIL; [ "$lw" = 3 ] && ! grep -q "$CAPMSG" <<<"$out" && grep -q "queued unblocked work" <<<"$out" && s3=PASS; echo "S3: $s3"
rm -rf "$ST/reviewer-3".* 2>/dev/null

echo; echo "=== S4: adversarial - a worker whose state cannot be read counts (fail closed) ==="
worker unreadable ship corrupt "working [at=$now]: under way"
echo "unreadable: $(FM_CREW_STATE_NO_FORGE=1 "$REPO/bin/fm-crew-state.sh" unreadable | head -1)"
lw=$("$REPO/bin/fm-afk-contract.sh" live-workers); echo "live-workers: $lw"
out=$(spawn reviewer-4); echo "$out" | sed 's/^/  /'
s4=FAIL; [ "$lw" = 4 ] && grep -q "$CAPMSG at 4 and 4" <<<"$out" && s4=PASS; echo "S4: $s4"

echo; echo "=== S5: a dead worker (pane gone) does not count ==="
tmux -S "$SOCK" kill-window -t crew:fm-busy-1
echo "busy-1: $(FM_CREW_STATE_NO_FORGE=1 "$REPO/bin/fm-crew-state.sh" busy-1 | head -1)"
lw=$("$REPO/bin/fm-afk-contract.sh" live-workers); echo "live-workers: $lw"
s5=FAIL; [ "$lw" = 3 ] && s5=PASS; echo "S5: $s5"
echo; echo "SUMMARY S1=$s1 S2=$s2 S3=$s3 S4=$s4 S5=$s5"
