#!/usr/bin/env bash
# bin/backends/tmux.sh - the tmux session-provider adapter.
#
# Reference backend (AGENTS.md section 8; data/fm-backend-design-d7). P1 moves
# the tmux command sequences that fm-send.sh, fm-peek.sh, fm-watch.sh,
# fm-spawn.sh, and fm-teardown.sh already ran inline into named functions
# here, running the EXACT same commands in the EXACT same order, so the
# default (tmux, `backend=` absent) path stays byte-identical. Sourced only
# through bin/fm-backend.sh's fm_backend_source, never directly.
#
# Worktree acquisition (running `treehouse get` inside the pane, and polling
# its cwd) is unchanged by this extraction: P1 scopes only the session
# provider, not the worktree provider, so fm-spawn.sh still drives that part
# inline with these same send/current-path primitives.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# already live in bin/fm-tmux-lib.sh, shared with the away-mode daemon
# (bin/fm-supervise-daemon.sh); this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than
# duplicating it, so the two consumers cannot drift apart.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-agent-process-lib.sh"

# fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# fm-send.sh's and fm-peek.sh's own (until now duplicated) resolve().
fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# fm_backend_tmux_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's and fm-watch.sh's `tmux capture-pane -p -t "$T" -S -"$N"`.
fm_backend_tmux_capture() {  # <target> <lines>
  tmux capture-pane -p -t "$1" -S -"$2"
}

# fm_backend_tmux_visible_capture: the visible viewport only. `-S -0` starts at
# the first line of the pane rather than in its history, so nothing scrolled out
# of view can appear in the result - the guarantee a trust-dialog predicate
# needs, which the scrollback-bounded capture above cannot give.
fm_backend_tmux_visible_capture() {  # <target>
  tmux capture-pane -p -t "$1" -S -0
}

# fm_backend_tmux_send_key: one named key. Tmux can prefix-match a gone target
# to a live neighbor, so require exact membership before sending the key.
fm_backend_tmux_send_key() {  # <target> <key>
  fm_backend_tmux_target_exists "$1" || return 1
  tmux send-keys -t "$1" "$2"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. Re-exports fm_tmux_submit_core (bin/fm-tmux-lib.sh) verbatim; see
# that file for the composer-verification contract and echoed verdicts.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

# fm_backend_tmux_own_session: print the name of the tmux session this process
# was started in. An untargeted display-message picks the most recently used
# member of a session group, and so does a pane target, so an external client
# attached through a grouped session (`new-session -t <session>`) would be
# named instead. The third field of $TMUX is the id of the session the pane was
# created in, which stays unambiguous across the group; fall back to the
# untargeted lookup when it is absent, malformed, or stale (tmux answers a
# killed session's id with empty output and exit 0).
#
# The name printed is the session a task window is recorded under, so it must
# outlive any viewer. A pane opened from a viewer carries the viewer's id, and a
# window recorded as <viewer>:fm-<id> reads as missing once that viewer closes
# although the window lives on in the rest of the group. So a grouped session
# resolves to the session the group is named after (tmux names a group after
# the session `new-session -t` first grouped), provided that session still
# exists in the same group; otherwise, and for an ungrouped session, the
# resolved session itself is printed unchanged.
fm_backend_tmux_own_session() {
  local sid=${TMUX##*,} name='' group
  case "$sid" in
  ''|*[!0-9]*) ;;
  *) name=$(tmux display-message -p -t "\$$sid" '#S' 2>/dev/null) ;;
  esac
  [ -n "$name" ] || name=$(tmux display-message -p '#S') || return 1
  group=$(tmux display-message -p -t "=$name:" '#{?session_grouped,#{session_group},}' 2>/dev/null) || group=
  if [ -n "$group" ] && [ "$group" != "$name" ] \
      && [ "$(tmux display-message -p -t "=$group:" '#{session_name}|#{session_group}' 2>/dev/null)" = "$group|$group" ]; then
    name=$group
  fi
  printf '%s\n' "$name"
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Mirrors fm-spawn.sh's container-ensure block;
# prints the resolved session name.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    fm_backend_tmux_own_session
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
    printf 'firstmate'
  fi
}

# fm_backend_tmux_create_task: create the task's window in <proj-abs>,
# refusing an existing <window-name> in <session>. Mirrors fm-spawn.sh's
# duplicate-check-then-new-window sequence, including the exact error text
# (session:window, matching how fm-spawn.sh composed its own $T). Prints the
# created window's stable window id on stdout for the caller to target.
#
# Robustness (fm-spawn tmux window handling under a non-default captain config):
#   - Capture a STABLE window id with -P -F '#{window_id}', and let tmux append
#     at the next free index by targeting the session with a trailing colon
#     ("$ses:"), so a non-default base-index (e.g. base-index 1) cannot collide.
#   - PIN the window name by disabling automatic-rename and allow-rename on the
#     new window: the captain's tmux may rename the window away from fm-<id> once
#     treehouse cd's into the worktree, which would break name-based targeting.
# The returned window id lets callers target the window even if its name is ever
# lost, so worktree discovery cannot fall back to the active client's window.
fm_backend_tmux_create_task() {  # <session> <window-name> <proj-abs> -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 wid
  if tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs") || return 1
  tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

# fm_backend_tmux_current_path: the live pane's current working directory, or
# empty on any tmux error. Mirrors fm-spawn.sh's worktree-discovery poll:
# `tmux display-message -p -t "$T" '#{pane_current_path}'`.
fm_backend_tmux_current_path() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

# fm_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for the fixed spawn-time commands
# (`treehouse get`, the GOTMPDIR export) that already ran this exact sequence
# inline in fm-spawn.sh. Mirrors `tmux send-keys -t "$T" "<text>" Enter`.
fm_backend_tmux_send_text_line() {  # <target> <text>
  tmux send-keys -t "$1" "$2" Enter
}

# fm_backend_tmux_send_literal: send TEXT as literal bytes with no
# submission - the caller sends Enter separately (fm-spawn.sh's launch-command
# send pauses between the literal send and Enter for the harness to settle).
# Mirrors `tmux send-keys -t "$T" -l "<text>"`.
fm_backend_tmux_send_literal() {  # <target> <text>
  tmux send-keys -t "$1" -l "$2"
}

# fm_backend_tmux_window_inventory: <session-target>'s window names, one per
# line on stdout, together with a verdict on the READ ITSELF, which is what
# every caller that must not guess depends on:
#   0 - the inventory was read; its lines are that session's windows.
#   2 - tmux answered definitively that the session, or its whole server, is
#       absent, so no window of that session exists.
#   1 - the read could not be made at all, and proves nothing either way. A
#       transient tmux problem, or a tmux that is not even on PATH, must never
#       be read as an absent endpoint: that mistake launches a duplicate agent
#       for fm_backend_tmux_agent_state and reports a live window as closed for
#       fm_backend_tmux_kill.
# The target is passed through exactly as the caller means it, so a caller that
# requires the exact recorded session asks for `=session` and still gets the
# same classification. An optional <socket> reads the server listening there
# instead of the one this process addresses.
fm_backend_tmux_window_inventory() {  # <session-target> [socket]
  local windows
  if windows=$(if [ -n "${2:-}" ]; then
      LC_ALL=C tmux -S "$2" list-windows -t "$1" -F '#{window_name}' 2>&1
    else
      LC_ALL=C tmux list-windows -t "$1" -F '#{window_name}' 2>&1
    fi); then
    printf '%s\n' "$windows"
    return 0
  fi
  case "$windows" in
    *"can't find session:"*|*"no server running on "*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
      return 2
      ;;
  esac
  return 1
}

# fm_backend_tmux_server_identity: the identity of the tmux server holding
# <target>, as "<socket-path>\t<server-pid>:<server-start-time>", both read
# from the server itself. fm-spawn records it with the task so a later absence
# proof can name the exact server the window lived on
# (fm_backend_tmux_endpoint_absence_recheck). Nonzero, printing nothing, when
# the server cannot be read or answers with something that is not an identity.
fm_backend_tmux_server_identity() {  # <target>
  local out socket server
  out=$(LC_ALL=C tmux display-message -p -t "$1" '#{socket_path}|#{pid}:#{start_time}' 2>/dev/null) || return 1
  socket=${out%|*}
  server=${out##*|}
  case "$socket" in /*) ;; *) return 1 ;; esac
  fm_backend_tmux_server_id_valid "$server" || return 1
  printf '%s\t%s\n' "$socket" "$server"
}

fm_backend_tmux_server_id_valid() {  # <pid:start-time>
  case "${1:-}" in
    *[!0-9:]*|:*|*:|*:*:*|'') return 1 ;;
    *:*) [ "${1%%:*}" != 0 ] ;;
    *) return 1 ;;
  esac
}

# fm_backend_tmux_server_process: what process <pid> is now, settled from the
# process table rather than from any tmux socket:
#   gone       - no process has that pid.
#   other      - the pid now belongs to a program that is not tmux, so the
#                tmux server that held it has exited.
#   tmux       - a tmux process holds the pid; whether it is the recorded
#                server is the socket read's question, not this one's.
#   unreadable - the process table could not be read.
# `ps -p` exits 1 with no output at all for an absent pid on both macOS and
# procps; any message alongside a failure (a malformed pid, a broken ps) is
# not that answer. The comm basename is matched by prefix because Linux tmux
# retitles its server "tmux: server".
fm_backend_tmux_server_process() {  # <pid>
  local out rc
  out=$(LC_ALL=C ps -p "$1" -o comm= 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ -z "$out" ]; then printf 'gone'; else printf 'unreadable'; fi
    return 0
  fi
  out=${out##*/}
  case "$out" in
    '') printf 'unreadable' ;;
    tmux*) printf 'tmux' ;;
    *) printf 'other' ;;
  esac
}

# fm_backend_tmux_endpoint_absence_recheck: whether a task window that reads
# `missing` is provably gone, judged against the server identity its record
# carries (tmux_socket, tmux_server), never against whichever server this
# process happens to address. Prints one word:
#   missing    - PROVEN gone: the recorded server process no longer exists
#                (its pid is free, now another program, or a later server).
#   dead/alive - the window is on the recorded server, which is also the one
#                this process addresses, and the ordinary classifier re-read it.
#   foreign    - the window is still on the recorded server, but this process
#                addresses a different one, so nothing here may act on it.
#   unrecorded - the record carries no usable server identity (a record written
#                before identities were recorded).
#   unreadable - anything else: a tmux process still holds the recorded pid but
#                cannot be confirmed or excluded as the recorded server, or a
#                read failed. Never evidence of absence.
# Reads only; it never starts a server or creates anything.
fm_backend_tmux_endpoint_absence_recheck() {  # <target> <socket> <server-id>
  local target=${1:-} socket=${2:-} server=${3:-} session window windows inventory_status current state
  case "$target" in
    *:*:*|'':*|*:'') printf 'unreadable'; return 0 ;;
    *:*) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  case "$socket" in /*) ;; *) printf 'unrecorded'; return 0 ;; esac
  fm_backend_tmux_server_id_valid "$server" || { printf 'unrecorded'; return 0; }
  case "$(fm_backend_tmux_server_process "${server%%:*}")" in
    gone|other) printf 'missing'; return 0 ;;
    tmux) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  # A tmux process holds the recorded pid. Only the server at the recorded
  # socket answering with the recorded pid AND start time is that server;
  # a different start time under the same pid is a later server that reused
  # it, which also proves the recorded one exited.
  current=$(LC_ALL=C tmux -S "$socket" display-message -p '#{pid}:#{start_time}' 2>/dev/null) || current=
  if [ "$current" != "$server" ]; then
    if [ "${current%%:*}" = "${server%%:*}" ] && fm_backend_tmux_server_id_valid "$current"; then
      printf 'missing'
    else
      printf 'unreadable'
    fi
    return 0
  fi
  session=${target%%:*}
  window=${target#*:}
  windows=$(fm_backend_tmux_window_inventory "=$session" "$socket")
  inventory_status=$?
  case "$inventory_status" in
    0) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  if ! printf '%s\n' "$windows" | grep -Fqx -- "$window"; then
    printf 'unreadable'
    return 0
  fi
  current=$(LC_ALL=C tmux display-message -p '#{pid}:#{start_time}' 2>/dev/null) || current=
  if [ "$current" != "$server" ]; then
    printf 'foreign'
    return 0
  fi
  state=$(fm_backend_tmux_agent_state "$target")
  case "$state" in
    dead|alive) printf '%s' "$state" ;;
    *) printf 'unreadable' ;;
  esac
}

# Resolve one exact window selector in one exact session to its stable id.
# The shared dispatcher header owns the accepted target grammar.
fm_backend_tmux_window_id() {  # <session-name> <window-name|index|@id>
  local session=$1 selector=$2 rows window_id window_index window_name
  rows=$(LC_ALL=C tmux list-windows -t "=$session" \
    -F '#{window_id}|#{window_index}|#{window_name}' 2>/dev/null) || return 1
  while IFS='|' read -r window_id window_index window_name; do
    case "$selector" in
      @*) [ "$window_id" = "$selector" ] || continue ;;
      *[!0-9]*) [ "$window_name" = "$selector" ] || continue ;;
      *) [ "$window_index" = "$selector" ] || continue ;;
    esac
    printf '%s\n' "$window_id"
    return 0
  done <<EOF
$rows
EOF
  return 1
}

# Adapter-owned tmux endpoint membership. Every comparison is literal and
# session-scoped where the target names a session, so tmux never gets a chance
# to satisfy the predicate through its prefix, pattern, or active-window
# fallbacks.
fm_backend_tmux_target_exists() {  # <target>
  local target=${1:-} session selector windows base pane_index window_id
  [ -n "$target" ] || return 1
  case "$target" in
    %*)
      tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -Fqx -- "$target"
      ;;
    @*)
      tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -Fqx -- "$target"
      ;;
    *:*:*)
      return 1
      ;;
    *:*)
      session=${target%%:*}
      selector=${target#*:}
      case "$session" in =*) session=${session#=} ;; esac
      case "$selector" in =*) selector=${selector#=} ;; esac
      [ -n "$session" ] && [ -n "$selector" ] || return 1

      case "$selector" in
        @*) fm_backend_tmux_window_id "$session" "$selector" >/dev/null ; return ;;
        *[!0-9]*) ;;
        *) fm_backend_tmux_window_id "$session" "$selector" >/dev/null ; return ;;
      esac

      windows=$(fm_backend_tmux_window_inventory "=$session") || return 1
      if printf '%s\n' "$windows" | grep -Fqx -- "$selector"; then
        return 0
      fi

      case "$selector" in
        *.*)
          base=${selector%.*}
          pane_index=${selector##*.}
          [ -n "$base" ] && [ -n "$pane_index" ] || return 1
          case "$base" in *[!0-9]*) return 1 ;; esac
          case "$pane_index" in *[!0-9]*) return 1 ;; esac
          window_id=$(fm_backend_tmux_window_id "$session" "$base") || return 1
          tmux list-panes -t "$window_id" -F '#{pane_index}' 2>/dev/null \
            | grep -Fqx -- "$pane_index"
          ;;
        *) return 1 ;;
      esac
      ;;
    *)
      session=$target
      case "$session" in =*) session=${session#=} ;; esac
      [ -n "$session" ] || return 1
      tmux has-session -t "=$session" 2>/dev/null
      ;;
  esac
}

# fm_backend_tmux_kill: remove one explicitly named task window.
# Empty, omitted, and malformed targets return nonzero before invoking tmux so
# tmux can never interpret an empty target as the caller's current window.
#
# A close that did not succeed is resolved, never assumed: `kill-window` fails
# for the ordinary already-exited window exactly as it does for a window that
# is still there, so its status alone cannot tell a benign cleanup from a
# stranded endpoint. The re-read below settles which one happened, under the
# window's EXACT recorded identity (`=session` plus a whole-line name match -
# never a prefix, which would read a neighbor as this window's survivor).
# Only a read that actually happened can settle it, so the same classification
# fm_backend_tmux_agent_state uses applies here: a window still present is the
# kill failing to do its job, a definitively absent session or server is the
# silent success, and an inventory that could not be read refuses rather than
# calling a window it never saw closed. An already-gone window, and a whole
# server that is already gone, stay silent successes. Verified against real
# tmux 3.7c: killing a live window, re-killing the same gone window, and
# killing into a dead session all return 0 here
# (docs/verification/runtime-backends.md "Endpoint close").
fm_backend_tmux_kill() {  # <target>
  local target=${1:-} session window windows inventory_status
  case "$target" in
    *:*)
      session=${target%%:*}
      window=${target#*:}
      ;;
    *) return 1 ;;
  esac
  case "$session:$window" in
    :*|*:|*:*:*) return 1 ;;
  esac
  tmux kill-window -t "=$session:=$window" 2>/dev/null && return 0
  windows=$(fm_backend_tmux_window_inventory "=$session")
  inventory_status=$?
  if [ "$inventory_status" -eq 2 ]; then
    return 0
  fi
  if [ "$inventory_status" -ne 0 ]; then
    echo "error: tmux window $session:$window could not be read after its close, so whether it survived is unknown" >&2
    return 1
  fi
  printf '%s\n' "$windows" | grep -qxF -- "$window" || return 0
  echo "error: tmux window $session:$window is still present after its close" >&2
  return 1
}

# fm_backend_tmux_current_command: <target>'s live foreground process name -
# tmux's own `#{pane_current_command}`, already resolved from the pty's
# foreground process group (verified empirically with real tmux 3.6a: a
# harness invoked interactively stays the reported command even while it
# shells out to subcommands that do not take over the pty - e.g. `bash -c
# "sleep 30"` alone reports "sleep" because bash execs directly into it, but
# a persisting parent script running `sleep` as a child reports the PARENT's
# own name throughout; the value reverts to the shell's own name only once
# the foreground command actually exits). Empty on any tmux error.
fm_backend_tmux_current_command() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# The process-name classifier every liveness signal below feeds
# (fm_agent_process_classify_name) is owned by bin/fm-agent-process-lib.sh,
# shared with the Herdr adapter so both backends mean the same thing by
# `agent`, `shell`, and `other`.

# fm_backend_tmux_foreground_comms: the kernel-side names of every process in
# <target>'s pane tty foreground process group, one full value per line.
# Empty on any failure.
#
# This is the foreground-process-group half of the liveness probe, and it exists
# because `#{pane_current_command}` and `ps -o comm=` expose different name
# fields whose roles vary by platform. On macOS the tmux field can carry a
# harness-rewritten title (Claude Code 2.1.220 reports `2.1.220`) while `comm`
# retains executable identity; the portable Linux regression observes the
# reverse for its version-named executable. Reading both `comm` and argv[0]
# preserves an identifying install path without making either platform's field
# assignment load-bearing.
#
# Scoping to the foreground process group rather than to the pane's descendants
# is what keeps the probe honest in the other direction: a harness-named process
# left running in the background of an otherwise idle pane is deliberately NOT
# reported, so a genuinely agent-free pane still classifies `dead`. It also
# reports every member of a multi-process launcher (the Pi Launcher path runs a
# `pi-signed` wrapper and a `pi` engine in one group), so no launcher needs its
# own special case here.
#
# Like fm_backend_tmux_current_command this is a RAW pane read: tmux answers an
# absent target from the client's active window rather than failing, so callers
# must confirm exact window membership first, exactly as the classifier below
# does, or they will describe some other pane entirely.
fm_backend_tmux_foreground_comms() {  # <target>
  local target=$1 tty pid pgid tpgid comm
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$comm"
      done
}

# The foreground group's full command lines. Needed because a node-bundle
# harness carries its identity in argv[1] rather than in its command name or
# argv[0]; bin/fm-gemini-lib.sh owns what counts as evidence inside one.
fm_backend_tmux_foreground_args() {  # <target>
  local target=$1 tty pid pgid tpgid comm args
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        [ -n "$args" ] && printf '%s\n' "$args"
      done
}

fm_backend_tmux_foreground_pids() {  # <target>
  local target=$1 tty pid pgid tpgid comm
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$pid"
      done
}

fm_backend_tmux_foreground_argv0s() {  # <target>
  local target=$1 tty pid pgid tpgid comm args argv0
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        args=${args#"${args%%[![:space:]]*}"}
        argv0=${args%%[[:space:]]*}
        [ -n "$argv0" ] && printf '%s\n' "$argv0"
      done
}

# fm_backend_tmux_agent_state: recovery-grade harness-agent state for one
# recorded target. See bin/fm-backend.sh's fm_backend_agent_state for the
# shared state vocabulary and docs/tmux-backend.md "Agent liveness probe" for
# the empirical basis. Tmux silently falls back to the active window when a
# named target is absent, so the exact recorded window must appear in a
# successful session inventory before its foreground command can be trusted.
# An omitted window or a definitive missing-session/server response is
# `missing`; any other inventory or pane read failure is `unreadable`, so a
# transient tmux problem never licenses a duplicate.
# fm_backend_tmux_window_inventory above owns that read classification, shared
# with fm_backend_tmux_kill so both mean the same thing by an absent session.
#
# The verdict combines two independent name sources rather than trusting either
# alone. Either source naming a verified harness is enough for `alive`, because
# a false `dead` is the one outcome that can launch a duplicate agent onto a
# live worktree, while the foreground process group - when it is readable - is
# authoritative for the negative verdicts, since it is the only source that can
# distinguish a truly idle pane from a rewritten process title.
fm_backend_tmux_agent_state() {  # <target>
  local target=$1 comm session window windows inventory_status
  local foreground argv0s name pid fg_seen=0 fg_shell=0 fg_other=0
  case "$target" in
    *:*:*|'':*|*:'') printf 'unreadable'; return 0 ;;
    *:*) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  session=${target%%:*}
  window=${target#*:}
  windows=$(fm_backend_tmux_window_inventory "$session")
  inventory_status=$?
  if [ "$inventory_status" -ne 0 ]; then
    if [ "$inventory_status" -eq 2 ]; then
      printf 'missing'
    else
      printf 'unreadable'
    fi
    return 0
  fi
  if ! printf '%s\n' "$windows" | grep -Fqx "$window"; then
    printf 'missing'
    return 0
  fi

  foreground=$(fm_backend_tmux_foreground_comms "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fg_seen=1
    case "$(fm_agent_process_classify_name "$name")" in
      agent) printf 'alive'; return 0 ;;
      shell) fg_shell=1 ;;
      *) fg_other=1 ;;
    esac
  done <<EOF
$foreground
EOF

  argv0s=$(fm_backend_tmux_foreground_argv0s "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$(fm_agent_process_classify_name '' "$name")" = agent ]; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$argv0s
EOF

  # Preserve argv boundaries where the platform exposes them. This is needed
  # when a Gemini or Hermes script path contains whitespace, which flattened
  # ps output cannot represent unambiguously.
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if fm_gemini_pid_is_gemini "$pid" || fm_hermes_process_matches '' "$pid"; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$(fm_backend_tmux_foreground_pids "$target")
EOF

  # Fall back to flattened arguments on platforms without /proc. Positive
  # evidence only - a bare interpreter still reaches the negative verdicts.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if fm_gemini_args_are_gemini "$name" || fm_hermes_process_matches "$name"; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$(fm_backend_tmux_foreground_args "$target")
EOF

  comm=$(fm_backend_tmux_current_command "$target") || {
    printf 'unreadable'
    return 0
  }
  if [ "$(fm_agent_process_classify_name "$comm")" = agent ]; then
    printf 'alive'
    return 0
  fi

  # A readable foreground process group settles the negative verdicts: only a
  # group that is nothing but shells is confidently agent-free.
  if [ "$fg_seen" -eq 1 ]; then
    if [ "$fg_other" -eq 0 ] && [ "$fg_shell" -eq 1 ]; then
      printf 'dead'
    else
      printf 'ambiguous'
    fi
    return 0
  fi

  case "$comm" in
    '') printf 'unreadable'; return 0 ;;
  esac
  case "$(fm_agent_process_classify_name "$comm")" in
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_tmux_agent_alive() {  # <target>
  case "$(fm_backend_tmux_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
