Perform the complete flakes maintenance pipeline in this checkout. You have
exclusive ownership of changes created by this run. Do not change this prompt,
the timer tooling, any systemd units, or the live Codex daemon lifecycle.

Run Nix, npm, updater, lockfile, and package-cache operations serially. Do not
start other clients, create timers, or delegate mutable package work.

Read AGENTS.md and the canonical writing and commit rules before changing
files. Preserve existing work. The flakes worktree was required to be clean
before this run. The Home Manager worktree may contain pre-existing changes. Do
not discard, stage, commit, or rewrite those Home Manager changes. Record
whether they remain preserved in the final result.

The Home Manager flake contains credentials and unrelated local changes. Read
and patch it narrowly. Never print, log, or copy raw configuration or
credential lines. Update explicit version declarations inside the `dmTools`
blocks of top-level `*.nix` files, currently `flake.nix` and `flake.wsl.nix`.
Preserve every other byte, including the unversioned table in `olares.nix`, and
every non-tool root lock input. The Home Manager checkout is provided in
`FLAKES_MAINTENANCE_HOME_MANAGER_REPO`; logs belong in
`FLAKES_MAINTENANCE_RUN_DIR`.

Run every currently discovered `*/scripts/update-version.sh` under the flakes
checkout. Discover scripts dynamically at runtime. Give each script stdin from
`/dev/null`. The runner's current inventory is
`$FLAKES_MAINTENANCE_RUN_DIR/discovered-updaters.txt`; use those exact relative
paths in audit records. Record every script's relative path, attempt count, and
final exit code. Append one tab-separated line, with script path, attempt
number, and exit code, after each attempt to
`$FLAKES_MAINTENANCE_UPDATER_AUDIT`. The runner already holds the shared
maintenance lock, identified by `FLAKES_MAINTENANCE_LOCK_HELD=1`. Do not
acquire it again. When a script fails, diagnose and implement the smallest
secure fix, then retry the affected script and any consumers whose dependency
contract changed. Do not suppress vulnerability checks or allow insecure
packages.

Treat `SCHEMA_REVIEW_REQUIRED` as a real review gate. Inspect the upstream
schema and the local module contract. Update the schema contract only when the
source change is understood, then rerun the updater. Do not bypass the gate.

Run proportionate validation for every changed package and all repaired paths.
Commit only changes made by this run in the flakes repository. Follow the
repository's commit rules. Push the resulting `master` commit to `origin`. Do
not rewrite history, force push, reset, clean, stash, or amend unrelated
history.

Then update the non-Darwin Home Manager tool pins to the current flakes
versions. Discover the applicable pins dynamically. Exclude Darwin
configuration entirely. Refresh only the required Home Manager inputs, verify
their root inputs resolve to the pushed flakes revision, and run the Ubuntu
Home Manager switch. If the installed Codex package changes, test that exact
package with `codex/scripts/test-daemon.sh`, which uses an isolated temporary
`CODEX_HOME`. Do not update the live managed Codex daemon.

Before reporting completion, independently verify all discovered updater
scripts were attempted and ended with exit code zero, the flakes worktree is
clean, the local `master` equals `origin/master`, non-Darwin pin versions match
their selected inputs, and the requested Home Manager generation is active. If
any required action, verification, push, or switch fails, do not claim success.
Set `home_manager.profile_after` to the exact resolved value of
`$HOME/.local/state/nix/profiles/home-manager` after the switch. Do not
substitute the separate `~/.nix-profile` package profile.

Return only JSON that conforms to the provided result schema. Set `status` to
`complete` only when every required action and verification succeeded. Use
`blocked`, `partial`, or `failed` otherwise and explain all reasons in
`blocked_reasons`.
