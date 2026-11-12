#!/usr/bin/env bash
# Live upgrade reproduction: a runner started by firstmate code from BEFORE the
# pid-identity UTC pin (43cd3b7e^), then the stranded listener is read, reconciled
# and retired by (a) base f38253d7 and (b) the change under test (HEAD).
set -u
NEW=$1; LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-pe-lab.XXXXXX"); LAB=$(cd -P "$LAB" && pwd -P)
trap 'for h in "$LAB"/home-*; do [ -f "$LAB/claims/$(basename $h).claim" ] && kill -TERM -"$(sed -n 2p "$LAB/claims/$(basename $h).claim")" 2>/dev/null; done; rm -rf "$LAB"' EXIT
mkdir -p "$LAB/old" "$LAB/base" "$LAB/claims" "$LAB/lavish"
git -C "$NEW" archive 43cd3b7e^ | tar -x -C "$LAB/old"
git -C "$NEW" archive f38253d7 | tar -x -C "$LAB/base"
export FM_PROCEVENT_CLAIM_ROOT="$LAB/claims" LAVISH_AXI_STATE_DIR="$LAB/lavish"
unset TZ
cat > "$LAB/listener.sh" <<'SH'
#!/usr/bin/env bash
printf 'started %s\n' "$$" >> "$1"
while [ ! -e "$2" ]; do sleep 0.2; done
SH
chmod +x "$LAB/listener.sh"
pe() { local code=$1 home=$2; shift 2; FM_HOME="$home" "$code/bin/fm-procevent.sh" "$@"; }
start_old_runner() {  # <id>
  local h="$LAB/home-$1"; mkdir -p "$h/state"
  pe "$LAB/old" "$h" register lavish "$1" -- "$LAB/listener.sh" "$LAB/$1.log" "$LAB/$1.stop" >/dev/null
  pe "$LAB/old" "$h" reconcile
  for _ in $(seq 50); do [ -s "$LAB/$1.log" ] && break; sleep 0.1; done
  echo "claim (written by pre-pin code, host zone $(date +%Z)):"; sed -n '2p;4p' "$LAB/claims/$1.claim" | sed 's/^/  /'
}
section() { printf '\n===== %s =====\n' "$*"; }

section "A. pre-pin runner, then BASE code f38253d7 (reproduce the strand)"
start_old_runner lavish-a; LA=$(sed -n 2p "$LAB/claims/lavish-a.claim")
echo "\$ list";       pe "$LAB/base" "$LAB/home-lavish-a" list
echo "\$ reconcile";  pe "$LAB/base" "$LAB/home-lavish-a" reconcile
echo "\$ retire";     pe "$LAB/base" "$LAB/home-lavish-a" retire lavish-a; echo "exit=$?"
kill -0 -"$LA" 2>/dev/null && echo "runner group $LA still alive (stranded)"; echo "listener executions: $(wc -l < "$LAB/lavish-a.log")"

section "B. pre-pin runner, then NEW code (HEAD) in host default zone"
start_old_runner lavish-b; LB=$(sed -n 2p "$LAB/claims/lavish-b.claim")
echo "\$ list";       pe "$NEW" "$LAB/home-lavish-b" list
echo "\$ reconcile";  pe "$NEW" "$LAB/home-lavish-b" reconcile
echo "listener executions: $(wc -l < "$LAB/lavish-b.log")"
echo "\$ retire";     pe "$NEW" "$LAB/home-lavish-b" retire lavish-b; echo "exit=$?"
sleep 1; kill -0 -"$LB" 2>/dev/null && echo "runner group $LB STILL ALIVE" || echo "runner group $LB stopped"
[ -e "$LAB/claims/lavish-b.claim" ] && echo "claim remains" || echo "claim removed"

section "C. pre-pin runner (host zone), NEW code invoked with TZ=UTC exported (host-default fallback)"
start_old_runner lavish-c; LC=$(sed -n 2p "$LAB/claims/lavish-c.claim")
echo "\$ TZ=UTC list";      TZ=UTC pe "$NEW" "$LAB/home-lavish-c" list
echo "\$ TZ=UTC reconcile"; TZ=UTC pe "$NEW" "$LAB/home-lavish-c" reconcile
echo "\$ TZ=UTC retire";    TZ=UTC pe "$NEW" "$LAB/home-lavish-c" retire lavish-c; echo "exit=$?"
sleep 1; kill -0 -"$LC" 2>/dev/null && echo "runner group $LC STILL ALIVE" || echo "runner group $LC stopped"

section "D. adversarial: pre-pin record not an exact rendering of the live runner (1s skew) -> stays unproven"
start_old_runner lavish-d; LD=$(sed -n 2p "$LAB/claims/lavish-d.claim"); f="$LAB/claims/lavish-d.claim"
rec=$(sed -n 4p "$f"); sec=$(printf '%s' "$rec" | awk '{split($4,t,":"); print t[3]}')
nsec=$(printf '%02d' $(( (10#$sec + 1) % 60 ))); bad=$(printf '%s' "$rec" | awk -v n="$nsec" '{split($4,t,":"); $4=t[1]":"t[2]":"n; print}')
awk -v v="$bad" 'NR==4{print v;next}{print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f" && chmod 0600 "$f"
echo "tampered record: $bad"
echo "\$ list";      pe "$NEW" "$LAB/home-lavish-d" list
echo "\$ retire";    pe "$NEW" "$LAB/home-lavish-d" retire lavish-d; echo "exit=$?"
kill -0 -"$LD" 2>/dev/null && echo "runner group $LD still alive (not signalled)" || echo "runner group $LD WAS SIGNALLED"
echo "listener executions: $(wc -l < "$LAB/lavish-d.log")"
