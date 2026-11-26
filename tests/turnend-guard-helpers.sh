#!/usr/bin/env bash
# tests/turnend-guard-helpers.sh - fixture homes and supervision records shared
# by the turn-end guard suites (bin/fm-turnend-guard.sh). Sourced after
# tests/lib.sh; no side effects on source.

# Each scenario gets its own directory carrying a copy of the guard scripts
# under bin/, so the hook (invoked by absolute path) resolves its own FM_ROOT to
# that scenario dir regardless of the test's cwd.
install_guard_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard.sh"
  cp "$ROOT/bin/fm-turnend-guard-grok.sh" "$dir/bin/fm-turnend-guard-grok.sh"
  cp "$ROOT/bin/fm-operational-input.sh" "$dir/bin/fm-operational-input.sh"
  cp "$ROOT/bin/fm-supervision-instructions.sh" "$dir/bin/fm-supervision-instructions.sh"
  cp "$ROOT/bin/fm-harness.sh" "$dir/bin/fm-harness.sh"
  cp "$ROOT/bin/fm-hermes-process-lib.sh" "$dir/bin/fm-hermes-process-lib.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$dir/bin/fm-supervision-engine-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-path-lib.sh" "$dir/bin/fm-path-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-session-lock-decision-lib.sh" "$dir/bin/fm-session-lock-decision-lib.sh"
  cp "$ROOT/bin/fm-omp-process-lib.sh" "$dir/bin/fm-omp-process-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  # Launch probe sibling of fm-cursor-lib.sh; keep it next to the copy so a
  # fixture that ever verifies an executable does not source a missing file.
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/fm-timeout-lib.sh"
  mkdir -p "$dir/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard-grok.sh" "$dir/bin/fm-operational-input.sh" "$dir/bin/fm-supervision-instructions.sh" "$dir/bin/fm-harness.sh"
}

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/,
# state/ - everything the hook's scoping check requires to treat it as primary.
make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

watcher_identity() {
  local dir=$1 pid=$2
  FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$dir/bin/fm-wake-lib.sh" "$pid"
}

record_watcher_lock() {
  local dir=$1 pid=$2 identity=$3 root bin_dir
  root=$(cd "$dir" && pwd)
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
}

# Record a live away-mode daemon holding this home, the way the daemon does at
# startup: its singleton lock names the daemon pid plus the process identity it
# computed for itself (watcher_identity is that same fm_pid_identity read).
record_daemon_lock() {  # <dir> <pid> [identity]
  local dir=$1 pid=$2 identity=${3:-} lockdir
  if [ -z "$identity" ]; then
    identity=$(watcher_identity "$dir" "$pid") || return 1
  fi
  lockdir="$dir/state/.supervise-daemon.lock"
  mkdir -p "$lockdir"
  printf '%s\n' "$pid" > "$lockdir/pid"
  printf '%s\n' "$identity" > "$lockdir/pid-identity"
}
