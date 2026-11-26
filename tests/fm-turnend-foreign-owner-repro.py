#!/usr/bin/env python3
"""Executable regression for the foreign session-lock owner turn-end loop.

This is adapted from Appendix A of the downstream reproduction report. It
runs the shipped lock, Claude auto-arm, and turn-end guard scripts against
isolated synthetic primary homes and harness-shaped processes.
"""
import json
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
LAB = pathlib.Path(tempfile.mkdtemp(prefix="fm-turnend-foreign-owner-"))
OUT = LAB / "evidence"
OUT.mkdir()
# Basename must be an exact FM_HARNESS_NAMES entry. Linux procps comm= is the
# 15-char kernel name, so "synthetic-claude" becomes "synthetic-claud" and
# never matches the claude regex, so fm-lock.sh exits without writing .lock.
FAKE = LAB / "claude"
FAKE.symlink_to("/bin/bash")
PROCS = []
HOLD = (
    "while kill -0 " + str(os.getpid()) + ' 2>/dev/null && [ "$SECONDS" -lt 600 ]; do sleep 1; done; kill -TERM 0'
)

# The suite may itself run inside a Claude session. Its CLAUDE_CODE_SESSION_ID
# and CLAUDE_PID are scrubbed so the foreign-owner negative control below is
# genuinely id-less; the same-session positive control sets its own.
BASE_ENV = {
    k: v
    for k, v in os.environ.items()
    if not k.startswith(
        ("FM_", "HERDR_", "PI_", "CLAUDE_PROJECT_DIR", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "GROK_", "CURSOR_")
    )
}


def make(name):
    root = LAB / name
    root.mkdir()
    for directory in ("state", "config", "data", "projects"):
        (root / directory).mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True, env=BASE_ENV)
    (root / "AGENTS.md").write_text("Synthetic diagnostic fixture. No fleet or project operations.\n")
    (root / "bin").symlink_to(REPO / "bin", target_is_directory=True)
    (root / "state/task.meta").write_text("project=synthetic\n")
    (root / "state/home-summary.json").write_text("{}\n")
    env = BASE_ENV | {
        "FM_HOME": str(root),
        "FM_ROOT_OVERRIDE": str(root),
        "FM_STATE_OVERRIDE": str(root / "state"),
        "FM_CONFIG_OVERRIDE": str(root / "config"),
        "FM_DATA_OVERRIDE": str(root / "data"),
        "FM_PROJECTS_OVERRIDE": str(root / "projects"),
        "FM_POLL": "1",
        "FM_HEARTBEAT": "999999",
        "FM_HOME_SUMMARY_INTERVAL": "999999",
        "FM_CHECK_INTERVAL": "999999",
        "FM_CLAUDE_AUTOARM_SYNC_WAIT_MS": "0",
    }
    return root, env


def run(env, command):
    return subprocess.run(
        [str(FAKE), "-c", command],
        env=env,
        text=True,
        capture_output=True,
        timeout=30,
    )


def start(env, command, name):
    output = (OUT / name).open("w")
    process = subprocess.Popen(
        [str(FAKE), "-c", command],
        env=env,
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        text=True,
    )
    output.close()
    PROCS.append(process)
    return process


def until(test, seconds=20, message="condition timed out"):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if test():
            return
        time.sleep(0.1)
    raise RuntimeError(message() if callable(message) else message)


def session_lock_text(path):
    try:
        if path.is_symlink() or not path.is_file():
            return None
        text = path.read_text().strip()
    except OSError:
        return None
    return text if text.isdigit() else None


PAYLOAD = json.dumps({"session_id": "synthetic-second", "stop_hook_active": True})


def guard(env, label, prefix=""):
    process = run(
        env,
        prefix + "printf '%s\\n' '" + PAYLOAD + "' | \"$FM_ROOT_OVERRIDE/bin/fm-turnend-guard.sh\" --claude",
    )
    print(label, "rc=" + str(process.returncode), "stdout=" + repr(process.stdout), "stderr=" + repr(process.stderr), flush=True)
    return process


def autoarm(env, label):
    process = run(
        env,
        "printf '%s\\n' '" + PAYLOAD + "' | \"$FM_ROOT_OVERRIDE/bin/fm-claude-stop-autoarm.sh\"; "
        "rc=$?; printf 'autoarm_rc=%s\\n' \"$rc\"; true",
    )
    print(label, "rc=" + str(process.returncode), "stdout=" + repr(process.stdout), "stderr=" + repr(process.stderr), flush=True)
    return process


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


try:
    root, env = make("nonowner")
    owner = start(
        env,
        '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh" && touch "$FM_HOME/state/owner-ready" && ' + HOLD,
        "owner-idle.txt",
    )
    lock_path = root / "state/.lock"
    until(
        lambda: session_lock_text(lock_path) is not None,
        message=lambda: "synthetic owner did not publish a readable state/.lock; owner log="
        + (OUT / "owner-idle.txt").read_text(errors="replace"),
    )
    until(
        lambda: (root / "state/owner-ready").exists(),
        message="synthetic owner published state/.lock but did not reach owner-ready",
    )
    beat = root / "state/.last-watcher-beat"
    beat.touch()
    old_time = time.time() - 600
    os.utime(beat, (old_time, old_time))
    lock_owner = session_lock_text(lock_path)
    require(lock_owner is not None, "state/.lock vanished after the owner-ready wait")
    print("SETUP live synthetic owner=", owner.pid, "lock=", lock_owner, flush=True)

    acquisition = run(
        env,
        '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; rc=$?; printf "lock_rc=%s\\n" "$rc"; true',
    )
    print("second-session acquisition", "rc=" + str(acquisition.returncode), "stdout=" + repr(acquisition.stdout), "stderr=" + repr(acquisition.stderr), flush=True)
    require("lock_rc=1" in acquisition.stdout, "foreign session unexpectedly acquired the session lock")
    require("another live firstmate session holds the lock" in acquisition.stderr, "lock refusal lost its ownership diagnostic")

    auto = autoarm(env, "nonowner autoarm")
    require(auto.returncode == 0, "foreign-owner auto-arm must exit safely")
    require(not (root / "state/.claude-autoarm-epoch").exists(), "foreign-owner auto-arm must not claim a generation")

    for number in range(1, 6):
        result = guard(env, f"nonowner stop {number}")
        require(result.returncode == 0, f"foreign-owner Stop {number} must end safely")
        require("SUPERVISION IS OWNED BY ANOTHER LIVE SESSION: this read-only session" in result.stdout, "foreign-owner Stop lost its clear diagnostic")
        require("cannot and should not arm or repair" in result.stdout, "diagnostic did not explain the safe ownership boundary")
    require(not (root / "state/.turnend-claude-blocks").exists(), "foreign-owner guard must not consume its block budget")
    print("FIXED repeated non-owner Stops: all five ended safely", flush=True)

    beat.touch()
    fresh = guard(env, "fresh-beat-only counterfactual")
    require(fresh.returncode == 0, "a fresh leftover beat must not restore foreign-owner blocking")


    # A live harness-shaped process outside the owner's ancestry that carries
    # the owner's own trusted session id, while the sidecar records the owner as
    # that session's model-loop anchor, is a live twin: a second running copy of
    # the session. Its acquisition is refused with a diagnostic naming the live
    # holder and the unverified continuity, and its Stop ends safely as a
    # non-owner.
    # A sidecar that records the id alone, as every sidecar written before the
    # anchor existed does, proves no continuity either: the twin stays refused.
    # A recorded anchor that has exited proves no continuity either, so the
    # live line 1 is never handed to a same-id process outside its ancestry.
    # Positive control: a process that is itself the recorded model-loop
    # anchor, pid and start time, as a surviving helper is after its chain
    # to line 1 is recycled, continues the session, so the lock accepts it and re-anchors line 1 onto
    # its CLAUDE_PID, keeping the recorded id. A different id against the
    # re-anchored lock keeps the refusal and names the recorded id.
    same, same_env = make("same-session")
    same_env["CLAUDE_CODE_SESSION_ID"] = "synthetic-same"
    same_owner = start(
        same_env,
        'export CLAUDE_PID=$$; "$FM_ROOT_OVERRIDE/bin/fm-lock.sh" && touch "$FM_HOME/state/owner-ready" && ' + HOLD,
        "same-owner.txt",
    )
    same_lock = same / "state/.lock"
    until(
        lambda: session_lock_text(same_lock) is not None,
        message=lambda: "same-session owner did not publish a readable state/.lock; owner log="
        + (OUT / "same-owner.txt").read_text(errors="replace"),
    )
    until(
        lambda: (same / "state/owner-ready").exists(),
        message="same-session owner published state/.lock but did not reach owner-ready",
    )
    same_lock_owner = session_lock_text(same_lock)
    same_beat = same / "state/.last-watcher-beat"
    same_beat.touch()
    os.utime(same_beat, (old_time, old_time))
    twin = run(
        same_env,
        'export CLAUDE_PID=$$; "$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; rc=$?; printf "lock_rc=%s\\n" "$rc"; true',
    )
    print("live-twin acquisition", "rc=" + str(twin.returncode), "stdout=" + repr(twin.stdout), "stderr=" + repr(twin.stderr), flush=True)
    require("lock_rc=1" in twin.stdout, "a live twin of the owner's session took its lock")
    require(
        f"another live process holds the lock under this same session id (pid {same_lock_owner}, session synthetic-same) and this session's continuity with that holder could not be verified" in twin.stderr,
        "the live-twin refusal did not name the owner pid and the shared session id",
    )
    require(session_lock_text(same_lock) == same_lock_owner, "a live twin moved the lock line")
    require(
        (same / "state/.lock-session").read_text().splitlines()[:2] == ["synthetic-same", "anchor=" + same_lock_owner]
        and len((same / "state/.lock-session").read_text().splitlines()) == 3
        and (same / "state/.lock-session").read_text().splitlines()[2].startswith("anchor-start=")
        and len((same / "state/.lock-session").read_text().splitlines()[2]) > len("anchor-start="),
        "the owner did not record its trusted session id and model-loop anchor beside the lock",
    )
    twin_stop = guard(same_env, "live-twin stop", prefix="export CLAUDE_PID=$$; ")
    require(twin_stop.returncode == 0, "a live twin's Stop must end safely")
    require("SUPERVISION IS OWNED BY ANOTHER LIVE SESSION: this read-only session" in twin_stop.stdout, "a live twin's Stop lost the foreign-owner diagnostic")
    print("FIXED a live twin of the owner's session is refused and its Stop ends safely", flush=True)
    (same / "state/.lock-session").write_text("synthetic-same\n")
    id_only = run(
        same_env,
        'export CLAUDE_PID=$$; "$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; rc=$?; printf "lock_rc=%s\\n" "$rc"; true',
    )
    print("id-only sidecar twin acquisition", "rc=" + str(id_only.returncode), "stdout=" + repr(id_only.stdout), "stderr=" + repr(id_only.stderr), flush=True)
    require("lock_rc=1" in id_only.stdout, "a live twin took the owner's lock beside an id-only sidecar")
    require(
        f"another live process holds the lock under this same session id (pid {same_lock_owner}, session synthetic-same) and this session's continuity with that holder could not be verified" in id_only.stderr,
        "the id-only twin refusal did not name the owner pid and the shared session id",
    )
    require(session_lock_text(same_lock) == same_lock_owner, "a twin moved the lock line beside an id-only sidecar")
    id_only_stop = guard(same_env, "id-only twin stop", prefix="export CLAUDE_PID=$$; ")
    require(id_only_stop.returncode == 0, "an id-only twin's Stop must end safely")
    require("SUPERVISION IS OWNED BY ANOTHER LIVE SESSION: this read-only session" in id_only_stop.stdout, "an id-only twin's Stop lost the foreign-owner diagnostic")
    print("FIXED a live twin beside an id-only sidecar is refused and its Stop ends safely", flush=True)
    short_lived = start(same_env, "sleep 60", "short-lived-anchor.txt")
    exited = str(short_lived.pid)
    exited_start = run(
        same_env, '. "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh" && fm_pid_start_time ' + exited
    ).stdout.strip()
    require(exited_start != "" and exited != same_lock_owner, "could not record a short-lived model-loop anchor")
    (same / "state/.lock-session").write_text(f"synthetic-same\nanchor={exited}\nanchor-start={exited_start}\n")
    stop(short_lived)
    require(short_lived.poll() is not None, "the recorded anchor did not exit")
    exited_record = (same / "state/.lock-session").read_text()
    exited_twin = run(
        same_env,
        'export CLAUDE_PID=$$; "$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; rc=$?; printf "lock_rc=%s\\n" "$rc"; true',
    )
    print("exited-anchor twin acquisition", "rc=" + str(exited_twin.returncode), "stdout=" + repr(exited_twin.stdout), "stderr=" + repr(exited_twin.stderr), flush=True)
    require("lock_rc=1" in exited_twin.stdout, "a same-id process took the live owner's lock because the recorded anchor had exited")
    require(
        f"another live process holds the lock under this same session id (pid {same_lock_owner}, session synthetic-same) and this session's continuity with that holder could not be verified" in exited_twin.stderr,
        "the exited-anchor refusal did not name the owner pid and the shared session id",
    )
    require(session_lock_text(same_lock) == same_lock_owner, "a same-id process moved the lock line beside an exited anchor")
    require((same / "state/.lock-session").read_text() == exited_record, "a refused same-id process changed the exited-anchor record")
    exited_stop = guard(same_env, "exited-anchor stop", prefix="export CLAUDE_PID=$$; ")
    require(exited_stop.returncode == 0, "an exited-anchor twin's Stop must end safely")
    require("SUPERVISION IS OWNED BY ANOTHER LIVE SESSION: this read-only session" in exited_stop.stdout, "an exited-anchor twin's Stop lost the foreign-owner diagnostic")
    print("FIXED a same-id process beside an exited recorded anchor is refused and its Stop ends safely", flush=True)
    accepted = start(
        same_env,
        'export CLAUDE_PID=$$; printf "%s\\n" "$$" > "$FM_HOME/state/accepted-pid"; '
        '. "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"; '
        'printf "synthetic-same\\nanchor=%s\\nanchor-start=%s\\n" "$$" "$(fm_pid_start_time "$$")" > "$FM_HOME/state/.lock-session"; '
        '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; printf "%s\\n" "$?" > "$FM_HOME/state/accepted-rc.tmp"; '
        'mv "$FM_HOME/state/accepted-rc.tmp" "$FM_HOME/state/accepted-rc"; '
        + HOLD,
        "same-accepted.txt",
    )
    until(
        lambda: (same / "state/accepted-rc").exists(),
        message="the same-session acquisition did not finish",
    )
    accepted_pid = (same / "state/accepted-pid").read_text().strip()
    accepted_log = (OUT / "same-accepted.txt").read_text(errors="replace")
    print("same-session acquisition", "rc=" + (same / "state/accepted-rc").read_text().strip(), "pid=" + accepted_pid, "output=" + repr(accepted_log), flush=True)
    require((same / "state/accepted-rc").read_text().strip() == "0", "the same session id was refused as a foreign live owner")
    require(same_owner.poll() is None, "the original owner exited, so the re-anchor proves nothing over a live line 1")
    require(accepted_pid != same_lock_owner, "the same-session acquisition ran as the original owner")
    require(session_lock_text(same_lock) == accepted_pid, "a same-session confirmation outside the owner's ancestry did not re-anchor line 1 onto its own CLAUDE_PID")
    require((same / "state/.lock-session").read_text().splitlines()[0] == "synthetic-same", "a same-session confirmation changed the recorded id")
    refused = run(
        same_env | {"CLAUDE_CODE_SESSION_ID": "synthetic-other"},
        'export CLAUDE_PID=$$; "$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; rc=$?; printf "lock_rc=%s\\n" "$rc"; true',
    )
    print("other-session acquisition", "rc=" + str(refused.returncode), "stdout=" + repr(refused.stdout), "stderr=" + repr(refused.stderr), flush=True)
    require("lock_rc=1" in refused.stdout, "a different session id acquired the re-anchored lock")
    require(f"pid {accepted_pid}, session synthetic-same" in refused.stderr, "the refusal did not name the re-anchored pid and the recorded session id")
    other_stop = guard(same_env | {"CLAUDE_CODE_SESSION_ID": "synthetic-other"}, "other-session stop", prefix="export CLAUDE_PID=$$; ")
    require(other_stop.returncode == 0, "a different-session Stop must still end safely")
    require("SUPERVISION IS OWNED BY ANOTHER LIVE SESSION: this read-only session" in other_stop.stdout, "a different-session Stop lost the foreign-owner diagnostic")
    require(session_lock_text(same_lock) == accepted_pid, "a Stop moved the re-anchored lock line")
    print("FIXED same-session id re-anchors the lock onto its own process; a different id is still foreign", flush=True)
    stop(same_owner)

    single, single_env = make("single-idle")
    stale = single / "state/.last-watcher-beat"
    stale.touch()
    os.utime(stale, (old_time, old_time))
    sole_owner = run(
        single_env,
        '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; . "$FM_ROOT_OVERRIDE/bin/fm-session-lock-lib.sh"; '
        'if fm_session_lock_owned_by_self "$FM_HOME/state"; then printf "single_owner_verified=1\\n"; fi; '
        'printf \'%s\\n\' \'{"session_id":"synthetic-second","stop_hook_active":true}\' | '
        '"$FM_ROOT_OVERRIDE/bin/fm-turnend-guard.sh" --claude; rc=$?; printf "single_owner_guard_rc=%s\\n" "$rc"; true',
    )
    print("single owner, no autoarm firing", "rc=" + str(sole_owner.returncode), "stdout=" + repr(sole_owner.stdout), "stderr=" + repr(sole_owner.stderr), flush=True)
    require("single_owner_guard_rc=2" in sole_owner.stdout, "a sole owner without supervision must retain the guard")
    stop(owner)
    replacement = start(
        env,
        '{ printf \'%s\\n\' \'{"session_id":"replacement","stop_hook_active":true}\' | "$FM_ROOT_OVERRIDE/bin/fm-claude-stop-autoarm.sh"; printf "replacement_rc=%s\\n" "$?"; } & '
        'until [ -e "$FM_HOME/state/replacement-guard-go" ] || ! kill -0 ' + str(os.getpid()) + ' 2>/dev/null || [ "$SECONDS" -ge 120 ]; do sleep 0.1; done; '
        '[ -e "$FM_HOME/state/replacement-guard-go" ] || kill -TERM 0; '
        'printf \'%s\\n\' \'' + PAYLOAD + '\' | "$FM_ROOT_OVERRIDE/bin/fm-turnend-guard.sh" --claude; printf "replacement_guard_rc=%s\\n" "$?"; '
        + HOLD,
        "replacement.txt",
    )
    until(
        lambda: (root / "state/.watch.lock/pid").is_file(),
        message=lambda: "replacement owner did not publish state/.watch.lock/pid: " + (OUT / "replacement.txt").read_text(),
    )
    watcher_pid = (root / "state/.watch.lock/pid").read_text().strip()
    print("COUNTERFACTUAL dead original owner: watcher=", watcher_pid, flush=True)
    (root / "state/replacement-guard-go").touch()
    replacement_out = OUT / "replacement.txt"
    until(
        lambda: "replacement_guard_rc=" in replacement_out.read_text(),
        message=lambda: "replacement owner's guard did not finish: " + replacement_out.read_text(),
    )
    healthy = replacement_out.read_text()
    print("replacement-owned healthy watcher", repr(healthy), flush=True)
    require("replacement_guard_rc=0" in healthy, "a replacement owning session must still recover supervision")
    require("OWNED BY ANOTHER LIVE SESSION" not in healthy, "the replacement owner took the read-only exit")
    stop(replacement)

    print("COMPLETE", flush=True)
finally:
    for process in reversed(PROCS):
        stop(process)
    shutil.rmtree(LAB, ignore_errors=True)
