#!/usr/bin/env bash
# fm-idle-stop-lib.sh - the ONE owner of the idle-session stop contract: the
# local config, the stopped-session record, the relaunch-wait notice, and the
# idle proof a sweep needs before it may stop a worker's harness session.
#
# Why: an idle harness session costs about as much memory as a working one, and
# a worker that reported done, or has sat paused or parked for a long time,
# holds that memory until teardown. bin/fm-idle-stop.sh stops such a session
# through the control plane's own `exit` (bin/fm-control.sh) and records the
# stop here, so every reader can tell an expected, recorded stop from a crashed
# or dead worker. The window, worktree, branch, and every unlanded change stay
# exactly where they were; the session comes back through `relaunch` when
# something next needs the worker.
#
# Config: config/idle-session-stop, one optional local file
# (docs/configuration.md "Idle session stop" owns the operator contract).
# Blank lines and `#` comments are skipped; every other line is one of:
#   off                    stop nothing at all (the off switch)
#   done=on|off            stop a done worker's idle session (default on)
#   done_after=<seconds>   how long a done worker must be idle first (default 120)
#   idle_after=<seconds>   how long a paused or parked worker must be idle
#                          before memory pressure may stop it (default 1800)
#   memory_check=<abs-path> [args...]
#                          the host memory signal: run directly (no shell),
#                          exit 0 = memory is fine, any other exit = short;
#                          a timeout, a missing or unrunnable command, or a
#                          signal death is no answer and stops nothing. With
#                          no memory_check line, paused and parked workers are
#                          never stopped.
# With the file absent every key takes its default, so a done worker's idle
# session is stopped by default and nothing else is. The file must be a
# regular file owned by this user and writable by nobody else, or it is read as
# `off` (it chooses a command the watcher's sweep runs).
#
# Record: state/<id>.session-stopped, written only by bin/fm-idle-stop.sh after
# `fm-control.sh <id> exit` reported `stopped`:
#   schema=fm-session-stopped.v1
#   at=<epoch the session was stopped>
#   reason=done|idle-memory
#   endpoint=<the recorded backend target it was stopped at>
#   state=<the fm-crew-state.sh reading that made it eligible>
#   status=<the worker's current status declaration at that moment>
# The record is VALID only while its endpoint is still the task's recorded
# endpoint and that endpoint reads `dead` (its pane is there, holding no agent).
# An agent that came back, an endpoint that went missing, or a task record that
# moved to another endpoint makes it stale: readers ignore a stale record, and
# the next sweep removes it, so ordinary recovery owns everything a stop did
# not cause. A successful relaunch removes it (bin/fm-control.sh), and teardown
# removes it with the rest of the task's state.
#
# Notice: state/<id>.session-revive, written when a relaunch on demand was
# refused (the away spend cap, an account pin, any launch refusal):
#   schema=fm-session-revive.v1
#   at=<epoch of the refusal>
#   next=<epoch before which no retry runs>
#   surfaced=0|1
#   reason=<the refusal's own first line>
# The watcher reports each new refusal once as a check wake and the sweep
# retries silently after `next`; the waiting instruction stays durable in the
# task's steering inbox throughout.
#
# Sourced by bin/fm-idle-stop.sh, bin/fm-watch.sh, bin/fm-crew-state.sh,
# bin/fm-control.sh, bin/fm-send.sh, and bin/fm-session-start.sh. No side
# effects on source; requires bin/fm-backend.sh's dispatch for the endpoint
# reads.

_FM_IDLE_STOP_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_IDLE_STOP_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_IDLE_STOP_LIB_DIR=.
# shellcheck source=bin/fm-agent-process-lib.sh
. "${_FM_IDLE_STOP_LIB_DIR:-/}/fm-agent-process-lib.sh"
unset _FM_IDLE_STOP_LIB_DIR

FM_IDLE_STOP_RECORD_SCHEMA='fm-session-stopped.v1'
FM_IDLE_STOP_NOTICE_SCHEMA='fm-session-revive.v1'
FM_IDLE_STOP_DONE_AFTER_DEFAULT=120
FM_IDLE_STOP_IDLE_AFTER_DEFAULT=1800

fm_idle_stop_record_path() {  # <state-dir> <id>
  printf '%s/%s.session-stopped' "$1" "$2"
}

fm_idle_stop_notice_path() {  # <state-dir> <id>
  printf '%s/%s.session-revive' "$1" "$2"
}

# fm_idle_stop_field <file> <key>: the last value of key=<value> in a record.
fm_idle_stop_field() {  # <file> <key>
  [ -f "$1" ] || return 1
  awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2); found = 1 } END { if (!found) exit 1; print v }' "$1"
}

# --- config -----------------------------------------------------------------

fm_idle_stop_config_path() {  # <config-dir>
  printf '%s/idle-session-stop' "$1"
}

# A config file is trusted only when it is a regular file, not a symlink, owned
# by this user, and writable by nobody else, because it names a command.
fm_idle_stop_config_trusted() {  # <path>
  local f=$1 mode
  [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    mode=$(/usr/bin/stat -f '%Lp' "$f" 2>/dev/null) || return 1
  else
    mode=$(stat -c '%a' "$f" 2>/dev/null) || return 1
  fi
  case "$mode" in ''|*[!0-7]*) return 1 ;; esac
  [ $(( 8#$mode & 8#022 )) -eq 0 ]
}

# fm_idle_stop_config_load <config-dir>: set the FM_IDLE_STOP_* settings.
#   FM_IDLE_STOP_ENABLED      1 unless the file says off or is untrusted
#   FM_IDLE_STOP_DONE         1 when done workers are stopped
#   FM_IDLE_STOP_DONE_AFTER   seconds
#   FM_IDLE_STOP_IDLE_AFTER   seconds
#   FM_IDLE_STOP_MEMORY_CHECK the memory_check line's value, or empty
#   FM_IDLE_STOP_CONFIG_ERROR a one-line reason the file was refused, or empty
# A malformed value keeps its default and is named in the config error, so a
# typo never widens what is stopped.
# shellcheck disable=SC2034  # The settings are read by the sourcing script.
fm_idle_stop_config_load() {  # <config-dir>
  local f line key value
  f=$(fm_idle_stop_config_path "$1")
  FM_IDLE_STOP_ENABLED=1
  FM_IDLE_STOP_DONE=1
  FM_IDLE_STOP_DONE_AFTER=$FM_IDLE_STOP_DONE_AFTER_DEFAULT
  FM_IDLE_STOP_IDLE_AFTER=$FM_IDLE_STOP_IDLE_AFTER_DEFAULT
  FM_IDLE_STOP_MEMORY_CHECK=
  FM_IDLE_STOP_CONFIG_ERROR=
  [ -e "$f" ] || [ -L "$f" ] || return 0
  if ! fm_idle_stop_config_trusted "$f"; then
    FM_IDLE_STOP_ENABLED=0
    FM_IDLE_STOP_CONFIG_ERROR="$f is not a regular file owned by this user and writable only by it; idle-session stop is off until it is"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in ''|'#'*) continue ;; esac
    if [ "$line" = off ]; then
      FM_IDLE_STOP_ENABLED=0
      continue
    fi
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) FM_IDLE_STOP_CONFIG_ERROR="unrecognized line '$line'"; continue ;;
    esac
    case "$key" in
      done)
        case "$value" in
          on) FM_IDLE_STOP_DONE=1 ;;
          off) FM_IDLE_STOP_DONE=0 ;;
          *) FM_IDLE_STOP_CONFIG_ERROR="done must be on or off, not '$value'" ;;
        esac
        ;;
      done_after|idle_after)
        case "$value" in
          ''|*[!0-9]*) FM_IDLE_STOP_CONFIG_ERROR="$key must be whole seconds, not '$value'" ;;
          *)
            if [ "${#value}" -gt 9 ]; then
              FM_IDLE_STOP_CONFIG_ERROR="$key is out of range"
            elif [ "$key" = done_after ]; then
              FM_IDLE_STOP_DONE_AFTER=$((10#$value))
            else
              FM_IDLE_STOP_IDLE_AFTER=$((10#$value))
            fi
            ;;
        esac
        ;;
      memory_check)
        case "$value" in
          /*) FM_IDLE_STOP_MEMORY_CHECK=$value ;;
          *) FM_IDLE_STOP_CONFIG_ERROR="memory_check must start with an absolute command path" ;;
        esac
        ;;
      *) FM_IDLE_STOP_CONFIG_ERROR="unrecognized key '$key'" ;;
    esac
  done < "$f"
  return 0
}

# fm_idle_stop_memory_verdict: run the configured memory check once. Prints
# `fine`, `short`, or `unknown <why>`. The command line is split on blanks and
# run directly, never through a shell, with stdin closed, bounded by
# FM_IDLE_STOP_MEMORY_TIMEOUT (default 15) seconds.
fm_idle_stop_memory_verdict() {
  local timeout=${FM_IDLE_STOP_MEMORY_TIMEOUT:-15} rc=0
  local -a argv
  case "$timeout" in ''|*[!0-9]*|0) timeout=15 ;; esac
  [ -n "${FM_IDLE_STOP_MEMORY_CHECK:-}" ] || { printf 'unknown no memory_check configured'; return 0; }
  read -r -a argv <<< "$FM_IDLE_STOP_MEMORY_CHECK"
  [ -x "${argv[0]}" ] || { printf 'unknown %s is not executable' "${argv[0]}"; return 0; }
  fm_run_timed "$timeout" "${argv[@]}" </dev/null >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'fine'
  elif fm_timed_out "$rc" || [ "$rc" -ge 126 ]; then
    printf 'unknown memory_check gave no answer (exit %s)' "$rc"
  else
    printf 'short'
  fi
}

# --- record -----------------------------------------------------------------

# fm_idle_stop_record_valid <state-dir> <id> <meta>: 0 when the task has a
# well-formed stop record whose endpoint is the task's recorded endpoint and
# that endpoint reads `dead` right now. Sets FM_IDLE_STOP_RECORD_AGENT_STATE
# to the state it read (empty when it did not need to read one).
fm_idle_stop_record_valid() {  # <state-dir> <id> <meta>
  local state=$1 id=$2 meta=$3 rec endpoint target backend
  FM_IDLE_STOP_RECORD_AGENT_STATE=
  rec=$(fm_idle_stop_record_path "$state" "$id")
  [ -f "$rec" ] && [ -f "$meta" ] || return 1
  [ "$(fm_idle_stop_field "$rec" schema 2>/dev/null)" = "$FM_IDLE_STOP_RECORD_SCHEMA" ] || return 1
  endpoint=$(fm_idle_stop_field "$rec" endpoint 2>/dev/null) || return 1
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] && [ "$endpoint" = "$target" ] || return 1
  backend=$(fm_backend_of_meta "$meta")
  FM_IDLE_STOP_RECORD_AGENT_STATE=$(fm_backend_agent_state "$backend" "$target" "$meta" 2>/dev/null || true)
  [ "$FM_IDLE_STOP_RECORD_AGENT_STATE" = dead ]
}

# fm_idle_stop_record_describe <state-dir> <id>: one plain line for readers.
fm_idle_stop_record_describe() {  # <state-dir> <id>
  local rec at reason when
  rec=$(fm_idle_stop_record_path "$1" "$2")
  at=$(fm_idle_stop_field "$rec" at 2>/dev/null) || at=
  reason=$(fm_idle_stop_field "$rec" reason 2>/dev/null) || reason=
  when=$(date -u -r "${at:-0}" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@${at:-0}" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf '%s' "$at")
  case "$reason" in
    done) reason='done and idle' ;;
    idle-memory) reason='idle while host memory was short' ;;
  esac
  printf 'session stopped (%s) at %s; relaunches on demand' "${reason:-idle}" "$when"
}

fm_idle_stop_record_write() {  # <state-dir> <id> <reason> <endpoint> <state-line> <status-line>
  local rec tmp
  rec=$(fm_idle_stop_record_path "$1" "$2")
  tmp="$rec.tmp.$$"
  {
    printf 'schema=%s\n' "$FM_IDLE_STOP_RECORD_SCHEMA"
    printf 'at=%s\n' "$(date +%s)"
    printf 'reason=%s\n' "$3"
    printf 'endpoint=%s\n' "$4"
    printf 'state=%s\n' "$(printf '%s' "$5" | tr '\n' ' ')"
    printf 'status=%s\n' "$(printf '%s' "$6" | tr '\n' ' ')"
  } > "$tmp" && mv -f "$tmp" "$rec"
}

# Remove the record and any relaunch-wait notice. Idempotent.
fm_idle_stop_record_clear() {  # <state-dir> <id>
  rm -f "$(fm_idle_stop_record_path "$1" "$2")" "$(fm_idle_stop_notice_path "$1" "$2")"
}

# --- relaunch-wait notice -----------------------------------------------------

# fm_idle_stop_notice_write <state-dir> <id> <reason> <retry-secs>: record a
# refused relaunch. A refusal whose reason matches the standing notice keeps
# its surfaced flag, so one refusal reason is reported once, not every retry.
fm_idle_stop_notice_write() {  # <state-dir> <id> <reason> <retry-secs>
  local f tmp surfaced=0 prior now
  f=$(fm_idle_stop_notice_path "$1" "$2")
  prior=$(fm_idle_stop_field "$f" reason 2>/dev/null) || prior=
  if [ -n "$prior" ] && [ "$prior" = "$3" ]; then
    surfaced=$(fm_idle_stop_field "$f" surfaced 2>/dev/null) || surfaced=0
  fi
  now=$(date +%s)
  tmp="$f.tmp.$$"
  {
    printf 'schema=%s\n' "$FM_IDLE_STOP_NOTICE_SCHEMA"
    printf 'at=%s\n' "$now"
    printf 'next=%s\n' "$((now + $4))"
    printf 'surfaced=%s\n' "$surfaced"
    printf 'reason=%s\n' "$(printf '%s' "$3" | tr '\n' ' ')"
  } > "$tmp" && mv -f "$tmp" "$f"
}

fm_idle_stop_notice_mark_surfaced() {  # <state-dir> <id>
  local f tmp
  f=$(fm_idle_stop_notice_path "$1" "$2")
  [ -f "$f" ] || return 0
  tmp="$f.tmp.$$"
  awk '/^surfaced=/ { print "surfaced=1"; next } { print }' "$f" > "$tmp" && mv -f "$tmp" "$f"
}

# 0 when a refused relaunch's retry is not due yet.
fm_idle_stop_notice_holds() {  # <state-dir> <id>
  local next
  next=$(fm_idle_stop_field "$(fm_idle_stop_notice_path "$1" "$2")" next 2>/dev/null) || return 1
  case "$next" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(date +%s)" -lt "$next" ]
}

# --- idle proof -----------------------------------------------------------------

# fm_idle_stop_unhandled_steer <state-dir> <id>: 0 when the steering inbox
# holds any record not yet acknowledged, fire-and-forget records included.
fm_idle_stop_unhandled_steer() {  # <state-dir> <id>
  local f
  for f in "$1/$2.inbox"/*.msg; do
    [ -e "$f" ] && return 0
  done
  return 1
}

# fm_idle_stop_running_command <target>: whether the agent in a tmux pane is
# holding a running command. A harness's turn can end while a shell it started
# keeps running - a background job, a monitor, a validation it waits on - and
# exiting the harness would kill that shell with it, so a live shell anywhere
# below the agent process means the worker is not idle, whatever its busy
# record says. Prints the first such shell as `<pid> <comm>`.
# 0 = a running command was found; 1 = the agent holds none; 2 = no proof
# either way (no pane pid, an unreadable process table, or no agent process
# under the pane), which callers must treat as not idle.
fm_idle_stop_running_command() {  # <target>
  local target=$1 pane_pid table agents shells
  pane_pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || return 2
  case "$pane_pid" in ''|*[!0-9]*) return 2 ;; esac
  table=$(LC_ALL=C ps -A -o pid=,ppid=,comm= 2>/dev/null) || return 2
  [ -n "$table" ] || return 2
  # Walk the pane's process tree once: first the agent processes below the
  # pane, then the shells below any agent process.
  agents=$(printf '%s\n' "$table" | awk -v root="$pane_pid" '
    { pid = $1; ppid = $2; $1 = ""; $2 = ""; sub(/^  */, ""); comm[pid] = $0; parent[pid] = ppid; order[++n] = pid }
    END {
      inside[root] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= n; i++) { p = order[i]; if (!(p in inside) && (parent[p] in inside)) { inside[p] = 1; changed = 1 } }
      }
      for (i = 1; i <= n; i++) { p = order[i]; if ((p in inside) && p != root) print p "\t" comm[p] }
    }')
  local pid name agent_pids=''
  while IFS=$'\t' read -r pid name; do
    [ -n "$pid" ] || continue
    if [ "$(fm_agent_process_classify_name "$name")" = agent ]; then
      agent_pids="$agent_pids $pid"
    fi
  done <<EOF
$agents
EOF
  [ -n "$agent_pids" ] || return 2
  shells=$(printf '%s\n' "$table" | awk -v roots="$agent_pids" '
    BEGIN { m = split(roots, r, " "); for (i = 1; i <= m; i++) if (r[i] != "") inside[r[i]] = 1 }
    { pid = $1; ppid = $2; $1 = ""; $2 = ""; sub(/^  */, ""); comm[pid] = $0; parent[pid] = ppid; order[++n] = pid }
    END {
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= n; i++) { p = order[i]; if (!(p in inside) && (parent[p] in inside)) { inside[p] = 1; below[p] = 1; changed = 1 } }
      }
      for (i = 1; i <= n; i++) { p = order[i]; if (p in below) print p "\t" comm[p] }
    }')
  while IFS=$'\t' read -r pid name; do
    [ -n "$pid" ] || continue
    if [ "$(fm_agent_process_classify_name "$name")" = shell ]; then
      printf '%s %s' "$pid" "${name##*/}"
      return 0
    fi
  done <<EOF
$shells
EOF
  return 1
}

# fm_idle_stop_last_activity <state-dir> <id>: the newest epoch at which the
# worker showed any sign of activity: its busy record's last event, its status
# log, its turn-end notification, or its steering inbox acknowledgements.
fm_idle_stop_last_activity() {  # <state-dir> <id>
  local state=$1 id=$2 newest=0 t f line
  line=$(cat "$(fm_busy_record_path "$state" "$id")" 2>/dev/null) || line=
  t=$(printf '%s\n' "$line" | tr ' ' '\n' | awk -F= '$1 == "ts" { print $2; exit }')
  case "$t" in ''|*[!0-9]*) ;; *) [ "$t" -le "$newest" ] || newest=$t ;; esac
  for f in "$state/$id.status" "$state/$id.turn-ended" "$state/$id.inbox/handled" "$state/$id.inbox"; do
    [ -e "$f" ] || continue
    if [ "$(uname)" = Darwin ]; then
      t=$(/usr/bin/stat -f %m "$f" 2>/dev/null) || continue
    else
      t=$(stat -c %Y "$f" 2>/dev/null) || continue
    fi
    case "$t" in ''|*[!0-9]*) continue ;; esac
    [ "$t" -le "$newest" ] || newest=$t
  done
  printf '%s' "$newest"
}
