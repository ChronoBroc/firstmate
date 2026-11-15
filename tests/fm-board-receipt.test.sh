#!/usr/bin/env bash
# Behavior tests for the receipt and alarm on a review-board answer delivered
# to its owning worker (bin/fm-board-receipt-lib.sh, docs/configuration.md
# "Board answer receipts").
#
# Each case arms a real worker-owned Lavish board through the public adapter
# against a fake lavish-axi that returns one answered round and then blocks, so
# the round reaches the worker's steering inbox exactly as it does in a live
# home. The worker is played by reading its round from its own session and
# moving (or not moving) that inbox record, and
# firstmate's supervision cycle by `bin/fm-procevent.sh reconcile`, which the
# watcher runs once per cycle. No firstmate turn is involved anywhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-board-receipt-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state"
# Arming waits for its listener to prove it started; give a loaded host room.
export FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=15
mkdir -p "$LAVISH_AXI_STATE_DIR"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/lavish-stub")
export RECEIPT_STUB_DIR="$TMP_ROOT/stub-state"
mkdir -p "$RECEIPT_STUB_DIR"
# One answered round per board, then a poll that blocks like a quiet board.
# The block is bounded so an escaped stub cannot outlive the suite for long.
cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in --version|version) printf '0.1.80\n'; exit 0 ;; esac
board=
for a in "$@"; do case "$a" in *.html) board=${a##*/} ;; esac; done
count="$RECEIPT_STUB_DIR/${board:-none}.polls"
n=$(cat "$count" 2>/dev/null || printf 0)
printf '%s\n' "$((n + 1))" > "$count"
if [ "$n" -ge 1 ]; then
  while [ "$SECONDS" -lt 120 ]; do sleep 0.2; done
  exit 75
fi
printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","all four as recommended","","message",""\n'
SH
chmod +x "$FAKEBIN/lavish-axi"
export PATH="$FAKEBIN:$PATH"

lavish_session() {  # <artifact>
  perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -MEncode=decode -e '
    my ($path, $artifact) = @ARGV;
    my $real = realpath($artifact) // die "missing fixture artifact";
    my $key = substr(sha256_hex($real), 0, 16);
    my $state = { sessions => {} };
    if (-f $path) { open my $in, "<", $path or die $!; local $/; $state = decode_json(<$in>); }
    $state->{sessions}{$key} = {
      key => $key, file => decode("UTF-8", $real), status => "open",
      url => "http://127.0.0.1:14387/session/0123456789abcdef",
    };
    open my $out, ">", $path or die $!;
    print $out encode_json($state);
  ' "$LAVISH_AXI_STATE_DIR/state.json" "$1"
}

# A home with one worker that owns one armed board, its answered round already
# in the worker's steering inbox. Sets HOME_DIR, BOARD, SRC.
armed_board() {  # <case-name> <task>
  local name=$1 task=$2 _
  HOME_DIR="$TMP_ROOT/$name"
  mkdir -p "$HOME_DIR/state"
  printf 'window=fmtest:fm-%s\nworktree=%s/worktree\nproject=fmtest\n' "$task" "$HOME_DIR" \
    > "$HOME_DIR/state/$task.meta"
  BOARD="$TMP_ROOT/$name-board.html"
  printf '<h1>%s</h1>\n' "$name" > "$BOARD"
  lavish_session "$BOARD"
  SRC=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$BOARD")
  fm_test_track_procevent_home "$HOME_DIR"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent-lavish.sh" arm "$BOARD" --for "$task" >/dev/null \
    || fail "$name: the board could not be armed for $task"
  for _ in $(seq 1 150); do
    [ -f "$HOME_DIR/state/$task.inbox/001.msg" ] && [ -f "$(receipt 1)" ] && return 0
    sleep 0.1
  done
  fail "$name: the answered round never reached $task's steering inbox with a receipt"
}

receipt() { printf '%s/state/board-receipts/%s.%s.receipt\n' "$HOME_DIR" "$SRC" "$1"; }
field() { sed -n "s/^$2=//p" "$1" | head -1; }
cycle() { FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1 || true; }
result_file() { printf '%s/state/procevent-inbox/%s.%s.result\n' "$HOME_DIR" "$SRC" "$1"; }
# The worker reads its round from its own session, as the delivered record says.
worker_read() {  # <task> <seq>
  FM_TASK_INBOX="$HOME_DIR/state/$1.inbox" "$ROOT/bin/fm-procevent-lavish.sh" read "$(result_file "$2")" >/dev/null \
    || fail "the worker could not read round $2"
}
take() { mv "$HOME_DIR/state/$1.inbox/001.msg" "$HOME_DIR/state/$1.inbox/handled/001.msg"; }
wake_rows() {  # <key-fragment>: queue rows whose key contains it
  [ -f "$HOME_DIR/state/.wake-queue" ] || return 0
  awk -F '\t' -v k="$1" 'index($4, k) { print $3 "\t" $4 "\t" $5 }' "$HOME_DIR/state/.wake-queue"
}
row_count() { wake_rows "$1" | awk 'END { print NR + 0 }'; }
# Age the receipt's delivery so the alarm delay has passed, without sleeping.
age_delivery() {  # <seq> <seconds>
  local f d
  f=$(receipt "$1")
  d=$(field "$f" delivered_at)
  perl -0pi -e "s/^delivered_at=$d\$/delivered_at=$((d - $2))/m" "$f"
}

test_taken_answer_is_acknowledged_without_a_wake() {
  armed_board taken w-taken
  [ "$(field "$(receipt 1)" state)" = delivered ] \
    || fail "a fresh delivery was not recorded as waiting on the worker"
  [ "$(field "$(receipt 1)" task)" = w-taken ] || fail "the receipt does not name its worker"
  [ "$(field "$(receipt 1)" board)" = "$(cd -P "${BOARD%/*}" && pwd -P)/${BOARD##*/}" ] \
    || fail "the receipt does not name its board artifact: $(field "$(receipt 1)" board)"
  take w-taken
  cycle
  [ "$(field "$(receipt 1)" state)" = acknowledged ] \
    || fail "a supervision cycle did not record the worker taking the answer: $(cat "$(receipt 1)")"
  [ "$(field "$(receipt 1)" acknowledged_by)" = inbox ] \
    || fail "the acknowledgement does not name the inbox filing"
  age_delivery 1 100000
  cycle
  [ "$(row_count ":$SRC:")" = 0 ] || fail "a taken answer woke firstmate: $(wake_rows ":$SRC:")"
  pass "an answer the worker took is acknowledged by the next cycle and costs no wake"
}

test_answer_read_then_worked_at_length_is_acknowledged_at_pickup() {
  armed_board drawing w-draw
  [ -f "$(result_file 1)" ] || fail "the captured round is not where its record says"
  before=$(date +%s)
  worker_read w-draw 1
  after=$(date +%s)
  cycle
  [ "$(field "$(receipt 1)" state)" = acknowledged ] \
    || fail "the worker reading its round was not recorded as the pickup: $(cat "$(receipt 1)")"
  [ "$(field "$(receipt 1)" acknowledged_by)" = read ] || fail "the acknowledgement does not name the read"
  at=$(field "$(receipt 1)" acknowledged_at)
  [ "$at" -ge "$before" ] && [ "$at" -le "$after" ] \
    || fail "the acknowledgement is not dated at the read ($before..$after): $at"
  age_delivery 1 3600
  cycle
  cycle
  take w-draw
  cycle
  [ "$(row_count ":$SRC:")" = 0 ] || fail "a worker drawing for an hour after reading woke firstmate: $(wake_rows ":$SRC:")"
  [ "$(field "$(receipt 1)" acknowledged_at)" = "$at" ] || fail "the later filing moved the pickup time"
  pass "a worker that reads its round, works it for an hour, then files it is acknowledged at the read and never alarms"
}

test_untaken_answer_alarms_once_and_clears_on_pickup() {
  armed_board untaken w-stuck
  env -u FM_TASK_INBOX "$ROOT/bin/fm-procevent-lavish.sh" read "$(result_file 1)" >/dev/null \
    || fail "firstmate could not read the round"
  FM_TASK_INBOX="$HOME_DIR/state/w-other.inbox" "$ROOT/bin/fm-procevent-lavish.sh" read "$(result_file 1)" >/dev/null \
    || fail "another worker could not read the round"
  cycle
  [ "$(row_count ":$SRC:")" = 0 ] || fail "an answer still inside its alarm delay woke firstmate"
  age_delivery 1 400
  cycle
  cycle
  cycle
  [ "$(row_count ":$SRC:unacknowledged:1")" = 1 ] \
    || fail "an answer the worker never took did not raise exactly one alarm: $(wake_rows ":$SRC:")"
  row=$(wake_rows ":$SRC:unacknowledged:1")
  assert_contains "$row" "check	procevent:$SRC:unacknowledged:1" "the alarm is a main-owned check wake keyed to the board round"
  assert_contains "$row" "task w-stuck" "the alarm names its worker"
  assert_contains "$row" "${BOARD##*/}" "the alarm names its board"
  assert_contains "$row" "6m" "the alarm says how long the answer has waited"
  [ -n "$(field "$(receipt 1)" alarmed_at)" ] || fail "the receipt does not record its alarm"
  [ "$(field "$(receipt 1)" state)" = delivered ] || fail "an alarm changed the receipt's state"
  take w-stuck
  cycle
  cycle
  [ "$(field "$(receipt 1)" state)" = acknowledged ] || fail "the late pickup was not recorded"
  [ "$(row_count ":$SRC:acknowledged:1")" = 1 ] \
    || fail "the late pickup did not clear its alarm exactly once: $(wake_rows ":$SRC:")"
  [ "$(row_count ":$SRC:unacknowledged:1")" = 1 ] || fail "the late pickup re-raised the alarm"
  pass "an answer the worker never took alarms once after the delay and clears once on pickup"
}

test_acknowledged_round_counts_when_the_record_was_not_filed() {
  armed_board rearmed w-rearm
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" handled "$SRC" 1 >/dev/null \
    || fail "the round could not be acknowledged"
  age_delivery 1 400
  cycle
  [ "$(field "$(receipt 1)" state)" = acknowledged ] \
    || fail "an acknowledged round was left waiting on its worker: $(cat "$(receipt 1)")"
  [ "$(field "$(receipt 1)" acknowledged_by)" = round-handled ] \
    || fail "the acknowledgement does not name the round's own handled marker"
  [ "$(row_count ":$SRC:")" = 0 ] || fail "an acknowledged round raised an alarm: $(wake_rows ":$SRC:")"
  pass "a round its worker acknowledged counts as taken even when the inbox record stayed"
}

test_alarm_delay_is_tunable_and_bounded() {
  armed_board tuned w-tuned
  [ "$(field "$(receipt 1)" alarm_after)" = 300 ] || fail "the default alarm delay is not 300 seconds"
  age_delivery 1 30
  FM_PROCEVENT_RECEIPT_ALARM_SECONDS=10 cycle
  [ "$(row_count ":$SRC:unacknowledged:")" = 0 ] \
    || fail "a changed delay applied to a receipt written under the earlier one"
  perl -0pi -e 's/^alarm_after=300$/alarm_after=20/m' "$(receipt 1)"
  cycle
  [ "$(row_count ":$SRC:unacknowledged:1")" = 1 ] || fail "a receipt's own shorter delay did not alarm"
  out=$(FM_PROCEVENT_RECEIPT_ALARM_SECONDS=junk bash -c '. "$1/bin/fm-board-receipt-lib.sh"; fm_board_receipt_alarm_seconds' _ "$ROOT")
  [ "$out" = 300 ] || fail "an invalid delay did not fall back to the default: $out"
  out=$(FM_PROCEVENT_RECEIPT_ALARM_SECONDS=90 bash -c '. "$1/bin/fm-board-receipt-lib.sh"; fm_board_receipt_alarm_seconds' _ "$ROOT")
  [ "$out" = 90 ] || fail "a valid delay was not honored: $out"
  pass "the alarm delay defaults to five minutes, is tunable, and a receipt keeps the delay it was written with"
}

test_retired_worker_receipt_is_pruned_without_an_alarm() {
  armed_board retired w-gone
  rm -f "$HOME_DIR/state/w-gone.meta"
  age_delivery 1 400
  cycle
  [ ! -e "$(receipt 1)" ] || fail "a retired worker's receipt was kept"
  [ "$(row_count ":$SRC:")" = 0 ] || fail "a retired worker's receipt raised an alarm"
  pass "a retired worker's receipt is pruned without an alarm"
}

fm_test_run \
  test_taken_answer_is_acknowledged_without_a_wake \
  test_answer_read_then_worked_at_length_is_acknowledged_at_pickup \
  test_untaken_answer_alarms_once_and_clears_on_pickup \
  test_acknowledged_round_counts_when_the_record_was_not_filed \
  test_alarm_delay_is_tunable_and_bounded \
  test_retired_worker_receipt_is_pruned_without_an_alarm
