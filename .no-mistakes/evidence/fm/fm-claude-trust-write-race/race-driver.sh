#!/usr/bin/env bash
# race.sh <trust-script> <label> <n> [preload]
# Creates a disposable git project + n linked worktrees and an isolated
# CLAUDE_CONFIG_DIR, then launches n registrations simultaneously.
set -u
TRUST=$1 LABEL=$2 N=$3 PRE=${4:-}
D=$(mktemp -d /tmp/fmrace-case.XXXXXX)
git init -q "$D/proj"; git -C "$D/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
for i in $(seq 1 $N); do git -C "$D/proj" worktree add -q -b w$i "$D/wt$i" 2>/dev/null; done
mkdir -p "$D/cfg"; printf '{"oauthAccount":{"emailAddress":"kept"},"projects":{}}\n' > "$D/cfg/.claude.json"
for i in $(seq 1 $N); do
  ( if [ -n "$PRE" ]; then export NODE_OPTIONS="--require $PRE"; fi
    env -u NO_MISTAKES_GATE CLAUDE_CONFIG_DIR="$D/cfg" HOME="$D/cfg" "$TRUST" "$D/wt$i" "$D/proj" >"$D/out$i" 2>&1; echo $? >"$D/rc$i" ) &
done
wait
ok=0; for i in $(seq 1 $N); do [ "$(cat $D/rc$i)" = 0 ] && ok=$((ok+1)); done
landed=$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1]));let c=0;for(const i of process.argv.slice(2)){const p=require("fs").realpathSync(i);if(j.projects[p]&&j.projects[p].hasTrustDialogAccepted)c++}console.log(c)' "$D/cfg/.claude.json" $(for i in $(seq 1 $N); do echo "$D/wt$i"; done))
echo "[$LABEL] registrations=$N reported_success=$ok worktree_entries_in_store=$landed leftover=$(ls -A $D/cfg | tr '\n' ' ')"
[ "$ok" -gt 0 ] && head -2 "$D/out1" | sed "s/^/[$LABEL] out1: /"
rm -rf "$D"
