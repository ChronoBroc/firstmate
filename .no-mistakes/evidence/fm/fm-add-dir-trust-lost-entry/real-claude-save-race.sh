#!/usr/bin/env bash
# race.sh <label> <bin-dir> <iterations> <concurrent-claudes>
set -u
label=$1; bin=$2; n=$3; k=$4
W=$(cd "$(dirname "$0")" && pwd -P)
cfg=$W/cfg-$label; rm -rf "$cfg"; mkdir -p "$cfg" "$W/cwd"
lost=0; failed=0
for i in $(seq 1 "$n"); do
  wt=$W/wt-$label-$i; rm -rf "$cfg"; mkdir -p "$cfg"
  git -C "$W/proj" worktree add -q "$wt" -b "b-$label-$i" 2>/dev/null
  pids=()
  for j in $(seq 1 "$k"); do
    mkdir -p "$W/cwd/$label-$i-$j"
    ( cd "$W/cwd/$label-$i-$j" && CLAUDE_CONFIG_DIR=$cfg timeout 30 claude -p ok >/dev/null 2>&1 ) &
    pids+=($!)
  done
  sleep "0.$((RANDOM % 4))$((RANDOM % 10))"
  if ! out=$(CLAUDE_CONFIG_DIR=$cfg "$bin/fm-claude-trust.sh" "$wt" "$W/proj" 2>&1); then failed=$((failed+1)); echo "iter $i: registration refused: $out"; fi
  wait "${pids[@]}"
  if ! node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit(j.projects?.[process.argv[2]]?.hasTrustDialogAccepted===true?0:1)' "$cfg/.claude.json" "$wt"; then
    lost=$((lost+1)); echo "iter $i: registration reported '${out%%$'\n'*}' but worktree entry LOST after real Claude Code saves"
  fi
done
starts=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).numStartups??"?")' "$cfg/.claude.json")
echo "[$label] iterations=$n concurrent_claude=$k  entries_lost=$lost  registrations_refused=$failed  claude_numStartups=$starts"
