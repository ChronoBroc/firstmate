#!/bin/bash
set -u
export TMPDIR="$PWD/.test-phase/tmp"
evidence=~/.no-mistakes/evidence/01M75C1WF7H81D8WFBKR8YBNJK
status=0
for name in fm-send-inbox fm-worker-account fm-codex-account-quota fm-hermes-harness fm-capacity-auto fm-stow-guard fm-lavish-url; do
  /bin/bash "tests/$name.test.sh" > "$evidence/$name-regression.log" 2>&1
  rc=$?
  printf '%s exit=%s\n' "$name" "$rc"
  if [ "$rc" != 0 ]; then tail -12 "$evidence/$name-regression.log"; status=1; fi
done
exit "$status"
