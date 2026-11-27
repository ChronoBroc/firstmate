#!/usr/bin/env bash
# tests/fm-agent-process-probe.test.sh - the worktree probe
# (fm_agent_process_live_in_dir in bin/fm-agent-process-lib.sh) against real
# processes: it finds only agents (and a task's raw-launch executable) working
# in exactly the directory, keeps argv boundaries, identifies without ps, reads
# a partial listing, and is undecided only when no agent was verified. The
# stand-ins are real agent-named processes (tests/lib.sh fm_agent_standin), so
# no harness is needed. The relaunch commands that use this probe are covered
# by tests/fm-control-relaunch-live-agent.test.sh.
set -u

# shellcheck source=tests/relaunch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/relaunch-helpers.sh"

test_worktree_agent_probe_finds_only_agents_working_there() {
  local dir agent out rc agent_pid other_pid sub_pid shell_pid server_pid cursor_pid ui_pid nl_pid
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
  # A link to a sibling whose name ends in a newline is never read as the
  # sibling without it: the probe answers undecided instead.
  mkdir "$dir/slot" "$dir/slot"$'\n'
  ln -s "$dir/slot"$'\n' "$dir/slot-link"
  start_dir_process "$dir/slot"$'\n' "$agent" 600; nl_pid=$STARTED_PID
  rc=0; out=$(fm_agent_process_live_in_dir "$dir/slot-link") || rc=$?
  expect_code 2 "$rc" "a link into a newline-suffixed directory must be undecided, never absent"$'\n'"$out"
  assert_contains "$out" "control character" "the undecided answer should say why"
  stop_dir_process "$nl_pid"
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
  # shellcheck disable=SC2016
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

test_worktree_agent_probe_finds_only_agents_working_there
test_worktree_agent_probe_names_an_agent_beside_an_unreadable_process
test_worktree_agent_probe_counts_only_what_the_task_launched
test_worktree_agent_probe_survives_a_denied_ps_and_a_partial_listing
