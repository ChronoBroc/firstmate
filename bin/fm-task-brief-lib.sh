#!/usr/bin/env bash
# Protected copy of a ship or scout task's instructions.
#
# data/<id>/ is the task's evidence directory, and a worker may point a tool's
# output directory at it. A tool that empties its output directory before a
# run (Playwright's outputDir, for example) then deletes data/<id>/brief.md,
# the instructions every relaunch launches from.
#
# data/<id>/brief.md stays the one editable, authoritative copy.
# state/<id>.brief is a read-only copy of it, refreshed by every launch
# (bin/fm-spawn.sh, fresh or relaunch) and by bin/fm-promote.sh, so it holds
# the instructions the current worker was given.
# Readers that need the instructions of a live task (bin/fm-control.sh
# relaunch, bin/fm-spawn.sh --relaunch, bin/fm-teardown.sh) call
# fm_task_brief_restore first: when brief.md is missing it is rewritten from the
# protected copy and the restore is reported on stderr. A missing
# launch-brief.md is rewritten from the same copy, because a task with a
# protected copy was already launched and the previous-launch guard in
# fm_finished_brief_check must still apply after a retain teardown.
# A fresh spawn never restores, so a task id reused for a new item cannot
# resurrect the previous item's instructions; teardown removes the copy.
# The launch brief needs no copy of its own because every launch re-renders it
# from brief.md, and the steering inbox already lives under state/.
# bin/fm-promote.sh publishes the copy inside its promotion transaction and
# refreshes it from the scout brief whenever it rolls the promotion back.
#
# Regression coverage: tests/fm-control-relaunch.test.sh.

fm_task_brief_copy_path() {  # <state-dir> <id>
  printf '%s/%s.brief\n' "$1" "$2"
}

# Refresh the protected copy from data/<id>/brief.md. Returns non-zero with a
# message on stderr when brief.md is missing or the copy cannot be published.
fm_task_brief_protect() {  # <data-dir> <state-dir> <id>
  local brief="$1/$3/brief.md" copy tmp
  copy=$(fm_task_brief_copy_path "$2" "$3")
  tmp="$copy.tmp.${BASHPID:-$$}"
  [ -f "$brief" ] || {
    echo "error: cannot protect task $3's instructions: no brief at $brief" >&2
    return 1
  }
  if cp -- "$brief" "$tmp" && chmod 0444 "$tmp" && mv -f -- "$tmp" "$copy"; then
    return 0
  fi
  rm -f -- "$tmp"
  echo "error: could not keep a protected copy of task $3's instructions at $copy" >&2
  return 1
}

# Rewrite data/<id>/brief.md from the protected copy when it is missing.
# Returns 0 when brief.md is present afterwards or there is no copy to restore
# from (the caller's own missing-brief refusal then applies), and non-zero when
# a restore was needed but failed.
fm_task_brief_restore() {  # <data-dir> <state-dir> <id>
  local brief="$1/$3/brief.md" copy tmp launch
  copy=$(fm_task_brief_copy_path "$2" "$3")
  { [ -e "$brief" ] || [ -L "$brief" ]; } && return 0
  [ -f "$copy" ] && [ ! -L "$copy" ] || return 0
  tmp="$1/$3/.brief.md.restore.${BASHPID:-$$}"
  launch="$1/$3/launch-brief.md"
  if mkdir -p -- "$1/$3" && cp -- "$copy" "$tmp" && chmod 0644 "$tmp" &&
    { [ -e "$launch" ] || [ -L "$launch" ] || cp -- "$tmp" "$launch"; } &&
    mv -f -- "$tmp" "$brief"; then
    echo "warning: task $3's instructions were missing from $brief (its evidence directory was emptied); restored them from $copy" >&2
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null || true
  echo "error: task $3's instructions are missing from $brief and could not be restored from $copy" >&2
  return 1
}
