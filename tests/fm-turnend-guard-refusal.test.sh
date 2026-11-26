#!/usr/bin/env bash
# tests/fm-turnend-guard-refusal.test.sh - a Claude Stop that the shared
# session-lock decision refuses (bin/fm-turnend-guard.sh --claude) ends
# read-only and leaves the owner's and the parent's records untouched on every
# guard path, while the lock owner keeps the guard's ordinary writes.
# All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/turnend-guard-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/turnend-guard-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-turnend-guard-refusal)
fm_git_identity fmtest fmtest@example.invalid

# --- REFUSED CALLER: the owner's records are never touched -------------------
#
# A session that session start would refuse - here another live harness holds
# the lock - takes the read-only exit on every guard path, idle, healthy
# watcher, away-mode daemon, and stale watcher alike, and leaves the owner's
# continuation budget and failure records byte-for-byte. The owner, the process
# that holds line 1, keeps the guard's ordinary writes on the same paths.
refusal_records() {  # <dir>
  local f
  for f in .turnend-claude-blocks .claude-autoarm-failure-notified .claude-autoarm-failure-alarmed; do
    if [ -e "$1/state/$f" ]; then printf '%s=%s\n' "$f" "$(cat "$1/state/$f")"; else printf '%s=absent\n' "$f"; fi
  done
}

seed_owner_records() {  # <dir>
  printf 'session=sess-owner\ncount=1\nepoch=\n' > "$1/state/.turnend-claude-blocks"
  printf 'notified\n' > "$1/state/.claude-autoarm-failure-notified"
  printf 'alarmed\n' > "$1/state/.claude-autoarm-failure-alarmed"
}

make_refusal_path_home() {  # <dir-path> <idle|healthy|daemon|stale> -> prints dir
  local dir=$1 path=$2 pid gen
  dir=$(make_primary_dir "$dir")
  case "$path" in
    idle) ;;
    healthy)
      : > "$dir/state/task1.meta"
      sleep 120 > /dev/null 2>&1 &
      pid=$!
      printf '%s\n' "$pid" > "$dir/helper-pid"
      record_watcher_lock "$dir" "$pid" "$(watcher_identity "$dir" "$pid")"
      touch "$dir/state/.last-watcher-beat"
      ;;
    daemon)
      : > "$dir/state/task1.meta"
      : > "$dir/state/.afk"
      sleep 120 > /dev/null 2>&1 &
      pid=$!
      printf '%s\n' "$pid" > "$dir/helper-pid"
      record_daemon_lock "$dir" "$pid"
      touch "$dir/state/.last-watcher-beat"
      ;;
    stale)
      : > "$dir/state/task1.meta"
      touch -t 202001010000 "$dir/state/.last-watcher-beat"
      ;;
  esac
  seed_owner_records "$dir"
  printf 'sm-test-1\n' > "$dir/.fm-secondmate-home"
  mkdir -p "$dir/parent-state"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/parent-state" sm) || return 1
  printf 'writer=%s\nstate=%s\nid=sm\ngen=%s\n' "$ROOT/bin/fm-busy-event.sh" "$dir/parent-state" "$gen" > "$dir/.fm-busy-stop"
  printf '%s\n' "$dir"
}

parent_busy_verdict() {  # <dir>
  sed -n '1s/^.* \(state=[a-z]* source=[a-z-]* event=[a-z-]*\) .*$/\1/p' "$1/parent-state/sm.busy-state"
}

stop_refusal_helper() {  # <dir>
  local pid
  [ -f "$1/helper-pid" ] || return 0
  pid=$(cat "$1/helper-pid")
  kill "$pid" 2>/dev/null || true
}

test_hook_claude_refused_caller_never_touches_owner_records() {
  local path dir home claude holder before out status nojq tool tool_path variant failcat sidecarfail dead_line1 holder_start
  claude="$TMP_ROOT/refusal-harness/claude"
  mkdir -p "${claude%/*}"
  ln -sf /bin/bash "$claude"
  for path in idle healthy daemon stale; do
    dir=$(make_refusal_path_home "$TMP_ROOT/refused-$path" "$path")
    home=$(cd "$dir" && pwd)
    # shellcheck disable=SC2016
    "$claude" -c 'while kill -0 "$1" 2>/dev/null && [ "$SECONDS" -lt 600 ]; do sleep 1; done' refusal-holder "$$" &
    holder=$!
    printf '%s\n' "$holder" > "$dir/state/.lock"
    before=$(refusal_records "$dir")
    cp "$dir/parent-state/sm.busy-state" "$dir/parent-busy-before"
    status=0
    # shellcheck disable=SC2016 # the fake harness expands FM_HOME inside its child shell.
    out=$(printf '{"stop_hook_active":false,"session_id":"sess-refused"}' \
      | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID CLAUDECODE=1 FM_HOME="$home" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \
        "$claude" -c 'bash "$FM_HOME/bin/fm-turnend-guard.sh" --claude; exit $?' 2>&1) || status=$?
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    stop_refusal_helper "$dir"
    expect_code 0 "$status" "$path: a refused caller's Stop did not end read-only: $out"
    assert_contains "$out" "OWNED BY ANOTHER LIVE SESSION: this read-only session cannot and should not arm or repair the watcher (lock owner pid $holder)" \
      "$path: a refused caller's Stop did not report the verified live holder $holder"
    [ "$(refusal_records "$dir")" = "$before" ] \
      || fail "$path: a refused caller changed the owner's records: $(refusal_records "$dir")"
    cmp -s "$dir/parent-busy-before" "$dir/parent-state/sm.busy-state" \
      || fail "$path: a refused caller changed the parent's busy record: $(cat "$dir/parent-state/sm.busy-state")"
  done

  nojq="$TMP_ROOT/refusal-nojq-bin"
  mkdir -p "$nojq"
  for tool in bash sh cat sed head tail awk grep tr date mkdir rm mv cp ln git dirname basename uname sleep env stat \
    readlink mktemp touch ps kill wc cut sort tee find xargs id pwd printf test expr; do
    tool_path=$(command -v "$tool" 2>/dev/null) || continue
    case "$tool_path" in /*) ln -sf "$tool_path" "$nojq/$tool" ;; esac
  done
  failcat="$TMP_ROOT/refusal-failcat-bin"
  mkdir -p "$failcat"
  cat > "$failcat/cat" <<SH
#!/bin/sh
for arg in "\$@"; do
  case "\$arg" in
    */state/.lock)
      if [ ! -e "\$FM_TEST_LOCK_READ_FAILED" ]; then
        : > "\$FM_TEST_LOCK_READ_FAILED"
        exit 1
      fi
      ;;
  esac
done
exec $(command -v cat) "\$@"
SH
  chmod +x "$failcat/cat"
  sidecarfail="$TMP_ROOT/refusal-sidecar-once-bin"
  mkdir -p "$sidecarfail"
  for tool in cat sed head; do
    cat > "$sidecarfail/$tool" <<SH
#!/bin/sh
for arg in "\$@"; do
  case "\$arg" in
    */state/.lock-session)
      if [ -e "\$FM_TEST_SIDECAR_READ_ONCE" ]; then
        exit 1
      fi
      : > "\$FM_TEST_SIDECAR_READ_ONCE"
      ;;
  esac
done
exec $(command -v "$tool") "\$@"
SH
    chmod +x "$sidecarfail/$tool"
  done
  for variant in nojq unreadable-lock lock-directory lock-dangling-symlink sidecar-read-once; do
    dir=$(make_refusal_path_home "$TMP_ROOT/refused-$variant" stale)
    home=$(cd "$dir" && pwd)
    # shellcheck disable=SC2016
    "$claude" -c 'while kill -0 "$1" 2>/dev/null && [ "$SECONDS" -lt 600 ]; do sleep 1; done' refusal-holder "$$" &
    holder=$!
    case "$variant" in
      lock-directory) mkdir "$dir/state/.lock" ;;
      lock-dangling-symlink) ln -s "$dir/state/no-such-lock" "$dir/state/.lock" ;;
      sidecar-read-once)
        sh -c ':' &
        dead_line1=$!
        wait "$dead_line1" 2>/dev/null || true
        printf '%s\n' "$dead_line1" > "$dir/state/.lock"
        holder_start=$(STATE="$dir/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_start_time "$2"' _ "$ROOT" "$holder") \
          || fail "sidecar-read-once: could not read the holder's start time"
        printf 'S1\nanchor=%s\nanchor-start=%s\n' "$holder" "$holder_start" > "$dir/state/.lock-session"
        ;;
      *) printf '%s\n' "$holder" > "$dir/state/.lock" ;;
    esac
    before=$(refusal_records "$dir")
    cp "$dir/parent-state/sm.busy-state" "$dir/parent-busy-before"
    status=0
    case "$variant" in
      nojq)
        out=$(printf '{"stop_hook_active":false,"session_id":"sess-refused"}' \
          | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID PATH="$nojq" CLAUDECODE=1 FM_HOME="$home" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \
            "$nojq/bash" "$dir/bin/fm-turnend-guard.sh" --claude 2>&1) || status=$?
        ;;
      unreadable-lock)
        # shellcheck disable=SC2016 # the fake harness expands FM_HOME inside its child shell.
        out=$(printf '{"stop_hook_active":false,"session_id":"sess-refused"}' \
          | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID PATH="$failcat:$PATH" FM_TEST_LOCK_READ_FAILED="$dir/lock-read-failed" \
            CLAUDECODE=1 FM_HOME="$home" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \
            "$claude" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; bash "$FM_HOME/bin/fm-turnend-guard.sh" --claude; exit $?' 2>&1) || status=$?
        [ -e "$dir/lock-read-failed" ] || fail "unreadable-lock: the injected first lock read never happened"
        ;;
      sidecar-read-once)
        # shellcheck disable=SC2016 # the fake harness expands FM_HOME inside its child shell.
        out=$(printf '{"stop_hook_active":false,"session_id":"sess-refused"}' \
          | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID PATH="$sidecarfail:$PATH" FM_TEST_SIDECAR_READ_ONCE="$dir/sidecar-read" \
            CLAUDECODE=1 FM_HOME="$home" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \
            "$claude" -c 'bash "$FM_HOME/bin/fm-turnend-guard.sh" --claude; exit $?' 2>&1) || status=$?
        [ -e "$dir/sidecar-read" ] || fail "sidecar-read-once: the sidecar was never read"
        ;;
      *)
        out=$(printf '{"stop_hook_active":false,"session_id":"sess-refused"}' \
          | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID CLAUDECODE=1 FM_HOME="$home" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \
            bash "$dir/bin/fm-turnend-guard.sh" --claude 2>&1) || status=$?
        ;;
    esac
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    expect_code 0 "$status" "$variant: a refused caller's Stop did not end: $out"
    case "$variant" in
      unreadable-lock)
        assert_contains "$out" "OWNER CANNOT BE VERIFIED: this read-only session cannot and should not arm or repair the watcher (the session lock cannot be read)" \
          "unreadable-lock: the Stop did not take the read-only exit with the unreadable-lock reason"
        assert_not_contains "$out" "lock owner pid" "unreadable-lock: the diagnostic named a holder pid it could not read"
        ;;
      sidecar-read-once)
        assert_contains "$out" "OWNED BY ANOTHER LIVE SESSION: this read-only session cannot and should not arm or repair the watcher (lock owner pid $holder)" \
          "sidecar-read-once: a sidecar that can be read only once lost the live recorded anchor $holder"
        ;;
      lock-directory|lock-dangling-symlink)
        assert_contains "$out" "OWNER CANNOT BE VERIFIED: this read-only session cannot and should not arm or repair the watcher (the session lock is not a regular file)" \
          "$variant: the Stop did not take the read-only exit with the nonregular-lock reason"
        assert_not_contains "$out" "lock owner pid" "$variant: the diagnostic named a holder pid it could not read"
        ;;
    esac
    [ "$(refusal_records "$dir")" = "$before" ] \
      || fail "$variant: a refused caller changed the owner's records: $(refusal_records "$dir")"
    cmp -s "$dir/parent-busy-before" "$dir/parent-state/sm.busy-state" \
      || fail "$variant: a refused caller changed the parent's busy record: $(cat "$dir/parent-state/sm.busy-state")"
  done
  dir=$(make_refusal_path_home "$TMP_ROOT/owner-nojq" stale)
  home=$(cd "$dir" && pwd)
  status=0
  # shellcheck disable=SC2016 # the fake harness expands FM_HOME inside its child shell.
  out=$(printf '{"stop_hook_active":false,"session_id":"sess-owner"}' \
    | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID PATH="$nojq" CLAUDECODE=1 FM_HOME="$home" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \
      "$claude" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; bash "$FM_HOME/bin/fm-turnend-guard.sh" --claude; exit $?' 2>&1) || status=$?
  expect_code 0 "$status" "nojq: the owner's Stop without jq did not end: $out"
  [ "$(parent_busy_verdict "$dir")" = 'state=idle source=claude-hook event=stop' ] \
    || fail "nojq: the owner's Stop without jq did not record idle for the parent: $(cat "$dir/parent-state/sm.busy-state")"

  for path in idle healthy daemon stale; do
    dir=$(make_refusal_path_home "$TMP_ROOT/owner-$path" "$path")
    home=$(cd "$dir" && pwd)
    status=0
    # shellcheck disable=SC2016 # the fake harness expands FM_HOME inside its child shell.
    out=$(printf '{"stop_hook_active":false,"session_id":"sess-owner"}' \
      | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID CLAUDECODE=1 FM_HOME="$home" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \
        "$claude" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; bash "$FM_HOME/bin/fm-turnend-guard.sh" --claude; exit $?' 2>&1) || status=$?
    stop_refusal_helper "$dir"
    assert_not_contains "$out" "OWNED BY ANOTHER LIVE SESSION" "$path: the lock owner took the read-only exit"
    case "$path" in
      idle)
        expect_code 0 "$status" "idle: the owner's idle Stop did not end silently: $out"
        [ "$(refusal_records "$dir")" = "$(printf '.turnend-claude-blocks=session=sess-owner\ncount=1\nepoch=\n.claude-autoarm-failure-notified=notified\n.claude-autoarm-failure-alarmed=alarmed')" ] \
          || fail "idle: the owner's idle Stop changed records it keeps while a failure notice is open: $(refusal_records "$dir")"
        [ "$(parent_busy_verdict "$dir")" = 'state=idle source=claude-hook event=stop' ] \
          || fail "idle: the owner's allowed Stop did not record idle for the parent: $(cat "$dir/parent-state/sm.busy-state")"
        ;;
      healthy|daemon)
        expect_code 0 "$status" "$path: the owner's supervised Stop did not end: $out"
        [ "$(refusal_records "$dir")" = "$(printf '.turnend-claude-blocks=absent\n.claude-autoarm-failure-notified=absent\n.claude-autoarm-failure-alarmed=absent')" ] \
          || fail "$path: the owner's supervised Stop did not reset its failure episode: $(refusal_records "$dir")"
        [ "$(parent_busy_verdict "$dir")" = 'state=idle source=claude-hook event=stop' ] \
          || fail "$path: the owner's allowed Stop did not record idle for the parent: $(cat "$dir/parent-state/sm.busy-state")"
        ;;
      stale)
        expect_code 2 "$status" "stale: the owner's blind Stop was not blocked: $out"
        assert_contains "$out" "TURN WOULD END BLIND" "stale: the owner's blocked Stop lost its repair diagnostic"
        [ "$(refusal_records "$dir")" = "$(printf '.turnend-claude-blocks=session=sess-owner\ncount=2\nepoch=\n.claude-autoarm-failure-notified=notified\n.claude-autoarm-failure-alarmed=alarmed')" ] \
          || fail "stale: the owner's blocked Stop did not charge one continuation and keep its failure markers: $(refusal_records "$dir")"
        [ "$(parent_busy_verdict "$dir")" = 'state=busy source=claude-hook event=stop-blocked' ] \
          || fail "stale: the owner's blocked Stop did not record busy for the parent: $(cat "$dir/parent-state/sm.busy-state")"
        ;;
    esac
  done
  pass "fm-turnend-guard: a refused caller ends read-only on every path and never touches the owner's or the parent's records; the owner keeps its ordinary writes"
}

test_hook_claude_refused_caller_never_touches_owner_records
