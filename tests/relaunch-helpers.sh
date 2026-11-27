#!/usr/bin/env bash
# tests/relaunch-helpers.sh - the shared setup of the relaunch suites
# (tests/fm-control-relaunch.test.sh and
# tests/fm-control-relaunch-live-agent.test.sh): the lifecycle-modelling tmux
# stub, task fixtures, the fm-control/fm-spawn runners, recorded-server
# stand-ins, and real processes working in a worktree. Sourced, never run.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tasks-axi-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-process-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot "$(basename "$0" .test.sh)")
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()
# Real processes the worktree-agent probe tests start, stopped on exit.
LIVE_PIDS=()

relaunch_cleanup() {
  local d
  for d in "${LIVE_PIDS[@]:-}"; do
    [ -n "$d" ] && stop_dir_process "$d"
  done
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && fm_test_remove_tree "$d"
  done
  stop_tmux_named_processes
  for d in "${TMP_TMUX_ROOTS[@]:-}"; do
    [ -n "$d" ] || continue
    tmux -S "$d/tmux-$(id -u)/default" kill-server 2>/dev/null
    rm -rf "$d"
  done
  fm_test_cleanup
}
trap relaunch_cleanup EXIT

# The same lifecycle-modelling tmux stub as tests/fm-control.test.sh: the
# harness's exit command stops the agent, and a launch-brief literal starts the
# harness named in `becomes`.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
# `-S <socket>` addresses the server listening there. That server answers its
# identity from socket-server (absent: nothing is listening) and, when
# socket-windows exists, its own window list; otherwise it is the same server
# this process addresses.
SOCK=
if [ "${1:-}" = -S ]; then SOCK=${2:-}; shift 2; fi
case "${1:-}" in
  has-session)
    prev=
    for a in "$@"; do
      if [ "$prev" = -t ] && grep -Fqx -- "${a#=}" "$D/missing-sessions" 2>/dev/null; then
        exit 1
      fi
      prev=$a
    done
    exit 0 ;;
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          [ -z "${FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP:-}" ] || exit 1
          ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
          # The replacement's arrival records whether the process named in
          # watch-pid is still running then (a zombie has exited).
          if [ -f "$D/watch-pid" ]; then
            case "$(ps -o stat= -p "$(cat "$D/watch-pid")" 2>/dev/null)" in
              ''|*Z*) echo exited ;;
              *) echo running ;;
            esac > "$D/watch-pid-at-launch"
          fi
          cat "$D/becomes" > "$D/command"
          [ -z "${FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START:-}" ] || exit 1
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      case "$payload" in
        'export GOTMPDIR='*)
          if [ -n "${FM_FAKE_TRACE_PREPARE:-}" ]; then
            : > "$FM_FAKE_TRACE_PREPARE"
            while [ ! -e "$FM_FAKE_TRACE_RELEASE" ]; do /bin/sleep 0.01; done
          fi
          ;;
        'export TRACEPARENT='*)
          [ -z "${FM_FAKE_TRACE_EXPORTED:-}" ] || : > "$FM_FAKE_TRACE_EXPORTED"
          ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *socket_path*)
          [ -f "$D/tmux-server" ] || exit 1
          printf '%s|%s\n' "$(cat "$D/tmux-socket")" "$(cat "$D/tmux-server")"; exit 0 ;;
        *start_time*)
          if [ -n "$SOCK" ]; then
            [ -f "$D/socket-server" ] || { echo "no server running on $SOCK" >&2; exit 1; }
            cat "$D/socket-server"
          else
            [ -f "$D/tmux-server" ] || { echo 'no server running on /tmp/tmux-1000/default' >&2; exit 1; }
            cat "$D/tmux-server"
          fi
          printf '\n'; exit 0 ;;
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_pid*) [ -f "$D/pane-pid" ] && cat "$D/pane-pid"; printf '\n'; exit 0 ;;
        *pane_current_path*)
          if [ -n "${FM_FAKE_CWD_RACE_READY:-}" ]; then
            : > "$FM_FAKE_CWD_RACE_READY"
            /bin/sleep 1
          fi
          cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    [ -z "${FM_FAKE_COMPOSER_READ_FAIL:-}" ] || exit 1
    if [ -s "$D/composer" ]; then
      printf '╭────╮\n│ %s  │\n╰────╯\n' "$(cat "$D/composer")"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows)
    # The three shapes real tmux answers a per-session inventory with. The
    # first two are DEFINITIVE and classify `missing`; the third is not and
    # classifies `unreadable`.
    if [ -n "$SOCK" ] && [ -f "$D/socket-windows" ]; then
      cat "$D/socket-windows"; exit 0
    fi
    prev=
    for a in "$@"; do
      if [ "$prev" = -t ]; then
        ses=${a#=}; ses=${ses%%:*}
        if grep -Fqx -- "$ses" "$D/missing-sessions" 2>/dev/null; then
          echo "can't find session: $ses" >&2
          exit 1
        fi
      fi
      prev=$a
    done
    if [ -f "$D/server-dead" ]; then
      echo 'no server running on /tmp/tmux-1000/default' >&2
      exit 1
    fi
    if [ -f "$D/session-missing" ]; then
      echo "can't find session: $(cat "$D/session-name")" >&2
      exit 1
    fi
    if [ -f "$D/inventory-broken" ]; then
      echo 'lost server' >&2
      exit 1
    fi
    [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  new-session)
    # Nothing in the relaunch path may ever create a session; recording the
    # call is how a refusal test proves that.
    shift
    ses=
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) ses=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$ses" >> "$D/created-sessions"
    exit 0 ;;
  new-window)
    # Model the one thing an endpoint re-creation depends on: the window now
    # appears in the session inventory, so the very next agent-state read stops
    # answering `missing`. Echo a stable window id the way the real -P -F does.
    shift
    name=
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=${2:-}; shift 2 ;;
        -c|-t) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$name" >> "$D/windows"
    printf '%s\n' "$name" >> "$D/created-windows"
    printf '@9\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_LOCK_WAITING:-}" ] || : > "$FM_FAKE_LOCK_WAITING"
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> [id] -> echoes a case dir with a live claude ship task.
new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' fmses > "$dir/fake/session-name"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> [harness] [session]
add_ship_task() {
  local dir=$1 id=$2 harness=${3:-claude} ses=${4:-fmses}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise relaunch behavior for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  {
    echo "window=$ses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$ses" > "$dir/fake/session-name"
  printf '%s' "$wt" > "$dir/fake/cwd"
  register_task_tmp "$id" "$home"
}

# register_task_tmp <id> [home]: have this run's cleanup remove the scratch a
# spawn creates for <id> - /tmp/fm-<id>, and with [home] the launch staging
# /tmp/fm-<id>+<sha256 of the home's physical path> beside it (bin/fm-spawn.sh
# names it so) - each only when it does not exist yet, so a directory this run
# did not create is never removed.
register_task_tmp() {  # <id> [home]
  local d hash
  set -- "$1" "${2:-}" "/tmp/fm-$1"
  if [ -n "$2" ] && hash=$(printf '%s' "$(cd "$2" && pwd -P)" | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{print $1}') && [ -n "$hash" ]; then
    set -- "$@" "/tmp/fm-$1+$hash"
  fi
  shift 2
  for d in "$@"; do
    [ -e "$d" ] || [ -L "$d" ] || TASK_TMPS+=("$d")
  done
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), and a relaunch reaches it through fm-control.sh, so this runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT="${RUN_CONTROL_EXIT_WAIT:-0.05}" FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_REAL_GIT="${FM_REAL_GIT:-}" FM_FAKE_GIT_FAILURE="${FM_FAKE_GIT_FAILURE:-}" \
    FM_REAL_MV="${FM_REAL_MV:-}" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL="${FM_FAKE_COMPLETE_JOURNAL_MV_FAIL:-}" \
    FM_FAKE_META_PUBLISH_MV_FAIL="${FM_FAKE_META_PUBLISH_MV_FAIL:-}" \
    FM_FAKE_JOURNAL_PHASE_MV_FAIL="${FM_FAKE_JOURNAL_PHASE_MV_FAIL:-}" \
    FM_FAKE_TRACE_PREPARE="${FM_FAKE_TRACE_PREPARE:-}" \
    FM_FAKE_TRACE_RELEASE="${FM_FAKE_TRACE_RELEASE:-}" \
    FM_FAKE_META_WRITER_READY="${FM_FAKE_META_WRITER_READY:-}" \
    FM_FAKE_TRACE_EXPORTED="${FM_FAKE_TRACE_EXPORTED:-}" \
    "$CONTROL" "$@" 2>&1
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so it runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    "$SPAWN" "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

journal_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.control-relaunch" | tail -1 | cut -d= -f2-
}

make_git_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/git" <<'SH'
#!/usr/bin/env bash
case "${FM_FAKE_GIT_FAILURE:-}:$*" in
  head:*' rev-parse --verify HEAD'|head:*' symbolic-ref -q HEAD') exit 128 ;;
  status:*' status --porcelain') exit 128 ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$1/fakebin/git"
}

make_mv_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/mv" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_COMPLETE_JOURNAL_MV_FAIL:-}" ]; then
  for path in "$@"; do
    if [ -f "$path" ] && grep -Fqx 'phase=complete' "$path"; then
      exit 1
    fi
  done
fi
if [ -n "${FM_FAKE_JOURNAL_PHASE_MV_FAIL:-}" ]; then
  for path in "$@"; do
    if [ -f "$path" ] && grep -Fqx "phase=$FM_FAKE_JOURNAL_PHASE_MV_FAIL" "$path"; then
      exit 1
    fi
  done
fi
if [ -n "${FM_FAKE_META_PUBLISH_MV_FAIL:-}" ]; then
  for path in "$@"; do
    [ "$path" != "$FM_FAKE_META_PUBLISH_MV_FAIL" ] || exit 1
  done
fi
source_path=
target_path=
for path in "$@"; do
  source_path=$target_path
  target_path=$path
done
if [ -n "${FM_FAKE_META_WRITER_TARGET:-}" ] \
   && [ "$target_path" = "$FM_FAKE_META_WRITER_TARGET" ] \
   && grep -q '^x_request=' "$source_path" 2>/dev/null; then
  : > "$FM_FAKE_META_WRITER_READY"
  while [ ! -e "$FM_FAKE_META_WRITER_RELEASE" ]; do /bin/sleep 0.01; done
fi
exec "$FM_REAL_MV" "$@"
SH
  chmod +x "$1/fakebin/mv"
}

make_rm_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ -n "${FM_FAKE_RM_FAIL_PATH:-}" ] && [ "$arg" = "$FM_FAKE_RM_FAIL_PATH" ]; then
    exit 1
  fi
done
exec "$FM_REAL_RM" "$@"
SH
  chmod +x "$1/fakebin/rm"
}

# Give a case home a real backlog carrying <id>, so the relaunch path's paired
# backlog transition (bin/fm-backlog-transition-lib.sh) is live rather than
# skipped for want of a backlog file.
seed_backlog() {  # <case-dir> <id> <queued|in_flight>
  local dir=$1 id=$2 want=$3 file="$1/home/data/backlog.md"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$file"
  tasks-axi add "$id" "relaunch fixture task" --kind ship --file "$file" >/dev/null
  [ "$want" != in_flight ] || tasks-axi start "$id" --file "$file" >/dev/null
}

backlog_state() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$1/home/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# Shadow tasks-axi so every `start` fails and every other verb is real. A
# relaunch that re-reads the row before acting never calls it; one that assumes
# it must re-run the transition trips over it.
break_tasks_axi_start() {  # <case-dir>
  local dir=$1 real
  real=$(command -v tasks-axi)
  cat > "$dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = start ]; then
  echo 'error: "start refused"' >&2
  exit 1
fi
exec "$real" "\$@"
SH
  chmod +x "$dir/fakebin/tasks-axi"
}


# strand_endpoint <case-dir> <id>: make a tmux endpoint read `missing` the way
# a destroyed window does - a successful session inventory that omits the exact
# window.
strand_endpoint() {  # <case-dir> <id>
  : > "$1/fake/windows"
}

TMUX_NAMED_PIDS=()
TMP_TMUX_ROOTS=()

# record_tmux_server <case-dir> <id> <pid:start-time>
record_tmux_server() {
  printf 'tmux_socket=/fake/tmux.sock\ntmux_server=%s\n' "$3" >> "$1/home/state/$2.meta"
}

# serve_tmux_from <case-dir> <pid:start-time>: the server this process now
# addresses, which is also the identity a fresh window is recorded under.
serve_tmux_from() {
  printf '/fake/tmux.sock' > "$1/fake/tmux-socket"
  printf '%s' "$2" > "$1/fake/tmux-server"
}

# exited_pid: set EXITED_PID to a pid no process holds any more.
exited_pid() {
  sh -c 'exit 0' &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  EXITED_PID=$!
  wait "$EXITED_PID"
}

# start_tmux_named_process <case-dir>: a live process the process table names
# tmux, standing in for a server that is still running. Sets TMUX_NAMED_PID.
start_tmux_named_process() {
  mkdir -p "$1/proc"
  ln -s "$(command -v sleep)" "$1/proc/tmux"
  "$1/proc/tmux" 300 >/dev/null 2>&1 &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  TMUX_NAMED_PID=$!
  TMUX_NAMED_PIDS+=("$TMUX_NAMED_PID")
}

stop_tmux_named_processes() {
  local pid
  for pid in "${TMUX_NAMED_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  return 0
}

# --- an agent outside the recorded endpoint ---------------------------------
#
# The probe reads the kernel's working directory of real processes, so these
# cases start real agent-named stand-ins (tests/lib.sh fm_agent_standin) and
# need no harness. The endpoint itself stays the stubbed tmux above, which is
# what lets the endpoint read agent-free while an agent still works in the
# worktree - the double tmux server fault, without a second server.

# start_dir_process <dir> <executable> [args...]: start a real process whose
# working directory is <dir>; its pid lands in STARTED_PID and LIVE_PIDS.
start_dir_process() {
  local dir=$1
  shift
  (cd "$dir" && exec "$@") </dev/null >/dev/null 2>&1 &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  STARTED_PID=$!
  LIVE_PIDS+=("$STARTED_PID")
}

# stop_dir_process <pid>: the one owner of a started process: stop it and any
# child it forked, reap it, and drop it from LIVE_PIDS so nothing signals the
# number again.
stop_dir_process() {
  pkill -P "$1" 2>/dev/null
  kill "$1" 2>/dev/null
  reap_dir_process "$1"
}

# reap_dir_process <pid>: for a started process that ends on its own (or was
# ended by a helper that owns its signal): reap it and drop it from LIVE_PIDS
# without signalling it.
reap_dir_process() {
  local p kept=()
  wait "$1" 2>/dev/null
  for p in "${LIVE_PIDS[@]:-}"; do
    [ -n "$p" ] && [ "$p" != "$1" ] && kept+=("$p")
  done
  LIVE_PIDS=("${kept[@]:-}")
  return 0
}

# agent_standin_named <dir> <name>: an agent-named stand-in executable, or
# nonzero when this host cannot build one that survives the rename.
agent_standin_named() {
  local standin
  standin=$(fm_agent_standin "$1/standin") || return 1
  mkdir -p "$1/agentbin"
  ln -sf "$standin" "$1/agentbin/$2"
  printf '%s\n' "$1/agentbin/$2"
}

# wait_probe_rc <dir> <want-rc>: poll the probe until it answers <want-rc>.
wait_probe_rc() {
  local i=0 rc
  while [ "$i" -lt 50 ]; do
    rc=0
    fm_agent_process_live_in_dir "$1" >/dev/null || rc=$?
    [ "$rc" = "$2" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

