# Maintenance

Read `/home/ubuntu/.codex/rules/writing-and-commit-sanity.md` before writing or
committing. The recurring update workflow is documented in
`maintenance/README.md` and `maintenance/task.md`.

Interactive and scheduled maintenance share an exclusive `flock` on
`${XDG_STATE_HOME:-$HOME/.local/state}/flakes-maintenance/run.lock`. Hold it
through updater runs, repairs, commits, pushes, and the Home Manager switch. If
another process owns it, inspect the running service and wait for that run; do
not launch overlapping package or lockfile operations.

When `FLAKES_MAINTENANCE_LOCK_HELD=1`, the parent runner already holds the
lock. Do not acquire it again, release it, invoke the runner recursively, or
change the timer. Preserve unrelated Home Manager edits, exclude Darwin, and
leave managed Codex daemon replacement for an idle window.
