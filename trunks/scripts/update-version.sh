#!/usr/bin/env bash
# Appends the newest (or an explicit) trunks PyPI release to releases.json as a
# new version-table entry (keyed by version) and sets .latest to it. Existing
# entries are preserved so consumers can still select past versions.
#
# trunks ships a single universal `py3-none-any` wheel, so each entry stores the
# wheel URL and a single arch-agnostic SRI hash. The version data in flake.nix is
# never touched — everything lands in releases.json via jq.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly PYPI_PACKAGE="trunks"
readonly PACKAGE_ATTR="trunks"
readonly BIN_NAME="trunks"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v jq >/dev/null 2>&1 || { log_error "jq is required but not installed."; exit 2; }
  command -v python3 >/dev/null 2>&1 || { log_error "python3 is required but not installed."; exit 2; }
}

ensure_in_package_directory() {
  [ -f "$flake_file" ] || { log_error "flake.nix not found at: $flake_file"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at: $releases_file"; exit 2; }
}

# Current "latest" key recorded in the version table.
get_current_version() {
  jq -r '.latest // empty' "$releases_file"
}

# Does the table already have an entry for this key?
has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

get_latest_version_from_pypi() {
  python3 - "$PYPI_PACKAGE" <<'PY'
import json
import sys
import urllib.request

package = sys.argv[1]
with urllib.request.urlopen(f"https://pypi.org/pypi/{package}/json") as response:
    data = json.load(response)
print(data["info"]["version"])
PY
}

get_wheel_url_for_version() {
  local version="$1"
  python3 - "$PYPI_PACKAGE" "$version" <<'PY'
import json
import sys
import urllib.request

package, version = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(f"https://pypi.org/pypi/{package}/{version}/json") as response:
    data = json.load(response)

for file_info in data["urls"]:
    if (
        file_info["packagetype"] == "bdist_wheel"
        and file_info["python_version"] == "py3"
        and file_info["filename"].endswith("py3-none-any.whl")
    ):
        print(file_info["url"])
        break
else:
    raise SystemExit("No universal py3 wheel found")
PY
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | jq -r '.hash'
}

# Append/upsert an entry into releases.json and set .latest.
upsert_release_entry() {
  local key="$1"
  local entry_json="$2"

  local tmp
  tmp="$(mktemp)"
  jq --arg k "$key" --argjson e "$entry_json" \
    '.versions[$k] = $e | .latest = $k' "$releases_file" >"$tmp"
  mv "$tmp" "$releases_file"
}

# sanitize a JSON key into a valid nix attribute-name suffix (mirrors flake.nix)
sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
}

verify_build() {
  local sanitized_key="$1"
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build ".#${PACKAGE_ATTR}_${sanitized_key}" --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for ${PACKAGE_ATTR}_${sanitized_key}"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/$BIN_NAME"
    return 1
  fi
  # default must also resolve (it points at the new .latest).
  if ! (cd "$pkg_dir" && nix build ".#default" --no-link --no-write-lock-file); then
    log_error "nix build failed for default"
    return 1
  fi
  timeout 30 "$out_path/bin/$BIN_NAME" --version >/dev/null 2>&1 || true
  log_info "Build successful."
}

# Parallel-safe auto-commit. flock serialises the git index across concurrent updaters.
maybe_git_commit() {
  local commit_message="$1"
  shift
  local -a paths=("$@")

  if ! command -v git >/dev/null 2>&1; then
    log_warn "git not found; skipping auto-commit"
    return 0
  fi
  if ! git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_warn "not in a git work tree; skipping auto-commit"
    return 0
  fi

  if git -C "$pkg_dir" diff --quiet -- "${paths[@]}" \
    && git -C "$pkg_dir" diff --cached --quiet -- "${paths[@]}"; then
    return 0
  fi

  local git_dir lock_file
  git_dir="$(git -C "$pkg_dir" rev-parse --absolute-git-dir 2>/dev/null || true)"
  lock_file="${git_dir:-$pkg_dir/.git}/update-version-commit.lock"

  (
    if command -v flock >/dev/null 2>&1; then flock 9 || true; fi
    git -C "$pkg_dir" add -- "${paths[@]}"
    if git -C "$pkg_dir" diff --cached --quiet -- "${paths[@]}"; then
      exit 0
    fi
    git -C "$pkg_dir" commit --only -m "$commit_message" -- "${paths[@]}"
    log_info "Committed: $commit_message"
  ) 9>"$lock_file"
}

print_usage() {
  cat <<'USAGE'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) trunks PyPI release to releases.json as a
new version-table entry (keyed by version) and sets .latest to it. Existing
entries are preserved so consumers can still select past versions.

Options:
  --version VERSION   Append a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute the wheel hash for the current latest version
  --no-build          Skip build verification
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 1.2.14
USAGE
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local target_version="" check_only=false rehash=false no_build=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        target_version="$2"
        shift 2
        ;;
      --check) check_only=true; shift ;;
      --rehash) rehash=true; shift ;;
      --no-build) no_build=true; shift ;;
      --help) print_usage; exit 0 ;;
      *) log_error "Unknown option: $1"; print_usage; exit 2 ;;
    esac
  done

  local current_version
  current_version="$(get_current_version)"
  if [ -z "$current_version" ]; then
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi

  local new_version
  new_version="${target_version:-$(get_latest_version_from_pypi)}"
  if [ -z "$new_version" ]; then
    log_error "Failed to fetch latest version"
    exit 2
  fi

  log_info "Current latest: $current_version"
  log_info "Target version:  $new_version"

  if [ "$check_only" = true ]; then
    if has_version_entry "$new_version" && [ "$current_version" = "$new_version" ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_warn "Update available: $current_version -> $new_version"
    exit 1
  fi

  if has_version_entry "$new_version" && [ "$current_version" = "$new_version" ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"
    exit 0
  fi

  local wheel_url wheel_hash
  wheel_url="$(get_wheel_url_for_version "$new_version")"
  [ -n "$wheel_url" ] || { log_error "Failed to resolve wheel URL for $new_version"; exit 1; }
  wheel_hash="$(prefetch_sha256_sri "$wheel_url")"
  [ -n "$wheel_hash" ] || { log_error "Failed to prefetch wheel hash"; exit 1; }
  log_info "Wheel URL:  $wheel_url"
  log_info "Wheel hash: $wheel_hash"

  local entry_json
  entry_json="$(jq -n \
    --arg v "$new_version" \
    --arg url "$wheel_url" \
    --arg hash "$wheel_hash" \
    '{version: $v, url: $url, hash: $hash}')"

  local backup
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  upsert_release_entry "$new_version" "$entry_json"

  local sanitized_key
  sanitized_key="$(sanitize_key "$new_version")"

  if [ "$no_build" != true ]; then
    if ! verify_build "$sanitized_key"; then
      log_error "Build verification failed; restoring previous releases.json"
      cp "$backup" "$releases_file"
      rm -f "$backup"
      exit 1
    fi
  fi

  rm -f "$backup"

  local commit_message
  if [ "$current_version" != "$new_version" ]; then
    commit_message="chore(${PACKAGE_DIR_NAME}): bump to ${new_version}"
  elif [ "$rehash" = true ]; then
    commit_message="chore(${PACKAGE_DIR_NAME}): rehash ${new_version}"
  else
    commit_message="chore(${PACKAGE_DIR_NAME}): update version"
  fi

  maybe_git_commit "$commit_message" "releases.json"

  log_info "Successfully appended trunks $new_version (latest was $current_version)"
}

main "$@"
