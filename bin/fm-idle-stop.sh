#!/usr/bin/env bash
# fm-idle-stop.sh - stop idle worker sessions, and bring them back on demand.
#
# Usage: fm-idle-stop.sh sweep
#        fm-idle-stop.sh check <task-id>
#        fm-idle-stop.sh revive <task-id>
#
# A harness session costs about the same memory idle as working, so a worker
# that reported done, or that has sat paused or parked for a long time while
# the host is short of memory, holds that memory for nothing. This tool stops
# such a session through the control plane's own `fm-control.sh <id> exit` and
# nothing lower, records the stop (bin/fm-idle-stop-lib.sh owns the record,
# the config, and the idle proof), and relaunches the worker through
# `fm-control.sh <id> relaunch` when something next needs it. The window,
# worktree, branch, and every unlanded change stay untouched throughout, and
# teardown and landing treat a stopped worker exactly as any other.
#
#   sweep   One deterministic pass over this home's ship and scout tasks, run
#           detached by the watcher on a cadence (bin/fm-watch.sh
#           idle_stop_tick) in a home that created config/idle-session-stop;
#           it spends no model turns and wakes nobody. A task
#           is stopped only when every condition below holds, read fresh:
#             - an ordinary local ship or scout on tmux (the backend whose
#               process tree proves the agent holds no running command), not a
#               secondmate, a remote task, or an adopted pull request;
#             - its agent is alive and its semantic busy verdict is exactly
#               idle (bin/fm-busy-lib.sh; unknown is never idle), so a worker
#               waiting inside a foreground command - a CI wait, a validation
#               drive call - is busy and stays up;
#             - no shell is running below the agent process, so a worker whose
#               turn ended over a background job stays up too;
#             - its steering inbox holds no unacknowledged steer, and no other
#               lifecycle action holds its control lock;
#             - its current state (bin/fm-crew-state.sh) is `done`, and done
#               stopping is on, and it has been idle for done_after; or it is
#               `paused` or `parked`, it has been idle for idle_after, and the
#               configured memory check reports memory short. A done or paused
#               worker with any open decision stays up; a parked worker's own
#               open decision is what parks it, and its answer arrives as a
#               steer, which relaunches it.
#           Then it runs `fm-control.sh <id> exit --only-if-idle`. Every refusal
#           that exit makes - a busy agent, pending composer text, a blocking
#           dialog, a state it cannot prove - is "not now": logged, retried on a
#           later sweep, never forced. Only an exit that reports `stopped`
#           writes the record. A steer that landed while the exit ran is
#           noticed at once and relaunches the worker.
#           The sweep also removes records that no longer describe reality (the
#           agent came back, the endpoint moved or went missing) and retries a
#           refused relaunch once its wait has passed.
#   check   Print the verdict the sweep would reach for one task, as
#           `eligible done`, `eligible idle-memory`, or `skip <reason>`. Reads
#           only, stops nothing.
#   revive  Relaunch one stopped worker through `fm-control.sh <id> relaunch`
#           with a note that carries its recorded state forward and points it at
#           its steering inbox first. On success the record is cleared. A
#           refusal (the away spend cap's `deferred:` exit 75, an account pin,
#           any launch refusal) writes the relaunch-wait notice instead: the
#           watcher reports it once as a check wake, the steer stays durable in
#           the inbox, and the next retry waits FM_IDLE_STOP_REVIVE_RETRY_SECS.
#           Exits 0 when the worker is back, 75 on a refusal recorded as a wait,
#           1 when there is nothing to revive.
#           bin/fm-send.sh and the watcher start this detached when a steer
#           reaches a stopped worker; an explicit `fm-control.sh <id> relaunch`
#           works on a stopped worker directly and clears the record the same
#           way.
#
# Environment:
#   FM_HOME                         required, the home whose tasks are read
#   FM_IDLE_STOP_REVIVE_RETRY_SECS  wait before retrying a refused relaunch (600)
#   FM_IDLE_STOP_MEMORY_TIMEOUT     bound on one memory check run, seconds (15)
#   FM_IDLE_STOP_CONTROL            the control plane to call (tests only)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  sweep|check|revive) ;;
  *) usage >&2; exit 2 ;;
esac
VERB=$1
shift

if [ -z "${FM_HOME:-}" ] || [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME must name this home's directory; fm-idle-stop refuses to guess which home's workers to stop" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 1; }
CONTROL=${FM_IDLE_STOP_CONTROL:-$SCRIPT_DIR/fm-control.sh}
REVIVE_RETRY=${FM_IDLE_STOP_REVIVE_RETRY_SECS:-600}
case "$REVIVE_RETRY" in ''|*[!0-9]*) REVIVE_RETRY=600 ;; esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-idle-stop-lib.sh
. "$SCRIPT_DIR/fm-idle-stop-lib.sh"

LOG="$STATE/.idle-stop.log"
log() {  # <line>
  local max=${FM_IDLE_STOP_LOG_MAX_BYTES:-131072} size
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || return 0
  size=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ') || return 0
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$size" -gt "$max" ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
  fi
}

fm_idle_stop_config_load "$CONFIG"
MEMORY_VERDICT=

memory_verdict() {
  [ -n "$MEMORY_VERDICT" ] || MEMORY_VERDICT=$(fm_idle_stop_memory_verdict)
  printf '%s' "$MEMORY_VERDICT"
}

crew_state() {  # <id>
  FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CREW_STATE_NO_FORGE=1 \
    "$SCRIPT_DIR/fm-crew-state.sh" "$1" 2>/dev/null
}

# verdict <id>: prints `eligible <reason>` or `skip <why>`; sets VERDICT_STATE
# and VERDICT_STATUS for the record.
VERDICT_STATE=
VERDICT_STATUS=
verdict() {  # <id>
  local id=$1 meta="$STATE/$1.meta" kind backend target agent busy running reading word
  local status_file="$STATE/$1.status" open now idle after reason
  VERDICT_STATE=
  VERDICT_STATUS=
  if [ "$FM_IDLE_STOP_ENABLED" != 1 ]; then
    printf 'skip idle-session stop is off%s' "${FM_IDLE_STOP_CONFIG_ERROR:+ ($FM_IDLE_STOP_CONFIG_ERROR)}"
    return 0
  fi
  [ -f "$meta" ] || { printf 'skip no task record'; return 0; }
  kind=$(fm_meta_get "$meta" kind); [ -n "$kind" ] || kind=ship
  case "$kind" in
    ship|scout) ;;
    *) printf 'skip a %s is never stopped' "$kind"; return 0 ;;
  esac
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || { printf 'skip remote task'; return 0; }
  ! fm_pr_adopted_record "$meta" || { printf 'skip adopted pull request, no worker'; return 0; }
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || { printf 'skip no recorded endpoint'; return 0; }
  [ "$backend" = tmux ] || { printf 'skip the %s backend has no process proof that the agent holds no running command' "$backend"; return 0; }
  if fm_idle_stop_record_valid "$STATE" "$id" "$meta"; then
    printf 'skip already stopped'
    return 0
  fi
  agent=${FM_IDLE_STOP_RECORD_AGENT_STATE:-$(fm_backend_agent_state "$backend" "$target" "$meta" 2>/dev/null || true)}
  [ "$agent" = alive ] || { printf 'skip agent is %s' "${agent:-unreadable}"; return 0; }
  [ ! -d "$STATE/.control-$id.lock" ] || { printf 'skip another lifecycle action holds the task'; return 0; }
  busy=$(fm_busy_classify_meta "$meta" "$id" "$STATE")
  case "$busy" in
    idle\ *) ;;
    *) printf 'skip harness is not proven idle (%s)' "$busy"; return 0 ;;
  esac
  ! fm_idle_stop_unhandled_steer "$STATE" "$id" || { printf 'skip an unread steer waits in its inbox'; return 0; }
  running=0
  fm_idle_stop_running_command "$target" >/dev/null || running=$?
  case "$running" in
    0) printf 'skip agent holds a running command (%s)' "$(fm_idle_stop_running_command "$target")"; return 0 ;;
    1) ;;
    *) printf 'skip no process proof that the agent holds no running command'; return 0 ;;
  esac
  reading=$(crew_state "$id")
  word=${reading#state: }
  word=${word%% *}
  VERDICT_STATE=$reading
  VERDICT_STATUS=$(status_current_line "$status_file" "$kind")
  open=$(status_open_decisions "$status_file" "$kind")
  now=$(date +%s)
  idle=$((now - $(fm_idle_stop_last_activity "$STATE" "$id")))
  case "$word" in
    done)
      [ "$FM_IDLE_STOP_DONE" = 1 ] || { printf 'skip done stopping is off'; return 0; }
      [ -z "$open" ] || { printf 'skip an open decision stands'; return 0; }
      after=$FM_IDLE_STOP_DONE_AFTER
      reason='done'
      ;;
    paused|parked)
      if [ "$word" = paused ] && [ -n "$open" ]; then
        printf 'skip an open decision stands'
        return 0
      fi
      after=$FM_IDLE_STOP_IDLE_AFTER
      reason='idle-memory'
      ;;
    *)
      printf 'skip current state is %s' "${word:-unreadable}"
      return 0
      ;;
  esac
  [ "$idle" -ge "$after" ] || { printf 'skip idle %ss of %ss' "$idle" "$after"; return 0; }
  if [ "$reason" = idle-memory ]; then
    [ -n "$FM_IDLE_STOP_MEMORY_CHECK" ] || { printf 'skip no memory_check configured'; return 0; }
    case "$(memory_verdict)" in
      short) ;;
      fine) printf 'skip host memory is fine'; return 0 ;;
      *) printf 'skip memory check: %s' "$(memory_verdict)"; return 0 ;;
    esac
  fi
  printf 'eligible %s' "$reason"
}

# revive_detached <id>: start a revive without waiting for it.
revive_detached() {  # <id>
  FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG \
    nohup "$SCRIPT_DIR/fm-idle-stop.sh" revive "$1" </dev/null >/dev/null 2>&1 &
}

stop_one() {  # <id>
  local id=$1 meta="$STATE/$1.meta" v out rc=0 reason target
  v=$(verdict "$id")
  case "$v" in
    eligible\ *) reason=${v#eligible } ;;
    *) return 0 ;;
  esac
  target=$(fm_backend_target_of_meta "$meta")
  # The record goes down first: it is inert while the agent still runs (only a
  # dead endpoint makes it valid), so no reader can ever see the stopped pane
  # without it. A refused exit takes it away again.
  fm_idle_stop_record_write "$STATE" "$id" "$reason" "$target" "$VERDICT_STATE" "$VERDICT_STATUS" \
    || { log "$id not now: its stop record could not be written"; return 0; }
  out=$(FM_HOME=$FM_HOME "$CONTROL" "$id" exit --only-if-idle 2>&1) || rc=$?
  case "$rc:$out" in
    0:stopped\ *)
      log "$id stopped ($reason)"
      # A steer that arrived while the exit ran must not wait for anyone.
      if fm_idle_stop_unhandled_steer "$STATE" "$id"; then
        revive_detached "$id"
      fi
      ;;
    *)
      fm_idle_stop_record_clear "$STATE" "$id"
      log "$id not now: $(printf '%s' "$out" | tail -n 1)"
      ;;
  esac
}

# Records that no longer describe reality go; a refused relaunch whose wait has
# passed is retried.
reconcile_one() {  # <id>
  local id=$1 meta="$STATE/$1.meta" rec agent
  rec=$(fm_idle_stop_record_path "$STATE" "$id")
  [ -f "$rec" ] || return 1
  if fm_idle_stop_record_valid "$STATE" "$id" "$meta"; then
    if fm_idle_stop_unhandled_steer "$STATE" "$id" && ! fm_idle_stop_notice_holds "$STATE" "$id" \
      && [ ! -d "$STATE/.idle-revive-$id.lock" ]; then
      revive_detached "$id"
    fi
    return 0
  fi
  agent=$FM_IDLE_STOP_RECORD_AGENT_STATE
  case "$agent" in
    unreadable|ambiguous)
      # Not proven either way: keep the record for a later read.
      ;;
    '')
      fm_idle_stop_record_clear "$STATE" "$id"
      log "$id stop record cleared (it no longer matches the task record)"
      ;;
    *)
      fm_idle_stop_record_clear "$STATE" "$id"
      log "$id stop record cleared (endpoint now reads $agent)"
      ;;
  esac
  return 0
}

do_sweep() {
  local lock meta id
  if [ -n "$FM_IDLE_STOP_CONFIG_ERROR" ] && [ "$FM_IDLE_STOP_ENABLED" = 0 ]; then
    log "config refused: $FM_IDLE_STOP_CONFIG_ERROR"
  fi
  lock="$STATE/.idle-stop.lock"
  fm_lock_try_acquire "$lock" || return 0
  # shellcheck disable=SC2064
  trap "fm_lock_release '$lock' >/dev/null 2>&1 || true" EXIT
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    # Reconciling existing records runs even when stopping is off, so a home
    # that turns the feature off still gets its stopped workers back on demand.
    reconcile_one "$id" && continue
    [ "$FM_IDLE_STOP_ENABLED" = 1 ] || continue
    stop_one "$id"
  done
}

note_for() {  # <id>
  local id=$1 rec at status when
  rec=$(fm_idle_stop_record_path "$STATE" "$id")
  at=$(fm_idle_stop_field "$rec" at 2>/dev/null) || at=
  status=$(fm_idle_stop_field "$rec" status 2>/dev/null) || status=
  when=$(date -u -r "${at:-0}" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@${at:-0}" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf '%s' "$at")
  printf '%s\n' "Firstmate stopped this worker's idle session at $when to free host memory; nothing in the local copy was touched."
  [ -z "$status" ] || printf '%s\n' "Your latest status at that moment was: $status"
  printf '%s\n' "You were relaunched because something needs you: an instruction is waiting in your steering inbox. Read and act on it first, as the inbox instructions above describe, then continue from your latest status. If it asks nothing new, report your current status again and stop."
}

do_revive() {  # <id>
  local id=$1 meta="$STATE/$1.meta" lock out rc=0 note_file reason
  [ -f "$meta" ] || { echo "error: no task '$id' in $STATE" >&2; return 1; }
  lock="$STATE/.idle-revive-$id.lock"
  fm_lock_try_acquire "$lock" || { echo "revive of $id already running" >&2; return 0; }
  # shellcheck disable=SC2064
  trap "fm_lock_release '$lock' >/dev/null 2>&1 || true; rm -f '$STATE/.idle-revive-$id.note'" EXIT
  if ! fm_idle_stop_record_valid "$STATE" "$id" "$meta"; then
    echo "error: task $id has no valid stopped-session record (endpoint reads '${FM_IDLE_STOP_RECORD_AGENT_STATE:-not checked}'); relaunch it with fm-control.sh $id relaunch if it needs one" >&2
    return 1
  fi
  note_file="$STATE/.idle-revive-$id.note"
  note_for "$id" > "$note_file"
  out=$(FM_HOME=$FM_HOME "$CONTROL" "$id" relaunch --note-file "$note_file" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    fm_idle_stop_record_clear "$STATE" "$id"
    log "$id relaunched on demand"
    printf 'revived %s\n' "$id"
    return 0
  fi
  reason=$(printf '%s\n' "$out" | grep -E '^(deferred|error):' | tail -n 1)
  [ -n "$reason" ] || reason=$(printf '%s\n' "$out" | tail -n 1)
  [ -n "$reason" ] || reason="relaunch exited $rc"
  fm_idle_stop_notice_write "$STATE" "$id" "$reason" "$REVIVE_RETRY"
  log "$id relaunch refused (exit $rc): $reason"
  printf 'waiting %s: %s\n' "$id" "$reason"
  return 75
}

case "$VERB" in
  sweep)
    do_sweep
    ;;
  check)
    [ -n "${1:-}" ] || { usage >&2; exit 2; }
    fm_task_id_creation_valid "$1" || { echo "error: '$1' is not a valid task id" >&2; exit 2; }
    printf '%s\n' "$(verdict "$1")"
    ;;
  revive)
    [ -n "${1:-}" ] || { usage >&2; exit 2; }
    fm_task_id_creation_valid "$1" || { echo "error: '$1' is not a valid task id" >&2; exit 2; }
    do_revive "$1"
    exit $?
    ;;
esac
