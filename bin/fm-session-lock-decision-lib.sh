#!/usr/bin/env bash
# Session-lock sidecar records, model-loop anchor classification, the one
# ownership decision, and the read-only lock inspection. Sourced only by
# bin/fm-session-lock-lib.sh, which owns the harness identity, ancestry walk,
# and trusted session id this file reads; callers source that library and never
# this file directly. No side effects on source.

# Print the session id recorded beside the lock in state dir $1, or return 1.
# bin/fm-lock.sh is the only writer of state/.lock-session; a missing,
# symlinked, unreadable, or empty sidecar, or one whose first line contains a
# newline or carriage return, is simply no recorded id.
fm_session_lock_recorded_session_id() {  # <state>
  local text
  text=$(_fm_session_lock_sidecar_text "$1") || return 1
  _fm_session_lock_session_id_in "$text"
}

# Print the session id on line 1 of sidecar text $1, or return 1.
_fm_session_lock_session_id_in() {  # <sidecar-text>
  local recorded
  recorded=$(printf '%s\n' "$1" | sed -n '1p')
  [ -n "$recorded" ] || return 1
  case "$recorded" in *$'\r'*) return 1 ;; esac
  printf '%s\n' "$recorded"
}

# Print the model-loop anchor recorded in state dir $1's sidecar, or return 1.
# bin/fm-lock.sh writes the second sidecar line `anchor=<pid>` beside every
# trusted id: the recording session's own anchor pid (its CLAUDE_PID, or that
# pid tagged on Windows).
fm_session_lock_recorded_anchor() {  # <state>
  local text
  text=$(_fm_session_lock_sidecar_text "$1") || return 1
  _fm_session_lock_anchor_in "$text"
}

# Print state dir $1's sidecar text, or return 1 when it is absent, a symlink,
# not a regular file, or cannot be read.
_fm_session_lock_sidecar_text() {  # <state>
  [ -f "$1/.lock-session" ] && [ ! -L "$1/.lock-session" ] || return 1
  cat "$1/.lock-session" 2>/dev/null
}

# Print the valid anchor pid on line 2 of sidecar text $1, or return 1.
_fm_session_lock_anchor_in() {  # <sidecar-text>
  local line
  line=$(printf '%s\n' "$1" | sed -n '2p')
  case "$line" in anchor=*) ;; *) return 1 ;; esac
  line=${line#anchor=}
  fm_session_pid_valid "$line" || return 1
  printf '%s\n' "$line"
}

# Print the anchor start time on line 3 of sidecar text $1, or return 1.
_fm_session_lock_anchor_start_in() {  # <sidecar-text>
  local line
  line=$(printf '%s\n' "$1" | sed -n '3p')
  case "$line" in anchor-start=?*) ;; *) return 1 ;; esac
  printf '%s\n' "${line#anchor-start=}"
}

# Print the anchor's process start time recorded in state dir $1's sidecar, or
# return 1. bin/fm-lock.sh writes it as the third line `anchor-start=<start>`
# (fm_pid_start_time of the anchor) whenever that start time is readable; a
# sidecar without it, as for a tagged Windows anchor, records none.
fm_session_lock_recorded_anchor_start() {  # <state>
  local text
  text=$(_fm_session_lock_sidecar_text "$1") || return 1
  _fm_session_lock_anchor_start_in "$text"
}

# Classify the model-loop anchor recorded in state dir $1's sidecar. Sets
# FM_SESSION_LOCK_ANCHOR_PID to the recorded pid and FM_SESSION_LOCK_ANCHOR_STATE
# to one of:
#   none        no sidecar exists, or it records no anchor.
#   unreadable  the sidecar exists but cannot be read, so whether it records an
#               anchor is not known.
#   gone        positive evidence the recorded process ended: no such pid, a
#               readable start time of the same kind that differs from the
#               recorded one, or a tagged Windows pid whose readable executable
#               is not a verified harness.
#   alive       the pid's readable start time equals the recorded one.
#   unknown     the pid still exists but its identity cannot be confirmed: no
#               start time is recorded, the current one cannot be read, or the
#               two come from different sources (fm_pid_start_time's
#               `proc-starttime=` form against its ps form) and cannot be
#               compared.
# shellcheck disable=SC2034 # Output globals, read by sourcing callers.
FM_SESSION_LOCK_ANCHOR_PID=
# shellcheck disable=SC2034 # Output globals, read by sourcing callers.
FM_SESSION_LOCK_ANCHOR_STATE=none
fm_session_lock_anchor_state() {  # <state>
  local text anchor recorded current
  FM_SESSION_LOCK_ANCHOR_PID=
  FM_SESSION_LOCK_ANCHOR_STATE=none
  [ -f "$1/.lock-session" ] && [ ! -L "$1/.lock-session" ] || return 0
  if ! text=$(_fm_session_lock_sidecar_text "$1"); then
    FM_SESSION_LOCK_ANCHOR_STATE=unreadable
    return 0
  fi
  anchor=$(_fm_session_lock_anchor_in "$text") || return 0
  FM_SESSION_LOCK_ANCHOR_PID=$anchor
  fm_session_lock_pid_verdict "$anchor"
  if [ "$FM_SESSION_LOCK_PID_VERDICT" = dead ]; then
    FM_SESSION_LOCK_ANCHOR_STATE=gone
    return 0
  fi
  case "$anchor" in
    "$FM_WIN_PID_PREFIX"*)
      if [ "$FM_SESSION_LOCK_PID_VERDICT" = readable ] \
        && ! fm_harness_process_matches "$FM_PROC_COMM" "$FM_PROC_ARGS"; then
        FM_SESSION_LOCK_ANCHOR_STATE=gone
        return 0
      fi
      ;;
  esac
  FM_SESSION_LOCK_ANCHOR_STATE=unknown
  recorded=$(_fm_session_lock_anchor_start_in "$text") || return 0
  if ! command -v fm_pid_start_time >/dev/null 2>&1; then
    # shellcheck disable=SC2034 # Read by the sourced fm-wake-lib.sh.
    local STATE=${FM_STATE_OVERRIDE:-$1}
    # shellcheck source=/dev/null
    . "$FM_SESSION_LOCK_LIB_DIR/fm-wake-lib.sh"
  fi
  current=$(fm_pid_start_time "$anchor" 2>/dev/null) && [ -n "$current" ] || return 0
  case "$current:$recorded" in
    proc-starttime=*:proc-starttime=*) ;;
    proc-starttime=*:*|*:proc-starttime=*) return 0 ;;
  esac
  if [ "$current" = "$recorded" ]; then
    FM_SESSION_LOCK_ANCHOR_STATE=alive
  else
    FM_SESSION_LOCK_ANCHOR_STATE=gone
  fi
  return 0
}

# True when the lock in state dir $1 was recorded by this same Claude session:
# the trusted id equals the id recorded beside the lock. No trusted id, no
# sidecar, or a different recorded id is false.
fm_session_lock_same_session() {  # <state> [<ancestry-pids>]
  local state=$1 trusted recorded
  trusted=$(fm_session_lock_trusted_session_id "${2:-}") || return 1
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  [ "$recorded" = "$trusted" ]
}

# Print the pid bin/fm-lock.sh records on lock line 1 for this session. For a
# Claude session with a trusted id that is CLAUDE_PID, the model-loop process:
# never the shared transient daemon and never a front-end that outlives the
# session, so "recorded pid dead" keeps meaning "session gone" instead of
# wedging a home behind a live daemon whose session died. A replaced background
# helper leaves a dead pid that its own session's next hook reclaims, because
# the sidecar still names that session. Every other session records the
# outermost pid of its contiguous run, exactly as before; a trusted Windows
# session's run is its tagged CLAUDE_PID alone, so it records that tagged pid.
fm_session_lock_anchor_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  if fm_session_lock_trusted_session_id "$pids" >/dev/null \
    && fm_harness_pid_listed "$CLAUDE_PID" "$pids"; then
    printf '%s\n' "$CLAUDE_PID"
    return 0
  fi
  _fm_harness_outermost_pid "$pids"
}

# The one ownership decision for state dir $1's lock, taken against this
# process's contiguous harness ancestry. The first matching row decides:
#
#   1. The sidecar's recorded model-loop anchor
#      (fm_session_lock_anchor_state) is outside this ancestry and alive, or
#      unknown because its pid still exists but its identity cannot be
#      confirmed: a holder may be live, so the verdict names that anchor, even
#      when line 1 is a shared front-end inside this ancestry. It is foreign
#      when the anchor is alive and this ancestry was read to its end
#      (fm_harness_ancestry_complete); otherwise unknown, with reason
#      ancestry-incomplete when the walk stopped on a failed read, else
#      anchor-unverified. Only gone - no such pid, a different readable start
#      time, or a tagged pid naming a non-harness - lets the decision continue
#      past an anchor outside this ancestry.
#   2. The sidecar records a session id but no anchor, as one written before
#      anchors existed does, this process proves a trusted Claude session whose
#      CLAUDE_PID is not line 1, and line 1 is a member of this ancestry: line
#      1 is a front-end shared by more than one model loop, and the original
#      cannot be told from a duplicate, so the verdict is unknown naming line
#      1, with FM_SESSION_LOCK_DECISION_REASON legacy-front. This arises once, for
#      a session started before anchors existed under a shared front-end, and
#      clears when that front-end process stops: line 1 is then dead and the
#      ordinary reclaim applies. A process whose CLAUDE_PID is line 1 is not
#      affected and owns through the next row.
#   3. Line 1 is a member of this ancestry: own. This covers a recorded anchor
#      that is this process or its ancestor, a recorded anchor that has exited
#      or whose pid was reused while line 1 is still this process's ancestor,
#      and a sidecar that is absent or records the id alone.
#   4. The trusted Claude session id equals the recorded one, the live
#      recorded anchor is in this ancestry, and line 1 is still a live harness:
#      own. This is a recycled helper chain whose surviving model loop is the
#      recorded anchor; an id alone, an exited or reused anchor, or no recorded
#      start time is no such proof.
#   5. Line 1 must not be reclaimed (fm_session_lock_pid_blocks_reclaim):
#      the verdict names line 1. It is foreign when line 1 is a readable live
#      harness and this ancestry was read to its end; otherwise unknown, with
#      reason holder-unverified when line 1's identity could not be read, else
#      ancestry-incomplete. Otherwise none, and bin/fm-lock.sh reclaims.
#
# A lock that is a symlink or not a regular file is unknown naming no pid
# (reason lock-nonregular), and one that exists but cannot be read likewise
# (reason lock-unreadable). A missing or malformed line 1 is none. A sidecar that exists but cannot be
# read is unknown naming line 1, before any other row (reason
# sidecar-unreadable). An ancestry that cannot be resolved is unknown, naming
# the holder that may be live - a recorded anchor that is not gone, else a line
# 1 that must not be reclaimed - and none when neither exists (reason
# ancestry-unresolved). Sets FM_SESSION_LOCK_DECISION
# (own|foreign|unknown|none), FM_SESSION_LOCK_DECISION_REASON for unknown, and,
# for foreign or unknown, FM_SESSION_LOCK_FOREIGN_OWNER_PID.
# shellcheck disable=SC2034 # Output globals, read by sourcing callers.
FM_SESSION_LOCK_DECISION=none
# shellcheck disable=SC2034 # Output globals, read by sourcing callers.
FM_SESSION_LOCK_DECISION_REASON=
# shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
FM_SESSION_LOCK_FOREIGN_OWNER_PID=
fm_session_lock_decide() {  # <state>
  local state=$1 lock_pid pids
  FM_SESSION_LOCK_DECISION=none
  FM_SESSION_LOCK_DECISION_REASON=
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=
  if [ -L "$state/.lock" ] || { [ -e "$state/.lock" ] && [ ! -f "$state/.lock" ]; }; then
    FM_SESSION_LOCK_DECISION=unknown
    FM_SESSION_LOCK_DECISION_REASON='lock-nonregular'
    return 0
  fi
  if ! lock_pid=$(cat "$state/.lock" 2>/dev/null); then
    if [ -e "$state/.lock" ]; then
      FM_SESSION_LOCK_DECISION=unknown
      FM_SESSION_LOCK_DECISION_REASON='lock-unreadable'
    fi
    return 0
  fi
  fm_session_pid_valid "$lock_pid" || return 0
  fm_session_lock_anchor_state "$state"
  if [ "$FM_SESSION_LOCK_ANCHOR_STATE" = unreadable ]; then
    FM_SESSION_LOCK_DECISION=unknown
    FM_SESSION_LOCK_DECISION_REASON=sidecar-unreadable
    FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
    return 0
  fi
  if ! pids=$(fm_harness_ancestry_pids); then
    case "$FM_SESSION_LOCK_ANCHOR_STATE" in
      alive|unknown)
        FM_SESSION_LOCK_DECISION=unknown
        FM_SESSION_LOCK_DECISION_REASON=ancestry-unresolved
        FM_SESSION_LOCK_FOREIGN_OWNER_PID=$FM_SESSION_LOCK_ANCHOR_PID
        ;;
      *)
        if fm_session_lock_pid_blocks_reclaim "$lock_pid"; then
          FM_SESSION_LOCK_DECISION=unknown
          FM_SESSION_LOCK_DECISION_REASON=ancestry-unresolved
          FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
        fi
        ;;
    esac
    return 0
  fi
  case "$FM_SESSION_LOCK_ANCHOR_STATE" in
    alive|unknown)
      if ! fm_harness_pid_listed "$FM_SESSION_LOCK_ANCHOR_PID" "$pids"; then
        FM_SESSION_LOCK_FOREIGN_OWNER_PID=$FM_SESSION_LOCK_ANCHOR_PID
        if ! fm_harness_ancestry_complete "$pids"; then
          FM_SESSION_LOCK_DECISION=unknown
          FM_SESSION_LOCK_DECISION_REASON='ancestry-incomplete'
        elif [ "$FM_SESSION_LOCK_ANCHOR_STATE" = unknown ]; then
          FM_SESSION_LOCK_DECISION=unknown
          FM_SESSION_LOCK_DECISION_REASON='anchor-unverified'
        else
          FM_SESSION_LOCK_DECISION=foreign
        fi
        return 0
      fi
      ;;
  esac
  if [ "$FM_SESSION_LOCK_ANCHOR_STATE" = none ] && fm_harness_pid_listed "$lock_pid" "$pids" \
    && [ "$lock_pid" != "${CLAUDE_PID:-}" ] && [ "$lock_pid" != "$FM_WIN_PID_PREFIX${CLAUDE_PID:-}" ] \
    && fm_session_lock_recorded_session_id "$state" >/dev/null \
    && fm_session_lock_trusted_session_id "$pids" >/dev/null; then
    FM_SESSION_LOCK_DECISION=unknown
    FM_SESSION_LOCK_DECISION_REASON=legacy-front
    FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
    return 0
  fi
  if fm_harness_pid_listed "$lock_pid" "$pids"; then
    FM_SESSION_LOCK_DECISION=own
    return 0
  fi
  if [ "$FM_SESSION_LOCK_ANCHOR_STATE" = alive ] && fm_session_lock_same_session "$state" "$pids" \
    && fm_harness_pid_alive "$lock_pid"; then
    FM_SESSION_LOCK_DECISION=own
    return 0
  fi
  if fm_session_lock_pid_blocks_reclaim "$lock_pid"; then
    # shellcheck disable=SC2034 # Output global, read by sourcing callers.
    FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
    if [ "$FM_SESSION_LOCK_PID_VERDICT" != readable ]; then
      FM_SESSION_LOCK_DECISION=unknown
      FM_SESSION_LOCK_DECISION_REASON='holder-unverified'
    elif ! fm_harness_ancestry_complete "$pids"; then
      FM_SESSION_LOCK_DECISION=unknown
      FM_SESSION_LOCK_DECISION_REASON='ancestry-incomplete'
    else
      FM_SESSION_LOCK_DECISION=foreign
    fi
  fi
  return 0
}

# True when fm_session_lock_decide finds this process's session owns state dir
# $1's lock.
fm_session_lock_owned_by_self() {  # <state>
  fm_session_lock_decide "$1"
  [ "$FM_SESSION_LOCK_DECISION" = own ]
}

# True when fm_session_lock_decide refuses this process the lock in state dir
# $1, as bin/fm-lock.sh does: a live holder that is not this process's session
# (foreign), or a holder that may be live but cannot be verified (unknown, with
# FM_SESSION_LOCK_DECISION_REASON). Names the holder in
# FM_SESSION_LOCK_FOREIGN_OWNER_PID for a diagnostic caller.
fm_session_lock_foreign_owner_live() {  # <state>
  fm_session_lock_decide "$1"
  case "$FM_SESSION_LOCK_DECISION" in
    foreign|unknown) return 0 ;;
  esac
  return 1
}

# Print why the last fm_session_lock_decide verdict of unknown could not verify
# the holder, from FM_SESSION_LOCK_DECISION_REASON.
fm_session_lock_decision_reason_text() {
  case "$FM_SESSION_LOCK_DECISION_REASON" in
    legacy-front) printf '%s\n' "the lock was recorded before model-loop anchors existed under a front-end this session shares, so the original model loop cannot be told from a duplicate" ;;
    sidecar-unreadable) printf '%s\n' "the session sidecar beside the lock cannot be read" ;;
    ancestry-unresolved) printf '%s\n' "this session's harness ancestry cannot be read" ;;
    lock-unreadable) printf '%s\n' "the session lock cannot be read" ;;
    lock-nonregular) printf '%s\n' "the session lock is not a regular file" ;;
    ancestry-incomplete) printf '%s\n' "this session's harness ancestry could not be read to its end, so the recorded holder may be this session's own" ;;
    anchor-unverified) printf '%s\n' "the recorded model-loop anchor has not been shown to have exited, but its identity cannot be confirmed by its recorded start time" ;;
    holder-unverified) printf '%s\n' "the lock holder has not been shown to have exited, but its identity cannot be read" ;;
    *) printf '%s\n' "whether the holder is still running cannot be verified" ;;
  esac
}

# Read-only classification of state/.lock for machine-readable callers.
# Never acquires the lock. A held lock is not proof the holder is consuming
# wakes; that question belongs to the inbox readiness projection.
#
# Sets:
#   FM_LOCK_INSPECT_STATE         free|held|stale|unreadable|unknown
#   FM_LOCK_INSPECT_PID           recorded pid, or empty
#   FM_LOCK_INSPECT_LIVE_HARNESS  true|false|unknown
#
# held: the recorded pid is a live verified harness, or, when it is not, the
# sidecar's recorded model-loop anchor is alive by its recorded start time
# (fm_session_lock_anchor_state) and is a live verified harness; the pid then
# names that anchor.
# stale: the recorded pid is gone.
# unknown: the file or pid cannot be classified without guessing, including a
# live process that is not a verified harness, and a line 1 that is not held
# while the sidecar's recorded model-loop anchor still exists but cannot be
# confirmed by its start time or whose harness identity cannot be read; the pid
# then names that anchor and FM_LOCK_INSPECT_DETAIL is anchor-unverified. A
# valid line 1 whose identity cannot be read and that is not otherwise
# classified is unknown with FM_LOCK_INSPECT_DETAIL holder-unverified. A
# line 1 that is not held beside a sidecar that exists but cannot be read is
# unknown too, with FM_LOCK_INSPECT_DETAIL sidecar-unreadable. Existence of a lock file, a session
# record, or a pane is never treated as liveness.
# shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
FM_LOCK_INSPECT_STATE=unknown
FM_LOCK_INSPECT_PID=
FM_LOCK_INSPECT_LIVE_HARNESS=unknown
FM_LOCK_INSPECT_DETAIL=
fm_session_lock_inspect() {  # <state>
  local state=$1 lock pid
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=unknown
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=unknown
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_DETAIL=
  lock="$state/.lock"
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    FM_LOCK_INSPECT_STATE=free
    FM_LOCK_INSPECT_LIVE_HARNESS=false
    return 0
  fi
  if [ ! -f "$lock" ] || [ -L "$lock" ]; then
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  fi
  pid=$(cat "$lock" 2>/dev/null) || {
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  }
  pid=${pid%%$'\n'*}
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=$pid
  fm_session_pid_valid "$pid" || return 0
  # One verdict for every identity form. A tagged Windows pid is resolved by
  # this same call through the Windows table, so the match below is the single
  # place "live verified harness" is decided; deciding it a second time ahead
  # of this one is what let a holder read as held there and unknown here.
  fm_session_lock_pid_verdict "$pid"
  case "$FM_SESSION_LOCK_PID_VERDICT" in
    dead)
      # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
      FM_LOCK_INSPECT_STATE=stale
      # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
      FM_LOCK_INSPECT_LIVE_HARNESS=false
      ;;
    readable)
      if fm_harness_process_matches "$FM_PROC_COMM" "$FM_PROC_ARGS"; then
        # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
        FM_LOCK_INSPECT_STATE=held
        # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
        FM_LOCK_INSPECT_LIVE_HARNESS=true
      else
        # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
        FM_LOCK_INSPECT_LIVE_HARNESS=false
      fi
      ;;
    unreadable)
      # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
      FM_LOCK_INSPECT_DETAIL='holder-unverified'
      ;;
  esac
  [ "$FM_LOCK_INSPECT_STATE" != held ] || return 0
  fm_session_lock_anchor_state "$state"
  if [ "$FM_SESSION_LOCK_ANCHOR_STATE" = unreadable ]; then
    # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
    FM_LOCK_INSPECT_STATE=unknown
    # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
    FM_LOCK_INSPECT_LIVE_HARNESS=unknown
    # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
    FM_LOCK_INSPECT_DETAIL='sidecar-unreadable'
    return 0
  fi
  if [ "$FM_SESSION_LOCK_ANCHOR_STATE" = alive ] && ! fm_harness_pid_alive "$FM_SESSION_LOCK_ANCHOR_PID"; then
    FM_SESSION_LOCK_ANCHOR_STATE=unknown
  fi
  if [ "$FM_SESSION_LOCK_ANCHOR_STATE" = unknown ]; then
    # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
    FM_LOCK_INSPECT_STATE=unknown
    # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
    FM_LOCK_INSPECT_PID=$FM_SESSION_LOCK_ANCHOR_PID
    # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
    FM_LOCK_INSPECT_LIVE_HARNESS=unknown
    # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
    FM_LOCK_INSPECT_DETAIL='anchor-unverified'
    return 0
  fi
  if [ "$FM_SESSION_LOCK_ANCHOR_STATE" = alive ]; then
    # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
    FM_LOCK_INSPECT_STATE=held
    # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
    FM_LOCK_INSPECT_PID=$FM_SESSION_LOCK_ANCHOR_PID
    # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
    FM_LOCK_INSPECT_LIVE_HARNESS=true
  fi
}
