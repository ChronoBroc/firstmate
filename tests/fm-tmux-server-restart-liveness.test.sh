#!/usr/bin/env bash
# tests/fm-tmux-server-restart-liveness.test.sh - a worker whose tmux server
# was replaced must not read as alive or working.
#
# After a tmux server restart the new server can carry a session and window
# under the names a task record holds, while the worker that record describes
# died with the old server and left its last busy record behind. Every
# liveness reader must bind its answer to the server identity the record
# carries (tmux_socket, tmux_server), so the crew-state reading, the endpoint
# read the session-start digest and fleet snapshot make, the watcher's agent
# state, and the live busy classifier all report the endpoint gone, exactly as
# they do for a window closed on a surviving server. A live worker on its
# unchanged server, and a record written before server identity was recorded,
# must read as they always did.
#
# Real tmux on a private socket: only `-S <private socket>` servers are
# started or killed, and TMUX_TMPDIR points at the same private directory so
# the bare `tmux` calls under test address that server and never a real one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

# A short root keeps the socket path under the platform's Unix-socket limit.
TMP=$(mktemp -d /tmp/fmsr.XXXXXX)
mkdir -m 700 "$TMP/tmux-$(id -u)"
SOCK="$TMP/tmux-$(id -u)/default"
cleanup() {
  tmux -S "$SOCK" kill-server >/dev/null 2>&1 || true
  rm -rf "$TMP"
  fm_test_cleanup
}
trap cleanup EXIT
export TMUX_TMPDIR=$TMP
unset TMUX

HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
FAKEBIN="$TMP/fakebin"
mkdir -p "$STATE" "$FAKEBIN" "$TMP/bin" "$TMP/wt"
# An agent-named foreground process: the process classifier reads the
# executable's name; tests/lib.sh's fm_agent_standin owns a stand-in that
# survives that foreign name.
STANDIN_BIN=$(fm_agent_standin "$TMP/standin") || {
  echo "skip: no long-running stand-in binary survives a rename (multicall coreutils, no C compiler)"
  exit 0
}
ln -s "$STANDIN_BIN" "$TMP/bin/claude"
# No pipeline run is attributed to the task, so crew-state answers from the
# endpoint and busy record alone.
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/no-mistakes"
git -C "$TMP/wt" init -q -b fm/sr1
git -C "$TMP/wt" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "the tmux backend should load"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

ID=sr1
LEGACY=sr2
TARGET="crew:fm-$ID"
META="$STATE/$ID.meta"
LEGACY_META="$STATE/$LEGACY.meta"

start_worker_window() {
  tmux -S "$SOCK" new-window -d -t crew: -n "fm-$ID" "$TMP/bin/claude 600" \
    || fail "the worker window should start"
  local i=0
  while [ "$i" -lt 50 ]; do
    [ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  fail "the agent-named worker window never read alive, got $(fm_backend_agent_state tmux "$TARGET")"
}

write_meta() {  # <file> <id> [identity]
  {
    printf 'window=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nbranch=fm/sr1\n' \
      "$TARGET" "$TMP/wt" "$TMP/wt"
    [ -z "${3:-}" ] || printf 'tmux_socket=%s\ntmux_server=%s\n' "${3%%$'\t'*}" "${3#*$'\t'}"
  } > "$1"
  "$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$2" >/dev/null || fail "the busy record should arm"
  printf 'working [at=%s]: under way\n' "$(date +%s)" > "$STATE/$2.status"
}

crew_state() {  # <id>
  PATH="$FAKEBIN:$PATH" FM_CREW_STATE_NO_FORGE=1 FM_STATE_OVERRIDE="$STATE" \
    "$ROOT/bin/fm-crew-state.sh" "$1" 2>/dev/null | tail -1
}

# The digest and fleet snapshot read endpoint existence with the record.
endpoint_read() {  # <meta>
  if fm_backend_target_exists tmux "$TARGET" "fm-$ID" "$1"; then printf alive; else printf dead; fi
}

# The watcher resolves the record by window, then reads the agent state.
watcher_agent_state() {
  fm_backend_agent_state tmux "$TARGET" "$(fm_backend_meta_for_window "$TARGET" "$STATE")"
}

tmux -S "$SOCK" new-session -d -s crew -n keep || fail "a private tmux server should start"
[ -S "$SOCK" ] || fail "the private server must listen on the private socket"
start_worker_window
IDENT=$(fm_backend_tmux_server_identity "$TARGET") || fail "the private server's identity should be readable"
write_meta "$META" "$ID" "$IDENT"

# --- a live worker on its recorded server reads exactly as before ----------

out=$(crew_state "$ID")
case "$out" in
  *"state: working"*"harness busy"*) ;;
  *) fail "a live busy worker should read working, got: $out" ;;
esac
[ "$(endpoint_read "$META")" = alive ] || fail "a live worker's endpoint should read alive"
[ "$(watcher_agent_state)" = alive ] || fail "a live worker's agent should read alive, got $(watcher_agent_state)"
case "$(fm_busy_classify_live tmux "$TARGET" claude "$ID" "$STATE")" in
  busy\ *) ;;
  *) fail "a live busy worker should classify busy, got $(fm_busy_classify_live tmux "$TARGET" claude "$ID" "$STATE")" ;;
esac
pass "a live worker on its unchanged recorded server reads alive and working"

# --- the server restarts and a same-named window holds another process -------

tmux -S "$SOCK" kill-server || fail "the private server must be killed"
recorded_pid=${IDENT#*$'\t'}
recorded_pid=${recorded_pid%%:*}
i=0
while kill -0 "$recorded_pid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
tmux -S "$SOCK" new-session -d -s crew -n keep || fail "a fresh server should start on the same socket"
start_worker_window
[ "$(LC_ALL=C tmux -S "$SOCK" display-message -p '#{pid}:#{start_time}')" != "${IDENT#*$'\t'}" ] \
  || fail "the fresh server must have a different identity"

# The masking condition is real: an unbound read cannot tell the windows apart.
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] \
  || fail "the same-named window on the fresh server should read alive to an unbound read"

out=$(crew_state "$ID")
case "$out" in
  *"state: unknown"*"backend target gone: $TARGET"*) ;;
  *) fail "a worker whose recorded server was replaced must read gone, got: $out" ;;
esac
[ "$(endpoint_read "$META")" = dead ] || fail "the digest's endpoint read must report the replaced server's window dead"
[ "$(watcher_agent_state)" = missing ] || fail "the watcher must read the replaced server's endpoint missing, got $(watcher_agent_state)"
[ "$(fm_backend_agent_alive tmux "$TARGET" "$META")" = dead ] || fail "the yes/no agent view must read dead"
[ "$(fm_busy_classify_live tmux "$TARGET" claude "$ID" "$STATE")" = "dead endpoint-gone" ] \
  || fail "the live busy classifier must override the stale busy record, got $(fm_busy_classify_live tmux "$TARGET" claude "$ID" "$STATE")"
pass "after a server restart, a same-named window and a stale busy record no longer make a dead worker read alive or working"

# --- the closed-window path every reader already handled agrees --------------

tmux -S "$SOCK" kill-window -t "=crew:=fm-$ID" || fail "the window must close"
closed=$(crew_state "$ID")
[ "$closed" = "$out" ] || fail "a replaced server must read exactly like a closed window, got '$out' vs '$closed'"
pass "a replaced server reads exactly like a window closed on a surviving server"

# --- a record without server identity is never reported dead on that ground ---

start_worker_window
write_meta "$LEGACY_META" "$LEGACY" ''
# The legacy task's window is the same live window; only its record differs.
out=$(crew_state "$LEGACY")
case "$out" in
  *"state: working"*"harness busy"*) ;;
  *) fail "a record without server identity must read as before, got: $out" ;;
esac
[ "$(endpoint_read "$LEGACY_META")" = alive ] || fail "a record without server identity must keep its endpoint alive"
[ "$(fm_backend_agent_state tmux "$TARGET" "$LEGACY_META")" = alive ] \
  || fail "a record without server identity must keep its agent alive"
pass "a record written before server identity was recorded is not reported dead on that ground"
