# fm-teardown freeze-then-decide: live lab evidence

Driver: lab-drive.sh <repo-root> <scenario>. Each run mints a marked disposable FM_HOME (fm-lab-home.sh create),
a real git origin/project/worktree, a real tmux server on a private socket (-L fm-lab) whose task window
runs an interactive `bash -i` in the copy with the worker as a foreground job (the same shape fm-spawn.sh
uses for tmux spawns: typed `treehouse get`, then the worker command). Teardown runs with FM_HOME=<lab>.
Only external boundaries are stubbed: `treehouse` (logs `return`), gh/gh-axi (no PR), and no-mistakes (no run).
The late-writer scenario's lsof shim is a timing hook: on teardown's first process scan it lets the live
worker write a tracked edit, then runs the real lsof.

- s3-clean-landed.log: clean landed copy -> paused, reaped, returned (exit 0)
- s1-dirty-refusal-keeps-worker-then-retry.log: uncommitted edit -> refused, worker alive, copy kept; commit+push -> rerun succeeds
- s2-late-writer-BASE-86e67864.log: base commit reproduces the report: "force-killing" then REFUSED, worker + window gone
- s2-late-writer-fixed.log: fix: paused, REFUSED, resumed, worker alive, copy unreturned, edit intact
- s2-term-writer-fixed.log: worker with a TERM handler that writes: SIGKILL after the frozen proof, nothing written, clean pass
- s6-no-lsof-refuses-then-force.log: no lsof -> checked refuses with worker alive; --force reaps the process group
- s4-tty-reader-after-refusal.log / s5-real-claude-worker-after-refusal.log: DEFECT. After a frozen-proof refusal the pane's
  interactive shell prints "[1]+ Stopped <worker>", takes back the terminal, and the worker becomes a background job.
  A worker that reads its terminal (bash `read`, the real `claude` TUI) is then stopped by SIGTTIN (state T) and stays paused,
  and a line typed into the pane (how a supervisor messages a worker) is executed by the shell instead:
  "PANE-INPUT-RAN-IN-SHELL-NOT-WORKER".

## Round 2 (target c7513921: refusal types `fg` into the task's own tmux pane)
Driver: lab-drive-r2.sh (same as lab-drive.sh, plus the pane-input probe for tty-reader and heartbeat after the probe).
- r2-s4-tty-reader-after-refusal.log: FIXED. After the refusal, "returned task process ... to the foreground of its pane"; worker is S+,
  its heartbeat stays fresh (0s), and the probe line is read by the worker, not run by the shell.
- r2-s5-real-claude-worker-after-refusal.log: FIXED. Real `claude` TUI stays S+ after the refusal; the probe line appears in Claude's own prompt.
- r2-s1 / r2-s2-late-writer / r2-s2-term-writer / r2-s3 / r2-s6: same results as round 1 (refusals end nothing and return no copy;
  clean and forced runs reap and return).
