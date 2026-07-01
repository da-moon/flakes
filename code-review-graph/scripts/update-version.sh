#!/usr/bin/env bash
# Appends the newest (or an explicit) code-review-graph PyPI release to
# releases.json (the JSON version table the flake reads) as a new version-table
# entry (keyed by version) and sets .latest to it. Recomputes the universal
# py3-none-any wheel URL + hash via jq — the version data in flake.nix is never
# touched. Existing entries are preserved so consumers can still select past
# versions.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly PYPI_PACKAGE="code-review-graph"
readonly PACKAGE_ATTR="code-review-graph"
readonly BIN_NAME="code-review-graph"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v jq >/dev/null 2>&1 || { log_error "jq is required but not installed."; exit 2; }
  command -v curl >/dev/null 2>&1 || { log_error "curl is required but not installed."; exit 2; }
  command -v python3 >/dev/null 2>&1 || { log_error "python3 is required but not installed."; exit 2; }
}

ensure_in_package_directory() {
  if [ ! -f "$flake_file" ]; then
    log_error "flake.nix not found at: $flake_file"
    exit 2
  fi
  if [ ! -f "$releases_file" ]; then
    log_error "releases.json not found at: $releases_file"
    exit 2
  fi
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

# sanitize a JSON key into a valid nix attribute-name suffix (mirrors flake.nix)
sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
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

verify_build() {
  local sanitized_key="$1"
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build ".#code-review-graph_${sanitized_key}" --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for code-review-graph_${sanitized_key}"
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
  log_info "Build successful!"
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat releases.json 2>/dev/null || true
  fi
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
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) code-review-graph PyPI release to
releases.json as a new version-table entry (keyed by version) and sets .latest
to it. Existing entries are preserved so consumers can still select past
versions.

Options:
  --version VERSION   Append a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Re-upsert the current latest entry (recompute URL + hash)
  --no-build          Skip build verification
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 2.3.2
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local target_version=""
  local check_only=false
  local rehash=false
  local no_build=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        target_version="$2"
        shift 2
        ;;
      --check)
        check_only=true
        shift
        ;;
      --rehash)
        rehash=true
        shift
        ;;
      --no-build)
        no_build=true
        shift
        ;;
      --help)
        print_usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        print_usage
        exit 2
        ;;
    esac
  done

  local current_version
  current_version="$(get_current_version)"
  if [ -z "$current_version" ]; then
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi

  local latest_version
  if [ -n "$target_version" ]; then
    latest_version="$target_version"
  else
    latest_version="$(get_latest_version_from_pypi)"
  fi
  if [ -z "$latest_version" ]; then
    log_error "Failed to fetch latest version"
    exit 2
  fi

  log_info "Current latest: $current_version"
  log_info "Target version:  $latest_version"

  if [ "$check_only" = true ]; then
    if has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: $current_version -> $latest_version"
    exit 1
  fi

  if [ "$rehash" != true ] && has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ]; then
    log_info "Already up to date!"
    exit 0
  fi

  log_info "Resolving wheel URL for ${latest_version}..."
  local wheel_url
  wheel_url="$(get_wheel_url_for_version "$latest_version")"
  if [ -z "$wheel_url" ]; then
    log_error "Failed to determine wheel URL for ${latest_version}"
    exit 2
  fi

  local wheel_hash
  wheel_hash="$(prefetch_sha256_sri "$wheel_url")"
  if [ -z "$wheel_hash" ]; then
    log_error "Failed to prefetch wheel hash for ${latest_version}"
    exit 2
  fi

  log_info "Wheel URL:  $wheel_url"
  log_info "Wheel hash: $wheel_hash"

  local entry_json
  entry_json="$(jq -n \
    --arg v "$latest_version" \
    --arg rev "$latest_version" \
    --arg url "$wheel_url" \
    --arg hash "$wheel_hash" \
    '{version: $v, rev: $rev, url: $url, hash: $hash}')"

  local backup
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  upsert_release_entry "$latest_version" "$entry_json"

  local sanitized_key
  sanitized_key="$(sanitize_key "$latest_version")"

  if [ "$no_build" != true ]; then
    if ! verify_build "$sanitized_key"; then
      log_error "Build verification failed; restoring previous releases.json"
      cp "$backup" "$releases_file"
      rm -f "$backup"
      exit 1
    fi
  fi

  rm -f "$backup"

  show_changes

  local scope msg
  scope="$(basename "$pkg_dir")"
  if [ "$latest_version" = "$current_version" ]; then
    msg="chore(${scope}): rehash ${latest_version}"
  else
    msg="chore(${scope}): bump to ${latest_version}"
  fi
  maybe_git_commit "$msg" "releases.json"

  log_info "Successfully appended code-review-graph $latest_version (latest was $current_version)"
}

main "$@"
