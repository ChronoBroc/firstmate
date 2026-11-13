#!/usr/bin/env bash
# tests/fm-send-inbox-doorbell-live-e2e.test.sh - the live doorbell guard
# (live-harness-optin family).
#
# The steering inbox's one behavioral assumption is that a real worker agent
# follows the constant self-describing doorbell line: list the inbox, read and
# act on its records in numeric order, then mv each into handled/. The
# doorbell names the inbox as "$FM_TASK_INBOX", so each worker is launched the
# way bin/fm-spawn.sh launches it, with FM_TASK_INBOX exported to its home's
# state/<task>.inbox, and receives no brief at all: it must resolve the inbox
# from the doorbell plus its own environment. A stub can only confirm the
# assumption already written into the stub, so per
# .agents/skills/firstmate-coding-guidelines this is proven against every
# INSTALLED verified harness: each is launched idle in an isolated tmux server,
# steered through the REAL fm-send (durable record + doorbell), and must both
# ACT on the instruction (create a named file) and ACKNOWLEDGE it (the mv into
# handled/), failing loudly with the harness name and version. A second,
# lagged steer then reaches the worker while its foreground process group is
# frozen, and so does one watcher-role re-ring: the worker must still act and
# acknowledge with no further ring, which proves a re-ring submits a doorbell
# a lagging agent left in its composer rather than stacking another copy
# (stranded deterministically when the freeze alone does not leave it there).
#
# Run explicitly with FM_SEND_INBOX_LIVE_E2E=1. This test spends a small
# number of real model tokens per installed harness (two short turns each) -
# authorized by the harness-dependent-checks rule. An absent harness is
# reported explicitly and skipped; a run that verified nothing fails rather
# than passing vacuously. Restrict with
# FM_SEND_INBOX_LIVE_HARNESSES="claude codex ..." when needed, and tune the
# per-harness wait with FM_SEND_INBOX_LIVE_TIMEOUT (seconds, default 240).
# Record the dated per-harness result in
# docs/verification/runtime-backends.md ("Steering-inbox doorbell").
#
# Folder trust: harnesses launch with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unready state and correctly fails that harness's check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_SEND_INBOX_LIVE_E2E tmux

unset NO_MISTAKES_GATE

SOCKET="fm-inbox-live-$$"
SESSION="inboxlive"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-inbox-live.XXXXXX")
LAB=$(cd "$LAB" && pwd)
TIMEOUT=${FM_SEND_INBOX_LIVE_TIMEOUT:-240}
CHECKED=0
LAG_CHECKED=0
CODEX_LAG_CHECKED=0
FAILED=0

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

# fm-send and the composer readiness read both reach tmux through bare `tmux`
# calls, so a PATH shim pins them to the private socket.
SHIM_DIR="$LAB/shim"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# Launch <name> idle with its unattended-autonomy flags (the same posture
# bin/fm-spawn.sh uses), so the doorbell-triggered shell actions need no
# interactive approval.
launch_cmd() {  # <name>
  case "$1" in
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '\''{"feedbackDrafts":"off"}'\''' ;;
    codex) printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox --disable hooks' ;;
    opencode) printf '%s' "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode" ;;
    pi|pi-signed) printf '%s' "$1" ;;
    grok) printf '%s' 'grok --always-approve' ;;
    kimi) printf '%s' 'kimi --auto' ;;
    muse) printf '%s' 'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on muse --yolo' ;;
    *) return 1 ;;
  esac
}

# codex's crewmate launch in bin/fm-spawn.sh carries --disable hooks because the
# hook-trust modal ("N hooks are new or changed") opens on "Review hooks" and
# firstmate's key plane has no arrow navigation to move off it. Without the flag
# this guard parks on that dialog for the whole timeout and reports the doorbell
# unhonored, which is a dialog verdict rather than a doorbell one, so pin the
# switch here instead of letting the codex check go quietly unprovable again.
case "$(launch_cmd codex)" in
  *'--disable hooks'*) ;;
  *) fail 'codex launch recipe lost --disable hooks; the check would park on the hook-trust modal instead of judging the doorbell' ;;
esac

# Wait for the harness to look steerable. 0 = the composer classified a
# proven empty; 2 = the readiness budget expired without an empty verdict but
# also without a pending one. The caller proceeds on 2 with a note, because
# that mirrors production exactly: the send path's composer check is ADVISORY
# and skips only on visibly pending text, so a harness whose idle screen the
# classifier cannot positively identify still gets its doorbell (the composer
# matrix guard, not this one, owns re-proving the classifier per release).
wait_ready() {  # <window>
  local win=$1 i=0 budget=60 verdict dismissed=0 screen
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = empty ] && return 0
    i=$((i + 1))
    # Dismiss one non-trust startup modal (update prompts), as the composer
    # matrix guard does; never Enter, which could accept an upgrade.
    if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
      screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
      if ! printf '%s\n' "$screen" | grep -qi 'trust'; then
        tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  case "$verdict" in
    pending) return 1 ;;
  esac
  return 2
}

# Freeze the agent under the pane's shell around one call, so the agent reads
# the call's typed text and its Enter in one batch when it resumes, as a
# lagging event loop does on a loaded host. Codex's paste-burst heuristic then
# turns that Enter into a newline and leaves the doorbell unsubmitted. Only
# the shell's descendants are stopped: stopping the shell as well left the
# agent running (observed on macOS), as the kernel continues an orphaned
# process group whose members are all stopped.
lagged() {  # <window> <command...>
  local win=$1 pids frontier next p rc=0
  shift
  frontier=$(tmux -L "$SOCKET" display-message -p -t "$SESSION:$win" '#{pane_pid}')
  pids=
  while [ -n "$frontier" ]; do
    next=
    for p in $frontier; do
      next="$next $(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')"
    done
    pids="$pids $next"
    frontier=$(printf '%s' "$next" | tr -s ' ')
    [ -n "${frontier// /}" ] || frontier=
  done
  # shellcheck disable=SC2086
  [ -z "${pids// /}" ] || kill -STOP $pids 2>/dev/null || true
  "$@" || rc=$?
  sleep 0.5
  # shellcheck disable=SC2086
  [ -z "${pids// /}" ] || kill -CONT $pids 2>/dev/null || true
  return "$rc"
}

ring_as() {  # <harness> <ring args...>
  FM_COMPOSER_HARNESS=$1 fm_task_inbox_ring "${@:2}"
}

# The lagged-delivery phase: one steer sent to a frozen worker. When the
# freeze leaves its doorbell unsubmitted in the composer (the divergence this
# phase exists for, asserted rather than assumed), a single watcher-role
# re-ring, also into a frozen worker, must submit that doorbell instead of
# stacking another copy on it, and the worker must then act and acknowledge
# with no further ring. Whether the freeze strands the doorbell is timing
# luck (a fast enough event loop submits it anyway), so when it does not, the
# phase waits for that steer's acknowledgement and then strands the next
# doorbell deterministically: it enqueues a record with no ring and types its
# doorbell into a composer proven empty, without Enter - the state the
# 2026-10-30 incident left - before the same single lagged re-ring.
# Returns 0 proven, 1 failed, 2 not exercised.
check_lagged_doorbell() {  # <name> <version> <window> <home> <task>
  local name=$1 version=$2 win=$3 home=$4 task=$5 acted="$LAB/acted-lag-$1" rec handled doorbell i how=lagged
  local text="Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line."
  # Start from an idle composer, so the lag rather than a reply still being
  # rendered decides what the worker reads.
  wait_ready "$win" || true
  lagged "$win" env FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$task" "$text" \
    >/dev/null 2>&1
  rec="$home/state/$task.inbox/002.msg"
  handled="$home/state/$task.inbox/handled/002.msg"
  [ -f "$rec" ] || [ -f "$handled" ] || {
    printf 'not ok - %s (%s): the lagged steer left no durable inbox record\n' "$name" "$version" >&2
    return 1
  }
  sleep 3
  doorbell=$(fm_task_inbox_doorbell_line "$rec")
  if ! FM_COMPOSER_HARNESS=$name fm_task_inbox_composer_holds tmux "$SESSION:$win" "$doorbell"; then
    note "$name ($version): the lag did not strand its doorbell in the composer; stranding the next one deterministically"
    i=0
    while [ "$i" -lt "$TIMEOUT" ] && ! { [ -f "$handled" ] && [ -e "$acted" ]; }; do
      sleep 1
      i=$((i + 1))
    done
    if ! { [ -f "$handled" ] && [ -e "$acted" ]; }; then
      printf 'not ok - %s (%s): a lagged doorbell neither held in the composer nor honored within %ss\n' "$name" "$version" "$TIMEOUT" >&2
      tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
      return 1
    fi
    rm -f "$acted"
    # Never type into a composer not proven empty: an Enter-free doorbell
    # over a modal or a draft would not be the state under test.
    if ! wait_ready "$win"; then
      note "$name ($version): composer never read empty, so the stranded doorbell was not typed and the re-ring half is not exercised here"
      return 2
    fi
    rec=$(fm_task_inbox_write "$home/state" "$task" "$text") || {
      printf 'not ok - %s (%s): could not enqueue the stranded-doorbell record\n' "$name" "$version" >&2
      return 1
    }
    handled="$home/state/$task.inbox/handled/${rec##*/}"
    doorbell=$(fm_task_inbox_doorbell_line "$rec")
    tmux -L "$SOCKET" send-keys -t "$SESSION:$win" -l "$doorbell"
    sleep 1
    if ! FM_COMPOSER_HARNESS=$name fm_task_inbox_composer_holds tmux "$SESSION:$win" "$doorbell"; then
      printf 'not ok - %s (%s): a doorbell typed without Enter did not read as held in the composer\n' "$name" "$version" >&2
      return 1
    fi
    how=stranded
  fi
  lagged "$win" ring_as "$name" tmux "$SESSION:$win" "$rec" || true
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    sleep 1
    i=$((i + 1))
  done
  if [ -f "$handled" ] && [ -e "$acted" ]; then
    pass "$name ($version): a doorbell left in its composer ($how) was submitted by one re-ring, acted on and acked"
    return 0
  fi
  printf 'not ok - %s (%s): a doorbell left in a lagging composer was not honored after one re-ring within %ss (acted=%s acked=%s)\n' \
    "$name" "$version" "$TIMEOUT" "$([ -e "$acted" ] && echo yes || echo no)" \
    "$([ -f "$handled" ] && echo yes || echo no)" >&2
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  return 1
}

check_harness_doorbell() {  # <name>
  local name=$1 version cmd win="hx-$1" home task acted rec handled i ready_rc lag_rc
  version=$(harness_version "$name")
  cmd=$(launch_cmd "$name") || { note "no launch recipe for $name"; return 0; }
  home="$LAB/$name-home"
  mkdir -p "$home/state"
  task="live-$name"
  acted="$LAB/acted-$name"
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" \
    -- bash -lc "export FM_TASK_INBOX=$(printf '%q' "$home/state/$task.inbox"); $cmd" \
    || { FAILED=1; printf 'not ok - %s (%s): could not launch in the isolated tmux server\n' "$name" "$version" >&2; return 0; }
  wait_ready "$win"; ready_rc=$?
  if [ "$ready_rc" -eq 1 ]; then
    FAILED=1
    printf 'not ok - %s (%s): composer stayed visibly pending; the pane is not steerable\n' "$name" "$version" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -6 | sed 's/^/#   /' >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  [ "$ready_rc" -eq 0 ] || note "$name ($version): idle composer never classified empty; proceeding as production does (advisory check skips only on pending)"
  printf 'window=%s:%s\nkind=ship\nharness=%s\n' "$SESSION" "$win" "$name" > "$home/state/$task.meta"
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" \
    "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line." \
    >/dev/null 2>&1; then
    FAILED=1
    printf 'not ok - %s (%s): fm-send refused the live steer\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  rec="$home/state/$task.inbox/001.msg"
  handled="$home/state/$task.inbox/handled/001.msg"
  [ -f "$rec" ] || {
    FAILED=1
    printf 'not ok - %s (%s): fm-send left no durable inbox record\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  }
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    # Halfway through, play the watcher's role once: re-ring an unacknowledged
    # message so a doorbell swallowed by a startup or update modal recovers
    # exactly as the production re-ring ladder recovers it.
    if [ "$i" -eq $((TIMEOUT / 2)) ] && [ -f "$rec" ]; then
      fm_task_inbox_ring tmux "$SESSION:$win" "$rec" || true
      note "$name ($version): re-rang the doorbell once (watcher's role) at ${i}s"
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ -f "$handled" ] && [ -e "$acted" ]; then
    pass "$name ($version): the doorbell reached a real worker, which acted and acked with the mv"
    CHECKED=$((CHECKED + 1))
    lag_rc=0
    check_lagged_doorbell "$name" "$version" "$win" "$home" "$task" || lag_rc=$?
    case "$lag_rc" in
      0)
        LAG_CHECKED=$((LAG_CHECKED + 1))
        [ "$name" != codex ] || CODEX_LAG_CHECKED=1
        ;;
      1) FAILED=1 ;;
    esac
  else
    FAILED=1
    printf 'not ok - %s (%s): doorbell not honored within %ss (acted=%s acked=%s)\n' \
      "$name" "$version" "$TIMEOUT" "$([ -e "$acted" ] && echo yes || echo no)" \
      "$([ -f "$handled" ] && echo yes || echo no)" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

HARNESSES=${FM_SEND_INBOX_LIVE_HARNESSES:-'claude codex opencode pi grok kimi muse'}
for h in $HARNESSES; do
  if command -v "$h" >/dev/null 2>&1; then
    check_harness_doorbell "$h"
  else
    note "harness absent, not verified here: $h"
  fi
done

if [ "$FAILED" -ne 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard found failures above\n' >&2
  exit 1
fi
if [ "$CHECKED" -eq 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard verified nothing (no harness installed?)\n' >&2
  exit 1
fi
case " $HARNESSES " in
  *' codex '*)
    if command -v codex >/dev/null 2>&1 && [ "$CODEX_LAG_CHECKED" -eq 0 ]; then
      printf 'not ok - the lagged-doorbell re-ring was never exercised against codex, whose paste-burst Enter swallow it exists for\n' >&2
      exit 1
    fi
    ;;
esac
pass "live steering-inbox doorbell guard: $CHECKED harness(es) honored the doorbell contract, $LAG_CHECKED proved the lagged re-ring"
