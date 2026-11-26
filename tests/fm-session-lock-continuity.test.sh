#!/usr/bin/env bash
# tests/fm-session-lock-continuity.test.sh - session-lock ownership continuity
# (bin/fm-session-lock-lib.sh, bin/fm-lock.sh) across a recycled background
# helper chain, a same-session re-key, a failed lock write, and a re-anchor.
#
# The cases run the REAL bin/fm-lock.sh and, where a scenario needs them, the
# Stop auto-arm and turn-end guard, in fixture process trees whose ancestry
# walk terminates inside the fixture and never reaches the session running this
# suite. The identity unit cases and the platform layers live in
# tests/fm-session-lock-ancestry.test.sh.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/session-lock-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/session-lock-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-continuity)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- end-to-end layer: a background session whose helper chain is recycled ---
#
# The topology the four issue reports (#3902, #2314, #3398, #4066) recorded with
# real process listings: a front-end that acquired the lock, a transient daemon
# under it, the pty-host the daemon spawned, and the bg-spare inside the pty-host
# that runs the model loop and therefore fires every hook. Every fixture process
# is the fake claude, so the ancestry walk sees a contiguous claude-named run
# exactly as in production, and the tree is orphaned before use. The daemon is
# then ended while the front-end stays alive - the recycling that breaks the run
# above the pty-host - and the spare fires the real Stop auto-arm, the real
# turn-end guard, and the real lock script once per phase under a chosen hook
# environment, recording every verdict for the assertions below.

BG_FIXTURE_PIDS=()
reap_background_fixture() {
  local pid
  for pid in ${BG_FIXTURE_PIDS[@]+"${BG_FIXTURE_PIDS[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
}
trap 'reap_background_fixture; fm_test_cleanup' EXIT

make_background_session_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  # The whole bin, because the real turn-end guard composes far more of it than
  # the auto-arm alone; only the arm is replaced by the recording stub above.
  cp -R "$ROOT/bin" "$dir/bin"
  install_autoarm_scripts "$dir"
  # Every fixture script ends in an explicit exit so bash can never tail-exec the
  # script under test in place of the fake claude, which would collapse the
  # chain the assertions depend on.
  cat > "$dir/frontend.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/frontend-pid"
CLAUDE_CODE_SESSION_ID=S1 "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/frontend-lock.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/frontend-lock.rc"
"$FM_FIXTURE_CLAUDE" "$FM_HOME/daemon.sh" &
disown
while [ ! -e "$FM_HOME/state/stop-frontend" ] && kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null \
  && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.05; done
exit 0
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
exec -a 'claude bg-pty-host' "$FM_FIXTURE_CLAUDE" "$FM_HOME/ptyhost.sh" &
while kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.1; done
exit 0
SH
  cat > "$dir/ptyhost.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/ptyhost-pid"
exec -a 'claude bg-spare' "$FM_FIXTURE_CLAUDE" "$FM_HOME/spare.sh" &
while [ ! -e "$FM_HOME/state/stop-spare" ] && kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null \
  && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.1; done
exit 0
SH
  cat > "$dir/spare.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/spare-pid"
n=1
while [ ! -e "$FM_HOME/state/stop-spare" ] && kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null \
  && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do
  req="$FM_HOME/state/fire-$n"
  if [ -f "$req" ]; then
    out="$FM_HOME/state/phase-$n"
    mkdir -p "$out"
    unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
    # shellcheck disable=SC1090
    . "$req"
    ( . "$FM_HOME/bin/fm-session-lock-lib.sh" && fm_harness_ancestry_pids ) > "$out/ancestry" 2>/dev/null
    printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
      | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$out/hook.out" 2>&1
    printf '%s\n' "$?" > "$out/hook.rc"
    printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
      | "$FM_HOME/bin/fm-turnend-guard.sh" --claude > "$out/guard.out" 2>&1
    printf '%s\n' "$?" > "$out/guard.rc"
    "$FM_HOME/bin/fm-lock.sh" > "$out/lock.out" 2>&1
    printf '%s\n' "$?" > "$out/lock.rc"
    cp "$FM_HOME/state/.lock" "$out/lock-after"
    [ ! -e "$FM_HOME/state/.lock-session" ] || cp "$FM_HOME/state/.lock-session" "$out/session-after"
    : > "$out/done"
    n=$((n + 1))
  fi
  sleep 0.05
done
exit 0
SH
  chmod +x "$dir/frontend.sh" "$dir/daemon.sh" "$dir/ptyhost.sh" "$dir/spare.sh"
}

wait_for_file() {  # <path> <what>
  local i=0
  while [ "$i" -lt 400 ] && [ ! -s "$1" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$1" ] || fail "background-session fixture never produced $2"
}

fire_phase() {  # <dir> <n> <hook-environment-script>
  local dir=$1 n=$2
  printf '%s\n' "$3" > "$dir/state/fire-$n.tmp"
  mv "$dir/state/fire-$n.tmp" "$dir/state/fire-$n"
  wait_for_file "$dir/state/phase-$n/hook.rc" "phase $n"
  local i=0
  while [ "$i" -lt 400 ] && [ ! -e "$dir/state/phase-$n/done" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$dir/state/phase-$n/done" ] || fail "background-session fixture never finished phase $n"
}

phase_value() {  # <dir> <n> <file>
  tr -d '[:space:]' < "$1/state/phase-$2/$3"
}

arm_count() {  # <dir>
  [ -e "$1/state/arm-ran" ] || { printf '0'; return; }
  wc -l < "$1/state/arm-ran" | tr -d ' '
}

# The recycled chain must still be treated as the owner: arm, no diagnostic,
# lock accepted, line 1 naming <expected-lock-pid>, and the sidecar naming
# <expected-session-id>. An owned actionable close records two arm
# invocations - the foreground arm plus the handling successor the hook starts
# before the rewake - so the cumulative <expected-arms> grows by two for every
# owned phase.
expect_phase_owned() {  # <dir> <n> <expected-arms> <expected-lock-pid> <label> <expected-session-id>
  local dir=$1 n=$2 arms=$3 lock_pid=$4 label=$5 session_id=$6
  expect_code 2 "$(phase_value "$dir" "$n" hook.rc)" "$label: the Stop auto-arm did not rewake"
  [ "$(arm_count "$dir")" = "$arms" ] || fail "$label: expected $arms arm(s), got $(arm_count "$dir")"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "$label: no rewake claim was recorded, got: $(epoch_outcome "$dir")"
  expect_code 0 "$(phase_value "$dir" "$n" guard.rc)" "$label: the turn-end guard did not allow the stop"
  if grep -q 'OWNED BY ANOTHER LIVE SESSION' "$dir/state/phase-$n/guard.out"; then
    fail "$label: the turn-end guard took the foreign-owner exit: $(cat "$dir/state/phase-$n/guard.out")"
  fi
  expect_code 0 "$(phase_value "$dir" "$n" lock.rc)" "$label: fm-lock.sh refused the session's own lock: $(cat "$dir/state/phase-$n/lock.out")"
  [ "$(phase_value "$dir" "$n" lock-after)" = "$lock_pid" ] \
    || fail "$label: lock line 1 is $(phase_value "$dir" "$n" lock-after), expected $lock_pid"
  [ "$(sed -n 1p "$dir/state/phase-$n/session-after")" = "$session_id" ] \
    || fail "$label: the session sidecar names $(cat "$dir/state/phase-$n/session-after"), expected $session_id"
}

# Not the owner: no arm, the guard's foreign-owner diagnostic naming the live
# owner, and the lock refusal naming both the owner pid and its recorded id.
expect_phase_foreign() {  # <dir> <n> <expected-arms> <owner-pid> <label>
  local dir=$1 n=$2 arms=$3 owner=$4 label=$5
  expect_code 0 "$(phase_value "$dir" "$n" hook.rc)" "$label: the Stop auto-arm did not stand down"
  [ "$(arm_count "$dir")" = "$arms" ] || fail "$label: a non-owner armed: $(arm_count "$dir") arm(s), expected $arms"
  expect_code 0 "$(phase_value "$dir" "$n" guard.rc)" "$label: a non-owner Stop did not end safely"
  grep -q "OWNED BY ANOTHER LIVE SESSION: this read-only session.*lock owner pid $owner)" "$dir/state/phase-$n/guard.out" \
    || fail "$label: the guard did not report the live owner $owner: $(cat "$dir/state/phase-$n/guard.out")"
  expect_code 1 "$(phase_value "$dir" "$n" lock.rc)" "$label: fm-lock.sh accepted a lock this session does not own"
  grep -q "another live firstmate session holds the lock (pid $owner, session S1)" "$dir/state/phase-$n/lock.out" \
    || fail "$label: the refusal did not name the owner pid and recorded session: $(cat "$dir/state/phase-$n/lock.out")"
  [ "$(phase_value "$dir" "$n" lock-after)" = "$owner" ] || fail "$label: a non-owner rewrote the lock"
}

test_e2e_background_session_keeps_its_lock_across_a_recycled_chain() {
  local dir frontend daemon ptyhost spare i
  dir="$TMP_ROOT/e2e-background-session"
  make_background_session_home "$dir"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_FIXTURE_CLAUDE="$NAMED_CLAUDE" FM_POLL=1 FM_HEARTBEAT=999999 \
    FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 \
    bash -c '"$0" "$1" &' "$NAMED_CLAUDE" "$dir/frontend.sh"
  wait_for_file "$dir/state/frontend-lock.rc" "the front-end's lock result"
  wait_for_file "$dir/state/spare-pid" "the bg-spare"
  frontend=$(tr -d '[:space:]' < "$dir/state/frontend-pid")
  daemon=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  ptyhost=$(tr -d '[:space:]' < "$dir/state/ptyhost-pid")
  spare=$(tr -d '[:space:]' < "$dir/state/spare-pid")
  BG_FIXTURE_PIDS+=("$frontend" "$daemon" "$ptyhost" "$spare")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/frontend-lock.rc")" "the front-end could not acquire the lock: $(cat "$dir/state/frontend-lock.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$frontend" ] \
    || fail "the front-end's lock names $(cat "$dir/state/.lock"), expected its own pid $frontend"
  [ ! -e "$dir/state/.lock-session" ] \
    || fail "the front-end, which is not the model loop, recorded a trusted session id: $(cat "$dir/state/.lock-session")"

  # Phase 1: the healthy contiguous chain, the session's own id. Line 1 stays on
  # the front-end, an ancestor, and the sidecar records the id with the spare,
  # the session's CLAUDE_PID, as its model-loop anchor.
  fire_phase "$dir" 1 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  grep -qx "$frontend" "$dir/state/phase-1/ancestry" || fail "the healthy chain did not reach the front-end"
  expect_phase_owned "$dir" 1 2 "$frontend" "healthy chain" S1
  [ "$(sed -n 2p "$dir/state/.lock-session")" = "anchor=$spare" ] \
    || fail "the sidecar beside a front-end line 1 did not record the spare as its anchor: $(cat "$dir/state/.lock-session")"

  # Recycle the bridge: the daemon ends, the pty-host is reparented to init, and
  # the front-end that holds the lock stays alive.
  kill -TERM "$daemon"
  i=0
  while [ "$i" -lt 200 ] && { kill -0 "$daemon" 2>/dev/null || [ "$(ps -o ppid= -p "$ptyhost" 2>/dev/null | tr -d ' ')" != 1 ]; }; do
    sleep 0.05
    i=$((i + 1))
  done
  [ "$(ps -o ppid= -p "$ptyhost" 2>/dev/null | tr -d ' ')" = 1 ] || fail "the pty-host was not reparented to init after the daemon ended"
  kill -0 "$frontend" 2>/dev/null || fail "the front-end died with the daemon, so the recycled case cannot be exercised"

  # Phases 2-4: before the spare proves anything, a different id, the right id
  # from a CLAUDE_PID outside the run, and no id at all are each a non-owner
  # over the broken chain.
  fire_phase "$dir" 2 'export CLAUDE_CODE_SESSION_ID=S2; export CLAUDE_PID=$$'
  if grep -qx "$frontend" "$dir/state/phase-2/ancestry"; then
    fail "the recycled chain still reached the front-end, so these phases prove nothing"
  fi
  grep -qx "$spare" "$dir/state/phase-2/ancestry" || fail "the hook's ancestry lost its own spare"
  expect_phase_foreign "$dir" 2 2 "$frontend" "recycled chain, different session"
  fire_phase "$dir" 3 "export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$frontend"
  expect_phase_foreign "$dir" 3 2 "$frontend" "recycled chain, untrusted id"
  fire_phase "$dir" 4 ''
  expect_phase_foreign "$dir" 4 2 "$frontend" "recycled chain, no id"

  # Phase 5: the same session id over the broken chain - the reported drift. The
  # recorded anchor is the spare itself, so the confirmation re-anchors line 1
  # from the live non-ancestor front-end onto the spare - the model-loop
  # process - not onto the outermost pty-host.
  fire_phase "$dir" 5 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  expect_phase_owned "$dir" 5 4 "$spare" "recycled chain, same session" S1
  [ "$(sed -n 2p "$dir/state/phase-5/session-after")" = "anchor=$spare" ] \
    || fail "the re-anchor did not record the spare as the model-loop anchor: $(cat "$dir/state/phase-5/session-after")"
  [ "$spare" != "$ptyhost" ] || fail "fixture collapsed the spare into the pty-host"
  kill -0 "$frontend" 2>/dev/null || fail "the front-end exited, so the re-anchor was not over a live owner"

  # Phase 6: /clear - the same spare under a new id while the front-end that
  # first recorded the lock is still alive. Ancestry still proves ownership and
  # the sidecar is re-keyed.
  fire_phase "$dir" 6 'export CLAUDE_CODE_SESSION_ID=S2; export CLAUDE_PID=$$'
  expect_phase_owned "$dir" 6 6 "$spare" "same process after a session-id change" S2

  : > "$dir/state/stop-frontend"
  : > "$dir/state/stop-spare"
  pass "session-lock e2e: a background session keeps its lock and its supervision across a recycled helper chain and a same-process session-id change"
}

# A same-session confirmation must refresh a /clear re-key even while another
# process holds .lock.acquire. The prior-session-sweep-is-finishing refusal is
# a takeover rule and does not apply here; the confirmation waits, then writes
# the new id.
test_same_session_confirmation_refreshes_rekeyed_id_under_claim_lock() {
  local dir session_pid holder_pid confirm_pid
  dir="$TMP_ROOT/confirm-under-claim"
  mkdir -p "$dir/state"
  cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
acquire_rc=$?
if [ "$acquire_rc" != 0 ]; then
  printf '%s\n' "$acquire_rc" > "$FM_HOME/state/acquire.rc"
  printf '%s\n' 1 > "$FM_HOME/state/confirm.rc"
  exit 1
fi
cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/sidecar-after-acquire"
printf '%s\n' 0 > "$FM_HOME/state/acquire.rc"

bash -c '
  set -u
  . "$1"
  fm_lock_try_acquire "$2/.lock.acquire" || exit 1
  : > "$2/holder-ready"
  while [ ! -e "$2/release-holder" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
  fm_lock_release "$2/.lock.acquire"
' _ "$FM_WAKE" "$FM_HOME/state" &
printf '%s\n' "$!" > "$FM_HOME/state/holder-pid"

i=0
while [ "$i" -lt 400 ] && [ ! -e "$FM_HOME/state/holder-ready" ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ ! -e "$FM_HOME/state/holder-ready" ]; then
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
fi

CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/confirm.out" 2>&1 &
printf '%s\n' "$!" > "$FM_HOME/state/confirm-pid"

i=0
while [ "$i" -lt 20 ]; do
  sleep 0.05
  i=$((i + 1))
done

: > "$FM_HOME/state/release-holder"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/confirm-pid")"
printf '%s\n' "$?" > "$FM_HOME/state/confirm.rc"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/holder-pid")" || true
SH
  chmod +x "$dir/run.sh"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_WAKE="$ROOT/bin/fm-wake-lib.sh" \
    "$NAMED_CLAUDE" "$dir/run.sh" &
  session_pid=$!
  BG_FIXTURE_PIDS+=("$session_pid")
  wait_for_file "$dir/state/acquire.rc" "the initial lock acquisition"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(sed -n 1p "$dir/state/sidecar-after-acquire")" = S1 ] \
    || fail "the initial acquire did not record S1"
  wait_for_file "$dir/state/holder-pid" "the claim-lock holder pid"
  holder_pid=$(tr -d '[:space:]' < "$dir/state/holder-pid")
  BG_FIXTURE_PIDS+=("$holder_pid")
  wait_for_file "$dir/state/confirm-pid" "the same-session confirmation pid"
  confirm_pid=$(tr -d '[:space:]' < "$dir/state/confirm-pid")
  BG_FIXTURE_PIDS+=("$confirm_pid")
  wait_for_file "$dir/state/confirm.rc" "the contended confirmation result"
  wait "$session_pid" || true
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/confirm.rc")" \
    "the same-session confirmation failed while the claim lock was held: $(cat "$dir/state/confirm.out")"
  [ "$(sed -n 1p "$dir/state/.lock-session")" = S2 ] \
    || fail "the sidecar still names $(cat "$dir/state/.lock-session"), expected the re-keyed id S2"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$(tr -d '[:space:]' < "$dir/state/session-pid")" ] \
    || fail "the confirmation rewrote lock line 1"
  grep -q 'lock acquired: harness pid' "$dir/state/confirm.out" \
    || fail "the confirmation did not report acquisition: $(cat "$dir/state/confirm.out")"
  pass "session-lock: a same-session confirmation waits for the claim lock and refreshes a re-keyed id"
}

# If another live session publishes while a confirmation is waiting on the claim
# lock, the waiter must not overwrite that session's sidecar or report success.
test_same_session_confirmation_does_not_steal_after_wait() {
  local dir session_pid holder_pid confirm_pid other_pid
  dir="$TMP_ROOT/confirm-no-steal"
  mkdir -p "$dir/state"
  cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
acquire_rc=$?
if [ "$acquire_rc" != 0 ]; then
  printf '%s\n' "$acquire_rc" > "$FM_HOME/state/acquire.rc"
  printf '%s\n' 1 > "$FM_HOME/state/confirm.rc"
  exit 1
fi
cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/sidecar-after-acquire"
printf '%s\n' 0 > "$FM_HOME/state/acquire.rc"

"$FM_CLAUDE" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/other-pid"
  while [ ! -e "$FM_HOME/state/stop-other" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
' &
printf '%s\n' "$!" > "$FM_HOME/state/other-bash-pid"
i=0
while [ "$i" -lt 400 ] && [ ! -s "$FM_HOME/state/other-pid" ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -s "$FM_HOME/state/other-pid" ] || {
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
}

bash -c '
  set -u
  . "$1"
  fm_lock_try_acquire "$2/.lock.acquire" || exit 1
  : > "$2/holder-ready"
  while [ ! -e "$2/release-holder" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
  fm_lock_release "$2/.lock.acquire"
' _ "$FM_WAKE" "$FM_HOME/state" &
printf '%s\n' "$!" > "$FM_HOME/state/holder-pid"

i=0
while [ "$i" -lt 400 ] && [ ! -e "$FM_HOME/state/holder-ready" ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ ! -e "$FM_HOME/state/holder-ready" ]; then
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
fi

CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/confirm.out" 2>&1 &
printf '%s\n' "$!" > "$FM_HOME/state/confirm-pid"

i=0
while [ "$i" -lt 20 ]; do
  sleep 0.05
  i=$((i + 1))
done

cp "$FM_HOME/state/other-pid" "$FM_HOME/state/.lock"
printf '%s\n' OTHER > "$FM_HOME/state/.lock-session"
: > "$FM_HOME/state/release-holder"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/confirm-pid")"
printf '%s\n' "$?" > "$FM_HOME/state/confirm.rc"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/holder-pid")" || true
: > "$FM_HOME/state/stop-other"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/other-bash-pid")" || true
SH
  chmod +x "$dir/run.sh"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_WAKE="$ROOT/bin/fm-wake-lib.sh" \
    FM_CLAUDE="$NAMED_CLAUDE" \
    "$NAMED_CLAUDE" "$dir/run.sh" &
  session_pid=$!
  BG_FIXTURE_PIDS+=("$session_pid")
  wait_for_file "$dir/state/acquire.rc" "the initial lock acquisition"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  wait_for_file "$dir/state/other-pid" "the other live harness pid"
  other_pid=$(tr -d '[:space:]' < "$dir/state/other-pid")
  BG_FIXTURE_PIDS+=("$other_pid")
  wait_for_file "$dir/state/holder-pid" "the claim-lock holder pid"
  holder_pid=$(tr -d '[:space:]' < "$dir/state/holder-pid")
  BG_FIXTURE_PIDS+=("$holder_pid")
  wait_for_file "$dir/state/confirm-pid" "the same-session confirmation pid"
  confirm_pid=$(tr -d '[:space:]' < "$dir/state/confirm-pid")
  BG_FIXTURE_PIDS+=("$confirm_pid")
  wait_for_file "$dir/state/confirm.rc" "the contended confirmation result"
  wait "$session_pid" || true
  [ "$(tr -d '[:space:]' < "$dir/state/confirm.rc")" != 0 ] \
    || fail "the waiter reported success after another live session published: $(cat "$dir/state/confirm.out")"
  [ "$(sed -n 1p "$dir/state/.lock-session")" = OTHER ] \
    || fail "the waiter overwrote the other session's sidecar to $(cat "$dir/state/.lock-session")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$other_pid" ] \
    || fail "the waiter rewrote lock line 1 off the other live session"
  grep -q "another live firstmate session holds the lock (pid $other_pid, session OTHER)" "$dir/state/confirm.out" \
    || fail "the waiter did not refuse the other live owner: $(cat "$dir/state/confirm.out")"
  pass "session-lock: a waiting confirmation does not steal another session's lock"
}

# A failed line-1 write after publishing a new id must restore the previous
# sidecar, not leave the new id beside the unclaimed pid.
test_failed_lock_write_restores_previous_sidecar() {
  local dir stale_pid
  dir="$TMP_ROOT/restore-sidecar"
  mkdir -p "$dir/state"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/acquire.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/stale-pid"
    '
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the first session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(sed -n 1p "$dir/state/.lock-session")" = S1 ] \
    || fail "the first session did not record S1"
  stale_pid=$(tr -d '[:space:]' < "$dir/state/stale-pid")
  anchored_sidecar "$dir/state/.lock-session" S1 "$stale_pid" \
    || fail "the first session did not record its own pid $stale_pid as the anchor: $(cat "$dir/state/.lock-session")"
  cp "$dir/state/.lock" "$dir/state/lock-before-reclaim"
  touch -t 202001010000 "$dir/state/.lock-session" "$dir/state/sidecar-time-ref"
  cp -p "$dir/state/.lock-session" "$dir/state/sidecar-before-reclaim"
  chmod a-w "$dir/state/.lock" || fail "could not make the stale lock read-only"
  if [ -w "$dir/state/.lock" ]; then
    chmod u+w "$dir/state/.lock" 2>/dev/null || true
    printf 'skip: this runner can still write a read-only lock, so a lock write failure cannot be produced\n'
    return 0
  fi
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
    '
  chmod u+w "$dir/state/.lock" 2>/dev/null || true
  [ "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" != 0 ] \
    || fail "a read-only stale lock was overwritten: $(cat "$dir/state/reclaim.out")"
  grep -q 'cannot write session lock' "$dir/state/reclaim.out" \
    || fail "the reclaim did not fail on the lock write: $(cat "$dir/state/reclaim.out")"
  cmp -s "$dir/state/sidecar-before-reclaim" "$dir/state/.lock-session" \
    || fail "the failed reclaim left sidecar $(cat "$dir/state/.lock-session"), expected the previous sidecar byte for byte: $(cat "$dir/state/sidecar-before-reclaim")"
  if [ "$dir/state/.lock-session" -nt "$dir/state/sidecar-time-ref" ] || [ "$dir/state/sidecar-time-ref" -nt "$dir/state/.lock-session" ]; then
    fail "the failed reclaim restored the previous sidecar with a new modification time"
  fi
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$stale_pid" ] \
    || fail "the failed reclaim rewrote lock line 1"
  cmp -s "$dir/state/lock-before-reclaim" "$dir/state/.lock" \
    || fail "the failed reclaim changed lock bytes when line 1 was unwritable"
  pass "session-lock: a failed lock write restores the previous sidecar"
}

# A failed line-1 write that had no previous sidecar must not leave the new id
# behind; the lock stays ancestry-only.
test_failed_lock_write_removes_new_sidecar_when_none_existed() {
  local dir
  dir="$TMP_ROOT/restore-absent-sidecar"
  mkdir -p "$dir/state"
  printf '1\n' > "$dir/state/.lock"
  chmod a-w "$dir/state/.lock" || fail "could not make the stale lock read-only"
  if [ -w "$dir/state/.lock" ]; then
    chmod u+w "$dir/state/.lock" 2>/dev/null || true
    printf 'skip: this runner can still write a read-only lock, so a lock write failure cannot be produced\n'
    return 0
  fi
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
    '
  chmod u+w "$dir/state/.lock" 2>/dev/null || true
  [ "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" != 0 ] \
    || fail "a read-only stale lock was overwritten: $(cat "$dir/state/reclaim.out")"
  grep -q 'cannot write session lock' "$dir/state/reclaim.out" \
    || fail "the reclaim did not fail on the lock write: $(cat "$dir/state/reclaim.out")"
  [ ! -e "$dir/state/.lock-session" ] \
    || fail "the failed reclaim left sidecar $(cat "$dir/state/.lock-session"), expected none"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = 1 ] \
    || fail "the failed reclaim rewrote lock line 1"
  pass "session-lock: a failed lock write removes a newly created sidecar"
}

# A completed reclaim must keep the new id beside the new pid after the writer
# exits, so a late signal cannot unwind a verified publication.
test_verified_reclaim_keeps_new_sidecar() {
  local dir new_pid
  dir="$TMP_ROOT/verified-reclaim"
  mkdir -p "$dir/state"
  printf '1\n' > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  touch -t 202001010000 "$dir/state/.lock-session" "$dir/sidecar-time-ref"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/new-pid"
    '
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" \
    "the reclaim failed: $(cat "$dir/state/reclaim.out")"
  new_pid=$(tr -d '[:space:]' < "$dir/state/new-pid")
  anchored_sidecar "$dir/state/.lock-session" S2 "$new_pid" \
    || fail "the verified reclaim left sidecar $(cat "$dir/state/.lock-session"), expected S2 anchored at $new_pid"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$new_pid" ] \
    || fail "the verified reclaim did not record the new anchor pid"
  [ "$dir/state/.lock-session" -nt "$dir/sidecar-time-ref" ] \
    || fail "a session-id change kept the previous session's sidecar modification time"
  pass "session-lock: a verified reclaim keeps the new sidecar beside the new pid"
}

# A re-anchor moves leases recorded against the old live line 1 onto the new
# anchor, so the other supervision actor still cannot claim a held task.
test_reanchor_keeps_task_leases_live() {
  local dir front_pid model_pid lease_rc
  dir="$TMP_ROOT/reanchor-leases"
  mkdir -p "$dir/state"
  "$NAMED_CLAUDE" -c '
    printf "%s\n" "$$" > "$0/state/front-pid"
    while [ ! -e "$0/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
  ' "$dir" &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/front-pid" "the front-end pid"
  front_pid=$(tr -d '[:space:]' < "$dir/state/front-pid")
  printf '%s\n' "$front_pid" > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  printf 'branch\t%s\t100\n' "$front_pid" > "$dir/state/.lease-t1"
  printf 'main\t%s\t200\n' "$front_pid" > "$dir/state/.lease-t2"
  printf 'branch\t%s\t300\n' "$$" > "$dir/state/.lease-t3"
  cp "$dir/state/.lease-t3" "$dir/state/lease-t3-before"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      . "${FM_LOCK%/*}/fm-wake-lib.sh"
      printf "S1\nanchor=%s\nanchor-start=%s\n" "$$" "$(fm_pid_start_time "$$")" > "$FM_HOME/state/.lock-session"
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reanchor.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reanchor.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/model-pid"
      while [ ! -e "$FM_HOME/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
    ' &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/model-pid" "the model-loop pid"
  model_pid=$(tr -d '[:space:]' < "$dir/state/model-pid")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reanchor.rc")" \
    "the same-session re-anchor failed: $(cat "$dir/state/reanchor.out")"
  kill -0 "$front_pid" 2>/dev/null || fail "the front-end exited, so the lock line was never live"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$model_pid" ] \
    || fail "the re-anchor left lock line 1 at $(cat "$dir/state/.lock"), expected $model_pid"
  [ "$(cat "$dir/state/.lease-t1")" = "$(printf 'branch\t%s\t100' "$model_pid")" ] \
    || fail "the branch lease was not moved to the new anchor: $(cat "$dir/state/.lease-t1")"
  [ "$(cat "$dir/state/.lease-t2")" = "$(printf 'main\t%s\t200' "$model_pid")" ] \
    || fail "the main lease was not moved to the new anchor: $(cat "$dir/state/.lease-t2")"
  cmp -s "$dir/state/lease-t3-before" "$dir/state/.lease-t3" \
    || fail "a lease recorded against another pid changed: $(cat "$dir/state/.lease-t3")"
  env -u FM_SUPERVISION_ACTOR -u FM_LEASE_HOLDER_PID FM_HOME="$dir" \
    "$ROOT/bin/fm-lease.sh" claim t1 > "$dir/state/main-claim.out" 2>&1
  lease_rc=$?
  expect_code 6 "$lease_rc" "main claimed the branch's task after the re-anchor: $(cat "$dir/state/main-claim.out")"
  env -u FM_SUPERVISION_ACTOR FM_HOME="$dir" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID="$model_pid" \
    "$ROOT/bin/fm-lease.sh" claim t2 > "$dir/state/branch-claim.out" 2>&1
  lease_rc=$?
  expect_code 6 "$lease_rc" "the branch claimed main's task after the re-anchor: $(cat "$dir/state/branch-claim.out")"
  : > "$dir/state/stop"
  pass "session-lock: a re-anchor keeps both supervision actors' task leases live"
}

autoarm_midturn_healthy() {  # <state-dir>
  FM_STATE_OVERRIDE="$1" bash -c '. "$0"; fm_autoarm_midturn_healthy "$FM_STATE_OVERRIDE" 300' "$ROOT/bin/fm-wake-lib.sh"
}

# A re-anchor during a rewake handling turn that has outrun grace moves the
# auto-arm ledger's session_pid with line 1 and keeps the ledger's other bytes
# and mtime, so the mid-turn guard still sees healthy supervision.
test_reanchor_keeps_autoarm_midturn_healthy() {
  local dir front_pid model_pid
  dir="$TMP_ROOT/reanchor-autoarm"
  mkdir -p "$dir/state"
  "$NAMED_CLAUDE" -c '
    printf "%s\n" "$$" > "$0/state/front-pid"
    while [ ! -e "$0/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
  ' "$dir" &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/front-pid" "the front-end pid"
  front_pid=$(tr -d '[:space:]' < "$dir/state/front-pid")
  printf '%s\n' "$front_pid" > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  printf 'epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid=%s recovery_generation=g1\nidentity-1\n' \
    "$front_pid" > "$dir/state/.claude-autoarm-epoch"
  printf 'acked:handling:g1\n' > "$dir/state/.watcher-down"
  touch -t 201901010000 "$dir/state/.last-watcher-beat"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch" "$dir/state/epoch-mtime"
  autoarm_midturn_healthy "$dir/state" || fail "the rewake fixture is not healthy before the re-anchor, so this case proves nothing"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      . "${FM_LOCK%/*}/fm-wake-lib.sh"
      printf "S1\nanchor=%s\nanchor-start=%s\n" "$$" "$(fm_pid_start_time "$$")" > "$FM_HOME/state/.lock-session"
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reanchor.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reanchor.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/model-pid"
      while [ ! -e "$FM_HOME/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
    ' &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/model-pid" "the model-loop pid"
  model_pid=$(tr -d '[:space:]' < "$dir/state/model-pid")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reanchor.rc")" \
    "the same-session re-anchor failed: $(cat "$dir/state/reanchor.out")"
  kill -0 "$front_pid" 2>/dev/null || fail "the front-end exited, so the lock line was never live"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$model_pid" ] \
    || fail "the re-anchor left lock line 1 at $(cat "$dir/state/.lock"), expected $model_pid"
  [ "$(cat "$dir/state/.claude-autoarm-epoch")" = "$(printf 'epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid=%s recovery_generation=g1\nidentity-1' "$model_pid")" ] \
    || fail "the rewake was not moved to the new anchor intact: $(cat "$dir/state/.claude-autoarm-epoch")"
  if [ "$dir/state/.claude-autoarm-epoch" -nt "$dir/state/epoch-mtime" ] \
    || [ "$dir/state/.claude-autoarm-epoch" -ot "$dir/state/epoch-mtime" ]; then
    fail "the rewake move changed the ledger mtime"
  fi
  autoarm_midturn_healthy "$dir/state" \
    || fail "the mid-turn guard rejects the rewake after the re-anchor: $(cat "$dir/state/reanchor.out")"
  : > "$dir/state/stop"
  pass "session-lock: a re-anchor during a rewake turn keeps the mid-turn auto-arm proof healthy"
}

test_e2e_background_session_keeps_its_lock_across_a_recycled_chain
test_same_session_confirmation_refreshes_rekeyed_id_under_claim_lock
test_same_session_confirmation_does_not_steal_after_wait
test_failed_lock_write_restores_previous_sidecar
test_failed_lock_write_removes_new_sidecar_when_none_existed
test_verified_reclaim_keeps_new_sidecar
test_reanchor_keeps_task_leases_live
test_reanchor_keeps_autoarm_midturn_healthy
