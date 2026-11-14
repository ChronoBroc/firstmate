#!/usr/bin/env bash
# fm-captain-wait-lib.sh - ties a captain outcome to the wait it reported, so
# the line that later ends that wait reaches main as settled.
#
# CONTRACT (this header is the one owner of the record and its settle rule).
#   - Record: $STATE/.<task>.captain-wait, at most one per task, written by
#     bin/fm-branch-outcome.sh append for every captain-verdict row. When the
#     task's status log, at the row's captured status provenance
#     (statusEndpoint and statusIdent), holds a declared wait
#     (status_declared_wait_line, bin/fm-classify-lib.sh), the record names
#     that row and that wait; otherwise the row removes any record, because the
#     newer captain outcome supersedes what main was last told. Routine rows
#     never touch it. Format, one key=value line each, values on one line:
#       v=fm-captain-wait-v1
#       seq=<outcome seq>
#       endpoint=<status log size at that row>
#       ident=<status log identity at that row>
#       wait=<the declared wait line>
#       summary=<the row's summary, capped>
#   - Settled: the bytes the status log gained after <endpoint>, under the same
#     identity, hold the line that ends <wait> (status_wait_ending_line). A
#     record whose status log is gone or was replaced is stale: it can never
#     settle, and the drain removes it.
#   - Consumers: bin/fm-watch.sh treats a signaled status log whose task has a
#     settled record as actionable and decision-owned, so the signal is never
#     absorbed as routine progress and an attended supervision session cannot
#     keep it from main; bin/fm-wake-drain.sh presents every settled record to
#     main in its SETTLED WAITS section once, outside an away record, then
#     removes it; bin/fm-teardown.sh removes a retired task's record.
#   - A record is a cache of facts the append-only outcome store and status log
#     already hold; losing one loses only this presentation.
set -u

FM_CAPTAIN_WAIT_VERSION=fm-captain-wait-v1
FM_CAPTAIN_WAIT_TEXT_MAX=400

fm_captain_wait_path() {  # <state> <task>
  case "$2" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/.%s.captain-wait' "$1" "$2"
}

# Print every task id that has a record, one per line.
fm_captain_wait_tasks() {  # <state>
  local p base
  for p in "$1"/.*.captain-wait; do
    [ -f "$p" ] && [ ! -L "$p" ] || continue
    base=${p##*/}
    base=${base#.}
    printf '%s\n' "${base%.captain-wait}"
  done
}

_fm_captain_wait_one_line() {  # <text>
  local text=$1
  text=${text//$'\n'/ }
  text=${text//$'\r'/ }
  text=${text//$'\t'/ }
  printf '%s' "${text:0:$FM_CAPTAIN_WAIT_TEXT_MAX}"
}

# Record or remove <task>'s wait for captain outcome <seq>, per the contract.
# Returns 1 only when a record could not be written or removed.
fm_captain_wait_note() {  # <state> <task> <seq> <endpoint> <ident> <summary>
  local state=$1 task=$2 seq=$3 endpoint=$4 ident=$5 summary=$6 path f prefix wait='' tmp
  path=$(fm_captain_wait_path "$state" "$task") || return 1
  f="$state/$task.status"
  case "$endpoint" in ''|0|*[!0-9]*) rm -f -- "$path"; return ;; esac
  case "$ident" in ''|-|*$'\t'*|*$'\n'*) rm -f -- "$path"; return ;; esac
  if [ -f "$f" ] && [ ! -L "$f" ] && [ "$(_fm_open_decisions_file_ident "$f" 2>/dev/null)" = "$ident" ]; then
    prefix=$(mktemp "$state/.captain-wait-prefix.XXXXXX") || return 1
    if _fm_status_read_span "$f" 0 "$endpoint" > "$prefix" 2>/dev/null; then
      wait=$(status_declared_wait_line "$prefix")
    fi
    rm -f -- "$prefix"
  fi
  if [ -z "$wait" ]; then
    rm -f -- "$path"
    return
  fi
  tmp=$(mktemp "$state/.captain-wait.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! printf 'v=%s\nseq=%s\nendpoint=%s\nident=%s\nwait=%s\nsummary=%s\n' \
      "$FM_CAPTAIN_WAIT_VERSION" "$seq" "$endpoint" "$ident" \
      "$(_fm_captain_wait_one_line "$wait")" "$(_fm_captain_wait_one_line "$summary")" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$path"
}

# Load <task>'s record and judge it. Sets FM_CAPTAIN_WAIT_SEQ, _WAIT, _SUMMARY,
# and, when settled, _ENDING (the line that ended the wait). Returns 0 settled,
# 1 still open or no record, 2 the status log could not be read, 3 the record
# is stale or malformed.
fm_captain_wait_settled() {  # <state> <task>
  local state=$1 task=$2 path f data endpoint ident ending rc
  FM_CAPTAIN_WAIT_SEQ='' FM_CAPTAIN_WAIT_WAIT='' FM_CAPTAIN_WAIT_SUMMARY='' FM_CAPTAIN_WAIT_ENDING=''
  path=$(fm_captain_wait_path "$state" "$task") || return 1
  [ -e "$path" ] || [ -L "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 3
  data=$(LC_ALL=C command cat "$path" 2>/dev/null) || return 3
  [ "$(printf '%s\n' "$data" | sed -n 's/^v=//p')" = "$FM_CAPTAIN_WAIT_VERSION" ] || return 3
  FM_CAPTAIN_WAIT_SEQ=$(printf '%s\n' "$data" | sed -n 's/^seq=//p')
  endpoint=$(printf '%s\n' "$data" | sed -n 's/^endpoint=//p')
  ident=$(printf '%s\n' "$data" | sed -n 's/^ident=//p')
  FM_CAPTAIN_WAIT_WAIT=$(printf '%s\n' "$data" | sed -n 's/^wait=//p')
  FM_CAPTAIN_WAIT_SUMMARY=$(printf '%s\n' "$data" | sed -n 's/^summary=//p')
  case "$FM_CAPTAIN_WAIT_SEQ:$endpoint" in *[!0-9:]*|:*|*:) return 3 ;; esac
  [ -n "$ident" ] && [ -n "$FM_CAPTAIN_WAIT_WAIT" ] || return 3
  f="$state/$task.status"
  [ -f "$f" ] && [ ! -L "$f" ] || return 3
  [ "$(_fm_open_decisions_file_ident "$f" 2>/dev/null)" = "$ident" ] || return 3
  ending=$(status_wait_ending_line "$f" "$endpoint" "$FM_CAPTAIN_WAIT_WAIT")
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  FM_CAPTAIN_WAIT_ENDING=$ending
  return 0
}

# Remove <task>'s record only while it still names outcome <seq>, so a newer
# captain outcome recorded meanwhile keeps its own record.
fm_captain_wait_clear() {  # <state> <task> <seq>
  local path
  path=$(fm_captain_wait_path "$1" "$2") || return 1
  [ -f "$path" ] || return 0
  [ "$(sed -n 's/^seq=//p' "$path" 2>/dev/null)" = "$3" ] || return 0
  rm -f -- "$path"
}
