#!/usr/bin/env bash
# tests/session-lock-helpers.sh - shared assertions over the session-lock
# sidecar record (state/.lock-session) that bin/fm-lock.sh writes.

# The sidecar <file> records session <id> with anchor <pid> and a non-empty
# anchor start time on its third line, as bin/fm-lock.sh's sidecar contract
# states.
anchored_sidecar() {  # <file> <id> <pid>
  [ "$(sed -n 1,2p "$1" 2>/dev/null)" = "$(printf '%s\nanchor=%s' "$2" "$3")" ] \
    && sed -n 3p "$1" | grep -q '^anchor-start=.' \
    && [ "$(wc -l < "$1" | tr -d ' ')" = 3 ]
}

# Copy the real Stop auto-arm, fm-lock.sh, and their libraries into fixture
# home <dir>, with a fixture watcher arm in place of the real one.
install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-path-lib.sh" "$dir/bin/fm-path-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-session-lock-decision-lib.sh" "$dir/bin/fm-session-lock-decision-lib.sh"
  cp "$ROOT/bin/fm-omp-process-lib.sh" "$dir/bin/fm-omp-process-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  # Launch probe sibling of fm-cursor-lib.sh; keep it next to the copy so a
  # fixture that ever verifies an executable does not source a missing file.
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/fm-timeout-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$dir/bin/fm-supervision-engine-lib.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  # The fixture arm written here stands in for the watcher arm, so the home opts out
  # of the supervision host a Claude home otherwise runs by default.
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host-off"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# The outcome recorded on the first line of <dir>'s auto-arm epoch ledger.
epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}
