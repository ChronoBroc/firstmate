#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/session-lock-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/session-lock-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone (FM_TEST_KILL_RC=1
# makes every pid dead). The suite itself may run inside a Claude session whose
# CLAUDE_CODE_SESSION_ID and CLAUDE_PID would leak into the expression, so both
# are scrubbed and only FM_TEST_SESSION_ID and FM_TEST_CLAUDE_PID reach it.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  local -a session_env=()
  [ -z "${FM_TEST_SESSION_ID:-}" ] || session_env+=("CLAUDE_CODE_SESSION_ID=$FM_TEST_SESSION_ID")
  [ -z "${FM_TEST_CLAUDE_PID:-}" ] || session_env+=("CLAUDE_PID=$FM_TEST_CLAUDE_PID")
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID ${session_env[@]+"${session_env[@]}"} \
    PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return \${FM_TEST_KILL_RC:-0}; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

# A harness that is pid 1 of its own PID namespace - a container, or the
# `codex sandbox` this shape was verified in - used to be invisible: the walk
# stopped as soon as the NEXT pid was 1, so the one process that identifies the
# session was never examined and the session could not recognize its own lock.
test_harness_at_namespace_pid1_is_examined() {
  local dir fakebin got
  dir="$TMP_ROOT/namespace-pid1"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  1:comm=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:args=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-watch.sh' ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '1\n' > "$dir/state/.lock"

  # Non-vacuity: with a host-shaped pid 1 the same table must find nothing, so
  # this case cannot pass by the walk matching everything it reaches.
  if FM_TEST_PID1_COMM=systemd lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null 2>&1; then
    fail "a host-shaped pid 1 was read as a harness process"
  fi

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the harness at namespace pid 1 was not found in the ancestry at all"
  [ "$got" = 1 ] || fail "ancestry resolved '$got', expected the namespace harness pid 1"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the session holding the lock at namespace pid 1 did not recognize itself as the owner"
  pass "session-lock: a harness that is pid 1 of its own namespace is examined, not skipped"
}

test_bun_run_omp_is_identified_on_both_platforms() {
  local comm fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/bun-omp")
  # macOS reports the executable path in comm, procps on Linux the exec name.
  for comm in bun /Users/u/.bun/bin/bun /opt/homebrew/bin/bun; do
    lib_eval "$fakebin" "fm_harness_process_matches '$comm' 'bun /Users/u/.bun/bin/omp'" \
      || fail "$comm running the omp launcher must be identified"
    if lib_eval "$fakebin" "fm_harness_process_matches '$comm' 'bun /Users/u/.bun/bin/ompd'"; then
      fail "$comm running ompd was identified as a harness"
    fi
  done
  pass "session-lock: a bun-run omp script is identified under both platforms' comm reporting"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

# A background Claude session's process table. The hook fires inside
# `claude bg-spare` (710), whose parent is `claude bg-pty-host` (720). With the
# transient daemon gone the pty-host is reparented to launchd, so the contiguous
# claude-named run from the hook ends at 720 and the live front-end 700 that
# holds the lock is no longer an ancestor at all. FM_TEST_DAEMON_PRESENT=1 puts
# the daemon (730) back between 720 and 700: the healthy topology.
write_background_session_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ "$pid" != "${FM_TEST_PS_FAIL_PID:-}" ] || exit 1
case "$pid:$field:${FM_TEST_DAEMON_PRESENT:-0}" in
  700:comm=:*) printf '%s\n' claude ;;
  700:args=:*) printf '%s\n' 'claude --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  730:comm=:*) printf '%s\n' claude ;;
  730:args=:*) printf '%s\n' 'claude daemon run --origin transient' ;;
  730:ppid=:*) printf '%s\n' 700 ;;
  730:lstart=:*) [ "${FM_TEST_DAEMON_START-Wed Dec 31 00:00:00 2025}" = '' ] || printf '%s\n' "${FM_TEST_DAEMON_START-Wed Dec 31 00:00:00 2025}" ;;
  720:comm=:*) printf '%s\n' 'claude bg-pty-host' ;;
  720:args=:*) printf '%s\n' 'claude bg-pty-host /tmp/pty.sock 120 40 -- claude --bg-spare' ;;
  720:ppid=:1) printf '%s\n' 730 ;;
  720:ppid=:*) printf '%s\n' 1 ;;
  710:comm=:*) printf '%s\n' 'claude bg-spare' ;;
  710:args=:*) printf '%s\n' 'claude bg-spare /tmp/claim.sock' ;;
  710:ppid=:*) printf '%s\n' 720 ;;
  710:lstart=:*) printf '%s\n' "${FM_TEST_SPARE_START:-Thu Jan  1 00:00:00 2026}" ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 710 ;;
esac
SH
  chmod +x "$1/ps"
}

owned() {  # <fakebin> <state>
  lib_eval "$1" "fm_session_lock_owned_by_self '$2'"
}

foreign_owner() {  # <fakebin> <state>  -> prints the foreign pid
  lib_eval "$1" "fm_session_lock_foreign_owner_live '$2' && printf '%s' \"\$FM_SESSION_LOCK_FOREIGN_OWNER_PID\""
}

test_same_session_id_owns_a_recycled_background_chain() {
  local dir fakebin state got spare_start
  dir="$TMP_ROOT/background-session"
  spare_start='Thu Jan  1 00:00:00 2026'
  export FM_PROC_ROOT_OVERRIDE="$dir/no-proc"
  fakebin=$(fm_fakebin "$dir")
  state="$dir/state"
  mkdir -p "$state"
  write_background_session_ps "$fakebin"
  printf '700\n' > "$state/.lock"
  printf 'S1\nanchor=710\nanchor-start=%s\n' "$spare_start" > "$state/.lock-session"

  # The divergence itself, so none of the verdicts below can be vacuous: with
  # the daemon gone the front-end is not an ancestor, with it back it is.
  if lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700; then
    fail "the recycled chain still reached the front-end, so the id cases would prove nothing"
  fi
  FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700 \
    || fail "the healthy chain did not reach the front-end"

  # 1. The session's own id from its model-loop process: owned, not foreign.
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "the same session's trusted id did not own the lock after the helper chain was recycled"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "the session's own live front-end was reported as a foreign owner despite the matching id"
  fi
  # 1b. The same id without positive continuity: a sidecar recording the id
  # alone, an anchor without its start time, a reused anchor pid, and an
  # anchor that is another live harness outside this run prove nothing, so the
  # live owner is foreign.
  printf 'S1\n' > "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "an id-only sidecar let the same id own a live lock outside its ancestry"
  fi
  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state") \
    || fail "an id-only sidecar suppressed the foreign-owner verdict"
  [ "$got" = 700 ] || fail "the id-only foreign owner pid was '$got', expected 700"
  printf 'S1\nanchor=710\n' > "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "an anchor recorded without its start time let the same id own a live lock"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "an anchor recorded without its start time suppressed the foreign-owner verdict"
  # The recorded anchor pid reused by a later process of the same id: its start
  # identity differs from the one recorded, so it proves no continuity.
  printf 'S1\nanchor=710\nanchor-start=%s\n' "$spare_start" > "$state/.lock-session"
  if FM_TEST_SPARE_START='Fri Jan  2 00:00:00 2026' FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a reused anchor pid let the same id own a live lock outside its ancestry"
  fi
  got=$(FM_TEST_SPARE_START='Fri Jan  2 00:00:00 2026' FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state") \
    || fail "a reused anchor pid suppressed the foreign-owner verdict"
  [ "$got" = 700 ] || fail "the reused-anchor foreign owner pid was '$got', expected 700"
  printf 'S1\nanchor=730\nanchor-start=%s\n' 'Wed Dec 31 00:00:00 2025' > "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a live recorded anchor outside the run let the same id own the lock"
  fi
  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state") \
    || fail "a live recorded anchor outside the run suppressed the foreign-owner verdict"
  [ "$got" = 730 ] || fail "the live recorded anchor's holder pid was '$got', expected the anchor 730"
  # The same anchor whose start time cannot be read still exists, so it is no
  # evidence that the holder ended: still foreign, still naming the anchor.
  if FM_TEST_DAEMON_START='' FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "an existing anchor with an unreadable start time let the same id own the lock"
  fi
  got=$(FM_TEST_DAEMON_START='' FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state") \
    || fail "an existing anchor with an unreadable start time suppressed the foreign-owner verdict"
  [ "$got" = 730 ] || fail "the unconfirmed anchor's holder pid was '$got', expected the anchor 730"
  printf 'S1\nanchor=710\nanchor-start=%s\n' "$spare_start" > "$state/.lock-session"
  # 2. A different id: the existing refusal, naming the live owner.
  if FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a different session id claimed a live owner's lock"
  fi
  got=$(FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state") \
    || fail "a different session id did not see the live owner as foreign"
  [ "$got" = 700 ] || fail "the foreign owner pid was '$got', expected 700"
  # 3. The trust gate: the right id carried by a CLAUDE_PID outside the run.
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 owned "$fakebin" "$state"; then
    fail "an id whose CLAUDE_PID is outside the current Claude run was trusted"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "an untrusted id suppressed the foreign-owner verdict"
  printf 'S1:x\nanchor=710\nanchor-start=%s\n' "$spare_start" > "$state/.lock-session"
  FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "a trusted id containing a colon did not own the lock"
  if FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "a matching id containing a colon was reported as a foreign owner"
  fi
  printf 'S1\r' > "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a recorded id containing a carriage return was treated as a session id"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "a carriage-return sidecar suppressed the foreign-owner verdict"
  printf 'S1\nanchor=710\nanchor-start=%s\n' "$spare_start" > "$state/.lock-session"
  # 4. No id at all: the legacy ancestry verdict, unchanged.
  if owned "$fakebin" "$state"; then
    fail "with no session id the recycled chain claimed the lock"
  fi
  foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "with no session id the live owner was not reported as foreign"
  # 5. The healthy chain owns by ancestry whatever the environment says.
  FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "ancestry membership lost to a different session id"
  FM_TEST_DAEMON_PRESENT=1 owned "$fakebin" "$state" \
    || fail "ancestry membership lost with no session id"
  if FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "an ancestor was reported as a foreign owner"
  fi
  # 6. Never fail open: no sidecar, a symlinked sidecar, and a dead recorded pid
  # are all ancestry-only, so the dead one is left for the ordinary reclaim.
  rm -f "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a lock with no recorded session id was owned through the environment id"
  fi
  printf 'S1\nanchor=710\nanchor-start=%s\n' "$spare_start" > "$dir/elsewhere"
  ln -s "$dir/elsewhere" "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a symlinked sidecar was trusted"
  fi
  rm -f "$state/.lock-session"
  printf 'S1\nanchor=710\nanchor-start=%s\n' "$spare_start" > "$state/.lock-session"
  if FM_TEST_KILL_RC=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a same-session lock whose recorded pid is dead was owned instead of left for reclaim"
  fi
  # 7. A walk that stops because a parent cannot be read is incomplete, while
  # one that reaches a non-harness parent is complete.
  lib_eval "$fakebin" 'fm_harness_ancestry_complete "$(fm_harness_ancestry_pids)"' \
    || fail "a walk that reached the non-harness top of the recycled chain was reported incomplete"
  got=$(FM_TEST_PS_FAIL_PID=720 lib_eval "$fakebin" 'fm_harness_ancestry_pids') \
    || fail "the walk failed outright instead of stopping at the unreadable pty-host"
  [ "$got" = 710 ] || fail "a walk stopped at an unreadable parent printed '$got', expected the spare 710 alone"
  if FM_TEST_PS_FAIL_PID=720 lib_eval "$fakebin" 'fm_harness_ancestry_complete 710'; then
    fail "a walk that stopped at an unreadable Claude parent was reported complete"
  fi
  unset FM_PROC_ROOT_OVERRIDE
  pass "session-lock: a trusted same-session id keeps owning a recycled background chain, and nothing weaker does"
}

test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id() {
  local dir fakebin got
  dir="$TMP_ROOT/background-anchor"
  fakebin=$(fm_fakebin "$dir")
  write_background_session_ps "$fakebin"

  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for a trusted id"
  [ "$got" = 710 ] || fail "a trusted id anchored '$got', expected the model-loop process 710"
  got=$(lib_eval "$fakebin" 'fm_session_lock_anchor_pid') || fail "no anchor pid was resolved without an id"
  [ "$got" = 720 ] || fail "without an id the anchor was '$got', expected the outermost pid 720"
  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for an untrusted id"
  [ "$got" = 720 ] || fail "an untrusted id anchored '$got', expected the outermost pid 720"
  got=$(FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain"
  [ "$got" = 700 ] || fail "the healthy chain without an id anchored '$got', expected the outermost pid 700"
  got=$(FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain with a trusted id"
  [ "$got" = 710 ] || fail "the healthy chain with a trusted id anchored '$got', expected 710 rather than the front-end"
  pass "session-lock: a trusted id anchors the lock on the model-loop process, anything else on the outermost pid"
}

# --- Cygwin / Git-for-Windows layer ------------------------------------------
#
# Both of this platform's departures are reproduced here rather than assumed, so
# these run identically on Linux and macOS CI: its ps rejects -o outright, and
# every shell it reports has its parent link severed at 1 because the real parent
# is a Windows process Cygwin cannot see.

# A fakebin whose ps behaves like Cygwin's and whose uname reports MINGW.
# The Windows-side table is supplied per case through FM_TEST_WIN_TABLE, in the
# same column order the real `ps -W` prints.
cygwin_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'MINGW64_NT-10.0-26200'
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  # Cygwin's ps has no -o option at all; it fails the whole invocation.
  [ "$a" = "-o" ] && { echo "ps: unknown option -- o" >&2; exit 1; }
done
mode=p full=0 pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -W) mode=W; shift ;;
    -f) full=1; shift ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$mode" = W ]; then
  [ -z "${FM_TEST_WIN_PS_FAIL:-}" ] || { echo "ps: cannot read the Windows process table" >&2; exit 1; }
  printf '%s\n' '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND'
  [ -n "${FM_TEST_WIN_TABLE:-}" ] && printf '%s\n' "$FM_TEST_WIN_TABLE"
  exit 0
fi
# The Cygwin-side table. 700 is an MSYS-native harness; everything else is an
# ordinary shell whose parent link is severed exactly as the real ps reports it.
case "$pid" in
  700) comm='/opt/claude/versions/2.1.220'; ppid=1 ;;
  *)   comm='/usr/bin/bash'; ppid=${FM_TEST_CYG_PPID:-1} ;;
esac
if [ "$full" = 1 ]; then
  printf '%s\n' '     UID     PID    PPID  TTY        STIME COMMAND'
  printf 'u %s %s ? 00:00:00 %s\n' "$pid" "$ppid" "$comm"
else
  printf '%s\n' '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND'
  printf '%s %s %s 9999 ? 0 00:00:00 %s\n' "$pid" "$ppid" "$pid" "$comm"
fi
SH
  chmod +x "$fakebin/uname" "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

# WINPID 7204 is the session harness. 4321 is an ordinary desktop process, and
# 5150 is the path-shaped lookalike that must never read as a harness.
WIN_TABLE='  4201508       0       0       7204  ?              0 22:24:48 C:\Users\u\.local\bin\claude.exe
  4198625       0       0       4321  ?              0 22:24:48 C:\Windows\explorer.exe
  4199454       0       0       5150  ?              0 22:24:48 C:\tools\claude-notes\helper.exe'

test_windows_session_is_identified_from_its_published_pid() {
  local dir fakebin got
  dir="$TMP_ROOT/win-published"
  fakebin=$(cygwin_fakebin "$dir")
  mkdir -p "$dir/state"
  printf 'win:7204\n' > "$dir/state/.lock"

  got=$(FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=7204 lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the session was not identified at all on a severed Cygwin parent link"
  [ "$got" = 'win:7204' ] || fail "expected the tagged Windows session pid win:7204, got '$got'"
  FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=7204 lib_eval "$fakebin" 'fm_harness_pid_alive win:7204' \
    || fail "a live Windows-side session was classified as a dead lock owner"
  FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=7204 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the session holding the lock did not recognize itself as the owner"
  pass "session-lock: a Windows session is identified from its published pid across the severed parent link"
}

test_windows_published_pid_is_confirmed_before_it_is_trusted() {
  local dir fakebin
  dir="$TMP_ROOT/win-unconfirmed"
  fakebin=$(cygwin_fakebin "$dir")
  mkdir -p "$dir/state"

  # A published pid is a claim. Each of these shapes must be discarded rather
  # than bound: a process that is gone, one that is not a harness at all, and a
  # path that merely contains the harness name inside a longer component.
  for claimed in 9999 4321 5150; do
    if FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID="$claimed" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "published pid $claimed was bound as this session's harness without confirmation"
    fi
    if FM_TEST_WIN_TABLE="$WIN_TABLE" lib_eval "$fakebin" "fm_harness_pid_alive win:$claimed"; then
      fail "published pid $claimed passed the harness-liveness predicate"
    fi
  done
  pass "session-lock: a published Windows pid is confirmed against the process table before it is trusted"
}

test_windows_pid_is_never_resolved_as_a_cygwin_pid() {
  local dir fakebin
  dir="$TMP_ROOT/win-namespace"
  fakebin=$(cygwin_fakebin "$dir")
  mkdir -p "$dir/state"

  # 700 is a harness in the CYGWIN table and absent from the Windows one. The
  # two namespaces overlap numerically, so resolving a tagged pid through the
  # local table would bind a home to whatever unrelated process holds that
  # number - which is exactly what the tag exists to prevent.
  FM_TEST_WIN_TABLE="$WIN_TABLE" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
    || fail "fixture is vacuous: pid 700 must be a live harness in the Cygwin table"
  if FM_TEST_WIN_TABLE="$WIN_TABLE" lib_eval "$fakebin" 'fm_harness_pid_alive win:700'; then
    fail "a tagged Windows pid was resolved against the Cygwin process table"
  fi
  pass "session-lock: a tagged Windows pid is never resolved against the Cygwin process table"
}

test_a_published_identity_is_accepted_by_the_gates_that_read_the_lock() {
  local dir fakebin identity
  dir="$TMP_ROOT/win-identity-gates"
  fakebin=$(cygwin_fakebin "$dir")
  mkdir -p "$dir/state"

  # The identity a session writes into the lock is read back by gates spread
  # across several scripts - startup-completion recording and its clear/compact
  # validation, the deferred network sweeps, and the Stop auto-arm. Each one
  # asks only "is this value a usable identity", and each answered that with its
  # own numeric test, so introducing a second identity shape made every one of
  # them silently read a valid holder as malformed. The visible cost was a
  # completion record that was never written, which reads as "startup never
  # finished" and repeats the whole sequence on every clear or compact. One
  # predicate owns the question so a third shape can never split them again.
  identity=$(FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=7204 lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "fixture is vacuous: no identity was published to gate on"
  lib_eval "$fakebin" "fm_session_pid_valid '$identity'" \
    || fail "the identity '$identity' this session publishes is rejected by the gates that read it back"

  # A local pid stays equally valid: the Windows shape is additional, not a
  # replacement, and the same predicate serves both platforms.
  lib_eval "$fakebin" 'fm_session_pid_valid 700' \
    || fail "an ordinary local pid was rejected as an invalid lock identity"

  # Still fail closed on the shapes a torn or hand-edited lock produces, and on
  # a bare tag carrying no pid at all.
  for bad in '' 'win:' 'win:abc' 'win:7abc' 'win:7 x' 'win:-1' 'abc' '70 0' '-1'; do
    if lib_eval "$fakebin" "fm_session_pid_valid '$bad'"; then
      fail "the malformed lock value '$bad' was accepted as a usable identity"
    fi
  done
  pass "session-lock: a published identity is accepted by every gate that reads the lock"
}

test_windows_tagged_holder_is_a_live_foreign_owner() {
  local dir fakebin table got
  dir="$TMP_ROOT/win-foreign-owner"
  fakebin=$(cygwin_fakebin "$dir")
  mkdir -p "$dir/state"
  printf 'win:7204\n' > "$dir/state/.lock"
  # A second live session, 7300, reads the home held by the live session 7204.
  table="$WIN_TABLE
  4201600       0       0       7300  ?              0 22:30:00 C:\Users\u\.local\bin\claude.exe"

  got=$(FM_TEST_WIN_TABLE="$table" FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=7300 foreign_owner "$fakebin" "$dir/state") \
    || fail "a live tagged lock holder was not seen as a foreign owner by a second session"
  [ "$got" = 'win:7204' ] || fail "expected foreign owner win:7204, got '$got'"
  if FM_TEST_WIN_TABLE="$table" FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=7204 foreign_owner "$fakebin" "$dir/state" >/dev/null; then
    fail "the tagged lock holder read its own lock as foreign"
  fi

  got=$(FM_TEST_WIN_TABLE="$table" lib_eval "$fakebin" \
    "fm_session_lock_inspect '$dir/state'; printf '%s %s %s' \"\$FM_LOCK_INSPECT_STATE\" \"\$FM_LOCK_INSPECT_PID\" \"\$FM_LOCK_INSPECT_LIVE_HARNESS\"")
  [ "$got" = 'held win:7204 true' ] || fail "a live tagged holder was not inspected as held: '$got'"

  # A holder that is not a harness, or whose table cannot be read, is never a
  # live foreign owner. Inspection then matches the local-pid contract: a holder
  # absent from a readable table is stale, a live non-harness is unknown with no
  # live harness, and an unreadable table stays fully unknown.
  for gone in 9999 4321; do
    printf 'win:%s\n' "$gone" > "$dir/state/.lock"
    if FM_TEST_WIN_TABLE="$table" FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=7300 foreign_owner "$fakebin" "$dir/state" >/dev/null; then
      fail "an unverifiable tagged holder win:$gone was reported as a live foreign owner"
    fi
  done
  printf 'win:9999\n' > "$dir/state/.lock"
  got=$(FM_TEST_WIN_TABLE="$table" lib_eval "$fakebin" \
    "fm_session_lock_inspect '$dir/state'; printf '%s %s' \"\$FM_LOCK_INSPECT_STATE\" \"\$FM_LOCK_INSPECT_LIVE_HARNESS\"")
  [ "$got" = 'stale false' ] || fail "a tagged holder absent from the Windows table was classified as '$got', not stale"
  printf 'win:4321\n' > "$dir/state/.lock"
  got=$(FM_TEST_WIN_TABLE="$table" lib_eval "$fakebin" \
    "fm_session_lock_inspect '$dir/state'; printf '%s %s' \"\$FM_LOCK_INSPECT_STATE\" \"\$FM_LOCK_INSPECT_LIVE_HARNESS\"")
  [ "$got" = 'unknown false' ] || fail "a live non-harness tagged holder was classified as '$got'"
  printf 'win:9999\n' > "$dir/state/.lock"
  got=$(FM_TEST_WIN_PS_FAIL=1 FM_TEST_WIN_TABLE="$table" lib_eval "$fakebin" \
    "fm_session_lock_inspect '$dir/state'; printf '%s %s' \"\$FM_LOCK_INSPECT_STATE\" \"\$FM_LOCK_INSPECT_LIVE_HARNESS\"")
  [ "$got" = 'unknown unknown' ] || fail "a tagged holder behind an unreadable Windows table was classified as '$got'"
  pass "session-lock: a live tagged lock holder is a live foreign owner to a second Windows session"
}

test_windows_tagged_lock_acquisition_uses_the_shared_owner_verdict() {
  local dir fakebin home current_row live_table dead_table reused_table out status record got
  dir="$TMP_ROOT/win-lock-acquire"
  fakebin=$(cygwin_fakebin "$dir")
  home="$dir/home"
  mkdir -p "$home/state" "$home/endpoints" "$home/bin" "$home/config"
  git init -q "$home"
  git -C "$home" commit -q --allow-empty -m fixture
  : > "$home/AGENTS.md"
  : > "$home/state/task.meta"
  current_row='  4201600       0       0       7300  ?              0 22:30:00 C:\Users\u\.local\bin\claude.exe'
  live_table="$WIN_TABLE
$current_row"
  dead_table=$current_row
  reused_table="  4201508       0       0       7204  ?              0 22:24:48 C:\\Windows\\explorer.exe
$current_row"

  attempt_lock() {  # <caller-pid> <session-id> <windows-table> <table-fails> <local-ppid>
    local caller_pid=$1 caller_session=$2 table=$3 table_fails=$4 local_ppid=$5
    local -a assignments=()
    assignments+=("PATH=$fakebin:$PATH" "FM_HOME=$home" "FM_TEST_WIN_TABLE=$table")
    [ -z "$local_ppid" ] || assignments+=("FM_TEST_CYG_PPID=$local_ppid")
    [ -z "$caller_pid" ] || assignments+=("CLAUDE_PID=$caller_pid" "CLAUDE_CODE_SESSION_ID=$caller_session")
    [ "$table_fails" != 1 ] || assignments+=("FM_TEST_WIN_PS_FAIL=1")
    env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u FM_TEST_WIN_PS_FAIL -u FM_TEST_CYG_PPID \
      "${assignments[@]}" "$ROOT/bin/fm-lock.sh"
  }
  attempt_hook() {  # <script-name> <payload>
    local script=$1 payload=$2
    printf '%s' "$payload" | env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
      -u FM_TEST_WIN_PS_FAIL -u FM_TEST_CYG_PPID -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
      FM_TEST_WIN_TABLE="$live_table" CLAUDE_PID=7300 CLAUDE_CODE_SESSION_ID=S2 \
      "$ROOT/bin/$script"
  }

  printf 'win:7204\n' > "$home/state/.lock"
  printf 'S1\n' > "$home/state/.lock-session"
  if out=$(attempt_lock 7300 S2 "$live_table" 0 '' 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 1 ] || fail "fm-lock.sh acquired a live tagged harness lock: $out"
  case "$out" in *'another live firstmate session holds the lock'*) ;; *) fail "live tagged owner refusal was not reported: $out" ;; esac
  [ "$(cat "$home/state/.lock")" = 'win:7204' ] || fail "a live tagged owner lock was replaced"

  if out=$(attempt_hook fm-claude-stop-autoarm.sh '' 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "Stop recovery did not stand down for a live tagged owner: $out"
  [ "$(cat "$home/state/.lock")" = 'win:7204' ] || fail "Stop recovery replaced a live tagged owner lock"
  if out=$(attempt_hook fm-turnend-guard-cursor.sh '{"loop_count":0,"session_id":"S2"}' 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "turn-end recovery did not stand down for a live tagged owner: $out"
  [ "$(cat "$home/state/.lock")" = 'win:7204' ] || fail "turn-end recovery replaced a live tagged owner lock"

  printf 'win:7204\n' > "$home/state/.lock"
  printf 'S1\n' > "$home/state/.lock-session"
  if out=$(attempt_lock '' '' "$live_table" 1 700 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 1 ] || fail "fm-lock.sh acquired through an unreadable Windows process table: $out"
  [ "$(cat "$home/state/.lock")" = 'win:7204' ] || fail "an unreadable Windows table allowed the tagged owner lock to be replaced"
  case "$out" in
    *'whether the lock holder is still running could not be verified (pid win:7204): the lock holder has not been shown to have exited, but its identity cannot be read'*) ;;
    *) fail "an unreadable Windows table refusal did not state its uncertainty: $out" ;;
  esac
  case "$out" in *'another live'*) fail "an unreadable Windows table refusal claimed a definite live owner: $out" ;; esac
  out=$(env -u FM_TEST_CYG_PPID PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_WIN_TABLE="$live_table" FM_TEST_WIN_PS_FAIL=1 \
    "$ROOT/bin/fm-lock.sh" status 2>&1)
  [ "$out" = 'lock: unknown (pid win:7204 has not been shown to have exited, but its identity cannot be read)' ] \
    || fail "an unreadable Windows table was reported by lock status as '$out'"

  printf 'win:7204\n' > "$home/state/.lock"
  printf 'S1\n' > "$home/state/.lock-session"
  if out=$(attempt_lock 7300 S2 "$dead_table" 0 '' 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "fm-lock.sh refused a tagged owner absent from the Windows table: $out"
  [ "$(cat "$home/state/.lock")" = 'win:7300' ] || fail "a dead tagged owner was not replaced by the current session"

  printf 'win:7204\n' > "$home/state/.lock"
  printf 'S1\n' > "$home/state/.lock-session"
  if out=$(attempt_lock 7300 S2 "$reused_table" 0 '' 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "fm-lock.sh refused a reused tagged pid naming a non-harness: $out"
  [ "$(cat "$home/state/.lock")" = 'win:7300' ] || fail "a reused non-harness pid was not reclaimed"

  printf 'win:7204\n' > "$home/state/.lock"
  printf 'S1\nanchor=win:7204\n' > "$home/state/.lock-session"
  if out=$(attempt_lock 7300 S2 "$live_table" 0 '' 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 1 ] || fail "fm-lock.sh acquired over a recorded tagged anchor that still names a harness: $out"
  [ "$(cat "$home/state/.lock")" = 'win:7204' ] || fail "a live tagged anchor's lock was replaced"
  got=$(FM_TEST_WIN_TABLE="$reused_table" lib_eval "$fakebin" \
    "fm_session_lock_inspect '$home/state'; printf '%s %s' \"\$FM_LOCK_INSPECT_STATE\" \"\$FM_LOCK_INSPECT_DETAIL\"")
  [ "$got" = 'unknown ' ] || fail "a recorded tagged anchor reused by a non-harness was inspected as '$got'"
  if out=$(attempt_lock 7300 S2 "$reused_table" 0 '' 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "fm-lock.sh refused a recorded tagged anchor whose pid now names a non-harness: $out"
  [ "$(cat "$home/state/.lock")" = 'win:7300' ] || fail "a recorded tagged anchor reused by a non-harness was not reclaimed"

  for record in '' '   ' not-a-pid 0 00 000 0000 win: win:7abc; do
    printf '%s\n' "$record" > "$home/state/.lock"
    printf 'S1\n' > "$home/state/.lock-session"
    if out=$(attempt_lock 7300 S2 "$dead_table" 0 '' 2>&1); then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || fail "fm-lock.sh refused non-owner record '$record': $out"
    [ "$(cat "$home/state/.lock")" = 'win:7300' ] || fail "non-owner record '$record' was not replaced"
  done
  pass "session-lock: fm-lock.sh protects valid tagged owners and reclaims dead or malformed records"
}

test_windows_published_pid_needs_its_claude_session_id() {
  local dir fakebin got
  dir="$TMP_ROOT/win-session-id"
  fakebin=$(cygwin_fakebin "$dir")
  mkdir -p "$dir/state"

  # CLAUDE_PID is inherited by every process a Claude pane starts, so on its
  # own it names a live Claude without proving this process belongs to it.
  if FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_CLAUDE_PID=7204 lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null; then
    fail "a published Claude pid without its session id was bound as this session's harness"
  fi
  got=$(FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=7204 lib_eval "$fakebin" 'fm_session_lock_trusted_session_id') \
    || fail "the session id published with a confirmed Windows Claude pid was not trusted"
  [ "$got" = S1 ] || fail "expected the trusted session id S1, got '$got'"
  got=$(FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=7204 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for a Windows session with its id"
  [ "$got" = 'win:7204' ] || fail "a trusted Windows session anchored '$got', expected the tagged pid win:7204"
  pass "session-lock: a published Windows Claude pid is accepted only with its session id"
}

test_windows_clear_rekeys_the_lock_under_the_same_pid() {
  local dir fakebin home out
  dir="$TMP_ROOT/win-clear-rekey"
  fakebin=$(cygwin_fakebin "$dir")
  home="$dir/home"
  mkdir -p "$home/state"

  win_lock() {  # <session-id>
    env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID PATH="$fakebin:$PATH" \
      FM_TEST_WIN_TABLE="$WIN_TABLE" FM_HOME="$home" \
      CLAUDE_PID=7204 CLAUDE_CODE_SESSION_ID="$1" "$ROOT/bin/fm-lock.sh" 2>&1
  }
  out=$(win_lock S1) || fail "the Windows session could not acquire its lock: $out"
  [ "$(cat "$home/state/.lock")" = 'win:7204' ] || fail "the lock names '$(cat "$home/state/.lock")', not win:7204"
  [ "$(sed -n 1p "$home/state/.lock-session" 2>/dev/null)" = S1 ] \
    || fail "the Windows session did not record its session id beside the lock"

  # /clear keeps the Claude process, so CLAUDE_PID stays while the session id
  # changes. As on POSIX the session keeps its lock and the sidecar is re-keyed.
  out=$(win_lock S2) || fail "the Windows session was refused its own lock after /clear: $out"
  [ "$(cat "$home/state/.lock")" = 'win:7204' ] || fail "the /clear re-key rewrote the lock to '$(cat "$home/state/.lock")'"
  [ "$(sed -n 1p "$home/state/.lock-session")" = S2 ] || fail "the /clear re-key did not record the new session id"
  FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=7204 owned "$fakebin" "$home/state" \
    || fail "the Windows session did not own its lock after /clear"
  if FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=7204 foreign_owner "$fakebin" "$home/state" >/dev/null; then
    fail "the Windows session read its own lock as foreign after /clear"
  fi
  pass "session-lock: a Windows /clear keeps the lock and re-keys its session id"
}

test_tagged_lock_is_inert_off_windows() {
  local dir fakebin state got value
  dir="$TMP_ROOT/win-tag-off-windows"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' Linux
SH
  # Answers ps -W as if a live Windows harness held the lock, so only the
  # platform gate can keep the tag from being honored.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND'
printf '%s\n' '  4201508       0       0       7204  ?              0 22:24:48 C:\Users\u\.local\bin\claude.exe'
SH
  chmod +x "$fakebin/uname" "$fakebin/ps"
  state="$dir/state"
  mkdir -p "$state"
  printf 'win:7204\n' > "$state/.lock"

  for value in 'win:7204' 'win:7abc'; do
    if lib_eval "$fakebin" "fm_session_pid_valid '$value'"; then
      fail "the Windows-tagged value '$value' was accepted off Windows"
    fi
  done
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=7204 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$state'"; then
    fail "a Windows-tagged lock was owned off Windows"
  fi
  if foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "a Windows-tagged lock was reported as a live foreign owner off Windows"
  fi
  got=$(lib_eval "$fakebin" "fm_session_lock_inspect '$state'; printf '%s' \"\$FM_LOCK_INSPECT_STATE\"")
  [ "$got" = unknown ] || fail "a Windows-tagged lock off Windows was classified as '$got', not unknown"
  pass "session-lock: a Windows-tagged lock stays inert off Windows"
}

test_windows_task_lease_follows_a_tagged_lock_holder() {
  local dir fakebin home out status table
  local -x PI_CODING_AGENT=true
  dir="$TMP_ROOT/win-lease"
  fakebin=$(cygwin_fakebin "$dir")
  home="$dir/home"
  mkdir -p "$home/state"
  printf 'win:7204\n' > "$home/state/.lock"

  # The supervising actor's lease names the tagged session that holds the lock,
  # so it stays live while that session does and the other actor is refused.
  env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u FM_LEASE_HOLDER_PID PATH="$fakebin:$PATH" \
    FM_TEST_WIN_TABLE="$WIN_TABLE" FM_HOME="$home" FM_SUPERVISION_ACTOR=branch \
    "$ROOT/bin/fm-lease.sh" claim task-1 --actor branch || fail "branch lease claim failed under a tagged lock"
  out=$(cut -f2 "$home/state/.lease-task-1")
  [ "$out" = 'win:7204' ] || fail "the lease recorded holder '$out', not the tagged lock holder win:7204"
  out=$(env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u FM_LEASE_HOLDER_PID PATH="$fakebin:$PATH" \
    FM_TEST_WIN_TABLE="$WIN_TABLE" FM_HOME="$home" FM_SUPERVISION_ACTOR=main \
    "$ROOT/bin/fm-lease.sh" claim task-1 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "the other actor's claim over a live tagged lease exited $status, not 6: $out"

  # Once the tagged holder is gone from the Windows table, the lease is stale.
  env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u FM_LEASE_HOLDER_PID PATH="$fakebin:$PATH" \
    FM_TEST_WIN_TABLE='' FM_HOME="$home" FM_SUPERVISION_ACTOR=main \
    "$ROOT/bin/fm-lease.sh" claim task-1 || fail "a lease whose tagged holder exited still blocked the other actor"

  # A caller-supplied tagged holder naming a live harness is taken whole ahead
  # of the lock holder, never as its digits; a dead one falls back to the lock.
  table="$WIN_TABLE
  4201600       0       0       7300  ?              0 22:24:48 C:\Users\u\.local\bin\claude.exe"
  rm -f "$home/state/.lease-task-1"
  env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID PATH="$fakebin:$PATH" \
    FM_TEST_WIN_TABLE="$table" FM_HOME="$home" FM_SUPERVISION_ACTOR=branch \
    FM_LEASE_HOLDER_PID=win:7300 \
    "$ROOT/bin/fm-lease.sh" claim task-1 --actor branch || fail "branch lease claim failed with a tagged FM_LEASE_HOLDER_PID"
  out=$(cut -f2 "$home/state/.lease-task-1")
  [ "$out" = 'win:7300' ] || fail "a caller-supplied tagged holder was recorded as '$out', not win:7300"
  rm -f "$home/state/.lease-task-1"
  env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID PATH="$fakebin:$PATH" \
    FM_TEST_WIN_TABLE="$WIN_TABLE" FM_HOME="$home" FM_SUPERVISION_ACTOR=branch \
    FM_LEASE_HOLDER_PID=win:7300 \
    "$ROOT/bin/fm-lease.sh" claim task-1 --actor branch || fail "branch lease claim failed with a dead tagged FM_LEASE_HOLDER_PID"
  out=$(cut -f2 "$home/state/.lease-task-1")
  [ "$out" = 'win:7204' ] || fail "a dead caller-supplied tagged holder was recorded as '$out', not the lock holder win:7204"
  pass "session-lock: a task lease follows a live tagged lock holder and goes stale when it exits"
}

test_cygwin_ps_without_o_still_resolves_a_local_harness() {
  local dir fakebin got
  dir="$TMP_ROOT/cygwin-local"
  fakebin=$(cygwin_fakebin "$dir")
  mkdir -p "$dir/state"

  # An MSYS-native harness lives in the same process table as this shell, so it
  # must resolve through the ordinary walk and stay an untagged pid. This is
  # what proves the walk survives a ps with no -o option at all.
  got=$(FM_TEST_CYG_PPID=700 FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_CLAUDE_PID=7204 \
    lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "a harness in the local process table was not resolved when ps rejected -o"
  [ "$got" = 700 ] || fail "expected the untagged local harness pid 700, got '$got'"
  pass "session-lock: a harness in the local process table resolves untagged when ps has no -o option"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}


test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

test_version_named_session_is_identified_on_both_platforms
test_harness_at_namespace_pid1_is_examined
test_bun_run_omp_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_same_session_id_owns_a_recycled_background_chain
test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id
test_windows_session_is_identified_from_its_published_pid
test_windows_published_pid_is_confirmed_before_it_is_trusted
test_windows_pid_is_never_resolved_as_a_cygwin_pid
test_a_published_identity_is_accepted_by_the_gates_that_read_the_lock
test_windows_tagged_holder_is_a_live_foreign_owner
test_windows_tagged_lock_acquisition_uses_the_shared_owner_verdict
test_windows_published_pid_needs_its_claude_session_id
test_windows_clear_rekeys_the_lock_under_the_same_pid
test_tagged_lock_is_inert_off_windows
test_windows_task_lease_follows_a_tagged_lock_holder
test_cygwin_ps_without_o_still_resolves_a_local_harness
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
