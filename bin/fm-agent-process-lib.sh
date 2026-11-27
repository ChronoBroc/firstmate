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
_FM_AGENT_PROCESS_PROCINFO=$(cd "${_FM_AGENT_PROCESS_LIB_DIR:-/}" 2>/dev/null && pwd)/fm-procinfo.py
# shellcheck source=bin/fm-session-lock-lib.sh
. "${_FM_AGENT_PROCESS_LIB_DIR:-/}/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-gemini-lib.sh
. "${_FM_AGENT_PROCESS_LIB_DIR:-/}/fm-gemini-lib.sh"
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
    # grok is anchored on its verified identities - process name `grok`, pane
    # title `grok-<version>-...` (docs/verification/runtime-backends.md) - so
    # an unrelated command such as ngrok is never this harness.
    *claude*|*codex*|*opencode*|grok|grok-*|*kimi*|*rovo*|pi|pi-signed|pi-launcher|Pi|omp) printf 'agent' ;;
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
      if fm_harness_path_name "$(fm_process_path_below_boundary "$path")" >/dev/null \
         || fm_harness_path_name "$(fm_process_path_below_boundary "$argv0")" >/dev/null; then
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
#   <args>   the flattened command line, split into an argument vector for
#            the interpreter-hosted harnesses whose identity sits in their
#            script argument (a Bun-hosted omp's spaced script path is rebuilt
#            by fm_omp_argv_from_args).
#   [pid]    when given and /proc exposes it, the live process's own argv
#            replaces the flattened line, keeping its boundaries.
fm_agent_process_classify() {  # <name> <argv0> <args> [pid] -> agent|shell|other
  local name=${1:-} argv0=${2:-} args=${3:-} pid=${4:-} word
  local argv=()
  if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
    while IFS= read -r -d '' word; do argv+=("$word"); done < "/proc/$pid/cmdline"
  else
    fm_omp_argv_from_args "$name" "$args"
    argv=(${FM_PROCESS_ARGV[@]+"${FM_PROCESS_ARGV[@]}"})
  fi
  _fm_agent_process_verdict "$name" "$argv0" ${argv[@]+"${argv[@]}"}
}

# _fm_agent_process_verdict <name> <argv0> <argv...>: the one agent|shell|other
# decision, over the kernel name, argv[0] (empty when unknown), and an
# argument vector with its boundaries intact for the interpreter-hosted
# harnesses whose identity sits in their script argument. Every caller reaches
# it through an input adapter: fm_agent_process_classify for a backend's name,
# argv[0], and flattened command line, _fm_agent_process_identify for a live
# pid's kernel argv.
_fm_agent_process_verdict() {  # <name> <argv0> <argv...> -> agent|shell|other
  local name=${1:-} argv0=${2:-} by_name by_argv0
  shift 2
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
  if fm_hermes_argv_matches "$@" || fm_omp_argv_matches "$name" "$@" || fm_gemini_argv_is_gemini "$@"; then
    printf 'agent'
  elif [ "$by_name" = shell ] && [ "$by_argv0" = shell ]; then
    printf 'shell'
  else
    printf 'other'
  fi
}

# fm_agent_process_live_in_dir: the verified-harness agent processes owned by
# this user whose working directory is exactly <dir> (a subdirectory does not
# match), read from the kernel's per-process working directory rather than
# from any terminal endpoint. Each process is classified through the shared
# harness verdict, so only agents count - plus, when [launch-exe] names the
# executable a task was launched with as a raw command, a process running that
# executable (never a shell). Only the checking process itself (this shell and
# its subshells) is excluded, so an agent that is an ancestor of the caller
# still counts.
#
# Working directories come from /proc/<pid>/cwd where the kernel exposes it
# (Linux) and otherwise from lsof (macOS), matched by the directory's device
# and inode because lsof escapes bytes in the names it prints. A failed lsof
# listing still has its complete records checked. Under a Cygwin-family
# userspace (Git for Windows) a native Windows harness lives outside the
# process table this reads, and this probe does not enumerate Windows
# processes, so there it can name an agent it sees but never proves absence;
# the same holds inside a private Linux pid namespace
# (fm_agent_process_view_incomplete).
#
# Prints and returns:
#   0  one `<pid>\t<process name>` line per live agent process found; a
#      verified agent is reported even when another process could not be
#      read, unless [strict] is given (any non-empty word), when such an
#      undecided process answers 2 instead.
#   1  nothing: no agent process of this user works in <dir>.
#   2  one line naming why the probe could not decide, when no agent was
#      verified: <dir> does not resolve, no working-directory source is usable
#      or it failed, or a running candidate's identity (name and argv) could
#      not be read.
#      Callers that would start an agent in <dir> must treat this as a
#      refusal, never as 1.
fm_agent_process_live_in_dir() {  # <dir> [launch-exe] [strict]
  local dir=${1:-} exe=${2:-} strict=${3:-} dir_real dir_id uid pid self selves found='' undecided='' lsof_out lsof_rc p candidates=''
  exe=${exe##*/}
  [ "$(fm_agent_process_classify_name "$exe")" != shell ] || exe=
  undecided=$(fm_agent_process_view_incomplete) || undecided=
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
      if [ -d "$p/cwd" ]; then
        [ "$p/cwd" -ef "$dir_real" ] && candidates="$candidates $pid"
        continue
      fi
      ! readlink "$p/cwd" >/dev/null 2>&1 || continue
      [ -d "$p" ] || continue
      case "$(awk '{ s = $0; sub(/^.*\) /, "", s); print substr(s, 1, 1) }' "$p/stat" 2>/dev/null)" in
        Z|X|'') continue ;;
      esac
      case "$selves" in *" $pid "*) continue ;; esac
      if ! _fm_agent_process_identify "$pid" "$dir_real" "${dir%/}"; then
        kill -0 "$pid" 2>/dev/null || continue
        [ -n "$undecided" ] || undecided="the working directory and identity of running process $pid could not be read"
        continue
      fi
      _fm_agent_process_counts "$exe" || continue
      [ -n "$undecided" ] || undecided="the working directory of running agent process $pid could not be read"
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
    if [ -z "$lsof_out" ]; then
      printf 'lsof could not list the working directories of this user'"'"'s processes (exit %s)\n' "$lsof_rc"
      return 2
    fi
    [ "$lsof_rc" -eq 0 ] || [ -n "$undecided" ] \
      || undecided="lsof could not list every working directory of this user's processes (exit $lsof_rc)"
    candidates=$(printf '%s\n' "$lsof_out" | awk -v dev="$(printf '0x%x' "${dir_id%% *}")" -v ino="${dir_id##* }" '
      /^p/ { pid = substr($0, 2); d = ""; next }
      /^D/ { d = substr($0, 2); next }
      /^i/ { if (d == dev && substr($0, 2) == ino) printf " %s", pid }')
  fi
  for pid in $candidates; do
    case "$selves" in *" $pid "*) continue ;; esac
    if ! _fm_agent_process_identify "$pid" "$dir_real" "${dir%/}"; then
      kill -0 "$pid" 2>/dev/null || continue
      [ -n "$undecided" ] || undecided="the identity of running process $pid working in $dir_real could not be read"
      continue
    fi
    _fm_agent_process_counts "$exe" || continue
    found="$found$pid"$'\t'"${FM_AGENT_PROCESS_NAME##*/}"$'\n'
  done
  if [ -n "$found" ] && { [ -z "$strict" ] || [ -z "$undecided" ]; }; then
    printf '%s' "$found"
    return 0
  fi
  if [ -n "$undecided" ]; then
    printf '%s\n' "$undecided"
    return 2
  fi
  return 1
}

# _fm_agent_process_identify <pid> [dir...]: classify a live process from its
# kernel name and its argument vector into FM_AGENT_PROCESS_KIND
# (agent|shell|other), FM_AGENT_PROCESS_NAME, and FM_AGENT_PROCESS_ARGV0;
# returns 1 when they could not be read. Each [dir] (the worktree, by any of
# its spellings) is a checkout boundary: FM_PROCESS_PATH_BOUNDARIES hands it to
# the lexical installation-path checks, which judge a path under it by its part
# below it only, so the worktree's own path (a checkout at /work/pi) is never
# taken for a harness installation; symlink resolution keeps the real path.
# The first [dir] is also the process's own working directory, so a relative
# executable or script path (`./bin/agent`) is resolved against it, never
# against the checker's. On Linux both come from /proc (comm and cmdline);
# elsewhere from the kernel argv through bin/fm-procinfo.py, whose argv[0] is
# the name ps itself reports there, so a host that denies ps still identifies
# it.
_fm_agent_process_identify() {  # <pid> [dir...]
  local pid=$1 name word boundary i
  local argv=() judged=()
  FM_AGENT_PROCESS_KIND=
  FM_AGENT_PROCESS_NAME=
  FM_AGENT_PROCESS_ARGV0=
  FM_AGENT_PROCESS_SCRIPT=
  if [ -r "/proc/$pid/cmdline" ]; then
    IFS= read -r name < "/proc/$pid/comm" 2>/dev/null || return 1
    while IFS= read -r -d '' word; do argv+=("$word"); done < "/proc/$pid/cmdline"
  else
    # The provider's own exit status follows its records as one final record,
    # so a read cut short can never pass for a complete argv.
    while IFS= read -r -d '' word; do argv+=("$word"); done < <(
      python3 "$_FM_AGENT_PROCESS_PROCINFO" --argv "$pid" 2>/dev/null
      printf '%s\0' "$?"
    )
    [ "${#argv[@]}" -gt 0 ] && [ "${argv[${#argv[@]}-1]}" = 0 ] || return 1
    unset 'argv[${#argv[@]}-1]'
    name=${argv[0]:-}
  fi
  [ -n "$name" ] && [ "${#argv[@]}" -gt 0 ] && [ -n "${argv[0]}" ] || return 1
  FM_AGENT_PROCESS_NAME=$name
  FM_AGENT_PROCESS_ARGV0=${argv[0]}
  FM_AGENT_PROCESS_SCRIPT=$(_fm_agent_process_script_operand "${argv[@]}")
  shift
  judged=("${argv[@]}")
  if [ -n "${1:-}" ]; then
    for i in "${!judged[@]}"; do
      case "${judged[i]}" in
        /*|-*) ;;
        */*) judged[i]="$1/${judged[i]#./}" ;;
      esac
    done
    case "$name" in /*) ;; */*) name="$1/${name#./}" ;; esac
  fi
  local -a FM_PROCESS_PATH_BOUNDARIES=()
  for boundary in "$@"; do
    [ -z "$boundary" ] || FM_PROCESS_PATH_BOUNDARIES+=("$boundary")
  done
  FM_AGENT_PROCESS_KIND=$(_fm_agent_process_verdict "$name" "${judged[0]}" "${judged[@]}")
}

# _fm_agent_process_counts [launch-exe]: after _fm_agent_process_identify,
# whether that process counts as an agent: a verified harness, or a process
# running the task's own raw launch executable - as its process name, its
# argv[0], or the script a known interpreter runs (a shebang script's kernel
# argv is the interpreter followed by the script path).
_fm_agent_process_counts() {  # [launch-exe]
  [ "$FM_AGENT_PROCESS_KIND" != agent ] || return 0
  [ -n "${1:-}" ] || return 1
  [ "${FM_AGENT_PROCESS_NAME##*/}" = "$1" ] || [ "${FM_AGENT_PROCESS_ARGV0##*/}" = "$1" ] \
    || { [ -n "$FM_AGENT_PROCESS_SCRIPT" ] && [ "${FM_AGENT_PROCESS_SCRIPT##*/}" = "$1" ]; }
}

# _fm_agent_process_script_operand <argv...>: the script a known interpreter
# (a shell, env, node, bun, or python) runs - its first argument that is
# neither an option nor, for env, a variable assignment - or nothing.
_fm_agent_process_script_operand() {  # <argv...>
  local interp=${1:-} arg
  case "${interp##*/}" in
    env|node|node-*|node[0-9]*|bun|python|python[0-9]*) ;;
    *) [ "$(fm_agent_process_classify_name "$interp")" = shell ] || return 0 ;;
  esac
  shift
  for arg in "$@"; do
    case "$arg" in
      -*) continue ;;
      *=*) [ "${interp##*/}" = env ] && continue ;;
    esac
    printf '%s' "$arg"
    return 0
  done
}

# fm_agent_process_view_incomplete: print why this host's process view cannot
# prove a worktree agent-free and succeed, or fail when it can. Under a
# Cygwin-family userspace native Windows harnesses live outside the process
# table; inside a private Linux pid namespace (a sandboxed command whose
# /proc/self/status NSpid has more than one level) host processes are hidden.
# Neither boundary is reached into: the probe can still name what it sees, never
# absence.
fm_agent_process_view_incomplete() {
  local levels
  if fm_win_boundary_applies; then
    printf 'native Windows processes are outside the process table this probe reads, so their absence cannot be proven\n'
    return 0
  fi
  levels=$(awk '/^NSpid:/ { print NF - 1; exit }' /proc/self/status 2>/dev/null) || levels=
  if [ -n "$levels" ] && [ "$levels" -gt 1 ] 2>/dev/null; then
    printf 'this process runs in a private pid namespace that hides host processes, so their absence cannot be proven\n'
    return 0
  fi
  return 1
}

# fm_agent_process_argv_reader_unusable: print why the kernel argv reader the
# probe identifies processes through without /proc (python3
# bin/fm-procinfo.py) cannot read this very process, and succeed; fail when it
# can, or when /proc serves identities instead. For a caller about to stop an
# agent whose replacement the probe must then admit.
fm_agent_process_argv_reader_unusable() {
  [ ! -r /proc/self/cwd ] && [ ! -L /proc/self/cwd ] || return 1
  _fm_agent_process_identify "$$" && return 1
  printf 'the process argv reader (python3 %s --argv) cannot read process identities on this host\n' "$_FM_AGENT_PROCESS_PROCINFO"
}

# fm_agent_process_format_live <probe-output>: fm_agent_process_live_in_dir's
# `<pid>\t<name>` lines as `<pid> (<name>)[, ...]`.
fm_agent_process_format_live() {  # <probe-output>
  printf '%s\n' "$1" | awk -F'\t' 'NF { printf "%s%s (%s)", sep, $1, $2; sep = ", " }'
}

# fm_agent_process_record_note <state-dir> <id>: fm_agent_process_live_note for
# the worktree and launch executable task <id>'s record names, only when the
# state directory is a real directory, the record passes this home's
# record-ownership check (bin/fm-backlog-transition-lib.sh), and it names its
# task unambiguously (bin/fm-backend.sh's fm_backend_meta_exact_value): one
# worktree (a secondmate's at most one home, which is where it runs), at most
# one harness, an endpoint_task_id equal to <id> when it
# carries one, and no remote_host (a task on another host); nothing otherwise.
fm_agent_process_record_note() {  # <state-dir> <id>
  local state=${1:-} id=${2:-} meta="${1:-}/${2:-}.meta" lib_dir=${_FM_AGENT_PROCESS_PROCINFO%/*}
  local worktree harness='' endpoint_id home
  [ -n "$state" ] && [ -n "$id" ] || return 0
  if ! declare -F fm_backlog_record_present >/dev/null 2>&1; then
    . "$lib_dir/fm-tasks-axi-lib.sh" >/dev/null 2>&1 \
      && . "$lib_dir/fm-backlog-transition-lib.sh" >/dev/null 2>&1 || return 0
  fi
  declare -F fm_backend_meta_exact_value >/dev/null 2>&1 || return 0
  fm_backlog_directory_present "$state" "state directory" || return 0
  fm_backlog_record_present "$meta" "task record" "$state" || return 0
  [ ! -L "$meta" ] || return 0
  worktree=$(fm_backend_meta_exact_value "$meta" worktree) || return 0
  if [ "$(fm_meta_get "$meta" kind)" = secondmate ] && grep -q '^home=' "$meta" 2>/dev/null; then
    home=$(fm_backend_meta_exact_value "$meta" home) || return 0
    worktree=$home
  fi
  ! grep -q '^remote_host=' "$meta" 2>/dev/null || return 0
  if grep -q '^harness=' "$meta" 2>/dev/null; then
    harness=$(fm_backend_meta_exact_value "$meta" harness) || return 0
  fi
  if grep -q '^endpoint_task_id=' "$meta" 2>/dev/null; then
    endpoint_id=$(fm_backend_meta_exact_value "$meta" endpoint_task_id) || return 0
    [ "$endpoint_id" = "$id" ] || return 0
  fi
  fm_agent_process_live_note "$worktree" "$harness"
}

# fm_agent_process_fold_survivor <text>: <text> - a command's combined output -
# with the survivor line fm_agent_process_live_note writes (a line of its own
# that a refusal reports after its reason) moved onto the end of the first
# line, so a caller that keeps only the first reported line still carries the
# pid; unchanged when no survivor line is there.
fm_agent_process_fold_survivor() {  # <text>
  local text=${1-} survivor
  survivor=$(printf '%s\n' "$text" | grep -m1 '^An agent process is still working in its worktree ') || survivor=
  if [ -z "$survivor" ] || [ "$(printf '%s\n' "$text" | sed -n '/./{p;q;}')" = "$survivor" ]; then
    printf '%s' "$text"
    return 0
  fi
  printf '%s\n' "$text" | FM_AGENT_PROCESS_SURVIVOR=$survivor awk 'BEGIN { s = ENVIRON["FM_AGENT_PROCESS_SURVIVOR"] }
    $0 == s && !dropped { dropped = 1; next }
    !done && NF { print $0 "; " s; done = 1; next }
    { print }'
}

# fm_agent_process_live_note <dir> [launch-exe]: a sentence naming the agent
# processes still working in <dir>, for appending to a refusal; prints nothing
# when none was found or the probe could not decide, and always succeeds.
fm_agent_process_live_note() {  # <dir> [launch-exe]
  local out
  [ -n "${1:-}" ] || return 0
  out=$(fm_agent_process_live_in_dir "$1" "${2:-}") || return 0
  printf ' %s' "$(fm_agent_process_survivor_line "$1" "$out")"
  return 0
}

# fm_agent_process_survivor_line <dir> <probe-output>: the one survivor line,
# naming the agent processes fm_agent_process_live_in_dir found in <dir>; a
# refusal writes it on a line of its own, where fm_agent_process_fold_survivor
# finds it.
fm_agent_process_survivor_line() {  # <dir> <probe-output>
  printf 'An agent process is still working in its worktree %s: pid %s.' "$1" "$(fm_agent_process_format_live "$2")"
}
