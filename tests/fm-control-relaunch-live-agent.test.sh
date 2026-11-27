#!/usr/bin/env bash
# tests/fm-control-relaunch-live-agent.test.sh - a relaunch never starts a
# second agent beside one still working in the task's worktree.
#
# The worktree probe (fm_agent_process_live_in_dir in
# bin/fm-agent-process-lib.sh) reads the kernel's working directory of real
# processes, so these cases start real agent-named stand-ins
# (tests/lib.sh fm_agent_standin) and need no harness. The endpoint stays the
# stubbed tmux of tests/relaunch-helpers.sh, which is what lets it read
# agent-free while an agent still works in the worktree - the double tmux
# server fault of 2026-11-25, without a second server.
#   - the probe finds only agents (and a raw-launch executable) working in
#     exactly the directory, keeps argv boundaries, and is undecided only when
#     no agent was verified;
#   - fm-spawn --relaunch, fm-control relaunch/exit, and the secondmate
#     respawn refuse naming the pid, and the rollback restores the
#     instructions it rewrote;
#   - a relaunch waits only for the agent processes of the endpoint it stopped.
set -u

# shellcheck source=tests/relaunch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/relaunch-helpers.sh"

# Task ids carry this run's own token, so a fixture's /tmp/fm-<id> scratch,
# and the launch staging beside it, can never be a real task's.
RL_RUN=rlt$$

test_worktree_agent_probe_finds_only_agents_working_there() {
  local dir agent out rc agent_pid other_pid sub_pid shell_pid server_pid cursor_pid ui_pid
  dir="$TMP_ROOT/probe-$RANDOM"
  mkdir -p "$dir/wt/sub"
  agent=$(agent_standin_named "$dir" claude) || {
    pass "worktree agent probe: skipped - no stand-in survives a rename on this host"
    return 0
  }
  start_dir_process "$dir/wt" /bin/sleep 600; other_pid=$STARTED_PID
  start_dir_process "$dir/wt" /bin/sh -c 'sleep 600; :'; shell_pid=$STARTED_PID
  start_dir_process "$dir/wt/sub" "$agent" 600; sub_pid=$STARTED_PID
  wait_probe_rc "$dir/wt" 1 || fail "a sleep, a shell, and an agent in a subdirectory are not agents working in the worktree: $(fm_agent_process_live_in_dir "$dir/wt")"
  start_dir_process "$dir/wt" "$agent" 600; agent_pid=$STARTED_PID
  wait_probe_rc "$dir/wt" 0 || fail "the agent-named process working in the worktree was never found"
  out=$(fm_agent_process_live_in_dir "$dir/wt"); rc=$?
  expect_code 0 "$rc" "the probe should find the agent"
  [ "$(printf '%s\n' "$out" | cut -f1)" = "$agent_pid" ] \
    || fail "the probe must name exactly the agent working in the worktree ($agent_pid), got: $out"
  assert_contains "$out" $'\t'claude "the probe should name the agent's process"
  # The same directory reached through another path names the same agent:
  # the probe compares directory objects, never path strings.
  ln -s "$dir/wt" "$dir/wt-link"
  rc=0; out=$(fm_agent_process_live_in_dir "$dir/wt-link") || rc=$?
  expect_code 0 "$rc" "the worktree reached through a link should still hold the agent"$'\n'"$out"
  [ "$(printf '%s\n' "$out" | cut -f1)" = "$agent_pid" ] \
    || fail "the probe must name the agent through the linked path ($agent_pid), got: $out"
  # A bind mount, where this host permits one, lives only in a private mount
  # namespace that ends with the probe, so nothing can outlive the test.
  mkdir -p "$dir/wt-bind"
  # shellcheck disable=SC2016
  if [ -e /proc/self/cwd ] && command -v unshare >/dev/null 2>&1 \
     && unshare -m true 2>/dev/null; then
    rc=0; out=$(unshare -m bash -c 'mount --bind "$2" "$3" || exit 99; . "$1/bin/fm-agent-process-lib.sh"; fm_agent_process_live_in_dir "$3"' _ "$ROOT" "$dir/wt" "$dir/wt-bind") || rc=$?
    if [ "$rc" != 99 ]; then
      expect_code 0 "$rc" "the worktree reached through a bind mount should still hold the agent"$'\n'"$out"
      [ "$(printf '%s\n' "$out" | cut -f1)" = "$agent_pid" ] \
        || fail "the probe must name the agent through the bind mount ($agent_pid), got: $out"
    fi
  fi
  # A worktree whose own path names a harness (a checkout at .../pi) is no
  # evidence of one: a project server running from inside it is not an agent.
  mkdir -p "$dir/pi/.venv/bin"
  ln -sf "$dir/standin/standin" "$dir/pi/.venv/bin/server"
  start_dir_process "$dir/pi" "$dir/pi/.venv/bin/server" 600; server_pid=$STARTED_PID
  wait_dir_process_alive "$server_pid" || fail "the project server stand-in must keep running"
  rc=0; out=$(fm_agent_process_live_in_dir "$dir/pi") || rc=$?
  expect_code 1 "$rc" "a project process inside a worktree named pi is not a Pi agent"$'\n'"$out"
  stop_dir_process "$server_pid"
  # Cursor's legacy alias inside the worktree ($WT/bin/agent) resolves into its
  # versioned install (tests/fm-cursor-harness.test.sh make_cursor_tree): the
  # alias's real path, not one cut below the worktree, decides its identity.
  # The install needs a copy of the stand-in, which only the compiled one
  # survives (a copied platform sleep is killed by code signing on macOS arm64).
  if [ -L "$dir/standin/standin" ]; then
    echo "skip - Cursor alias cases need the compiled stand-in, and none could be built here"
  else
    mkdir -p "$dir/share/cursor-agent/versions/2026.08.11-e8db854" "$dir/wt/bin"
    cp "$dir/standin/standin" "$dir/share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent"
    ln -sf "$dir/share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent" "$dir/wt/bin/agent"
    start_dir_process "$dir/wt" "$dir/wt/bin/agent" 600; cursor_pid=$STARTED_PID
    wait_dir_process_alive "$cursor_pid" || fail "the Cursor alias stand-in must keep running"
    rc=0; out=$(fm_agent_process_live_in_dir "$dir/wt" cursor) || rc=$?
    expect_code 0 "$rc" "a live Cursor worker run through its worktree-local alias must be found"$'\n'"$out"
    printf '%s\n' "$out" | cut -f1 | grep -Fqx "$cursor_pid" \
      || fail "the probe must name the Cursor worker ($cursor_pid), got: $out"
    stop_dir_process "$cursor_pid"
    # The same alias reached relatively (`PATH=./bin` resolves `./bin/agent`)
    # is resolved against the worker's own directory, not the checker's.
    start_dir_process "$dir/wt" ./bin/agent 600; cursor_pid=$STARTED_PID
    wait_dir_process_alive "$cursor_pid" || fail "the relative Cursor alias stand-in must keep running"
    rc=0; out=$(cd "$dir" && fm_agent_process_live_in_dir "$dir/wt" cursor) || rc=$?
    expect_code 0 "$rc" "a live Cursor worker run through a relative alias must be found"$'\n'"$out"
    printf '%s\n' "$out" | cut -f1 | grep -Fqx "$cursor_pid" \
      || fail "the probe must name the relatively launched Cursor worker ($cursor_pid), got: $out"
    stop_dir_process "$cursor_pid"
  fi
  # A script operand is judged below the worktree too: a UI server at
  # <checkout named ui-tui>/dist/entry.js is not Hermes's TUI.
  mkdir -p "$dir/ui-tui/dist" "$dir/Node Dir"
  : > "$dir/ui-tui/dist/entry.js"
  ln -sf "$dir/standin/standin" "$dir/Node Dir/node"
  if [ ! -L "$dir/standin/standin" ]; then
    start_dir_process "$dir/ui-tui" "$dir/Node Dir/node" "$dir/ui-tui/dist/entry.js"; ui_pid=$STARTED_PID
    wait_dir_process_alive "$ui_pid" || fail "the UI server stand-in must keep running"
    rc=0; out=$(fm_agent_process_live_in_dir "$dir/ui-tui") || rc=$?
    expect_code 1 "$rc" "a UI server in a checkout named ui-tui is not Hermes"$'\n'"$out"
    stop_dir_process "$ui_pid"
  fi
  # The checking process itself is never a finding, but an agent that is its
  # ancestor and works in the worktree is one.
  ln -s "$(command -v bash)" "$dir/agentbin/claude-checker" || fail "could not name a checker shell like an agent"
  # shellcheck disable=SC2016
  out=$(cd "$dir/wt" && "$dir/agentbin/claude-checker" -c '. "$1/bin/fm-agent-process-lib.sh"; fm_agent_process_live_in_dir "$2"; exit $?' _ "$ROOT" "$dir/wt"); rc=$?
  expect_code 0 "$rc" "the probe run from an agent-named checker should still find the agent"
  [ "$(printf '%s\n' "$out" | cut -f1)" = "$agent_pid" ] \
    || fail "the checking process must exclude itself, got: $out"
  # shellcheck disable=SC2016
  out=$(cd "$dir/wt" && "$dir/agentbin/claude-checker" -c 'printf "%s\n" "$$"; bash -c ". \"\$1/bin/fm-agent-process-lib.sh\"; fm_agent_process_live_in_dir \"\$2\"" _ "$1" "$2"; exit $?' _ "$ROOT" "$dir/wt"); rc=$?
  expect_code 0 "$rc" "the probe run below an agent-named ancestor should find agents"
  local ancestor_pid
  ancestor_pid=$(printf '%s\n' "$out" | head -1)
  printf '%s\n' "$out" | sed 1d | cut -f1 | grep -Fqx "$ancestor_pid" \
    || fail "an agent-named ancestor working in the worktree must be reported ($ancestor_pid), got: $out"
  printf '%s\n' "$out" | sed 1d | cut -f1 | grep -Fqx "$agent_pid" \
    || fail "the agent working in the worktree must still be reported, got: $out"
  stop_dir_process "$agent_pid"
  wait_probe_rc "$dir/wt" 1 || fail "once the agent exits the probe must find nothing"
  # argv[0] with a space keeps its identity: a version-named Claude install
  # (docs/tmux-backend.md "Agent liveness probe") under a home with a space.
  mkdir -p "$dir/Crew User/.local/share/claude/versions"
  ln -s "$dir/standin/standin" "$dir/Crew User/.local/share/claude/versions/2.1.220"
  start_dir_process "$dir/wt" "$dir/Crew User/.local/share/claude/versions/2.1.220" 600; agent_pid=$STARTED_PID
  wait_probe_rc "$dir/wt" 0 || fail "a version-named Claude whose install path has a space was never found"
  [ "$(fm_agent_process_live_in_dir "$dir/wt" | cut -f1)" = "$agent_pid" ] \
    || fail "the probe must name the version-named Claude ($agent_pid)"
  stop_dir_process "$agent_pid"
  wait_probe_rc "$dir/wt" 1 || fail "once the version-named Claude exits the probe must find nothing"
  # A directory name holding a literal backslash sequence is compared byte for byte.
  mkdir -p "$dir/back\\tslash"
  start_dir_process "$dir/back\\tslash" "$agent" 600; agent_pid=$STARTED_PID
  wait_probe_rc "$dir/back\\tslash" 0 || fail "an agent in a folder whose name holds a backslash sequence was never found"
  [ "$(fm_agent_process_live_in_dir "$dir/back\\tslash" | cut -f1)" = "$agent_pid" ] \
    || fail "the probe must name the agent in the backslash-named folder ($agent_pid)"
  stop_dir_process "$agent_pid"
  # Interpreter-hosted harnesses carry their identity in the script argument,
  # so the interpreter path and the script path both hold spaces here: a bun
  # omp (docs/verification/runtime-backends.md), a node Gemini
  # (bin/fm-gemini-lib.sh), and a node Hermes TUI (bin/fm-hermes-process-lib.sh).
  if [ ! -L "$dir/standin/standin" ]; then
    mkdir -p "$dir/Bun Dir" "$dir/Node Dir" "$dir/omp dist" "$dir/Crew User/bin" "$dir/Crew User/hermes_cli/tui_dist"
    : > "$dir/omp dist/omp"
    : > "$dir/Crew User/bin/gemini"
    : > "$dir/Crew User/hermes_cli/tui_dist/entry.js"
    ln -sf "$dir/standin/standin" "$dir/Bun Dir/bun"
    ln -sf "$dir/standin/standin" "$dir/Node Dir/node"
    local hosted
    for hosted in "$dir/Bun Dir/bun|$dir/omp dist/omp" "$dir/Node Dir/node|$dir/Crew User/bin/gemini" "$dir/Node Dir/node|$dir/Crew User/hermes_cli/tui_dist/entry.js"; do
      start_dir_process "$dir/wt" "${hosted%%|*}" "${hosted#*|}" -y; agent_pid=$STARTED_PID
      wait_probe_rc "$dir/wt" 0 || fail "the interpreter-hosted harness ${hosted#*|} was never found"
      [ "$(fm_agent_process_live_in_dir "$dir/wt" | cut -f1)" = "$agent_pid" ] \
        || fail "the probe must name the interpreter-hosted harness ${hosted#*|} ($agent_pid)"
      stop_dir_process "$agent_pid"
      wait_probe_rc "$dir/wt" 1 || fail "once ${hosted#*|} exits the probe must find nothing"
    done
  fi
  rc=0; out=$(fm_agent_process_live_in_dir "$dir/missing") || rc=$?
  expect_code 2 "$rc" "a directory that does not resolve is inconclusive, never empty"
  assert_contains "$out" "does not resolve" "the inconclusive answer should say why"
  stop_dir_process "$other_pid"; stop_dir_process "$shell_pid"; stop_dir_process "$sub_pid"
  pass "worktree agent probe: finds the agent working in the directory and nothing else"
}

test_worktree_agent_probe_names_an_agent_beside_an_unreadable_process() {
  local dir agent out rc agent_pid other_pid real_python
  if [ -e /proc/self/cwd ]; then
    pass "worktree agent probe beside an unreadable process: skipped - this host reads argv from /proc"
    return 0
  fi
  dir="$TMP_ROOT/probe-unreadable-$RANDOM"
  mkdir -p "$dir/wt" "$dir/fakebin"
  agent=$(agent_standin_named "$dir" claude) || {
    pass "worktree agent probe beside an unreadable process: skipped - no stand-in survives a rename on this host"
    return 0
  }
  real_python=$(command -v python3) || { pass "worktree agent probe beside an unreadable process: skipped - no python3"; return 0; }
  start_dir_process "$dir/wt" /bin/sleep 600; other_pid=$STARTED_PID
  # The argv provider fails for that one process, as a protected process does.
  printf '#!/bin/sh\n[ "$3" = "%s" ] && exit 1\nexec "%s" "$@"\n' "$other_pid" "$real_python" > "$dir/fakebin/python3"
  chmod +x "$dir/fakebin/python3"
  rc=0; out=$(PATH="$dir/fakebin:$PATH" fm_agent_process_live_in_dir "$dir/wt") || rc=$?
  expect_code 2 "$rc" "an unreadable process alone leaves the probe undecided"$'\n'"$out"
  assert_contains "$out" "$other_pid" "the undecided answer should name the unreadable process"
  start_dir_process "$dir/wt" "$agent" 600; agent_pid=$STARTED_PID
  wait_probe_rc "$dir/wt" 0 || fail "the stand-in agent never appeared in the worktree"
  rc=0; out=$(PATH="$dir/fakebin:$PATH" fm_agent_process_live_in_dir "$dir/wt") || rc=$?
  expect_code 0 "$rc" "a verified agent proves presence even beside an unreadable process"$'\n'"$out"
  [ "$(printf '%s\n' "$out" | cut -f1)" = "$agent_pid" ] || fail "the probe must name the verified agent ($agent_pid), got: $out"
  stop_dir_process "$agent_pid"
  stop_dir_process "$other_pid"
  pass "worktree agent probe: names a verified agent beside an unreadable process"
}

# wait_dir_process_alive <pid>: confirm a started stand-in keeps running for a
# couple of seconds (one only ever classified `other` never makes the probe
# answer 0, so its presence is read from the process itself).
wait_dir_process_alive() {
  local i=0
  while [ "$i" -lt 20 ]; do
    kill -0 "$1" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$1" 2>/dev/null
}

test_worktree_agent_probe_counts_only_what_the_task_launched() {
  local dir agent out rc ngrok_pid raw_pid shell_pid
  dir="$TMP_ROOT/probe-launch-$RANDOM"
  mkdir -p "$dir/wt"
  agent=$(agent_standin_named "$dir" claude) || {
    pass "worktree agent probe and the launch executable: skipped - no stand-in survives a rename on this host"
    return 0
  }
  # ngrok is not grok: its name only contains the harness's
  # (docs/verification/runtime-backends.md records grok's own identities).
  ln -sf "$dir/standin/standin" "$dir/agentbin/ngrok"
  start_dir_process "$dir/wt" "$dir/agentbin/ngrok" 600; ngrok_pid=$STARTED_PID
  wait_dir_process_alive "$ngrok_pid" || fail "the ngrok stand-in must keep running"
  rc=0; out=$(fm_agent_process_live_in_dir "$dir/wt") || rc=$?
  expect_code 1 "$rc" "an ngrok tunnel left in the worktree is not a live agent"$'\n'"$out"
  kill -0 "$ngrok_pid" 2>/dev/null || fail "the ngrok stand-in must still be running when the probe answers"
  stop_dir_process "$ngrok_pid"
  # A raw launch command (`custom-agent --flag`, recorded as harness
  # custom-agent) is the task's own agent, and only its executable counts.
  ln -sf "$dir/standin/standin" "$dir/agentbin/custom-agent"
  start_dir_process "$dir/wt" "$dir/agentbin/custom-agent" 600; raw_pid=$STARTED_PID
  start_dir_process "$dir/wt" /bin/sh -c 'sleep 600; :'; shell_pid=$STARTED_PID
  wait_dir_process_alive "$raw_pid" || fail "the raw-launch stand-in must keep running"
  rc=0; out=$(fm_agent_process_live_in_dir "$dir/wt") || rc=$?
  expect_code 1 "$rc" "an unknown executable is no harness by itself"$'\n'"$out"
  rc=0; out=$(fm_agent_process_live_in_dir "$dir/wt" custom-agent) || rc=$?
  expect_code 0 "$rc" "the task's own raw launch executable counts as its agent"$'\n'"$out"
  [ "$(printf '%s\n' "$out" | cut -f1)" = "$raw_pid" ] || fail "the probe must name the raw-launch worker ($raw_pid), got: $out"
  rc=0; out=$(fm_agent_process_live_in_dir "$dir/wt" sh) || rc=$?
  expect_code 1 "$rc" "a raw launch through a shell never makes every shell an agent"$'\n'"$out"
  stop_dir_process "$raw_pid"
  stop_dir_process "$shell_pid"
  pass "worktree agent probe: counts the task's raw launch executable, never ngrok or a shell"
}

test_worktree_agent_probe_survives_a_denied_ps_and_a_partial_listing() {
  local dir agent out rc agent_pid real_lsof
  dir="$TMP_ROOT/probe-denied-$RANDOM"
  mkdir -p "$dir/wt" "$dir/fakebin"
  agent=$(agent_standin_named "$dir" claude) || {
    pass "worktree agent probe without ps: skipped - no stand-in survives a rename on this host"
    return 0
  }
  start_dir_process "$dir/wt" "$agent" 600; agent_pid=$STARTED_PID
  wait_probe_rc "$dir/wt" 0 || fail "the stand-in agent never appeared in the worktree"
  # An endpoint-security policy can deny ps outright (bin/fm-procinfo.py).
  printf '#!/bin/sh\nexit 126\n' > "$dir/fakebin/ps"
  chmod +x "$dir/fakebin/ps"
  rc=0; out=$(PATH="$dir/fakebin:$PATH" fm_agent_process_live_in_dir "$dir/wt") || rc=$?
  expect_code 0 "$rc" "a host that denies ps must still identify the agent"$'\n'"$out"
  [ "$(printf '%s\n' "$out" | cut -f1)" = "$agent_pid" ] || fail "the probe must name the agent without ps ($agent_pid), got: $out"
  rm -f "$dir/fakebin/ps"
  if [ ! -e /proc/self/cwd ] && real_lsof=$(command -v lsof); then
    # lsof can fail after listing most processes; the complete records it
    # did list still name the agent.
    printf '#!/bin/sh\n"%s" "$@"\nexit 1\n' "$real_lsof" > "$dir/fakebin/lsof"
    chmod +x "$dir/fakebin/lsof"
    rc=0; out=$(PATH="$dir/fakebin:$PATH" fm_agent_process_live_in_dir "$dir/wt") || rc=$?
    expect_code 0 "$rc" "a failed listing that still holds the agent's record must name it"$'\n'"$out"
    [ "$(printf '%s\n' "$out" | cut -f1)" = "$agent_pid" ] || fail "the probe must name the agent from the partial listing ($agent_pid), got: $out"
    rm -f "$dir/fakebin/lsof"
  fi
  # Git for Windows: native harnesses live outside this process table.
  printf '#!/bin/sh\necho MINGW64_NT-10.0\n' > "$dir/fakebin/uname"
  chmod +x "$dir/fakebin/uname"
  rc=0; out=$(PATH="$dir/fakebin:$PATH" fm_agent_process_live_in_dir "$dir/wt") || rc=$?
  expect_code 0 "$rc" "an agent the probe sees is named on Windows too"$'\n'"$out"
  stop_dir_process "$agent_pid"
  wait_probe_rc "$dir/wt" 1 || fail "the stand-in agent should be gone"
  rc=0; out=$(PATH="$dir/fakebin:$PATH" fm_agent_process_live_in_dir "$dir/wt") || rc=$?
  expect_code 2 "$rc" "on Windows the probe never proves a worktree agent-free"$'\n'"$out"
  assert_contains "$out" "native Windows processes" "the undecided answer should say why"
  pass "worktree agent probe: identifies without ps, reads a partial listing, and never proves absence on Windows"
}

test_relaunch_refuses_a_raw_launch_worker_still_in_the_worktree() {
  local dir out rc raw_pid
  dir=$(new_case rawworker rl98-${RL_RUN})
  add_ship_task "$dir" rl98-${RL_RUN} custom-agent
  # `custom-agent --flag` as a shebang script: its kernel argv is the
  # interpreter followed by the script path, never the script's own name.
  mkdir -p "$dir/rawbin"
  printf '#!/bin/sh\nsleep 600\n' > "$dir/rawbin/custom-agent"
  chmod +x "$dir/rawbin/custom-agent"
  printf 'zsh' > "$dir/fake/command"
  start_dir_process "$dir/wt" "$dir/rawbin/custom-agent" --flag; raw_pid=$STARTED_PID
  wait_dir_process_alive "$raw_pid" || fail "the raw-launch script must keep running"
  out=$(run_spawn "$dir" rl98-${RL_RUN} --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a relaunch beside the task's surviving raw-launch worker must refuse"$'\n'"$out"
  assert_contains "$out" "pid $raw_pid (" "the refusal must name the raw-launch script's process"
  # fm-control refuses a raw launch it has no control mechanics for, and
  # still names the worker that refusal leaves running.
  out=$(run_control "$dir" rl98-${RL_RUN} relaunch --harness claude --note "manual"); rc=$?
  expect_code 1 "$rc" "fm-control cannot stop a raw-launch worker"$'\n'"$out"
  assert_contains "$out" "no verified control mechanics" "the refusal should keep its reason"
  assert_contains "$out" "pid $raw_pid (" "fm-control's refusal must name the raw-launch worker too"
  ! grep -Fq "Firstmate operational input waiting: read" "$dir/fake/literal" || fail "no replacement agent may be launched"
  stop_dir_process "$raw_pid"
  pass "fm-spawn --relaunch: refuses and names a raw-launch worker still working in the worktree"
}

test_relaunch_on_an_incomplete_process_view_refuses_before_the_stop() {
  local dir agent out rc agent_pid=
  dir=$(new_case winview rl99-${RL_RUN})
  add_ship_task "$dir" rl99-${RL_RUN} claude
  cp -p "$dir/home/data/rl99-${RL_RUN}/brief.md" "$dir/brief.orig"
  if agent=$(agent_standin_named "$dir" claude); then
    start_dir_process "$dir/wt" "$agent" 600; agent_pid=$STARTED_PID
    wait_probe_rc "$dir/wt" 0 || fail "the stand-in agent never appeared in the worktree"
  fi
  # Git for Windows: the replacement's launch could only refuse after a stop.
  printf '#!/bin/sh\necho MINGW64_NT-10.0\n' > "$dir/fakebin/uname"
  chmod +x "$dir/fakebin/uname"
  out=$(run_control "$dir" rl99-${RL_RUN} relaunch --note "on windows"); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch whose replacement could only be refused must refuse first"$'\n'"$out"
  assert_contains "$out" "native Windows processes" "the refusal should name the incomplete process view"
  ! grep -Fqx /exit "$dir/fake/literal" || fail "the running agent must not be stopped"
  cmp -s "$dir/brief.orig" "$dir/home/data/rl99-${RL_RUN}/brief.md" || fail "the instructions must be left untouched"
  if [ -n "$agent_pid" ]; then
    assert_contains "$out" "pid $agent_pid (claude)" "the refusal should name the agent it can see"
    stop_dir_process "$agent_pid"
  fi
  pass "fm-control relaunch: an incomplete process view refuses before the agent is stopped"
}

test_relaunch_without_a_cwd_provider_refuses_before_the_stop() {
  local dir out rc path_without_lsof path_without_python
  if [ -e /proc/self/cwd ]; then
    pass "fm-control relaunch without a working-directory source: skipped - this host reads them from /proc"
    return 0
  fi
  dir=$(new_case nolsof rl89-${RL_RUN})
  add_ship_task "$dir" rl89-${RL_RUN} claude
  cp -p "$dir/home/data/rl89-${RL_RUN}/brief.md" "$dir/brief.orig"
  path_without_lsof=$(fm_test_base_path_sans "$PATH" lsof) || fail "could not build a PATH without lsof"
  out=$(PATH="$path_without_lsof" run_control "$dir" rl89-${RL_RUN} relaunch --note "no lsof"); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch whose replacement could only be refused must refuse first"$'\n'"$out"
  assert_contains "$out" "neither /proc nor lsof" "the refusal should name the missing working-directory source"
  ! grep -Fqx /exit "$dir/fake/literal" || fail "the running agent must not be stopped"
  cmp -s "$dir/brief.orig" "$dir/home/data/rl89-${RL_RUN}/brief.md" || fail "the instructions must be left untouched"
  # lsof works but the argv reader does not: the probe could not identify the
  # pane shell left after the stop, so it refuses before the stop too.
  path_without_python=$(fm_test_base_path_sans "$PATH" python3) || fail "could not build a PATH without python3"
  out=$(PATH="$path_without_python" run_control "$dir" rl89-${RL_RUN} relaunch --note "no python3"); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch whose replacement could only be refused must refuse first"$'\n'"$out"
  assert_contains "$out" "argv reader" "the refusal should name the unusable argv reader"
  ! grep -Fqx /exit "$dir/fake/literal" || fail "the running agent must not be stopped"
  cmp -s "$dir/brief.orig" "$dir/home/data/rl89-${RL_RUN}/brief.md" || fail "the instructions must be left untouched"
  pass "fm-control relaunch: a host whose working directories or argv cannot be read refuses before the agent is stopped"
}

test_relaunch_refuses_a_brief_backup_it_cannot_take() {
  local dir out rc
  dir=$(new_case unusablebackup rl97-${RL_RUN})
  add_ship_task "$dir" rl97-${RL_RUN} claude
  cp -p "$dir/home/data/rl97-${RL_RUN}/brief.md" "$dir/brief.orig"
  mkdir -p "$dir/home/state/rl97-${RL_RUN}.control-relaunch.brief-prior"
  out=$(run_control "$dir" rl97-${RL_RUN} relaunch --note "the backup path is a directory"); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch whose instructions cannot be preserved must refuse"$'\n'"$out"
  assert_contains "$out" "could not preserve task rl97-${RL_RUN}'s instructions" "the refusal should say the instructions could not be preserved"
  cmp -s "$dir/brief.orig" "$dir/home/data/rl97-${RL_RUN}/brief.md" \
    || fail "instructions that could not be preserved must never receive the progress note"
  ! grep -Fqx /exit "$dir/fake/literal" || fail "the agent must not be stopped"
  pass "fm-control relaunch: a brief backup that cannot be taken refuses before the note is appended"
}

test_relaunch_refuses_an_agent_still_working_in_the_worktree() {
  local dir agent out rc agent_pid
  dir=$(new_case beside rl90-${RL_RUN})
  add_ship_task "$dir" rl90-${RL_RUN} claude
  agent=$(agent_standin_named "$dir" claude) || {
    pass "fm-control relaunch beside a live agent: skipped - no stand-in survives a rename on this host"
    return 0
  }
  cp -p "$dir/home/data/rl90-${RL_RUN}/brief.md" "$dir/brief.orig"
  start_dir_process "$dir/wt" "$agent" 600; agent_pid=$STARTED_PID
  wait_probe_rc "$dir/wt" 0 || fail "the stand-in agent never appeared in the worktree"
  out=$(run_spawn "$dir" rl90-${RL_RUN} --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "fm-spawn --relaunch must refuse an endpoint that reads alive"$'\n'"$out"
  assert_contains "$out" "a relaunch requires a positively agent-free endpoint" "fm-spawn should refuse on the endpoint state"
  assert_contains "$out" "pid $agent_pid (claude)" "fm-spawn's endpoint-state refusal must name the agent in the worktree"
  printf 'vim' > "$dir/fake/command"
  out=$(run_control "$dir" rl90-${RL_RUN} exit); rc=$?
  expect_code 1 "$rc" "exit must refuse an unattributed endpoint"$'\n'"$out"
  assert_contains "$out" "unattributed endpoint" "exit should refuse the unattributed endpoint"
  assert_contains "$out" "pid $agent_pid (claude)" "exit's unattributed-endpoint refusal must name the agent in the worktree"
  printf 'claude' > "$dir/fake/command"
  : > "$dir/fake/literal"
  out=$(run_control "$dir" rl90-${RL_RUN} relaunch --note "lost its terminal"); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch beside a live agent in the worktree must refuse"$'\n'"$out"
  assert_contains "$out" "pid $agent_pid (claude)" "the refusal must name the live agent's pid"
  assert_contains "$out" "still working in its local copy" "the outcome must not claim no agent is running"
  assert_not_contains "$out" "no agent is running" "an agent is running in the worktree"
  ! grep -Fq "Firstmate operational input waiting: read" "$dir/fake/literal" || fail "no replacement agent may be launched"
  cmp -s "$dir/brief.orig" "$dir/home/data/rl90-${RL_RUN}/brief.md" \
    || fail "the live agent's instructions must be restored byte-exact"
  kill -0 "$agent_pid" 2>/dev/null || fail "the found agent must be left running, never killed"
  stop_dir_process "$agent_pid"
  pass "fm-control relaunch: refuses and names the pid of an agent still working in the worktree"
}

test_relaunch_waits_for_a_stopping_agent_to_finish_exiting() {
  local dir agent out rc agent_pid waiter_pid
  dir=$(new_case settling rl91-${RL_RUN})
  add_ship_task "$dir" rl91-${RL_RUN} claude
  agent=$(agent_standin_named "$dir" claude) || {
    pass "fm-control relaunch after a stopping agent: skipped - no stand-in survives a rename on this host"
    return 0
  }
  start_dir_process "$dir/wt" "$agent" 600; agent_pid=$STARTED_PID
  printf '%s' "$agent_pid" > "$dir/fake/pane-pid"
  printf '%s' "$agent_pid" > "$dir/fake/watch-pid"
  wait_probe_rc "$dir/wt" 0 || fail "the stand-in agent never appeared in the worktree"
  # The stand-in outlives the stop by a few seconds, as a real harness can
  # while it shuts down, so the replacement is due while it still runs.
  (
    i=0
    until grep -Fqx /exit "$dir/fake/literal" 2>/dev/null || [ "$i" -ge 300 ]; do sleep 0.1; i=$((i + 1)); done
    sleep 2
    kill "$agent_pid" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  waiter_pid=$!
  LIVE_PIDS+=("$waiter_pid")
  out=$(RUN_CONTROL_EXIT_WAIT=10 run_control "$dir" rl91-${RL_RUN} relaunch --note "stopped mid-refactor"); rc=$?
  reap_dir_process "$waiter_pid"
  reap_dir_process "$agent_pid"
  expect_code 0 "$rc" "an agent the relaunch stopped must be waited for until it leaves the worktree"$'\n'"$out"
  assert_grep "Firstmate operational input waiting: read" "$dir/fake/literal" "the replacement should have been launched"
  [ "$(cat "$dir/fake/watch-pid-at-launch" 2>/dev/null)" = exited ] \
    || fail "the replacement must arrive only after the stopped agent exited, got: $(cat "$dir/fake/watch-pid-at-launch" 2>/dev/null || echo none)"
  pass "fm-control relaunch: the agent it stopped is waited for until it exits, then replaced"
}

test_relaunch_waits_only_for_the_agent_it_stopped() {
  local dir agent out rc stopped_pid other_pid waiter_pid started
  dir=$(new_case attributed rl94-${RL_RUN})
  add_ship_task "$dir" rl94-${RL_RUN} claude
  agent=$(agent_standin_named "$dir" claude) || {
    pass "fm-control relaunch beside an unrelated agent: skipped - no stand-in survives a rename on this host"
    return 0
  }
  start_dir_process "$dir/wt" "$agent" 600; stopped_pid=$STARTED_PID
  printf '%s' "$stopped_pid" > "$dir/fake/pane-pid"
  start_dir_process "$dir/wt" "$agent" 600; other_pid=$STARTED_PID
  wait_probe_rc "$dir/wt" 0 || fail "the stand-in agents never appeared in the worktree"
  (
    i=0
    until grep -Fqx /exit "$dir/fake/literal" 2>/dev/null || [ "$i" -ge 300 ]; do sleep 0.1; i=$((i + 1)); done
    sleep 1
    kill "$stopped_pid" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  waiter_pid=$!
  LIVE_PIDS+=("$waiter_pid")
  started=$SECONDS
  out=$(RUN_CONTROL_EXIT_WAIT=30 run_control "$dir" rl94-${RL_RUN} relaunch --note "beside an unrelated agent"); rc=$?
  reap_dir_process "$waiter_pid"
  reap_dir_process "$stopped_pid"
  [ $((SECONDS - started)) -lt 20 ] \
    || fail "the relaunch must wait only for the agent it stopped, never the exit wait for an unrelated one (took $((SECONDS - started))s)"
  [ "$rc" -ne 0 ] || fail "a relaunch beside an unrelated live agent must refuse"$'\n'"$out"
  assert_contains "$out" "pid $other_pid (claude)" "the refusal must name the unrelated agent still in the worktree"
  assert_not_contains "$out" "pid $stopped_pid (claude)" "the stopped agent was waited for and is gone"
  ! grep -Fq "Firstmate operational input waiting: read" "$dir/fake/literal" || fail "no replacement agent may be launched"
  stop_dir_process "$other_pid"
  pass "fm-control relaunch: waits for the agent it stopped, not for an unrelated one, then refuses naming it"
}

test_relaunch_stopping_rollback_reports_a_survivor_in_the_worktree() {
  local dir agent out rc agent_pid real_mv
  dir=$(new_case survivor rl95-${RL_RUN})
  add_ship_task "$dir" rl95-${RL_RUN} claude
  agent=$(agent_standin_named "$dir" claude) || {
    pass "fm-control relaunch stopping rollback beside a survivor: skipped - no stand-in survives a rename on this host"
    return 0
  }
  cp -p "$dir/home/data/rl95-${RL_RUN}/brief.md" "$dir/brief.orig"
  start_dir_process "$dir/wt" "$agent" 600; agent_pid=$STARTED_PID
  wait_probe_rc "$dir/wt" 0 || fail "the stand-in agent never appeared in the worktree"
  # The endpoint's own agent stops, but the transaction cannot record that it
  # did, so the rollback runs from `stopping` while another agent survives.
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_JOURNAL_PHASE_MV_FAIL=exited \
    run_control "$dir" rl95-${RL_RUN} relaunch --note "survivor in the worktree"); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch whose exited phase cannot be recorded must fail"$'\n'"$out"
  [ "$(journal_field "$dir" rl95-${RL_RUN} phase)" = failed:stopping ] \
    || fail "the rollback should run from the stopping phase, got $(journal_field "$dir" rl95-${RL_RUN} phase)"
  assert_contains "$out" "pid $agent_pid (claude)" "the stopping rollback must name the agent still in the worktree"
  assert_not_contains "$out" "no agent is running" "an agent is running in the worktree"
  cmp -s "$dir/brief.orig" "$dir/home/data/rl95-${RL_RUN}/brief.md" \
    || fail "the surviving agent's instructions must be restored byte-exact"
  stop_dir_process "$agent_pid"
  pass "fm-control relaunch: a rollback from stopping reports and restores for an agent surviving in the worktree"
}

test_relaunch_rollback_never_restores_an_earlier_relaunch_backup() {
  local dir out rc
  dir=$(new_case stalebrief rl96-${RL_RUN})
  add_ship_task "$dir" rl96-${RL_RUN} claude
  cp -p "$dir/home/data/rl96-${RL_RUN}/brief.md" "$dir/brief.orig"
  # An earlier relaunch left its backup behind; this one fails before it
  # takes its own, because its progress note cannot be written.
  printf '# an earlier relaunch'"'"'s instructions\n' > "$dir/home/state/rl96-${RL_RUN}.control-relaunch.brief-prior"
  mkdir -p "$dir/home/state/rl96-${RL_RUN}.control-relaunch.note"
  out=$(run_control "$dir" rl96-${RL_RUN} relaunch --note "cannot be written"); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch whose note cannot be written must fail"$'\n'"$out"
  cmp -s "$dir/brief.orig" "$dir/home/data/rl96-${RL_RUN}/brief.md" \
    || fail "the current instructions must never be replaced by an earlier relaunch's backup"$'\n'"$(cat "$dir/home/data/rl96-${RL_RUN}/brief.md")"
  pass "fm-control relaunch: a rollback never restores a backup it did not take"
}

test_relaunch_refusal_of_an_unprovable_absence_names_the_worktree_agent() {
  local dir agent out rc agent_pid recorded_pid
  dir=$(new_case unprovable rl93-${RL_RUN})
  add_ship_task "$dir" rl93-${RL_RUN} claude
  agent=$(agent_standin_named "$dir" claude) || {
    pass "relaunch refusal of an unprovable absence: skipped - no stand-in survives a rename on this host"
    return 0
  }
  # The double tmux server fault: the recorded server still runs the agent,
  # while the server this process addresses on the same socket lacks its window.
  start_tmux_named_process "$dir"; recorded_pid=$TMUX_NAMED_PID
  start_tmux_named_process "$dir/replacement"
  record_tmux_server "$dir" rl93-${RL_RUN} "$recorded_pid:1700000000"
  serve_tmux_from "$dir" "$TMUX_NAMED_PID:1700000001"
  strand_endpoint "$dir" rl93-${RL_RUN}
  start_dir_process "$dir/wt" "$agent" 600; agent_pid=$STARTED_PID
  wait_probe_rc "$dir/wt" 0 || fail "the stand-in agent never appeared in the worktree"
  out=$(run_spawn "$dir" rl93-${RL_RUN} --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "fm-spawn --relaunch must refuse an endpoint it cannot prove absent"$'\n'"$out"
  assert_contains "$out" "cannot be proven absent" "fm-spawn should refuse on the endpoint check"
  assert_contains "$out" "pid $agent_pid (claude)" "fm-spawn's endpoint refusal must name the agent still in the worktree"
  out=$(run_control "$dir" rl93-${RL_RUN} exit); rc=$?
  expect_code 1 "$rc" "exit must refuse an endpoint it cannot prove absent"$'\n'"$out"
  assert_contains "$out" "pid $agent_pid (claude)" "exit's endpoint refusal must name the agent still in the worktree"
  out=$(run_control "$dir" rl93-${RL_RUN} relaunch --note "after the server fault"); rc=$?
  expect_code 1 "$rc" "relaunch must refuse an endpoint it cannot prove absent"$'\n'"$out"
  assert_contains "$out" "pid $agent_pid (claude)" "relaunch's endpoint refusal must name the agent still in the worktree"
  [ ! -s "$dir/fake/literal" ] || fail "no replacement agent may be launched"
  stop_dir_process "$agent_pid"
  pass "relaunch and exit: refusing an unprovable endpoint absence names the agent still in the worktree"
}

test_spawn_relaunch_refuses_when_the_worktree_probe_is_inconclusive() {
  local dir out rc
  if [ -e /proc/self/cwd ]; then
    pass "fm-spawn --relaunch inconclusive probe: skipped - this host reads working directories from /proc, not lsof"
    return 0
  fi
  dir=$(new_case inconclusive rl92-${RL_RUN})
  add_ship_task "$dir" rl92-${RL_RUN} claude
  printf 'zsh' > "$dir/fake/command"
  printf '#!/bin/sh\nprintf "p1\\nn/\\n"\nexit 1\n' > "$dir/fakebin/lsof"
  chmod +x "$dir/fakebin/lsof"
  out=$(run_spawn "$dir" rl92-${RL_RUN} --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "an inconclusive worktree probe must refuse the relaunch"$'\n'"$out"
  assert_contains "$out" "could not establish whether an agent process is still working" "the refusal should say the probe was inconclusive"
  assert_contains "$out" "lsof can" "a failed lsof that listed some rows must still refuse, naming lsof as the cause"
  ! grep -Fq "Firstmate operational input waiting: read" "$dir/fake/literal" || fail "no replacement agent may be launched"
  pass "fm-spawn --relaunch: an inconclusive worktree probe refuses rather than launching"
}

test_secondmate_respawn_refuses_an_agent_still_working_in_its_home() {
  local dir home agent out rc agent_pid
  dir=$(new_case smbeside sm90-${RL_RUN})
  home="$dir/home"
  agent=$(agent_standin_named "$dir" codex) || {
    pass "fm-spawn --secondmate beside a live agent: skipped - no stand-in survives a rename on this host"
    return 0
  }
  mkdir -p "$home/data/sm90-${RL_RUN}"
  printf '# secondmate brief\n' > "$home/data/sm90-${RL_RUN}/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf '%s\n' "sm90-${RL_RUN}" > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  printf '%s\n' "fm-sm90-${RL_RUN}" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'zsh' > "$dir/fake/command"
  start_dir_process "$dir/smhome" "$agent" 600; agent_pid=$STARTED_PID
  wait_probe_rc "$dir/smhome" 0 || fail "the stand-in agent never appeared in the secondmate home"
  # A task record that is a symlink is never read, even with the home given.
  printf 'harness=codex\nhome=%s\n' "$dir/smhome" > "$dir/foreign.meta"
  mkdir -p "$home/state"
  ln -s "$dir/foreign.meta" "$home/state/sm90-${RL_RUN}.meta"
  out=$(run_spawn "$dir" sm90-${RL_RUN} "$dir/smhome" --secondmate claude); rc=$?
  expect_code 1 "$rc" "a symlinked secondmate task record must refuse"$'\n'"$out"
  assert_contains "$out" "secondmate task record is unsafe" "the refusal should name the unsafe record"
  rm -f "$home/state/sm90-${RL_RUN}.meta"
  out=$(run_spawn "$dir" sm90-${RL_RUN} "$dir/smhome" --secondmate claude); rc=$?
  expect_code 1 "$rc" "a secondmate respawn beside its live agent must refuse"$'\n'"$out"
  assert_contains "$out" "the secondmate home" "the refusal should name the secondmate home"
  assert_contains "$out" "pid $agent_pid (codex)" "the refusal must name the live agent's pid"
  ! grep -Fq "Firstmate operational input waiting: read" "$dir/fake/literal" || fail "no second secondmate may be launched"
  stop_dir_process "$agent_pid"
  wait_probe_rc "$dir/smhome" 1 || fail "the stand-in agent should be gone"
  : > "$dir/fake/literal"
  : > "$dir/fake/windows"
  register_task_tmp "sm90-${RL_RUN}" "$dir/home"
  out=$(run_spawn "$dir" sm90-${RL_RUN} "$dir/smhome" --secondmate claude); rc=$?
  expect_code 0 "$rc" "once its agent has exited, the secondmate respawn must succeed"$'\n'"$out"
  assert_grep "Firstmate operational input waiting: read" "$dir/fake/literal" "the respawn should deliver the replacement launch"
  pass "fm-spawn --secondmate: refuses and names the pid of an agent still working in the home"
}
test_worktree_agent_probe_finds_only_agents_working_there
test_worktree_agent_probe_names_an_agent_beside_an_unreadable_process
test_worktree_agent_probe_counts_only_what_the_task_launched
test_worktree_agent_probe_survives_a_denied_ps_and_a_partial_listing
test_relaunch_on_an_incomplete_process_view_refuses_before_the_stop
test_relaunch_without_a_cwd_provider_refuses_before_the_stop
test_relaunch_refuses_a_brief_backup_it_cannot_take
test_relaunch_refuses_a_raw_launch_worker_still_in_the_worktree
test_relaunch_refuses_an_agent_still_working_in_the_worktree
test_relaunch_waits_for_a_stopping_agent_to_finish_exiting
test_relaunch_waits_only_for_the_agent_it_stopped
test_relaunch_stopping_rollback_reports_a_survivor_in_the_worktree
test_relaunch_rollback_never_restores_an_earlier_relaunch_backup
test_relaunch_refusal_of_an_unprovable_absence_names_the_worktree_agent
test_spawn_relaunch_refuses_when_the_worktree_probe_is_inconclusive
test_secondmate_respawn_refuses_an_agent_still_working_in_its_home
