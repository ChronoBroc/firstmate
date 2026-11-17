#!/usr/bin/env bash
# End to end: a real Claude Code worker (fm-spawn hooks, token-free API stub) runs in a
# real tmux pane on a private lab socket, inside a 30s tool call. A Lavish board owned by it
# is armed through the real adapter (vendor lavish-axi stubbed to return one answered round),
# so the answer lands in its steering inbox mid-step. Real `fm-procevent.sh reconcile` then
# alarms (delay aged past), the step ends and the hook hands the answer over, the worker's
# read acknowledges it.
set -eu
ROOT=$1
. "$ROOT/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-s4-e2e)
LABSOCK="$TMP_ROOT/lab.sock"
REALTMUX=$(command -v tmux)
STUB_PID=''
cleanup() { [ -z "$STUB_PID" ] || kill "$STUB_PID" 2>/dev/null; "$REALTMUX" -S "$LABSOCK" kill-server 2>/dev/null || true; fm_test_cleanup; }
trap cleanup EXIT
ID=w-board-e2e
H="$TMP_ROOT/home"; PROJ="$TMP_ROOT/project"; WT="$TMP_ROOT/wt"; STATE="$H/state"
CAPTURE="$TMP_ROOT/after-tool-call.jsonl"
fm_test_spawn_home "$H" claude
fm_git_worktree "$PROJ" "$WT" board-e2e
fm_test_spawn_brief "$H" "$ID"
FAKEBIN=$(make_spawn_fakebin "$TMP_ROOT/fake" claude)
fm_test_run_spawn "$H" "$WT" "$FAKEBIN" "$ID" "$PROJ" --mode no-mistakes --yolo off >/dev/null 2>&1 || fail spawn
# lab tmux wrapper: every product tmux call goes to the private lab socket
LABBIN="$TMP_ROOT/labbin"; mkdir -p "$LABBIN"
printf '#!/usr/bin/env bash\nexec %q -S %q "$@"\n' "$REALTMUX" "$LABSOCK" > "$LABBIN/tmux"; chmod +x "$LABBIN/tmux"
# vendor stub lavish-axi (one answered round, then a quiet board), as tests/fm-board-receipt.test.sh
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state" RECEIPT_STUB_DIR="$TMP_ROOT/stub-state" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=15
mkdir -p "$LAVISH_AXI_STATE_DIR" "$RECEIPT_STUB_DIR"
cat > "$LABBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in --version|version) printf '0.1.80\n'; exit 0 ;; esac
board=; for a in "$@"; do case "$a" in *.html) board=${a##*/} ;; esac; done
count="$RECEIPT_STUB_DIR/${board:-none}.polls"; n=$(cat "$count" 2>/dev/null || printf 0); printf '%s\n' "$((n + 1))" > "$count"
if [ "$n" -ge 1 ]; then while [ "$SECONDS" -lt 90 ]; do sleep 0.2; done; exit 75; fi
printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","Ship the PNG export at 2x and drop the SVG path","","message",""\n'
SH
chmod +x "$LABBIN/lavish-axi"
export PATH="$LABBIN:$PATH"
python3 "$ROOT/tests/fixtures/fm-claude-tool-call-stub.py" "$TMP_ROOT/port" "python3 -c 'import time; time.sleep(30)'; echo long-validation-done" "$CAPTURE" &
STUB_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP_ROOT/port" ] && break; sleep 0.1; done
port=$(cat "$TMP_ROOT/port")
tmux new-session -d -s fmtest -n "fm-$ID" -x 200 -y 50 -c "$WT" \
  "env -i PATH='$PATH' HOME='$TMP_ROOT/user-home' TERM=xterm CLAUDE_CONFIG_DIR='$TMP_ROOT/claude-config' ANTHROPIC_API_KEY=sk-ant-synthetic-stub-only ANTHROPIC_BASE_URL=http://127.0.0.1:$port DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude -p 'run the check' --max-turns 3 --dangerously-skip-permissions </dev/null > '$TMP_ROOT/claude.out' 2>&1; touch '$TMP_ROOT/claude.done'; sleep 120"
PANE="fmtest:fm-$ID"; tmux list-panes -t "$PANE" >/dev/null || fail "no lab window"
perl -pi -e "s/^window=.*/window=$PANE/" "$STATE/$ID.meta"
echo "worker pane on lab socket: $PANE"; grep -E '^(window|harness|backend)=' "$STATE/$ID.meta"
for _ in $(seq 1 300); do [ -e "$STATE/$ID.progress" ] && break; sleep 0.1; done
[ -e "$STATE/$ID.progress" ] || fail "worker never entered its long step: $(cat $TMP_ROOT/claude.out) (no PreToolUse progress marker): $(cat $TMP_ROOT/claude.out 2>/dev/null)"
sleep 1; echo "tool call started (PreToolUse progress marker present); claude processes: $(pgrep -f "claude -p" | wc -l)"
echo "=== $(date +%T) worker is in a 30s step (python3 sleep 30). busy record:"; cat "$STATE/$ID.busy-state"
# captain answers the worker-owned board
BOARD="$TMP_ROOT/decklist-export.html"; printf '<h1>decklist export round 2</h1>\n' > "$BOARD"
perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -MEncode=decode -e '
  my ($path, $a) = @ARGV; my $real = realpath($a); my $key = substr(sha256_hex($real), 0, 16);
  my $s = { sessions => { $key => { key => $key, file => decode("UTF-8",$real), status => "open", url => "http://127.0.0.1:14387/session/0123456789abcdef" } } };
  open my $o, ">", $path or die; print $o encode_json($s);' "$LAVISH_AXI_STATE_DIR/state.json" "$BOARD"
SRC=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$BOARD")
fm_test_track_procevent_home "$H"
FM_HOME="$H" "$ROOT/bin/fm-procevent-lavish.sh" arm "$BOARD" --for "$ID" >/dev/null || fail "arm"
R="$STATE/board-receipts/$SRC.1.receipt"
for _ in $(seq 1 150); do [ -f "$STATE/$ID.inbox/001.msg" ] && [ -f "$R" ] && break; sleep 0.1; done
[ -f "$R" ] || fail "round never delivered"
echo "=== $(date +%T) answer delivered to steering inbox while worker mid-step; receipt:"; cat "$R"
[ ! -e "${R%.receipt}.midturn" ] || fail "handed over before step boundary"
# alarm delay passes (age the delivery 6m instead of sleeping), supervision cycle runs
d=$(sed -n 's/^delivered_at=//p' "$R"); perl -0pi -e "s/^delivered_at=$d\$/delivered_at=$((d - 360))/m" "$R"
FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
echo "=== busy-state at reconcile:"; cat "$STATE/$ID.busy-state"; echo "=== live classification (fm_busy_classify_live):"; bash -c ". $ROOT/bin/fm-pr-lib.sh; . $ROOT/bin/fm-backend.sh; . $ROOT/bin/fm-busy-lib.sh; m=$STATE/$ID.meta; fm_busy_classify_live \"\$(fm_backend_of_meta \$m)\" \"\$(fm_backend_target_of_meta \$m)\" claude $ID $STATE; echo"
echo "=== $(date +%T) wake queued for firstmate by reconcile while worker still busy:"
awk -F '\t' -v k=":$SRC:" 'index($4,k){print $4; print $5}' "$STATE/.wake-queue" | tee "$TMP_ROOT/alarm.txt"
grep -q "unacknowledged:1" "$TMP_ROOT/alarm.txt" || fail "no alarm for busy worker"
grep -q "busy in a turn; its current step started" "$TMP_ROOT/alarm.txt" || fail "alarm does not report busy step"
grep -q "No mid-turn handoff is recorded" "$TMP_ROOT/alarm.txt" || fail "alarm handoff claim wrong"
grep -q "message: Ship the PNG export at 2x and drop the SVG path" "$TMP_ROOT/alarm.txt" || fail "alarm lacks answer"
# step ends: hook hands the answer over
for _ in $(seq 1 600); do [ -e "$TMP_ROOT/claude.done" ] && break; sleep 0.1; done
[ -e "$TMP_ROOT/claude.done" ] || fail "claude did not finish"
echo "=== $(date +%T) worker's step ended; midturn marker:"; cat "${R%.receipt}.midturn"
echo "=== context Claude Code put in front of the model after that step:"
tail -1 "$CAPTURE" | jq -r '[.. | strings | select(test("review-board answer"))] | unique | .[]' | tee "$TMP_ROOT/ctx.txt"
grep -q "001.msg" "$TMP_ROOT/ctx.txt" || fail "handoff not delivered to model"
echo "=== worker reads the round (its FM_TASK_INBOX), next cycle:"
FM_TASK_INBOX="$STATE/$ID.inbox" "$ROOT/bin/fm-procevent-lavish.sh" read "$STATE/procevent-inbox/$SRC.1.result" | sed -n '1,12p'
FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
grep -E '^(state|acknowledged_by)=' "$R"
awk -F '\t' -v k=":$SRC:acknowledged:1" 'index($4,k){print $4; print $5}' "$STATE/.wake-queue"
grep -q '^acknowledged_by=read' "$R" || fail "read not recorded as pickup"
pass "busy Claude worker: answer alarmed with turn+answer while busy, handed over at step end, cleared on read"
