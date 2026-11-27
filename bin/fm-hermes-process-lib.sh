#!/usr/bin/env bash
# Hermes process identity, shared by detection, liveness and the tmux composer.
# Match only argv[0], a Node TUI script argument, or Python's exact -m module;
# never a later prompt argument or a working-directory path. Linux argv fields
# preserve spaces; the ps fallback conservatively rejects ambiguous paths. It
# also owns the checkout-boundary rule every harness matcher shares
# (fm_process_path_below_boundary, below).
fm_hermes_process_matches() {  # <args> [pid]
  local args=${1:-} pid=${2:-} word
  local words=()
  if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
    while IFS= read -r -d '' word; do words+=("$word"); done < "/proc/$pid/cmdline"
  else
    read -r -a words <<< "$args"
  fi
  fm_hermes_argv_matches ${words[@]+"${words[@]}"}
}

# fm_hermes_argv_matches <argv...>: the Hermes rule over an argument vector
# whose boundaries are intact. A script operand under a checkout boundary is
# judged by its path below it only (fm_process_path_below_boundary).
fm_hermes_argv_matches() {  # <argv...>
  local word first=1 interpreter='' module=0
  for word in "$@"; do
    if [ "$first" = 1 ]; then
      first=0
      case "${word##*/}" in
        hermes) return 0 ;;
        node|node-*|node[0-9]*|MainThread) interpreter=node ;;
        python|python[0-9]*) interpreter=python ;;
        *) return 1 ;;
      esac
      continue
    fi
    if [ "$module" = 1 ]; then
      [ "$word" = tui_gateway.entry ] && return 0
      return 1
    fi
    case "$word" in
      -m) [ "$interpreter" = python ] || return 1; module=1; continue ;;
      -c|-e|--eval|--print) return 1 ;;
      -*) continue ;;
    esac
    word=$(fm_process_path_below_boundary "$word")
    case "$interpreter:$word" in
      node:*/ui-tui/dist/entry.js|node:*/hermes_cli/tui_dist/entry.js) return 0 ;;
      python:*/hermes|python:*/hermes_cli/main.py) return 0 ;;
    esac
    return 1
  done
  return 1
}

# fm_process_path_below_boundary <path>: <path> with any leading checkout
# boundary in FM_PROCESS_PATH_BOUNDARIES (set while the worktree probe in
# bin/fm-agent-process-lib.sh classifies a process) cut down to the `/rest`
# below it, for the lexical installation-path checks of every harness matcher
# (this file, bin/fm-gemini-lib.sh, bin/fm-agent-process-lib.sh), so the
# worktree's own path is never taken for a harness installation; unchanged
# everywhere else.
fm_process_path_below_boundary() {  # <path>
  local path=${1:-} boundary
  for boundary in ${FM_PROCESS_PATH_BOUNDARIES[@]+"${FM_PROCESS_PATH_BOUNDARIES[@]}"}; do
    case "$path" in "$boundary"/*) path=${path#"$boundary"} ;; esac
  done
  printf '%s' "$path"
}
