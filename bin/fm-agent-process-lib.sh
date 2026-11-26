#!/usr/bin/env bash
# Backend-neutral harness-process identity.
# Sourced by bin/backends/tmux.sh and bin/backends/herdr.sh. This file is
# sourced by scripts and has no side effects on source.
#
# Why one owner: every runtime backend that proves an agent is alive does it by
# attributing operating-system processes - the pane's foreground process group
# on tmux, Herdr's `pane process-info` view plus the pane shell's descendants
# on Herdr - and the two must agree on what a given process name means, or a
# harness one backend recognizes silently reads as a dead pane on the other.
# The classifier moved here verbatim from the tmux adapter, where it was born;
# docs/tmux-backend.md "Agent liveness probe" owns the empirical basis for the
# names below, and tests/fm-tmux-agent-liveness.test.sh plus
# tests/fm-harness-liveness-drift-live-e2e.test.sh keep them honest.

_FM_AGENT_PROCESS_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_AGENT_PROCESS_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_AGENT_PROCESS_LIB_DIR=.
# shellcheck source=bin/fm-session-lock-lib.sh
. "${_FM_AGENT_PROCESS_LIB_DIR:-/}/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-gemini-lib.sh
. "${_FM_AGENT_PROCESS_LIB_DIR:-/}/fm-gemini-lib.sh"
# shellcheck source=bin/fm-hermes-process-lib.sh
. "${_FM_AGENT_PROCESS_LIB_DIR:-/}/fm-hermes-process-lib.sh"
# shellcheck source=bin/fm-omp-process-lib.sh
. "${_FM_AGENT_PROCESS_LIB_DIR:-/}/fm-omp-process-lib.sh"
unset _FM_AGENT_PROCESS_LIB_DIR

# fm_agent_process_classify_name: the single owner of the process-name
# vocabulary shared by every liveness signal - `agent` for a verified harness,
# `shell` for an idle login/interactive shell, `other` for anything else.
# Keeping one classifier means independent name sources (a kernel process
# name, an argv[0], a rendered pane title) can never drift into disagreeing
# about what a given name means.
fm_agent_process_classify_name() {  # <path> [argv0] -> agent|shell|other
  local path=$1 argv0=${2:-} base
  base=${path##*/}
  base=${base#-}
  case "$base" in
    # muse is anchored rather than globbed like its neighbours: its installed
    # binary is muse-bin-<version> (the launcher execs it, so the version is the
    # live process name and changes on every auto-update), and unlike `claude` or
    # `codex` the substring `muse` is a common English fragment - a *muse* glob
    # would classify musescore or amuse as a live agent pane. The install path
    # cannot carry it either: ~/.local/bin/muse-bin-<version> has no `muse` path
    # COMPONENT, so the fm_harness_path_name fallback below never fires for it.
    muse|muse-bin-*) printf 'agent' ;;
    # omp (Oh My Pi) is anchored for the same reason as muse: its live process
    # name is the bare word `omp` (verified, omp 18.1.11) and a glob would claim
    # unrelated commands such as ompd or comp.
    *claude*|*codex*|*opencode*|*grok*|*kimi*|*rovo*|pi|pi-signed|pi-launcher|Pi|omp) printf 'agent' ;;
    # agy (Antigravity CLI) is anchored for the same reason as muse and omp: its
    # live process name is the bare word `agy` (verified, agy 1.2.0: a Go-compiled
    # single binary, comm=agy with argv[0]=agy), and a glob would claim
    # unrelated commands containing that fragment. devin is anchored the same
    # way (verified, devin 3000.11.1: comm=devin), so a `*devin*` glob never
    # claims an unrelated command. Command Code is anchored on its own process
    # title (verified, Command Code 1.74.1: comm=command-code). polytoken is
    # anchored the same way (verified, polytoken 0.8.19: a TUI pane's foreground
    # process is comm `polytoken`, the same binary name as its per-session
    # daemon), so a `*polytoken*` glob never claims an unrelated command.
    # cortex (Cortex Code) is anchored too (verified, cortex 1.1.104: a
    # Bun-compiled single binary, comm=cortex).
    agy|devin|command-code|polytoken|cortex|hermes) printf 'agent' ;;
    # kiro (Kiro CLI) is anchored for the same reason as muse, omp, and agy: its
    # live foreground process name is the bare word `kiro-cli` (verified,
    # kiro-cli 2.21.4: a toolbox/aim-sandbox wrapper whose comm and tmux
    # #{pane_current_command} both read kiro-cli), and a glob would claim
    # unrelated commands containing that fragment.
    kiro-cli) printf 'agent' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'shell' ;;
    *)
      if fm_harness_path_name "$path" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
        printf 'agent'
      # cursor-agent runs as a bundled node script, so tmux reports the pane
      # command as a bare `node` that no name pattern above can own, and its
      # other installed name is the far-too-generic `agent` (verified live on
      # cursor-agent 2026.08.11-e8db854: #{pane_current_command} is `node` while
      # `ps -o comm=` carries the cursor-agent install path). Identity therefore
      # comes from the narrowed structural rule in bin/fm-cursor-lib.sh, which
      # demands Cursor's own name or install tree in the path or argv[0]. An
      # unrelated `node` or `agent` matches nothing here and stays `other`,
      # which the callers fold into `ambiguous` rather than `dead`, so a
      # stranger's node pane is never reported as an agent-free pane.
      elif fm_cursor_process_matches "${path:-$argv0}" '' "$argv0"; then
        printf 'agent'
      else
        printf 'other'
      fi
      ;;
  esac
}

# fm_agent_process_classify: one process, from every identity surface a
# backend can hand over, as agent|shell|other. Any single surface naming a
# verified harness carries `agent`, because a false negative is the one outcome
# that launches a duplicate agent onto a live worktree; `shell` needs every
# readable surface to agree the process is a shell; anything else is `other`.
#
#   <name>   the kernel process name (ps comm, or Herdr's process-info .name):
#            on Linux the exec name, on macOS argv[0] truncated to 16 bytes.
#   <argv0>  argv[0] as the process reports it - a bare name or an install
#            path, whichever the launcher used (empty when unknown).
#   <args>   the flattened command line, read only for the node-bundle
#            harnesses whose identity sits in argv[1] (bin/fm-gemini-lib.sh).
#   [pid]    when given, lets the Gemini rule read argv boundaries from the
#            live process instead of the flattened line.
fm_agent_process_classify() {  # <name> <argv0> <args> [pid] -> agent|shell|other
  local name=${1:-} argv0=${2:-} args=${3:-} pid=${4:-} by_name by_argv0
  by_name=$(fm_agent_process_classify_name "$name" "$argv0")
  [ "$by_name" != agent ] || { printf 'agent'; return 0; }
  if [ -n "$argv0" ]; then
    # argv[0] is classified as a path in its own right, so a bare `pi` or a
    # `-zsh` login name reads by basename and an install path by component.
    by_argv0=$(fm_agent_process_classify_name "$argv0" "$argv0")
    [ "$by_argv0" != agent ] || { printf 'agent'; return 0; }
  else
    by_argv0=$by_name
  fi
  if fm_hermes_process_matches "$args" "$pid"; then
    printf 'agent'
    return 0
  fi
  if fm_omp_process_matches "$name" "$args"; then
    printf 'agent'
    return 0
  fi
  if [ -n "$pid" ] && fm_gemini_pid_is_gemini "$pid"; then
    printf 'agent'
    return 0
  fi
  if [ -n "$args" ] && fm_gemini_args_are_gemini "$args"; then
    printf 'agent'
    return 0
  fi
  if [ "$by_name" = shell ] && [ "$by_argv0" = shell ]; then
    printf 'shell'
  else
    printf 'other'
  fi
}

# fm_agent_process_live_in_dir: the verified-harness agent processes owned by
# this user whose working directory is exactly <dir> (a subdirectory does not
# match), read from the kernel's per-process working directory rather than
# from any terminal endpoint. Each process is classified through
# fm_agent_process_classify, so only agents count; only the checking process
# itself (this shell and its subshells) is excluded, so an agent that is an
# ancestor of the caller still counts.
#
# Working directories come from /proc/<pid>/cwd where the kernel exposes it
# (Linux) and otherwise from lsof (macOS), matched by the directory's device
# and inode because lsof escapes bytes in the names it prints.
#
# Prints and returns:
#   0  one `<pid>\t<process name>` line per live agent process found.
#   1  nothing: no agent process of this user works in <dir>.
#   2  one line naming why the probe could not decide: <dir> does not
#      resolve, no working-directory source is usable or it failed, or a
#      running candidate's identity (name and command line) could not be read.
#      Callers that would start an agent in <dir> must treat this as a
#      refusal, never as 1.
fm_agent_process_live_in_dir() {  # <dir>
  local dir=${1:-} dir_real dir_id uid pid cwd self selves found='' lsof_out lsof_rc p candidates=''
  dir_real=$(cd "$dir" 2>/dev/null && pwd -P) || {
    printf 'the directory %s does not resolve\n' "${dir:-<empty>}"
    return 2
  }
  uid=$(id -u 2>/dev/null) || { printf 'the current user id could not be read\n'; return 2; }
  selves=" $$ "
  self=${BASHPID:-$$}
  while [ -n "$self" ] && [ "$self" -gt 1 ] 2>/dev/null && [ "${selves#* "$self" }" = "$selves" ]; do
    selves="$selves$self "
    self=$(LC_ALL=C ps -o ppid= -p "$self" 2>/dev/null) || self=
    self=${self//[[:space:]]/}
  done
  if [ -r /proc/self/cwd ] || [ -L /proc/self/cwd ]; then
    for p in /proc/[0-9]*; do
      [ -O "$p" ] || continue
      pid=${p#/proc/}
      if cwd=$(readlink "$p/cwd" 2>/dev/null); then
        [ "$cwd" = "$dir_real" ] && candidates="$candidates $pid"
        continue
      fi
      [ -d "$p" ] || continue
      case "$(awk '{ s = $0; sub(/^.*\) /, "", s); print substr(s, 1, 1) }' "$p/stat" 2>/dev/null)" in
        Z|X|'') continue ;;
      esac
      case "$selves" in *" $pid "*) continue ;; esac
      _fm_agent_process_identify "$pid" || {
        kill -0 "$pid" 2>/dev/null || continue
        printf 'the working directory and identity of running process %s could not be read\n' "$pid"
        return 2
      }
      [ "$FM_AGENT_PROCESS_KIND" = agent ] || continue
      printf 'the working directory of running agent process %s could not be read\n' "$pid"
      return 2
    done
  else
    command -v lsof >/dev/null 2>&1 || {
      printf 'neither /proc nor lsof is available to read process working directories\n'
      return 2
    }
    dir_id=$(stat -c '%d %i' "$dir_real" 2>/dev/null) || dir_id=$(stat -f '%d %i' "$dir_real" 2>/dev/null) || dir_id=
    case "$dir_id" in
      [0-9]*' '[0-9]*) ;;
      *) printf 'the identity of the directory %s could not be read\n' "$dir_real"; return 2 ;;
    esac
    lsof_rc=0
    lsof_out=$(LC_ALL=C lsof -w -a -u "$uid" -d cwd -FpDi 2>/dev/null) || lsof_rc=$?
    if [ "$lsof_rc" -ne 0 ] || [ -z "$lsof_out" ]; then
      printf 'lsof could not list the working directories of this user'"'"'s processes (exit %s)\n' "$lsof_rc"
      return 2
    fi
    candidates=$(printf '%s\n' "$lsof_out" | awk -v dev="$(printf '0x%x' "${dir_id%% *}")" -v ino="${dir_id##* }" '
      /^p/ { pid = substr($0, 2); d = ""; next }
      /^D/ { d = substr($0, 2); next }
      /^i/ { if (d == dev && substr($0, 2) == ino) printf " %s", pid }')
  fi
  for pid in $candidates; do
    case "$selves" in *" $pid "*) continue ;; esac
    _fm_agent_process_identify "$pid" || {
      kill -0 "$pid" 2>/dev/null || continue
      printf 'the identity of running process %s working in %s could not be read\n' "$pid" "$dir_real"
      return 2
    }
    [ "$FM_AGENT_PROCESS_KIND" = agent ] || continue
    found="$found$pid"$'\t'"${FM_AGENT_PROCESS_NAME##*/}"$'\n'
  done
  [ -n "$found" ] || return 1
  printf '%s' "$found"
  return 0
}

# _fm_agent_process_identify <pid>: classify a live process from its kernel
# name and command line into FM_AGENT_PROCESS_KIND (agent|shell|other) and
# FM_AGENT_PROCESS_NAME; returns 1 when either could not be read.
_fm_agent_process_identify() {  # <pid>
  local pid=$1 name args argv0
  FM_AGENT_PROCESS_KIND=
  FM_AGENT_PROCESS_NAME=
  name=$(LC_ALL=C ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(LC_ALL=C ps -o args= -p "$pid" 2>/dev/null) || return 1
  name=${name#"${name%%[![:space:]]*}"}
  args=${args#"${args%%[![:space:]]*}"}
  [ -n "$name" ] && [ -n "$args" ] || return 1
  argv0=${args%%[[:space:]]*}
  if [ -r "/proc/$pid/cmdline" ]; then
    argv0=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | head -n 1)
    [ -n "$argv0" ] || return 1
  fi
  FM_AGENT_PROCESS_NAME=$name
  FM_AGENT_PROCESS_KIND=$(fm_agent_process_classify "$name" "$argv0" "$args" "$pid")
}

# fm_agent_process_format_live <probe-output>: fm_agent_process_live_in_dir's
# `<pid>\t<name>` lines as `<pid> (<name>)[, ...]`.
fm_agent_process_format_live() {  # <probe-output>
  printf '%s\n' "$1" | awk -F'\t' 'NF { printf "%s%s (%s)", sep, $1, $2; sep = ", " }'
}

# fm_agent_process_live_note <dir>: a sentence naming the agent processes
# still working in <dir>, for appending to a refusal; prints nothing when none
# was found or the probe could not decide, and always succeeds.
fm_agent_process_live_note() {  # <dir>
  local out
  [ -n "${1:-}" ] || return 0
  out=$(fm_agent_process_live_in_dir "$1") || return 0
  printf ' An agent process is still working in its worktree %s: pid %s.' "$1" "$(fm_agent_process_format_live "$out")"
  return 0
}
