#!/usr/bin/env bash
# omp (Oh My Pi) process identity, shared by harness detection and the
# session-lock ancestry walk. This file has no side effects on source.
#
# omp ships two ways, and the live process looks different for each:
#   - the Bun-compiled single binary, whose process name is exactly `omp`
#     (verified, omp 18.1.11);
#   - the bun global package (`bun install -g @oh-my-pi/pi-coding-agent`), whose
#     ~/.bun/bin/omp launcher is a symlink to dist/cli.js with a
#     `#!/usr/bin/env bun` shebang, so `ps -o comm=` reports `bun` and
#     `ps -o args=` reports `bun <path>/omp` (verified on macOS).
# Match the exact compiled name, or bun whose argv0 is bun and whose very next
# argument is a script named exactly `omp`.
# A flattened command line is first turned back into an argument vector by
# fm_process_argv_from_args below.
# Anchored throughout, so ompd, comp, and similar names are never this harness.
fm_omp_process_matches() {  # <comm> <args>
  fm_process_argv_from_args "${2:-}"
  fm_omp_argv_matches "${1:-}" ${FM_PROCESS_ARGV[@]+"${FM_PROCESS_ARGV[@]}"}
}

# fm_process_argv_from_args <args>: FM_PROCESS_ARGV rebuilt from a ps-style
# space-joined command line. ps cannot represent argument boundaries, so a
# script argument containing spaces is rebuilt by extending argv[1] word by
# word until it names an existing file; with no such file argv[1] is the word
# alone, and every later word stays its own argument.
fm_process_argv_from_args() {  # <args>
  local i n script
  FM_PROCESS_ARGV=()
  read -r -a FM_PROCESS_ARGV <<< "${1:-}"
  n=${#FM_PROCESS_ARGV[@]}
  [ "$n" -ge 3 ] || return 0
  script=${FM_PROCESS_ARGV[1]}
  for ((i = 2; i < n; i++)); do
    [ -f "$script" ] && break
    script+=" ${FM_PROCESS_ARGV[i]}"
  done
  [ -f "$script" ] || return 0
  FM_PROCESS_ARGV=("${FM_PROCESS_ARGV[0]}" "$script" ${FM_PROCESS_ARGV[@]+"${FM_PROCESS_ARGV[@]:i}"})
}

# fm_omp_argv_matches <comm> <argv...>: the same rule over an argument vector
# whose boundaries are intact.
fm_omp_argv_matches() {  # <comm> <argv...>
  local comm=${1:-}
  shift
  case "${comm##*/}" in
    omp) return 0 ;;
    bun) ;;
    *) return 1 ;;
  esac
  [ "$#" -ge 2 ] && [ "${1##*/}" = bun ] && [ "${2##*/}" = omp ]
}
