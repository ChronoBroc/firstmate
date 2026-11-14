#!/usr/bin/env bash
# fm-captain-wait-lib.sh - ties a captain outcome to the wait it reported, so
# the line that later ends that wait reaches main as settled.
#
# CONTRACT (this header is the one owner of the record and its settle rule).
#   - Record: one file per recorded wait, $STATE/.<task>.captain-wait.<seq>.<key>,
#     where <seq> is the captain outcome's seq and <key> the wait's phase key
#     ("+keyless" for the keyless phase, a name no stated key can take, so a
#     keyless wait and a [key=default] wait stay distinct; which records are
#     the same wait is decided from the phase key of each record's wait line,
#     never from the file name). bin/fm-branch-outcome.sh append writes
#     them for every captain-verdict row: each wait in force in the task's
#     status log at the row's captured status provenance (statusEndpoint and
#     statusIdent) - the declared wait (status_declared_wait_line,
#     bin/fm-classify-lib.sh) and every open keyed needs-decision
#     (status_open_decisions; keyless and "default" decisions excluded) - gets
#     its own record. Waits are independent per key: a row never removes,
#     replaces or touches a record for another key, and records nothing when no
#     wait is in force. A same-key record still open is replaced by the newer
#     row's record (the same wait re-reported); a same-key record already
#     settled or unconfirmable is left for the drain, and the new wait gets its
#     own record. Routine rows never touch records. Format, one key=value line
#     each, values on one line:
#       v=fm-captain-wait-v1
#       seq=<outcome seq>
#       endpoint=<status log size at that row>
#       ident=<status log identity at that row>
#       wait=<the declared wait line, or needs-decision [key=<key>]: <note>>
#       summary=<the row's summary, capped>
#   - Settled: the bytes the status log gained after <endpoint>, under the same
#     identity, hold the line that ends <wait> (status_wait_ending_line): a
#     resolved line for the wait's own phase key, whatever the wait's verb (a
#     keyless wait: a keyless resolved line). A resolved line for another key,
#     routine progress, and every other event leave the record open.
#     Unconfirmable: the status log is gone or was replaced, or the record is
#     malformed, so it can never settle.
#   - Removal: only main's drain removes a record, and only after presenting
#     it as settled or unconfirmable; an open record is never removed. Every
#     write and removal runs under $STATE/.branch-outcomes.lock.
#     bin/fm-teardown.sh removes a retired task's records with its status log.
#   - Consumers: bin/fm-watch.sh treats a signaled status log whose task has
#     any settled record as actionable and decision-owned, so the signal is
#     never absorbed as routine progress and an attended supervision session
#     cannot keep it from main; bin/fm-wake-drain.sh presents every settled or
#     unconfirmable record to main in its SETTLED WAITS section once, outside
#     an away record, then removes it.
#   - A record is a cache of facts the append-only outcome store and status log
#     already hold; losing one loses only this presentation.
set -u

FM_CAPTAIN_WAIT_VERSION=fm-captain-wait-v1
FM_CAPTAIN_WAIT_TEXT_MAX=400

# Print the record paths for <task>, or for every task, one per line.
fm_captain_wait_records() {  # <state> [<task>]
  local p
  if [ "$#" -gt 1 ]; then
    case "$2" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
    set -- "$1/.$2.captain-wait."*
  else
    set -- "$1"/.*.captain-wait.*
  fi
  for p in "$@"; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    printf '%s\n' "$p"
  done
}

# The task id a record path names.
fm_captain_wait_task_of() {  # <path>
  local base=${1##*/}
  base=${base#.}
  printf '%s' "${base%%.captain-wait.*}"
}

_fm_captain_wait_one_line() {  # <text>
  local text=$1
  text=${text//$'\n'/ }
  text=${text//$'\r'/ }
  text=${text//$'\t'/ }
  printf '%s' "${text:0:$FM_CAPTAIN_WAIT_TEXT_MAX}"
}

_fm_captain_wait_key() {  # <wait-line>
  local key
  key=$(_fm_decision_key "$1" "$_FM_CLASSIFY_KEYLESS_PHASE") || return 1
  printf '%s' "$key"
}

# Every wait in force in <status-file>: the declared wait, then each open keyed
# needs-decision as a decision line.
_fm_captain_wait_in_force() {  # <status-file> <kind>
  local key verb note
  status_declared_wait_line "$1"
  while IFS=$'\t' read -r key verb note; do
    [ "$verb" = needs-decision ] && [ -n "$key" ] && [ "$key" != default ] || continue
    printf 'needs-decision [key=%s]: %s\n' "$key" "$note"
  done <<EOF
$(status_open_decisions "$1" "$2")
EOF
}

# Record each wait <task> has in force for captain outcome <seq>, per the
# contract. The caller holds $STATE/.branch-outcomes.lock. Returns 1 only when
# a record could not be written or replaced.
fm_captain_wait_note() {  # <state> <task> <seq> <endpoint> <ident> <summary>
  local state=$1 task=$2 seq=$3 endpoint=$4 ident=$5 summary=$6 f prefix waits='' wait key slug path old tmp
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  case "$endpoint" in ''|0|*[!0-9]*) return 0 ;; esac
  case "$ident" in ''|-|*$'\t'*|*$'\n'*) return 0 ;; esac
  f="$state/$task.status"
  [ -f "$f" ] && [ ! -L "$f" ] && [ "$(_fm_open_decisions_file_ident "$f" 2>/dev/null)" = "$ident" ] || return 0
  prefix=$(mktemp "$state/.captain-wait-prefix.XXXXXX") || return 1
  if _fm_status_read_span "$f" 0 "$endpoint" > "$prefix" 2>/dev/null; then
    waits=$(_fm_captain_wait_in_force "$prefix" "$(_fm_status_kind "$f")")
  fi
  rm -f -- "$prefix"
  while IFS= read -r wait; do
    [ -n "$wait" ] || continue
    key=$(_fm_captain_wait_key "$wait") || continue
    while IFS= read -r old; do
      [ -n "$old" ] || continue
      if fm_captain_wait_judge "$state" "$old"; then continue; elif [ "$?" -ne 1 ]; then continue; fi
      [ "$(_fm_captain_wait_key "$FM_CAPTAIN_WAIT_WAIT")" = "$key" ] || continue
      rm -f -- "$old" || return 1
    done <<EOF
$(fm_captain_wait_records "$state" "$task")
EOF
    slug=$key
    [ "$key" != "$_FM_CLASSIFY_KEYLESS_PHASE" ] || slug=+keyless
    path="$state/.$task.captain-wait.$seq.$slug"
    tmp=$(mktemp "$state/.captain-wait-tmp.XXXXXX") || return 1
    chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    if ! printf 'v=%s\nseq=%s\nendpoint=%s\nident=%s\nwait=%s\nsummary=%s\n' \
        "$FM_CAPTAIN_WAIT_VERSION" "$seq" "$endpoint" "$ident" \
        "$(_fm_captain_wait_one_line "$wait")" "$(_fm_captain_wait_one_line "$summary")" > "$tmp"; then
      rm -f -- "$tmp"
      return 1
    fi
    mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
  done <<EOF
$waits
EOF
  return 0
}

# Load the record at <path> and judge it. Sets FM_CAPTAIN_WAIT_SEQ, _WAIT,
# _SUMMARY, and, when settled, _ENDING (the line that ended the wait). Returns
# 0 settled, 1 still open, 2 the status log could not be read, 3 the record is
# unconfirmable.
fm_captain_wait_judge() {  # <state> <path>
  local state=$1 path=$2 task f data endpoint ident ending rc
  FM_CAPTAIN_WAIT_SEQ='' FM_CAPTAIN_WAIT_WAIT='' FM_CAPTAIN_WAIT_SUMMARY='' FM_CAPTAIN_WAIT_ENDING=''
  [ -f "$path" ] && [ ! -L "$path" ] || return 3
  data=$(LC_ALL=C command cat "$path" 2>/dev/null) || return 3
  FM_CAPTAIN_WAIT_SEQ=$(printf '%s\n' "$data" | sed -n 's/^seq=//p')
  FM_CAPTAIN_WAIT_WAIT=$(printf '%s\n' "$data" | sed -n 's/^wait=//p')
  FM_CAPTAIN_WAIT_SUMMARY=$(printf '%s\n' "$data" | sed -n 's/^summary=//p')
  endpoint=$(printf '%s\n' "$data" | sed -n 's/^endpoint=//p')
  ident=$(printf '%s\n' "$data" | sed -n 's/^ident=//p')
  [ "$(printf '%s\n' "$data" | sed -n 's/^v=//p')" = "$FM_CAPTAIN_WAIT_VERSION" ] || return 3
  case "$FM_CAPTAIN_WAIT_SEQ:$endpoint" in *[!0-9:]*|:*|*:) return 3 ;; esac
  [ -n "$ident" ] && [ -n "$FM_CAPTAIN_WAIT_WAIT" ] || return 3
  task=$(fm_captain_wait_task_of "$path")
  f="$state/$task.status"
  [ -f "$f" ] && [ ! -L "$f" ] || return 3
  [ "$(_fm_open_decisions_file_ident "$f" 2>/dev/null)" = "$ident" ] || return 3
  ending=$(status_wait_ending_line "$f" "$endpoint" "$FM_CAPTAIN_WAIT_WAIT")
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  FM_CAPTAIN_WAIT_ENDING=$ending
  return 0
}

# 0 when any of <task>'s records is settled.
fm_captain_wait_any_settled() {  # <state> <task>
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    fm_captain_wait_judge "$1" "$path" && return 0
  done <<EOF
$(fm_captain_wait_records "$1" "$2")
EOF
  return 1
}
