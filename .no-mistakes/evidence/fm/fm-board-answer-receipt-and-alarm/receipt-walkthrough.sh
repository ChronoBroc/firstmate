#!/usr/bin/env bash
set -u
ROOT=$1; T=$2
export FM_PROCEVENT_CLAIM_ROOT="$T/claims" LAVISH_AXI_STATE_DIR="$T/lavish-state" STUB="$T/stub"
export FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=15 FM_PROCEVENT_RECEIPT_ALARM_SECONDS=5
mkdir -p "$LAVISH_AXI_STATE_DIR" "$STUB" "$T/bin"
cat > "$T/bin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in --version|version) printf '0.1.80\n'; exit 0 ;; esac
board=; for a in "$@"; do case "$a" in *.html) board=${a##*/} ;; esac; done
c="$STUB/${board:-none}.polls"; n=$(cat "$c" 2>/dev/null || echo 0); echo $((n+1)) > "$c"
if [ "$n" -ge 1 ]; then while [ "$SECONDS" -lt 60 ]; do sleep 0.2; done; exit 75; fi
printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","go with option B","","message",""\n'
SH
chmod +x "$T/bin/lavish-axi"; export PATH="$T/bin:$PATH"
H="$T/home"; mkdir -p "$H/state"
session() { perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -MEncode=decode -e '
 my ($p,$a)=@ARGV; my $r=realpath($a); my $k=substr(sha256_hex($r),0,16); my $s={sessions=>{}};
 if(-f $p){open my $i,"<",$p; local $/; $s=decode_json(<$i>);}
 $s->{sessions}{$k}={key=>$k,file=>decode("UTF-8",$r),status=>"open",url=>"http://127.0.0.1:14387/session/0123456789abcdef"};
 open my $o,">",$p; print $o encode_json($s);' "$LAVISH_AXI_STATE_DIR/state.json" "$1"; }
cycle() { echo "\$ fm-procevent.sh reconcile   # one supervision cycle"; FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1; }
show() { echo "--- $1"; cat "$1"; }
wq() { echo "--- wake queue rows for $1:"; awk -F '\t' -v k="$1" 'index($4,k){print "  " $3 "\t" $4 "\t" $5}' "$H/state/.wake-queue" 2>/dev/null; echo "  (end)"; }
arm() { local task=$1 b=$2
  printf 'window=fmtest:fm-%s\nworktree=%s/wt\nproject=fmtest\n' "$task" "$H" > "$H/state/$task.meta"
  printf '<h1>%s</h1>\n' "$task" > "$b"; session "$b"
  echo "\$ fm-procevent-lavish.sh arm ${b##*/} --for $task"
  FM_HOME="$H" "$ROOT/bin/fm-procevent-lavish.sh" arm "$b" --for "$task"
  SRC=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$b")
  for _ in $(seq 1 150); do [ -f "$H/state/board-receipts/$SRC.1.receipt" ] && break; sleep 0.1; done
  R="$H/state/board-receipts/$SRC.1.receipt"; RES="$H/state/procevent-inbox/$SRC.1.result"
  echo "--- inbox of $task:"; ls "$H/state/$task.inbox"; show "$R"; }

echo "===== Scenario A: prompt worker reads its round, then draws past the alarm delay ====="
arm w-prompt "$T/boardA.html"
echo "\$ FM_TASK_INBOX=state/w-prompt.inbox fm-procevent-lavish.sh read <result>   # the worker's first step"
FM_TASK_INBOX="$H/state/w-prompt.inbox" "$ROOT/bin/fm-procevent-lavish.sh" read "$RES" | head -5
cycle; show "$R"
echo "(sleeping 7s, past the 5s alarm delay, worker still 'drawing', record not filed)"; sleep 7; cycle; cycle
wq ":$SRC:"
A_SRC=$SRC

echo; echo "===== Scenario B: stuck worker; firstmate and another worker read it, owner never does ====="
arm w-stuck "$T/boardB.html"
echo "\$ fm-procevent-lavish.sh read <result>   # firstmate's own read, no FM_TASK_INBOX"
env -u FM_TASK_INBOX "$ROOT/bin/fm-procevent-lavish.sh" read "$RES" >/dev/null
echo "\$ FM_TASK_INBOX=state/w-other.inbox fm-procevent-lavish.sh read <result>   # a different worker"
FM_TASK_INBOX="$H/state/w-other.inbox" "$ROOT/bin/fm-procevent-lavish.sh" read "$RES" >/dev/null
cycle; show "$R"; wq ":$SRC:"
echo "(sleeping 7s past alarm delay)"; sleep 7; cycle; cycle; cycle
show "$R"; wq ":$SRC:"
echo "\$ worker finally (after nudge) reads its round"
FM_TASK_INBOX="$H/state/w-stuck.inbox" "$ROOT/bin/fm-procevent-lavish.sh" read "$RES" >/dev/null
cycle; cycle; show "$R"; wq ":$SRC:"
B_SRC=$SRC
echo; echo "===== cleanup ====="
FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1; echo "sweep-home exit $?"
