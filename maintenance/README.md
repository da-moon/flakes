# Flakes maintenance automation

This directory contains a user-systemd runner for the full flakes maintenance
pipeline. A fresh installation leaves the timer disabled; reinstalling
preserves its existing enablement. Install the unit files, run one manual
service test after the repository is clean, then enable the timer.

```bash
./maintenance/install.sh
systemctl --user start flakes-maintenance.service
journalctl --user -u flakes-maintenance.service -n 200 --no-pager
./maintenance/install.sh --enable
systemctl --user list-timers flakes-maintenance.timer
```

The timer runs at 08:00 and 20:00 UTC. `Persistent=true` starts one missed run
after the user manager becomes available. Linger must stay enabled for runs
while no user session is open.

Package release metadata is updated for all supported platforms, including
Darwin assets and hashes. Host version pins and activation use the available
Ubuntu/WSL Home Manager files. There is no Mac host configuration or Darwin
builder here; macOS builds and activation need a native Mac or remote Darwin
builder. The Linux runner leaves any separate Darwin host configuration alone.

`run.sh` takes a nonblocking `flock` before work begins. It rejects a dirty
flakes worktree, records the pre-existing Home Manager state, and starts Codex
with `--no-daemon` before `exec`. Codex uses the existing saved login and model
configuration. It never restarts the live managed Codex daemon. Changed Codex
packages are tested using a separate temporary `CODEX_HOME`.

Interactive maintenance must hold the same lock, as described in `AGENTS.md`.
The scheduled agent inherits `FLAKES_MAINTENANCE_LOCK_HELD=1` and must not take
the lock again. Builds, repairs, and Home Manager operations run serially.

Each run writes private files beneath
`~/.local/state/flakes-maintenance/logs/<timestamp>-<pid>/`:

- `discovered-updaters.txt` is the dynamic updater inventory.
- `codex.jsonl` and `codex.stderr.log` are the execution record.
- `result.json` is the schema-validated final result.
- `home-manager-before-*` records user work that must remain preserved.
- `updater-results.tsv` records each updater attempt and exit status.

The runner fails when Codex exits nonzero, reports any incomplete status, omits
an updater result, leaves flakes dirty, or fails to push local `master` to the
matching `origin/master` tip. It also checks all explicit non-Darwin pins,
protected configuration content and root inputs, and the active Home Manager
generation against the evaluated activation package. The agent retries failed
updaters after repairs. A failed overall run remains visible in systemd and the
private logs; the next scheduled run tries again if the checkout is clean.

Inspect or disable the schedule with:

```bash
systemctl --user status flakes-maintenance.timer flakes-maintenance.service
journalctl --user -u flakes-maintenance.service -n 100 --no-pager
systemctl --user disable --now flakes-maintenance.timer
```

The runner uses the
[documented non-interactive Codex mode](https://developers.openai.com/codex/noninteractive).
It requires the existing CLI login, Git remote access, and installed Nix tools.
Run the offline behavioral tests with `bash maintenance/tests/run-test.sh`.
