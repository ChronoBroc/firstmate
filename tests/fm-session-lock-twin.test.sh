#!/usr/bin/env bash
# tests/fm-session-lock-twin.test.sh - a running session resumed a second time
# under the same Claude session id (bin/fm-lock.sh, bin/fm-session-lock-lib.sh).
#
# Real orphaned fake-claude processes, each its own CLAUDE_PID under one id. The
# twin's acquisition is refused naming the live holder and leaves line 1 on the
# original, beside an anchored sidecar, a pre-anchor sidecar that records the id
# alone, a complete record whose anchor has exited, and one whose anchor pid the
# caller reuses. The original keeps its lock, upgrades an id-only sidecar
# without moving its timestamp, and keeps its recorded start time when a
# confirmation cannot read it; once the original is dead, a later process of the
# same session reclaims the lock.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child

set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/session-lock-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/session-lock-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-twin)

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"


wait_for_file() {  # <path> <what>
  local i=0
  while [ "$i" -lt 400 ] && [ ! -s "$1" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$1" ] || fail "twin fixture never produced $2"
}

make_twin_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state" "$dir/nostart-bin"
  cat > "$dir/nostart-bin/ps" <<'SH'
#!/usr/bin/env bash
case " $* " in *' lstart= '*) exit 1 ;; esac
exec /bin/ps "$@"
SH
  chmod +x "$dir/nostart-bin/ps"
  cat > "$dir/twin.sh" <<'SH'
#!/usr/bin/env bash
role=$1
i=0
while [ "${2:-}" != child ] && [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
export CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$
printf '%s\n' "$$" > "$FM_HOME/state/$role-pid"
n=1
while [ ! -e "$FM_HOME/state/stop-$role" ] && kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null \
  && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do
  req="$FM_HOME/state/$role-fire-$n"
  if [ -f "$req" ]; then
    out="$FM_HOME/state/$role-$n"
    mkdir -p "$out"
    if [ "$(cat "$req")" = nostart ]; then
      PATH="$FM_HOME/nostart-bin:$PATH" FM_PROC_ROOT_OVERRIDE="$FM_HOME/no-proc" \
        "$FM_BIN/fm-lock.sh" > "$out/lock.out" 2>&1
    else
      "$FM_BIN/fm-lock.sh" > "$out/lock.out" 2>&1
    fi
    printf '%s\n' "$?" > "$out/lock.rc"
    (
      . "$FM_BIN/fm-session-lock-lib.sh"
      fm_session_lock_owned_by_self "$FM_HOME/state"
      printf '%s\n' "$?" > "$out/owned.rc"
      fm_session_lock_foreign_owner_live "$FM_HOME/state"
      printf '%s\n' "$?" > "$out/foreign.rc"
    )
    cp "$FM_HOME/state/.lock" "$out/lock-after"
    : > "$out/done"
    n=$((n + 1))
  fi
  sleep 0.05
done
exit 0
SH
  chmod +x "$dir/twin.sh"
  cat > "$dir/front.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/front-pid"
for role in "$@"; do
  "$FM_FIXTURE_CLAUDE" "$FM_HOME/twin.sh" "$role" child &
done
while [ ! -e "$FM_HOME/state/stop-front" ] && kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null \
  && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do
  sleep 0.05
done
exit 0
SH
  chmod +x "$dir/front.sh"
}

start_twin_role() {  # <dir> <role>
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$1" FM_BIN="$ROOT/bin" \
    bash -c '"$0" "$1" "$2" &' "$NAMED_CLAUDE" "$1/twin.sh" "$2"
  wait_for_file "$1/state/$2-pid" "the $2 session"
}

fire_twin() {  # <dir> <role> <n> [nostart]
  printf '%s\n' "${4:-}" > "$1/state/$2-fire-$3.tmp"
  mv "$1/state/$2-fire-$3.tmp" "$1/state/$2-fire-$3"
  local i=0
  while [ "$i" -lt 600 ] && [ ! -e "$1/state/$2-$3/done" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$1/state/$2-$3/done" ] || fail "the $2 session never finished step $3"
}

twin_value() {  # <dir> <role> <n> <file>
  tr -d '[:space:]' < "$1/state/$2-$3/$4"
}

# The twin's step <n> was refused naming the live holder <orig>
# and left both the lock and the sidecar exactly as they were.
expect_twin_refused() {  # <dir> <n> <orig> <label>
  local dir=$1 n=$2 orig=$3 label=$4
  expect_code 1 "$(twin_value "$dir" twin "$n" lock.rc)" "$label: the twin took the lock from the live original: $(cat "$dir/state/twin-$n/lock.out")"
  grep -qF "another live process holds the lock under this same session id (pid $orig, session S1) and this session's continuity with that holder could not be verified" "$dir/state/twin-$n/lock.out" \
    || fail "$label: the twin's refusal does not name holder pid $orig and the unverified continuity: $(cat "$dir/state/twin-$n/lock.out")"
  [ "$(twin_value "$dir" twin "$n" lock-after)" = "$orig" ] || fail "$label: the twin rewrote the lock to $(cat "$dir/state/twin-$n/lock-after")"
  expect_code 1 "$(twin_value "$dir" twin "$n" owned.rc)" "$label: the twin reads the original's lock as its own"
  expect_code 0 "$(twin_value "$dir" twin "$n" foreign.rc)" "$label: the twin does not see the original as a live foreign owner"
}

test_e2e_live_twin_of_a_session_never_takes_the_lock() {
  local dir orig twin late exited exited_start twin_start reused_start
  dir="$TMP_ROOT/e2e-live-twin"
  make_twin_home "$dir"
  start_twin_role "$dir" orig
  orig=$(tr -d '[:space:]' < "$dir/state/orig-pid")

  fire_twin "$dir" orig 1
  expect_code 0 "$(twin_value "$dir" orig 1 lock.rc)" "the original could not acquire the lock: $(cat "$dir/state/orig-1/lock.out")"
  [ "$(twin_value "$dir" orig 1 lock-after)" = "$orig" ] || fail "the original's lock names $(cat "$dir/state/orig-1/lock-after"), expected $orig"
  anchored_sidecar "$dir/state/.lock-session" S1 "$orig" \
    || fail "the original did not record its id and its own pid as the anchor: $(cat "$dir/state/.lock-session")"

  start_twin_role "$dir" twin
  twin=$(tr -d '[:space:]' < "$dir/state/twin-pid")
  [ "$twin" != "$orig" ] || fail "fixture collapsed the twin into the original"
  cp "$dir/state/.lock-session" "$dir/sidecar-before-twin"
  fire_twin "$dir" twin 1
  kill -0 "$orig" 2>/dev/null || fail "the original exited, so the twin was not checked against a live holder"
  expect_twin_refused "$dir" 1 "$orig" "anchored sidecar"
  cmp -s "$dir/sidecar-before-twin" "$dir/state/.lock-session" \
    || fail "the refused twin changed the sidecar: $(cat "$dir/state/.lock-session")"

  # A sidecar written before anchors existed records the id alone, and proves
  # no continuity: the twin is still refused.
  printf 'S1\n' > "$dir/state/.lock-session"
  fire_twin "$dir" twin 2
  expect_twin_refused "$dir" 2 "$orig" "id-only sidecar"

  # A complete record of an anchor captured while it was alive proves no
  # continuity once that anchor has exited, so a live line 1 is never handed to
  # a same-id process outside its ancestry.
  sleep 60 &
  exited=$!
  exited_start=$(FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1/bin/fm-wake-lib.sh" && fm_pid_start_time "$2"' _ "$ROOT" "$exited") \
    && [ -n "$exited_start" ] || fail "could not read the short-lived anchor's start time"
  printf 'S1\nanchor=%s\nanchor-start=%s\n' "$exited" "$exited_start" > "$dir/state/.lock-session"
  kill "$exited" 2>/dev/null
  wait "$exited" 2>/dev/null
  kill -0 "$exited" 2>/dev/null && fail "the recorded anchor did not exit"
  cp "$dir/state/.lock-session" "$dir/sidecar-exited-anchor"
  fire_twin "$dir" twin 3
  expect_twin_refused "$dir" 3 "$orig" "exited recorded anchor"
  cmp -s "$dir/sidecar-exited-anchor" "$dir/state/.lock-session" \
    || fail "the refused twin changed the exited-anchor sidecar: $(cat "$dir/state/.lock-session")"

  # The recorded anchor pid reused by the same-id caller itself: the pid is in
  # its ancestry, but the start time recorded beside it is another process's,
  # so it proves no continuity.
  twin_start=$(FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1/bin/fm-wake-lib.sh" && fm_pid_start_time "$2"' _ "$ROOT" "$twin") \
    && [ -n "$twin_start" ] || fail "could not read the twin's start time"
  reused_start='Thu Jan  1 00:00:00 1970'
  [ "$reused_start" != "$twin_start" ] || fail "the seeded start time collides with the twin's own start time"
  printf 'S1\nanchor=%s\nanchor-start=%s\n' "$twin" "$reused_start" > "$dir/state/.lock-session"
  fire_twin "$dir" twin 4
  expect_twin_refused "$dir" 4 "$orig" "anchor pid reused by the caller"

  # The original, whose own pid is line 1, still owns its lock beside an
  # id-only sidecar, and its lock run records its anchor.
  printf 'S1\n' > "$dir/state/.lock-session"
  touch -t 202001010000 "$dir/state/.lock-session" "$dir/sidecar-time-ref"
  fire_twin "$dir" orig 2
  expect_code 0 "$(twin_value "$dir" orig 2 lock.rc)" "the original lost its own lock beside an id-only sidecar: $(cat "$dir/state/orig-2/lock.out")"
  expect_code 0 "$(twin_value "$dir" orig 2 owned.rc)" "the original no longer reads its lock as its own"
  anchored_sidecar "$dir/state/.lock-session" S1 "$orig" \
    || fail "the original's lock run did not upgrade the id-only sidecar: $(cat "$dir/state/.lock-session")"
  if [ "$dir/state/.lock-session" -nt "$dir/sidecar-time-ref" ] || [ "$dir/sidecar-time-ref" -nt "$dir/state/.lock-session" ]; then
    fail "the anchor-only upgrade under the same session id changed the sidecar's modification time"
  fi

  # A confirmation whose own start time cannot be read keeps the start time
  # already recorded beside this same id and anchor.
  cp "$dir/state/.lock-session" "$dir/sidecar-before-nostart"
  fire_twin "$dir" orig 3 nostart
  expect_code 0 "$(twin_value "$dir" orig 3 lock.rc)" "the original lost its lock when its start time was unreadable: $(cat "$dir/state/orig-3/lock.out")"
  cmp -s "$dir/sidecar-before-nostart" "$dir/state/.lock-session" \
    || fail "an unreadable start time erased the recorded anchor proof: $(cat "$dir/state/.lock-session")"

  # A genuinely dead holder is still reclaimed by a later process of the same
  # session.
  : > "$dir/state/stop-orig"
  : > "$dir/state/stop-twin"
  local i=0
  while [ "$i" -lt 200 ] && { kill -0 "$orig" 2>/dev/null || kill -0 "$twin" 2>/dev/null; }; do
    sleep 0.05
    i=$((i + 1))
  done
  kill -0 "$orig" 2>/dev/null && fail "the original did not exit"
  start_twin_role "$dir" late
  late=$(tr -d '[:space:]' < "$dir/state/late-pid")
  fire_twin "$dir" late 1
  expect_code 0 "$(twin_value "$dir" late 1 lock.rc)" "the same session could not reclaim a dead holder's lock: $(cat "$dir/state/late-1/lock.out")"
  [ "$(twin_value "$dir" late 1 lock-after)" = "$late" ] || fail "the reclaim left line 1 at $(cat "$dir/state/late-1/lock-after")"
  anchored_sidecar "$dir/state/.lock-session" S1 "$late" \
    || fail "the reclaim did not record the new anchor: $(cat "$dir/state/.lock-session")"
  : > "$dir/state/stop-late"
  pass "session-lock e2e: a live twin of a session never takes its lock, beside an anchored, an id-only, an exited-anchor, or a reused-anchor sidecar, the anchor-only upgrade keeps the sidecar time, an unreadable start time keeps the recorded proof, and a dead holder is still reclaimed"
}


# Two model loops of one session id under one shared front-end, the original
# still live: line 1 is the front-end, which both loops have in their
# ancestry, and the sidecar records the original's loop as the anchor. The
# duplicate is refused naming the original's loop and leaves both records
# byte-for-byte; once the original's loop has exited, the surviving loop under
# that front-end owns the lock and records itself as the anchor.
test_e2e_sibling_model_loops_under_a_shared_front_end() {
  local dir front orig dup
  dir="$TMP_ROOT/e2e-shared-front"
  make_twin_home "$dir"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$dir" FM_BIN="$ROOT/bin" \
    FM_FIXTURE_CLAUDE="$NAMED_CLAUDE" \
    bash -c '"$0" "$1" sib-orig sib-dup &' "$NAMED_CLAUDE" "$dir/front.sh"
  wait_for_file "$dir/state/front-pid" "the shared front-end"
  wait_for_file "$dir/state/sib-orig-pid" "the original model loop"
  wait_for_file "$dir/state/sib-dup-pid" "the duplicate model loop"
  front=$(tr -d '[:space:]' < "$dir/state/front-pid")
  orig=$(tr -d '[:space:]' < "$dir/state/sib-orig-pid")
  dup=$(tr -d '[:space:]' < "$dir/state/sib-dup-pid")
  [ "$(ps -o ppid= -p "$orig" | tr -d ' ')" = "$front" ] || fail "the original model loop is not a child of the front-end"
  [ "$(ps -o ppid= -p "$dup" | tr -d ' ')" = "$front" ] || fail "the duplicate model loop is not a child of the front-end"

  printf '%s\n' "$front" > "$dir/state/.lock"
  fire_twin "$dir" sib-orig 1
  expect_code 0 "$(twin_value "$dir" sib-orig 1 lock.rc)" "the original loop could not confirm the front-end's lock: $(cat "$dir/state/sib-orig-1/lock.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$front" ] || fail "the original loop moved line 1 off its own front-end"
  anchored_sidecar "$dir/state/.lock-session" S1 "$orig" \
    || fail "the original loop did not record itself as the anchor: $(cat "$dir/state/.lock-session")"
  cp "$dir/state/.lock" "$dir/lock-before-dup"
  cp "$dir/state/.lock-session" "$dir/sidecar-before-dup"

  fire_twin "$dir" sib-dup 1
  kill -0 "$orig" 2>/dev/null || fail "the original loop exited, so the duplicate was not checked against a live holder"
  expect_code 1 "$(twin_value "$dir" sib-dup 1 lock.rc)" "the duplicate loop took the lock under the shared front-end: $(cat "$dir/state/sib-dup-1/lock.out")"
  grep -qF "another live process holds the lock under this same session id (pid $orig, session S1) and this session's continuity with that holder could not be verified" "$dir/state/sib-dup-1/lock.out" \
    || fail "the duplicate's refusal does not name the original loop $orig: $(cat "$dir/state/sib-dup-1/lock.out")"
  expect_code 1 "$(twin_value "$dir" sib-dup 1 owned.rc)" "the duplicate loop reads the shared lock as its own"
  expect_code 0 "$(twin_value "$dir" sib-dup 1 foreign.rc)" "the duplicate loop does not see the original loop as a live holder"
  cmp -s "$dir/lock-before-dup" "$dir/state/.lock" || fail "the refused duplicate changed lock line 1"
  cmp -s "$dir/sidecar-before-dup" "$dir/state/.lock-session" \
    || fail "the refused duplicate changed the sidecar: $(cat "$dir/state/.lock-session")"

  : > "$dir/state/stop-sib-orig"
  local i=0
  while [ "$i" -lt 200 ] && kill -0 "$orig" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
  done
  kill -0 "$orig" 2>/dev/null && fail "the original loop did not exit"
  fire_twin "$dir" sib-dup 2
  expect_code 0 "$(twin_value "$dir" sib-dup 2 lock.rc)" "the surviving loop could not own its front-end's lock after the original loop exited: $(cat "$dir/state/sib-dup-2/lock.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$front" ] || fail "the surviving loop moved line 1 off the front-end"
  anchored_sidecar "$dir/state/.lock-session" S1 "$dup" \
    || fail "the surviving loop did not record itself as the anchor: $(cat "$dir/state/.lock-session")"
  : > "$dir/state/stop-sib-dup"
  : > "$dir/state/stop-front"
  pass "session-lock e2e: a duplicate model loop under a shared front-end is refused while the original loop lives, and the surviving loop owns the lock once it has exited"
}

test_e2e_live_twin_of_a_session_never_takes_the_lock
test_e2e_sibling_model_loops_under_a_shared_front_end
