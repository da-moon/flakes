#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly REPO="${FLAKES_REPO:-/home/ubuntu/sync/github/flakes}"
readonly HOME_MANAGER_REPO="${HOME_MANAGER_REPO:-$HOME/.config/home-manager}"
readonly STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/flakes-maintenance"
readonly TASK_FILE="$REPO/maintenance/task.md"
readonly RESULT_SCHEMA="$REPO/maintenance/result.schema.json"
readonly LOCK_FILE="$STATE_ROOT/run.lock"

mkdir -p "$STATE_ROOT/logs"
chmod 700 "$STATE_ROOT" "$STATE_ROOT/logs"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  printf 'SKIPPED_OVERLAP: another flakes maintenance run owns %s\n' "$LOCK_FILE" >&2
  exit 75
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="$STATE_ROOT/logs/$stamp-$$"
mkdir "$run_dir"
stdout_file="$run_dir/codex.jsonl"
stderr_file="$run_dir/codex.stderr.log"
result_file="$run_dir/result.json"
meta_file="$run_dir/metadata.env"

fail() {
  printf 'FAILED: %s\n' "$*" >&2
  exit 1
}

[ -d "$REPO/.git" ] || fail "flakes repository is unavailable: $REPO"
[ -d "$HOME_MANAGER_REPO/.git" ] || fail "Home Manager repository is unavailable: $HOME_MANAGER_REPO"
[ -r "$TASK_FILE" ] || fail "task prompt is unavailable: $TASK_FILE"
[ -r "$RESULT_SCHEMA" ] || fail "result schema is unavailable: $RESULT_SCHEMA"
command -v codex >/dev/null || fail "codex is not on PATH"
command -v fd >/dev/null || fail "fd is not on PATH"
command -v jq >/dev/null || fail "jq is not on PATH"
command -v nix >/dev/null || fail "nix is not on PATH"

if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
  fail "flakes worktree is dirty before scheduled maintenance"
fi
[ "$(git -C "$REPO" branch --show-current)" = master ] || fail "flakes repository is not on master"

mapfile -t updater_scripts < <(
  cd "$REPO"
  fd -t f '^update-version\.sh$' | LC_ALL=C sort
)
[ "${#updater_scripts[@]}" -gt 0 ] || fail "no update-version.sh scripts discovered"
printf '%s\n' "${updater_scripts[@]}" > "$run_dir/discovered-updaters.txt"
python3 "$REPO/maintenance/snapshot_home_manager.py" snapshot \
  "$HOME_MANAGER_REPO" "$run_dir/home-manager-before.json"
readlink -f "$HOME/.local/state/nix/profiles/home-manager" > "$run_dir/home-manager-profile-before.txt" || true
: > "$run_dir/updater-results.tsv"

{
  printf 'STARTED_AT=%q\n' "$(date -u --iso-8601=seconds)"
  printf 'REPO=%q\n' "$REPO"
  printf 'HOME_MANAGER_REPO=%q\n' "$HOME_MANAGER_REPO"
  printf 'UPDATER_COUNT=%q\n' "${#updater_scripts[@]}"
  printf 'CODEX=%q\n' "$(command -v codex)"
  printf 'CODEX_VERSION=%q\n' "$(codex --version)"
} > "$meta_file"

export FLAKES_MAINTENANCE_LOCK_HELD=1
export FLAKES_MAINTENANCE_RUN_DIR="$run_dir"
export FLAKES_MAINTENANCE_HOME_MANAGER_REPO="$HOME_MANAGER_REPO"
export FLAKES_MAINTENANCE_UPDATER_AUDIT="$run_dir/updater-results.tsv"

set +e
codex --no-daemon --ask-for-approval never exec \
  --sandbox danger-full-access \
  --cd "$REPO" \
  --json \
  --output-schema "$RESULT_SCHEMA" \
  --output-last-message "$result_file" \
  "$(cat "$TASK_FILE")" \
  >"$stdout_file" 2>"$stderr_file"
codex_status=$?
set -e
printf 'CODEX_EXIT=%q\n' "$codex_status" >> "$meta_file"

[ "$codex_status" -eq 0 ] || fail "Codex exited with status $codex_status; inspect $run_dir"
[ -s "$result_file" ] || fail "Codex produced no final structured result; inspect $run_dir"
jq -e '
  .status == "complete"
  and .flakes_pushed
  and .home_manager.non_darwin_pins_updated
  and .home_manager.switch_completed
  and .home_manager.dirty_state_preserved
  and .home_manager.root_inputs_current
  and (.home_manager.profile_after | type == "string" and length > 0)
  and (.blocked_reasons | length == 0)
  and (all(.updater_results[]; .attempts >= 1 and .final_exit_code == 0))
' "$result_file" >/dev/null || fail "Codex reported an incomplete result; inspect $result_file"

python3 "$REPO/maintenance/snapshot_home_manager.py" verify-audit \
  "$run_dir/discovered-updaters.txt" "$FLAKES_MAINTENANCE_UPDATER_AUDIT" \
  "$result_file" || fail "updater audit does not match the completed result"

[ -z "$(git -C "$REPO" status --porcelain)" ] || fail "flakes worktree is dirty after maintenance"
[ "$(git -C "$REPO" branch --show-current)" = master ] || fail "flakes repository is not on master"
[ "$(git -C "$REPO" rev-parse HEAD)" = "$(git -C "$REPO" ls-remote origin refs/heads/master | awk 'NR == 1 { print $1 }')" ] \
  || fail "local master does not equal origin/master"
python3 "$REPO/maintenance/snapshot_home_manager.py" verify \
  "$HOME_MANAGER_REPO" "$run_dir/home-manager-before.json" \
  || fail "Home Manager changed outside dmTools versions, Darwin, or non-tool locks"
python3 "$REPO/maintenance/snapshot_home_manager.py" verify-pins \
  "$HOME_MANAGER_REPO" "$REPO" \
  || fail "Home Manager pins or tool locks are not current"
expected_profile="$(nix eval --raw --no-write-lock-file "$HOME_MANAGER_REPO#homeConfigurations.ubuntu.activationPackage.outPath")"
current_profile="$(readlink -f "${HOME_MANAGER_PROFILE:-$HOME/.local/state/nix/profiles/home-manager}" || true)"
[ -n "$current_profile" ] || fail "Home Manager profile is not resolvable after switch"
[ "$expected_profile" = "$current_profile" ] || fail "active Home Manager profile differs from evaluated activation package"
[ "$(jq -r '.home_manager.profile_after' "$result_file")" = "$current_profile" ] \
  || fail "Codex did not report the active Home Manager profile"

printf 'COMPLETED_AT=%q\n' "$(date -u --iso-8601=seconds)" >> "$meta_file"
printf 'COMPLETE: %s\n' "$run_dir"
