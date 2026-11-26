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
