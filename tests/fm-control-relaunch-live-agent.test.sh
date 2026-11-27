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
#   (the probe's own process identification lives in
#   tests/fm-agent-process-probe.test.sh)
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

test_relaunch_beside_an_unreadable_worktree_process_refuses_before_the_stop() {
  local dir agent out rc agent_pid other_pid real_python
  if [ -e /proc/self/cwd ] || ! real_python=$(command -v python3); then
    pass "fm-control relaunch beside an unreadable process: skipped - this host does not read argv through bin/fm-procinfo.py"
    return 0
  fi
  dir=$(new_case unreadable rl88-${RL_RUN})
  add_ship_task "$dir" rl88-${RL_RUN} claude
  cp -p "$dir/home/data/rl88-${RL_RUN}/brief.md" "$dir/brief.orig"
  agent=$(agent_standin_named "$dir" claude) || {
    pass "fm-control relaunch beside an unreadable process: skipped - no stand-in survives a rename on this host"
    return 0
  }
  # The endpoint's own agent is verified; another process in the worktree
  # cannot be identified, as a protected process cannot.
  start_dir_process "$dir/wt" "$agent" 600; agent_pid=$STARTED_PID
  printf '%s' "$agent_pid" > "$dir/fake/pane-pid"
  start_dir_process "$dir/wt" /bin/sleep 600; other_pid=$STARTED_PID
  wait_probe_rc "$dir/wt" 0 || fail "the stand-in agent never appeared in the worktree"
  printf '#!/bin/sh\n[ "$3" = "%s" ] && exit 1\nexec "%s" "$@"\n' "$other_pid" "$real_python" > "$dir/fakebin/python3"
  chmod +x "$dir/fakebin/python3"
  out=$(run_control "$dir" rl88-${RL_RUN} relaunch --note "beside an unreadable process"); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch whose replacement could only be refused must refuse first"$'\n'"$out"
  assert_contains "$out" "refused before its agent was touched" "the refusal should come before the stop"
  assert_contains "$out" "$other_pid" "the refusal should name the process it could not identify"
  ! grep -Fqx /exit "$dir/fake/literal" || fail "the running agent must not be stopped"
  cmp -s "$dir/brief.orig" "$dir/home/data/rl88-${RL_RUN}/brief.md" || fail "the instructions must be left untouched"
  stop_dir_process "$agent_pid"
  stop_dir_process "$other_pid"
  pass "fm-control relaunch: an unidentifiable worktree process refuses before the agent is stopped"
}

test_early_relaunch_refusals_name_an_agent_still_in_the_worktree() {
  local dir agent out rc agent_pid holder case_name
  for case_name in missing-note-file malformed-config data-override secondmate-lock; do
    dir=$(new_case "early-$case_name" rl87-${RL_RUN})
    agent=$(agent_standin_named "$dir" claude) || {
      pass "early relaunch refusals beside a live agent: skipped - no stand-in survives a rename on this host"
      return 0
    }
    case "$case_name" in
      missing-note-file)
        add_ship_task "$dir" rl87-${RL_RUN} claude
        start_dir_process "$dir/wt" "$agent" 600; agent_pid=$STARTED_PID
        wait_probe_rc "$dir/wt" 0 || fail "the stand-in agent never appeared in the worktree"
        out=$(run_control "$dir" rl87-${RL_RUN} relaunch --note-file "$dir/no-such-note"); rc=$?
        expect_code 1 "$rc" "a missing note file keeps its refusal status"$'\n'"$out"
        assert_contains "$out" "is not a readable file" "the refusal keeps its own reason"
        ;;
      malformed-config)
        add_ship_task "$dir" rl87-${RL_RUN} claude
        printf 'zsh' > "$dir/fake/command"
        mkdir -p "$dir/home/config"
        printf 'bogus\n' > "$dir/home/config/claude-permission-mode"
        start_dir_process "$dir/wt" "$agent" 600; agent_pid=$STARTED_PID
        wait_probe_rc "$dir/wt" 0 || fail "the stand-in agent never appeared in the worktree"
        out=$(run_spawn "$dir" rl87-${RL_RUN} --relaunch --harness claude); rc=$?
        expect_code 1 "$rc" "a malformed launch configuration keeps its refusal status"$'\n'"$out"
        assert_contains "$out" "config/claude-permission-mode holds 'bogus'" "the refusal keeps its own reason"
        ;;
      data-override)
        add_ship_task "$dir" rl87-${RL_RUN} claude
        printf 'zsh' > "$dir/fake/command"
        start_dir_process "$dir/wt" "$agent" 600; agent_pid=$STARTED_PID
        wait_probe_rc "$dir/wt" 0 || fail "the stand-in agent never appeared in the worktree"
        out=$(FM_DATA_OVERRIDE=no-such-relative-data run_spawn "$dir" rl87-${RL_RUN} --relaunch --harness claude); rc=$?
        expect_code 1 "$rc" "an unresolvable data directory keeps its refusal status"$'\n'"$out"
        assert_contains "$out" "FM_DATA_OVERRIDE directory cannot be resolved" "the refusal keeps its own reason"
        ;;
      secondmate-lock)
        mkdir -p "$dir/smhome" "$dir/home/data/rl87-${RL_RUN}"
        printf '%s\n' "rl87-${RL_RUN}" > "$dir/smhome/.fm-secondmate-home"
        printf '# secondmate brief\n' > "$dir/home/data/rl87-${RL_RUN}/brief.md"
        printf 'window=fmses:fm-rl87-%s\nkind=secondmate\nharness=claude\nworktree=%s\nhome=%s\n' \
          "$RL_RUN" "$dir/smhome" "$dir/smhome" > "$dir/home/state/rl87-${RL_RUN}.meta"
        start_dir_process "$dir/smhome" "$agent" 600; agent_pid=$STARTED_PID
        wait_probe_rc "$dir/smhome" 0 || fail "the stand-in agent never appeared in the secondmate home"
        holder=$(hold_home_task_set_lock "$dir")
        out=$(run_spawn "$dir" rl87-${RL_RUN} "$dir/smhome" --secondmate claude); rc=$?
        kill "$holder" 2>/dev/null || true
        wait "$holder" 2>/dev/null || true
        expect_code 1 "$rc" "a lost task-set lock keeps its refusal status"$'\n'"$out"
        assert_contains "$out" "task set is locked" "the refusal keeps its own reason"
        ;;
    esac
    assert_contains "$out" "pid $agent_pid (claude)" "the $case_name refusal must also name the agent still in the worktree"
    ! grep -Fq "Firstmate operational input waiting: read" "$dir/fake/literal" || fail "no replacement agent may be launched ($case_name)"
    stop_dir_process "$agent_pid"
  done
  pass "early relaunch refusals (missing note file, malformed configuration, unresolvable data directory, lost task-set lock) name the agent still in the worktree"
}

test_refusal_note_never_reads_a_foreign_state_directory() {
  local dir agent out rc agent_pid
  dir=$(new_case foreign rl86-${RL_RUN})
  add_ship_task "$dir" rl86-${RL_RUN} claude
  agent=$(agent_standin_named "$dir" claude) || {
    pass "refusal note and a foreign state directory: skipped - no stand-in survives a rename on this host"
    return 0
  }
  start_dir_process "$dir/wt" "$agent" 600; agent_pid=$STARTED_PID
  wait_probe_rc "$dir/wt" 0 || fail "the stand-in agent never appeared in the worktree"
  # This home's state directory is a symlink into another home's state.
  mv "$dir/home/state" "$dir/other-state"
  ln -s "$dir/other-state" "$dir/home/state"
  out=$(run_spawn "$dir" rl86-${RL_RUN} --relaunch --harness claude); rc=$?
  [ "$rc" -ne 0 ] || fail "a symlinked state directory must refuse"$'\n'"$out"
  assert_contains "$out" "state directory" "the refusal should name the unsafe state directory"
  assert_not_contains "$out" "pid $agent_pid" "a refusal must never report another home's task record"
  out=$(run_control "$dir" rl86-${RL_RUN} exit); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-control must refuse a symlinked state directory"$'\n'"$out"
  assert_contains "$out" "not a real directory" "fm-control should name the unsafe state directory"
  assert_not_contains "$out" "pid $agent_pid" "fm-control must never report another home's task record"
  # A relative FM_STATE_OVERRIDE naming the symlink is refused before it is
  # resolved away.
  local spelling
  for spelling in home/state home/state/ home/state// home/state/.; do
    out=$(cd "$dir" && FM_STATE_OVERRIDE=$spelling run_spawn "$dir" rl86-${RL_RUN} --relaunch --harness claude); rc=$?
    [ "$rc" -ne 0 ] || fail "a relative state override '$spelling' naming a symlink must refuse"$'\n'"$out"
    assert_contains "$out" "state directory is not a real directory" "the refusal should name the unsafe state override '$spelling'"
    assert_not_contains "$out" "pid $agent_pid" "a refusal must never report another home's task record ($spelling)"
    out=$(FM_STATE_OVERRIDE="$dir/$spelling" run_control "$dir" rl86-${RL_RUN} exit); rc=$?
    [ "$rc" -ne 0 ] || fail "fm-control must refuse the state override '$spelling'"$'\n'"$out"
    assert_contains "$out" "not a real directory" "fm-control should name the unsafe state override '$spelling'"
    assert_not_contains "$out" "pid $agent_pid" "fm-control must never report another home's task record ($spelling)"
  done
  rm "$dir/home/state"
  mv "$dir/other-state" "$dir/home/state"
  # A real state directory reached through a link to another home is that
  # home's state, however the override spells it.
  mkdir "$dir/foreign"
  cp -R "$dir/home/state" "$dir/foreign/state"
  ln -s "$dir/foreign" "$dir/home/other"
  out=$(cd "$dir" && FM_STATE_OVERRIDE=home/other/state run_spawn "$dir" rl86-${RL_RUN} --relaunch --harness claude); rc=$?
  [ "$rc" -ne 0 ] || fail "a state override through a linked home must refuse"$'\n'"$out"
  assert_contains "$out" "resolves outside this home" "the refusal should name the escaping state override"
  assert_not_contains "$out" "pid $agent_pid" "a refusal must never report a linked home's task record"
  out=$(FM_STATE_OVERRIDE="$dir/home/other/state" run_control "$dir" rl86-${RL_RUN} exit); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-control must refuse a state override through a linked home"$'\n'"$out"
  assert_contains "$out" "resolves outside this home" "fm-control should name the escaping state override"
  assert_not_contains "$out" "pid $agent_pid" "fm-control must never report a linked home's task record"
  out=$(cd "$dir" && FM_STATE_OVERRIDE=./home//other/./state run_spawn "$dir" rl86-${RL_RUN} --relaunch --harness claude); rc=$?
  [ "$rc" -ne 0 ] || fail "a dotted spelling of a state override through a linked home must refuse"$'\n'"$out"
  assert_contains "$out" "resolves outside this home" "the refusal should name the escaping dotted override"
  assert_not_contains "$out" "pid $agent_pid" "a dotted spelling must never report a linked home's task record"
  out=$(FM_STATE_OVERRIDE="$dir/./home/other/state" run_control "$dir" rl86-${RL_RUN} exit); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-control must refuse a dotted state override through a linked home"$'\n'"$out"
  assert_contains "$out" "resolves outside this home" "fm-control should name the escaping dotted override"
  assert_not_contains "$out" "pid $agent_pid" "fm-control must never report a linked home's task record for a dotted spelling"
  out=$(FM_STATE_OVERRIDE="$dir/home/other/fresh-state" run_spawn "$dir" rl86-${RL_RUN} --relaunch --harness claude); rc=$?
  [ "$rc" -ne 0 ] || fail "a fresh state override beneath a linked home must refuse"$'\n'"$out"
  assert_contains "$out" "resolves outside this home" "the refusal should name the escaping fresh override"
  [ ! -e "$dir/foreign/fresh-state" ] || fail "a refused override must never create state inside a linked home"
  out=$(cd "$dir/home" && RUN_FM_HOME=. FM_STATE_OVERRIDE=other/state run_control "$dir" rl86-${RL_RUN} exit); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-control must refuse a linked state override beside a relative home"$'\n'"$out"
  assert_contains "$out" "resolves outside this home" "fm-control should name the linked override beside a relative home"
  assert_not_contains "$out" "pid $agent_pid" "a relative home must never report a linked home's task record"
  ln -s "$dir/home" "$dir/home-alias"
  out=$(cd "$dir/home-alias" && FM_STATE_OVERRIDE=other/state run_spawn "$dir" rl86-${RL_RUN} --relaunch --harness claude); rc=$?
  [ "$rc" -ne 0 ] || fail "a linked state override from a symlinked working directory must refuse"$'\n'"$out"
  assert_contains "$out" "resolves outside this home" "the refusal should name the linked override reached through an aliased directory"
  assert_not_contains "$out" "pid $agent_pid" "an aliased working directory must never report a linked home's task record"
  rm "$dir/home-alias"
  out=$(FM_STATE_OVERRIDE="$dir/home/fresh/../other/new-state" run_spawn "$dir" rl86-${RL_RUN} --relaunch --harness claude); rc=$?
  [ "$rc" -ne 0 ] || fail "a parent step through a part that does not exist yet must refuse"$'\n'"$out"
  assert_contains "$out" "does not exist yet" "the refusal should name the unresolved parent step"
  [ ! -e "$dir/foreign/new-state" ] && [ ! -e "$dir/home/fresh" ] \
    || fail "a refused override must never create state through an unresolved parent step"
  mkdir "$dir/home/group"
  mv "$dir/home/other" "$dir/home/group/other"
  ln -s "$dir/home/group" "$dir/group-alias"
  out=$(FM_STATE_OVERRIDE="$dir/group-alias/other/state" run_control "$dir" rl86-${RL_RUN} exit); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-control must refuse an alias into this home that then leaves through a link"$'\n'"$out"
  assert_contains "$out" "resolves outside this home" "fm-control should name the override that enters through an alias"
  assert_not_contains "$out" "pid $agent_pid" "an alias into this home must never report a linked home's task record"
  rm "$dir/group-alias"
  mv "$dir/home/group/other" "$dir/home/other"
  rmdir "$dir/home/group"
  rm "$dir/home/other"
  # A parent step that lands on this home's own state is this home's state.
  mkdir -p "$dir/home/bin"
  out=$(cd "$dir/home/bin" && FM_STATE_OVERRIDE=../state run_spawn "$dir" rl86-${RL_RUN} --relaunch --harness claude); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch beside the live agent must still refuse"$'\n'"$out"
  assert_not_contains "$out" "resolves outside this home" "../state from the home's bin directory is this home's own state"
  assert_contains "$out" "pid $agent_pid (claude)" "a relaunch through ../state must still name the agent in the worktree"
  # A relative override is used exactly where the containment check found it:
  # alias/.. is the alias target's parent, never this home.
  mkdir -p "$dir/home/nested/leaf" "$dir/home/nested/linked-state"
  ln -s "$dir/home/nested/leaf" "$dir/home/alias"
  ln -s "$dir/foreign/state" "$dir/home/linked-state"
  out=$(cd "$dir/home" && FM_STATE_OVERRIDE=alias/../linked-state run_spawn "$dir" rl86-${RL_RUN} --relaunch --harness claude); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch from an empty state directory must refuse"$'\n'"$out"
  assert_contains "$out" "no $dir/home/nested/linked-state/rl86-${RL_RUN}.meta" "the override must be read from the directory the check evaluated"$'\n'"$out"
  assert_not_contains "$out" "pid $agent_pid" "alias/.. must never reach a linked home's task record"
  # The absolute spelling of that path is used the same way, by both commands.
  out=$(FM_STATE_OVERRIDE="$dir/home/alias/../linked-state" run_spawn "$dir" rl86-${RL_RUN} --relaunch --harness claude); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch from an empty absolute state directory must refuse"$'\n'"$out"
  assert_contains "$out" "/home/nested/linked-state/rl86-${RL_RUN}.meta" "spawn must use the physical directory the check evaluated"$'\n'"$out"
  assert_not_contains "$out" "alias/../linked-state/rl86-${RL_RUN}.meta" "spawn must not keep a spelling a later logical cd could redirect"
  assert_not_contains "$out" "pid $agent_pid" "an absolute alias/.. must never reach a linked home's task record"
  out=$(FM_STATE_OVERRIDE="$dir/home/alias/../linked-state" run_control "$dir" rl86-${RL_RUN} exit); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-control must refuse a task absent from the evaluated state directory"$'\n'"$out"
  assert_contains "$out" "/home/nested/linked-state" "fm-control must use the physical directory the check evaluated"$'\n'"$out"
  assert_not_contains "$out" "alias/../linked-state" "fm-control must not keep a spelling a later logical cd could redirect"
  assert_not_contains "$out" "pid $agent_pid" "fm-control must never reach a linked home's task record through alias/.."
  rm "$dir/home/alias" "$dir/home/linked-state"
  rm -rf "$dir/home/nested"
  out=$(FM_STATE_OVERRIDE="$dir/home/state/fresh-leaf" run_spawn "$dir" rl86-${RL_RUN} --relaunch --harness claude); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch from a fresh state directory must refuse"$'\n'"$out"
  [ -d "$dir/home/state/fresh-leaf" ] || fail "a fresh state override inside this home should be created"$'\n'"$out"
  assert_contains "$out" "needs an existing task record; no $dir/home/state/fresh-leaf/rl86-${RL_RUN}.meta" "a fresh state directory holds no record of the task"$'\n'"$out"
  assert_not_contains "$out" "pid $agent_pid" "a fresh state directory must never report the default state's worker"
  # A record that names two worktrees is no evidence about which agent is its.
  printf 'worktree=%s\n' "$dir/wt" >> "$dir/home/state/rl86-${RL_RUN}.meta"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl86-${RL_RUN} --relaunch --harness claude); rc=$?
  [ "$rc" -ne 0 ] || fail "an ambiguous record must refuse"$'\n'"$out"
  assert_not_contains "$out" "pid $agent_pid" "an ambiguous record must never attribute a worker's pid"
  stop_dir_process "$agent_pid"
  pass "refusal note: a symlinked state directory or an ambiguous record is never read for the survivor diagnostic"
}

test_refusal_survivor_reaches_first_line_summaries() {
  local dir agent out rc agent_pid holder summary
  dir=$(new_case summary rl85-${RL_RUN})
  agent=$(agent_standin_named "$dir" claude) || {
    pass "survivor in first-line summaries: skipped - no stand-in survives a rename on this host"
    return 0
  }
  # The automatic recovery the session-start and watcher sweeps share
  # (bin/fm-secondmate-liveness-lib.sh), refused because the task set is locked.
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-summary
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin" "$dir/home/data/rl85-${RL_RUN}"
  printf '%s\n' "rl85-${RL_RUN}" > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  printf '# secondmate brief\n' > "$dir/home/data/rl85-${RL_RUN}/brief.md"
  printf 'window=fmses:fm-rl85-%s\nkind=secondmate\nharness=claude\nworktree=%s\nhome=%s\n' \
    "$RL_RUN" "$dir/smhome" "$dir/smhome" > "$dir/home/state/rl85-${RL_RUN}.meta"
  start_dir_process "$dir/smhome" "$agent" 600; agent_pid=$STARTED_PID
  wait_probe_rc "$dir/smhome" 0 || fail "the stand-in agent never appeared in the secondmate home"
  holder=$(hold_home_task_set_lock "$dir")
  # shellcheck disable=SC2016
  summary=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT="$ROOT" STATE="$dir/home/state" HOME="$dir/user-home" \
    bash -c '. "$1/bin/fm-ff-lib.sh"; . "$1/bin/fm-secondmate-liveness-lib.sh"
      FM_SM_LIVE_KILL=0 FM_SM_LIVE_RESUME=0 FM_SM_LIVE_STATE=missing
      fm_secondmate_liveness_relaunch "$2" "$3" || true
      printf "bootstrap: %s\n" "$(first_line "$FM_SM_LIVE_OUT")"
      printf "watch: %s\n" "$(fm_sm_live_first_line "$FM_SM_LIVE_OUT")"' _ "$ROOT" "$dir/home/state/rl85-${RL_RUN}.meta" rl85-${RL_RUN} 2>&1)
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  assert_contains "$(printf '%s\n' "$summary" | grep '^bootstrap: ')" "pid $agent_pid (claude)" "the session-start summary must carry the survivor pid"$'\n'"$summary"
  assert_contains "$(printf '%s\n' "$summary" | grep '^bootstrap: ')" "task set is locked" "the session-start summary must keep the refusal reason"
  assert_contains "$(printf '%s\n' "$summary" | grep '^watch: ')" "pid $agent_pid (claude)" "the watcher summary must carry the survivor pid"$'\n'"$summary"
  # A recovery skipped before any spawn (here a dangling, so unreadable,
  # relaunch ledger)
  # names the survivor on the skip-reason line both sweeps publish.
  ln -sf "$dir/no-such-ledger" "$dir/home/state/.secondmate-relaunch-rl85-${RL_RUN}"
  # shellcheck disable=SC2016
  summary=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT="$ROOT" STATE="$dir/home/state" HOME="$dir/user-home" \
    bash -c '. "$1/bin/fm-ff-lib.sh"; . "$1/bin/fm-secondmate-liveness-lib.sh"
      FM_SM_LIVE_KILL=0 FM_SM_LIVE_RESUME=0 FM_SM_LIVE_STATE=missing
      rc=0; fm_secondmate_liveness_relaunch "$2" "$3" || rc=$?
      printf "rc: %s status: %s\nreason: %s\n" "$rc" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_REASON"' _ "$ROOT" "$dir/home/state/rl85-${RL_RUN}.meta" rl85-${RL_RUN} 2>&1)
  rm -f "$dir/home/state/.secondmate-relaunch-rl85-${RL_RUN}"
  assert_contains "$summary" "rc: 1 status: skipped" "an unreadable ledger keeps its skipped verdict and status"$'\n'"$summary"
  assert_contains "$(printf '%s\n' "$summary" | grep '^reason: ')" "is unreadable; endpoint left missing" "the skip keeps its own reason"$'\n'"$summary"
  assert_contains "$(printf '%s\n' "$summary" | grep '^reason: ')" "pid $agent_pid (claude)" "the skip reason must name the agent still in the home"$'\n'"$summary"
  # The home probe itself refuses, after a warning that leads the output.
  mkdir -p "$dir/home/config"
  printf 'claude default not-an-effort\n' > "$dir/home/config/secondmate-harness"
  printf '%s\n' "fm-rl85-${RL_RUN}" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'zsh' > "$dir/fake/command"
  # shellcheck disable=SC2016
  summary=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT="$ROOT" STATE="$dir/home/state" HOME="$dir/user-home" FM_FAKE_DIR="$dir/fake" \
    bash -c '. "$1/bin/fm-ff-lib.sh"; . "$1/bin/fm-secondmate-liveness-lib.sh"
      FM_SM_LIVE_KILL=0 FM_SM_LIVE_RESUME=0 FM_SM_LIVE_STATE=missing
      fm_secondmate_liveness_relaunch "$2" "$3" || true
      printf "bootstrap: %s\n" "$(first_line "$FM_SM_LIVE_OUT")"
      printf "watch: %s\n" "$(fm_sm_live_first_line "$FM_SM_LIVE_OUT")"' _ "$ROOT" "$dir/home/state/rl85-${RL_RUN}.meta" rl85-${RL_RUN} 2>&1)
  assert_contains "$(printf '%s\n' "$summary" | grep '^bootstrap: ')" "pid $agent_pid (claude)" "the session-start summary must carry the pid the home probe found"$'\n'"$summary"
  assert_contains "$(printf '%s\n' "$summary" | grep '^watch: ')" "pid $agent_pid (claude)" "the watcher summary must carry the pid the home probe found"$'\n'"$summary"
  stop_dir_process "$agent_pid"
  pass "refusal survivor: the session-start and watcher first-line summaries carry the pid beside the reason"
}

test_relaunch_composer_and_journal_refusals_name_the_survivor() {
  local dir agent out rc agent_pid real_mv
  dir=$(new_case pending rl84-${RL_RUN})
  add_ship_task "$dir" rl84-${RL_RUN} claude
  agent=$(agent_standin_named "$dir" claude) || {
    pass "composer and journal refusals beside a live agent: skipped - no stand-in survives a rename on this host"
    return 0
  }
  start_dir_process "$dir/wt" "$agent" 600; agent_pid=$STARTED_PID
  wait_probe_rc "$dir/wt" 0 || fail "the stand-in agent never appeared in the worktree"
  printf 'half-typed instruction' > "$dir/fake/composer"
  out=$(run_control "$dir" rl84-${RL_RUN} relaunch --note "pending text"); rc=$?
  [ "$rc" -ne 0 ] || fail "a composer holding pending text must refuse the stop"$'\n'"$out"
  assert_contains "$out" "composer state is" "the refusal keeps its own reason"
  assert_contains "$out" "pid $agent_pid (claude)" "the pending-composer refusal must name the agent still in the worktree"
  : > "$dir/fake/composer"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_JOURNAL_PHASE_MV_FAIL=stopping \
    run_control "$dir" rl84-${RL_RUN} relaunch --note "journal fails"); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch whose stopping phase cannot be recorded must fail"$'\n'"$out"
  assert_contains "$out" "pid $agent_pid (claude)" "the journal-write failure must name the agent still in the worktree"
  ! grep -Fqx /exit "$dir/fake/literal" || fail "neither refusal may stop the agent"
  stop_dir_process "$agent_pid"
  pass "fm-control relaunch: pending-composer and journal-write refusals name the agent still in the worktree"
}

test_secondmate_relaunch_checks_the_home_it_launches_in() {
  local dir agent out rc agent_pid
  dir=$(new_case smstale rl83-${RL_RUN})
  add_ship_task "$dir" rl83-${RL_RUN} claude
  agent=$(agent_standin_named "$dir" claude) || {
    pass "secondmate relaunch home check: skipped - no stand-in survives a rename on this host"
    return 0
  }
  # The record's worktree names an empty checkout; its home is where the mate runs.
  fm_git_worktree "$dir/smproj" "$dir/smhome" sm-stale
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf '%s\n' "rl83-${RL_RUN}" > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  sed -i.bak 's/^kind=ship$/kind=secondmate/' "$dir/home/state/rl83-${RL_RUN}.meta"
  rm -f "$dir/home/state/rl83-${RL_RUN}.meta.bak"
  printf 'home=%s\n' "$dir/smhome" >> "$dir/home/state/rl83-${RL_RUN}.meta"
  printf 'zsh' > "$dir/fake/command"
  start_dir_process "$dir/smhome" "$agent" 600; agent_pid=$STARTED_PID
  wait_probe_rc "$dir/smhome" 0 || fail "the stand-in agent never appeared in the secondmate home"
  out=$(run_spawn "$dir" rl83-${RL_RUN} --relaunch --harness claude); rc=$?
  [ "$rc" -ne 0 ] || fail "a secondmate relaunch beside its live agent must refuse"$'\n'"$out"
  assert_contains "$out" "pid $agent_pid (claude)" "the refusal must name the agent working in the home the relaunch would launch in"
  assert_contains "$out" "the secondmate home $dir/smhome" "the refusal should come from the check of the home itself"
  # fm-control reads the same split record: its refusals probe the home too.
  printf 'vim' > "$dir/fake/command"
  out=$(run_control "$dir" rl83-${RL_RUN} exit); rc=$?
  [ "$rc" -ne 0 ] || fail "exit must refuse an unattributed endpoint"$'\n'"$out"
  assert_contains "$out" "pid $agent_pid (claude)" "fm-control must name the agent working in the secondmate's home"
  # A home whose marker names another mate is no evidence about this one.
  printf 'zsh' > "$dir/fake/command"
  printf 'some-other-mate\n' > "$dir/smhome/.fm-secondmate-home"
  out=$(run_spawn "$dir" rl83-${RL_RUN} --relaunch --harness claude); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch into a home marked for another mate must refuse"$'\n'"$out"
  assert_contains "$out" "marked for secondmate some-other-mate" "the refusal should name the mismatched marker"
  assert_not_contains "$out" "pid $agent_pid" "a mismatched home's agent must never be attributed to this task"
  printf 'vim' > "$dir/fake/command"
  out=$(run_control "$dir" rl83-${RL_RUN} exit); rc=$?
  [ "$rc" -ne 0 ] || fail "exit must refuse when the secondmate's home is marked for another mate"$'\n'"$out"
  assert_not_contains "$out" "pid $agent_pid" "fm-control must never attribute a mismatched home's agent"
  # A legacy record names the home in its worktree row; the marker still rules.
  sed -i.bak -e '/^home=/d' -e "s|^worktree=.*|worktree=$dir/smhome|" "$dir/home/state/rl83-${RL_RUN}.meta"
  rm -f "$dir/home/state/rl83-${RL_RUN}.meta.bak"
  out=$(run_control "$dir" rl83-${RL_RUN} exit); rc=$?
  [ "$rc" -ne 0 ] || fail "exit must refuse a legacy record whose home is marked for another mate"$'\n'"$out"
  assert_not_contains "$out" "pid $agent_pid" "fm-control must never attribute a legacy record's mismatched home"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl83-${RL_RUN} --relaunch --harness claude); rc=$?
  [ "$rc" -ne 0 ] || fail "a legacy relaunch into a home marked for another mate must refuse"$'\n'"$out"
  assert_contains "$out" "marked for secondmate some-other-mate" "the legacy refusal should name the mismatched marker"
  assert_not_contains "$out" "pid $agent_pid" "a legacy record's mismatched home must never be attributed"
  printf '%s\n' "rl83-${RL_RUN}" > "$dir/smhome/marker-target"
  rm "$dir/smhome/.fm-secondmate-home"
  ln -s "$dir/smhome/marker-target" "$dir/smhome/.fm-secondmate-home"
  out=$(run_spawn "$dir" rl83-${RL_RUN} --relaunch --harness claude); rc=$?
  [ "$rc" -ne 0 ] || fail "a home whose marker is a symlink must refuse"$'\n'"$out"
  assert_not_contains "$out" "pid $agent_pid" "a symlinked marker must never attribute the home's agent"
  ! grep -Fq "Firstmate operational input waiting: read" "$dir/fake/literal" || fail "no second secondmate may be launched"
  stop_dir_process "$agent_pid"
  pass "fm-spawn --relaunch: a secondmate relaunch checks the home it launches in, not a stale recorded worktree"
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
  assert_contains "$out" "no replacement was launched because an agent is still working in" "the outcome must not claim no agent is running"
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
  local dir out rc real_lsof
  if [ -e /proc/self/cwd ] || ! real_lsof=$(command -v lsof); then
    pass "fm-spawn --relaunch inconclusive probe: skipped - this host does not read working directories through lsof"
    return 0
  fi
  dir=$(new_case inconclusive rl92-${RL_RUN})
  add_ship_task "$dir" rl92-${RL_RUN} claude
  printf 'zsh' > "$dir/fake/command"
  # The provider answers for one process (its self-check passes), but the
  # user-wide enumeration lists only an unrelated cwd record and then fails.
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -u ] && { printf "p1\\nfcwd\\nD0x1\\ni2\\n"; exit 1; }; done\nexec "%s" "$@"\n' "$real_lsof" > "$dir/fakebin/lsof"
  chmod +x "$dir/fakebin/lsof"
  out=$(run_spawn "$dir" rl92-${RL_RUN} --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "an inconclusive worktree probe must refuse the relaunch"$'\n'"$out"
  assert_contains "$out" "could not establish whether an agent process is still working" "the refusal should say the probe was inconclusive"
  assert_contains "$out" "lsof could not list every working directory" "an incomplete listing must refuse, naming the incomplete listing as the cause"
  # The same incomplete listing stops fm-control relaunch before it touches a
  # live endpoint: the replacement could only be refused after the stop.
  printf 'claude' > "$dir/fake/command"
  : > "$dir/fake/literal"
  out=$(run_control "$dir" rl92-${RL_RUN} relaunch --note "incomplete listing"); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch whose replacement could only be refused must refuse first"$'\n'"$out"
  assert_contains "$out" "refused before its agent was touched" "the refusal should come before the stop"
  assert_contains "$out" "lsof could not list every working directory" "the refusal should name the incomplete listing"
  ! grep -Fqx /exit "$dir/fake/literal" || fail "the live agent must not be stopped"
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
test_relaunch_on_an_incomplete_process_view_refuses_before_the_stop
test_relaunch_without_a_cwd_provider_refuses_before_the_stop
test_relaunch_beside_an_unreadable_worktree_process_refuses_before_the_stop
test_early_relaunch_refusals_name_an_agent_still_in_the_worktree
test_refusal_note_never_reads_a_foreign_state_directory
test_refusal_survivor_reaches_first_line_summaries
test_relaunch_composer_and_journal_refusals_name_the_survivor
test_secondmate_relaunch_checks_the_home_it_launches_in
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
