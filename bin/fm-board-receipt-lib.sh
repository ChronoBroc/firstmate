# shellcheck shell=bash
# fm-board-receipt-lib.sh - the receipt for each review-board answer delivered
# to a worker, and the alarm when the worker does not take it.
#
# A worker-owned board's captured round is delivered straight to the owning
# task's steering inbox (bin/fm-procevent.sh publish_result). Nothing else
# records that delivery, so a worker that took the answer and one that never
# did look identical until the worker posts its next round. This library keeps
# one receipt per delivered round and judges it on every reconcile, which the
# watcher runs once per supervision cycle, so neither the receipt nor its
# acknowledgement costs a firstmate turn.
#
# The acknowledgement is the owning worker reading the round with
# `bin/fm-procevent-lavish.sh read <result>`, the first step the delivered
# instruction gives it, before it works the round: fm_board_receipt_read, run
# from that command in a process whose FM_TASK_INBOX (bin/fm-spawn.sh exports it
# into every worker launch) is the receipt's task's inbox, dates the pickup.
# Anyone else reading the result, firstmate included, records nothing. The
# worker's later filing of the round's steering-inbox record into handled/, or
# the round's handled marker (re-arm, or the conclude of a terminal round), also
# counts, for a worker that took the round without that read.
# A worker's resolved status line is not used: it is free text the worker may
# not write, under a key it chooses, naming no source or round.
#
# docs/configuration.md "Board answer receipts" owns the record's location,
# fields, and states for readers such as the crew dashboard. This header owns
# the mechanics:
#   - Write: fm_board_receipt_delivered, once per source and round, called
#     under that source's lock when the delivery's inbox record exists. A
#     receipt already present is left alone, so the runner's republication on
#     every reconcile never moves its delivery time. A new round's receipt
#     removes the same board's acknowledged receipts for earlier rounds.
#   - Pickup: fm_board_receipt_read writes <source>.<seq>.read beside a
#     delivered receipt, under the source lock, holding read_at, the epoch of
#     the worker's read.
#   - Judge: fm_board_receipt_tick, from reconcile, under each source's lock. A
#     delivered receipt with a pickup, an inbox record in handled/, or a round
#     handled marker becomes acknowledged, dated at the pickup when there is one. One still delivered after its
#     alarm_after (FM_PROCEVENT_RECEIPT_ALARM_SECONDS, default 300, 1..86400,
#     as it was when the receipt was written) queues one `check` wake keyed
#     procevent:<source>:unacknowledged:<seq> and records alarmed_at; the wake
#     is queued before the record, so a failed record write can repeat the
#     wake rather than lose it. A receipt acknowledged after its alarm queues
#     one procevent:<source>:acknowledged:<seq> wake, so the alarm is visibly
#     cleared. The watcher headlines both (bin/fm-watch.sh
#     procevent_surface_queued).
#   - Prune: a receipt whose task has no metadata (retired), and an
#     acknowledged receipt whose board registration is gone (concluded or
#     retired), are removed with their pickup.
# A receipt is a cache of facts the inbox and the procevent inbox already hold;
# losing one loses only this presentation and its alarm.

FM_BOARD_RECEIPT_VERSION=fm-board-receipt-v1
FM_BOARD_RECEIPT_ALARM_DEFAULT_SECONDS=300

fm_board_receipt_dir() { printf '%s\n' "$1/board-receipts"; }

fm_board_receipt_path() {  # <state> <source-id> <seq>
  printf '%s/%s.%s.receipt\n' "$(fm_board_receipt_dir "$1")" "$2" "$3"
}

# The alarm delay in whole seconds, 1..86400; anything else is the default.
fm_board_receipt_alarm_seconds() {
  local value=${FM_PROCEVENT_RECEIPT_ALARM_SECONDS:-}
  case "$value" in ''|*[!0-9]*) value=$FM_BOARD_RECEIPT_ALARM_DEFAULT_SECONDS ;; esac
  if [ "${#value}" -gt 5 ] || [ "$value" -lt 1 ] || [ "$value" -gt 86400 ]; then
    value=$FM_BOARD_RECEIPT_ALARM_DEFAULT_SECONDS
  fi
  printf '%s\n' "$value"
}

# Remove a receipt and its pickup.
_fm_board_receipt_remove() {  # <receipt-path>
  rm -f -- "$1" "${1%.receipt}.read"
}

_fm_board_receipt_get() {  # <receipt-text> <field>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

_fm_board_receipt_one_line() {  # <text>
  local text=$1
  text=${text//$'\n'/ }
  text=${text//$'\r'/ }
  printf '%s' "$text"
}

# Atomically replace <path> with <text>, private.
_fm_board_receipt_store() {  # <path> <text>
  local path=$1 dir tmp
  dir=${path%/*}
  (umask 077; mkdir -p "$dir") || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.receipt.XXXXXX") || return 1
  if printf '%s' "$2" > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$path"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Where the delivery's inbox record is now: "inbox", "handled", or "gone".
_fm_board_receipt_record_place() {  # <state> <task> <record-name>
  local name=$3
  if [ -f "$(fm_task_inbox_dir "$1" "$2")/$name" ]; then
    printf 'inbox\n'
  elif [ -f "$(fm_task_inbox_handled_dir "$1" "$2")/$name" ]; then
    printf 'handled\n'
  else
    printf 'gone\n'
  fi
}

# Record that round <seq> of board <source-id> was delivered to <task> as
# steering-inbox record <record>. The caller holds the source lock. Returns 1
# only when a new receipt could not be written.
fm_board_receipt_delivered() {  # <state> <source-id> <seq> <task> <round> <record> [board]
  local state=$1 id=$2 seq=$3 task=$4 round=$5 record=$6 board=${7:-} path name age now delivered old old_seq
  fm_procevent_source_id_valid "$id" || return 1
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  fm_pr_task_id_valid "$task" || return 1
  case "$round" in feedback|terminal) ;; *) return 1 ;; esac
  name=${record##*/}
  fm_task_inbox_seq_of "$name" >/dev/null || return 1
  path=$(fm_board_receipt_path "$state" "$id" "$seq")
  [ -e "$path" ] || [ -L "$path" ] && return 0
  now=$(date +%s)
  # The record's own age dates the delivery, so a receipt written late (an
  # earlier write failed) still dates it from when the answer reached the inbox.
  if [ -f "$record" ]; then
    age=$(fm_path_age "$record")
  else
    age=$(fm_path_age "$(fm_task_inbox_handled_dir "$state" "$task")/$name")
  fi
  case "$age" in ''|*[!0-9]*) age=0 ;; esac
  [ "$age" -le "$now" ] || age=0
  delivered=$((now - age))
  _fm_board_receipt_store "$path" "$(printf 'v=%s\nsource=%s\nseq=%s\ntask=%s\nround=%s\nboard=%s\ninbox_record=%s\ndelivered_at=%s\nalarm_after=%s\nstate=delivered\n' \
    "$FM_BOARD_RECEIPT_VERSION" "$id" "$seq" "$task" "$round" \
    "$(_fm_board_receipt_one_line "$board")" "$name" "$delivered" "$(fm_board_receipt_alarm_seconds)")
" || return 1
  for old in "$(fm_board_receipt_dir "$state")/$id".*.receipt; do
    [ -f "$old" ] || continue
    old_seq=${old%.receipt}
    old_seq=${old_seq##*.}
    case "$old_seq" in ''|*[!0-9]*) continue ;; esac
    [ "$old_seq" -lt "$seq" ] || continue
    [ "$(_fm_board_receipt_get "$(cat -- "$old" 2>/dev/null)" state)" = acknowledged ] || continue
    _fm_board_receipt_remove "$old"
  done
  return 0
}

_fm_board_receipt_waited() {  # <seconds>
  local s=$1
  if [ "$s" -lt 60 ]; then
    printf '%ss' "$s"
  else
    printf '%sm%02ds' "$((s / 60))" "$((s % 60))"
  fi
}

# Judge one receipt. The caller holds its source lock.
_fm_board_receipt_judge_locked() {  # <state> <path> <source-id> <seq> <registry-dir>
  local state=$1 path=$2 id=$3 seq=$4 reg=$5 text task name round board delivered alarmed now by='' at waited where after
  text=$(cat -- "$path" 2>/dev/null) || return 0
  [ "$(_fm_board_receipt_get "$text" v)" = "$FM_BOARD_RECEIPT_VERSION" ] || return 0
  task=$(_fm_board_receipt_get "$text" task)
  if ! fm_pr_task_id_valid "$task" || [ ! -f "$state/$task.meta" ]; then
    _fm_board_receipt_remove "$path"
    return 0
  fi
  if [ "$(_fm_board_receipt_get "$text" state)" = acknowledged ]; then
    [ -f "$reg/$id.source" ] || _fm_board_receipt_remove "$path"
    return 0
  fi
  name=$(_fm_board_receipt_get "$text" inbox_record)
  round=$(_fm_board_receipt_get "$text" round)
  board=$(_fm_board_receipt_get "$text" board)
  delivered=$(_fm_board_receipt_get "$text" delivered_at)
  alarmed=$(_fm_board_receipt_get "$text" alarmed_at)
  case "$delivered" in ''|*[!0-9]*) return 0 ;; esac
  text=$(printf '%s\n' "$text" | grep -v '^state=')
  now=$(date +%s)
  where=$(_fm_board_receipt_record_place "$state" "$task" "$name")
  at=$(_fm_board_receipt_get "$(cat -- "${path%.receipt}.read" 2>/dev/null)" read_at)
  case "$at" in ''|*[!0-9]*) at=$now ;; *) by="read" ;; esac
  if [ -z "$by" ] && [ "$where" = handled ]; then
    by=inbox
  elif [ -z "$by" ] && fm_procevent_is_handled "$state" "$id" "$seq"; then
    by="round-handled"
  fi
  [ -n "$board" ] || board="no artifact path recorded"
  if [ -n "$by" ]; then
    if [ -n "$alarmed" ]; then
      fm_wake_append check "procevent:$id:acknowledged:$seq" \
        "check: board answer picked up after its alarm: task $task has now taken Lavish board $id round $seq ($board), $(_fm_board_receipt_waited "$((now - delivered))") after delivery; the worker has the answer, so stop any recovery started for that alarm and tell the captain only if they were told it was missed." \
        || return 0
    fi
    _fm_board_receipt_store "$path" "$text
acknowledged_at=$at
acknowledged_by=$by
state=acknowledged
" || return 0
    return 0
  fi
  [ -z "$alarmed" ] || return 0
  waited=$((now - delivered))
  after=$(_fm_board_receipt_get "$text" alarm_after)
  case "$after" in ''|*[!0-9]*) after=$(fm_board_receipt_alarm_seconds) ;; esac
  [ "${#after}" -le 5 ] || after=$(fm_board_receipt_alarm_seconds)
  [ "$waited" -ge "$after" ] || return 0
  fm_wake_append check "procevent:$id:unacknowledged:$seq" \
    "check: board answer not picked up: task $task has not taken Lavish board $id round $seq ($board, a $round round) $(_fm_board_receipt_waited "$waited") after it reached its steering inbox as $name (that record is now: $where); whoever answered the board sees nothing until the worker takes it. Inspect the worker and recover it if it is stuck (stuck-crewmate-recovery); this alarm clears itself once the worker reads the round, files that record, or acknowledges the round." \
    || return 0
  _fm_board_receipt_store "$path" "$text
alarmed_at=$now
state=delivered
" || return 0
}

# Record that the owning worker read captured round <result-file>: only in a
# worker process whose FM_TASK_INBOX is the inbox of the task a still-delivered
# receipt for that round names. It takes the source lock, which publication
# holds from the inbox write through the receipt write, so a read that races a
# delivery waits for its receipt; read_at is the moment of the read.
# Best-effort; always returns 0.
fm_board_receipt_read() {  # <result-file>
  local inbox=${FM_TASK_INBOX:-} state task id seq path marker text now
  now=$(date +%s)
  case "$inbox" in */*.inbox) ;; *) return 0 ;; esac
  state=${inbox%/*}
  task=${inbox##*/}
  task=${task%.inbox}
  id=$(fm_procevent_result_source_id "$1")
  seq=$(fm_procevent_result_sequence "$1")
  fm_procevent_source_id_valid "$id" || return 0
  case "$seq" in ''|*[!0-9]*) return 0 ;; esac
  path=$(fm_board_receipt_path "$state" "$id" "$seq")
  marker=${path%.receipt}.read
  fm_procevent_source_lock_acquire "$id" || return 0
  if [ -f "$path" ] && [ ! -L "$path" ] && [ ! -e "$marker" ] \
    && text=$(cat -- "$path" 2>/dev/null) \
    && [ "$(_fm_board_receipt_get "$text" task)" = "$task" ] \
    && [ "$(_fm_board_receipt_get "$text" state)" = delivered ]; then
    _fm_board_receipt_store "$marker" "read_at=$now
" || true
  fi
  fm_procevent_source_lock_release "$id"
  return 0
}

# Judge every receipt in <state> (see the header).
fm_board_receipt_tick() {  # <state> <registry-dir>
  local state=$1 reg=$2 path base id seq
  for path in "$(fm_board_receipt_dir "$state")"/*.receipt; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    base=${path##*/}
    base=${base%.receipt}
    seq=${base##*.}
    id=${base%.*}
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    fm_procevent_source_id_valid "$id" || continue
    fm_procevent_source_lock_acquire "$id" || continue
    _fm_board_receipt_judge_locked "$state" "$path" "$id" "$seq" "$reg"
    fm_procevent_source_lock_release "$id"
  done
  return 0
}
