#!/usr/bin/env bash
# Replays the reported OPTCG Sim timeline (2026-11-14) against a firstmate tree's
# real bin/fm-watch.sh, bin/fm-branch-outcome.sh and bin/fm-wake-drain.sh in a
# disposable home. Usage: replay-board-answer.sh <firstmate-tree> <scenario>
#   scenario: reported      - paused [key=board-review] wait, answer while worker busy
#             decision      - needs-decision [key=board-review] (fm-brief board workflow)
#             other-key     - unrelated resolved [key=other] arrives instead (adversarial)
#             superseded    - a newer captain outcome about a credential lands before the answer
# Only the worker-busy probe (fm-crew-state.sh) and tmux are stubbed, as in the repo's tests.
set -u
TREE=$1 SCEN=$2
. "$TREE/tests/watch-triage-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-replay)
OUTCOME="$TREE/bin/fm-branch-outcome.sh"
dir=$(make_case replay); state="$dir/state"; fakebin="$dir/fakebin"
say() { printf '\n== %s\n' "$*"; }
verdict() {
  local pid=$1 i=0
  while [ $i -lt 100 ]; do
    grep -Fq "absorbed benign signal:" "$state/.watch-triage.log" 2>/dev/null && { kill $pid 2>/dev/null; wait $pid 2>/dev/null; echo absorbed; return; }
    kill -0 $pid 2>/dev/null || { wait $pid 2>/dev/null; echo "exited (wake surfaced)"; return; }
    sleep 0.1; i=$((i+1))
  done
  kill $pid; echo timeout
}
drain() {
  local err="$dir/drain.err" seqn gen
  FM_STATE_OVERRIDE="$state" "$DRAIN" 2>"$err"
  seqn=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -z "$seqn" ] || FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seqn" --recovery-generation "$gen" >/dev/null 2>&1
}
case $SCEN in decision) WAIT='needs-decision [key=board-review] [at=1794686615]: round 7 waits for the owner on the Lavish board' ;;
  *) WAIT='paused [key=board-review] [at=1794686615]: round 7 waits for the owner on the Lavish board' ;; esac
ANSWER='resolved [key=board-review] [at=1794687324]: round 7 answered, all four as recommended; drawing round 8'

printf 'window=test:fm-designer\nkind=scout\nharness=claude\n' > "$state/designer.meta"
printf 'working [at=1794686610]: round 7 is on the board\n' > "$state/designer.status"
printf '%s' "$(seen_sig "$state/designer.status")" > "$state/.seen-designer_status"
say "14:03:35 worker appends: $WAIT"
printf '%s\n' "$WAIT" >> "$state/designer.status"
export FM_FAKE_CREW_STATE='state: idle · source: pane · waiting at its prompt'
watch_bg "$state" "$fakebin" "$dir/w1.out"; echo "watcher: $(verdict $!)"
ack_stopped_cycle "$state" >/dev/null 2>&1
say "supervision session records captain outcome; main relays and acks it"
seq=$(FM_STATE_OVERRIDE="$state" "$OUTCOME" append --task designer --verdict captain \
  --summary "Round 7 is on the Lavish board with four questions. Waiting for the captain's answers." \
  --wake "signal: $state/designer.status"); echo "outcome seq=$seq"
FM_STATE_OVERRIDE="$state" "$OUTCOME" mark-read --through "$seq" >/dev/null
FM_STATE_OVERRIDE="$state" "$OUTCOME" mark-processed --through "$seq" >/dev/null
echo "wait records: $(ls -a "$state" | grep captain-wait || echo none)"
if [ "$SCEN" = superseded ]; then
  say "worker appends an unrelated credential block; supervision records a newer captain outcome for it"
  printf '%s\n' 'blocked [key=cred] [at=1794686800]: needs the deploy token' >> "$state/designer.status"
  printf '%s' "$(seen_sig "$state/designer.status")" > "$state/.seen-designer_status"
  s2=$(FM_STATE_OVERRIDE="$state" "$OUTCOME" append --task designer --verdict captain --summary "Needs the deploy token." --wake "signal: $state/designer.status")
  FM_STATE_OVERRIDE="$state" "$OUTCOME" mark-read --through "$s2" >/dev/null; FM_STATE_OVERRIDE="$state" "$OUTCOME" mark-processed --through "$s2" >/dev/null
  printf '%s\n' 'resolved [key=cred] [at=1794686900]: token received' >> "$state/designer.status"
  printf '%s' "$(seen_sig "$state/designer.status")" > "$state/.seen-designer_status"
  echo "outcome seq=$s2; credential resolved; wait records: $(ls -a "$state" | grep captain-wait || echo none)"
fi
if [ "$SCEN" = other-key ]; then
  say "worker (busy) appends an unrelated resolve instead of the board answer"
  printf '%s\n' 'resolved [key=other] [at=1794687000]: lint question settled' >> "$state/designer.status"
else
  say "14:15:24 board answered; worker (now busy drawing round 8) appends: $ANSWER"
  printf '%s\n' "$ANSWER" >> "$state/designer.status"
fi
export FM_FAKE_CREW_STATE='state: working · source: pane · busy drawing round 8'
watch_bg "$state" "$fakebin" "$dir/w2.out"; echo "watcher: $(verdict $!)"
echo "watcher wake output: $(cat "$dir/w2.out")"
echo "queued row: $(grep designer.status "$state/.wake-queue" 2>/dev/null | tail -1 | tr '\t' '|')"
say "main drains"
drain | grep -A3 -E 'SETTLED WAITS|BRANCH OUTCOMES' || echo "(no SETTLED WAITS / BRANCH OUTCOMES section)"
say "main drains again"
drain | grep -A3 'SETTLED WAITS' || echo "(no SETTLED WAITS section)"
echo "wait records left: $(ls -a "$state" | grep captain-wait || echo none)"
rm -rf "$TMP_ROOT"
