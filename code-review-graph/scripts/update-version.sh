#!/usr/bin/env bash
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
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v curl >/dev/null 2>&1 || { log_error "curl is required but not installed."; exit 2; }
  command -v python3 >/dev/null 2>&1 || { log_error "python3 is required but not installed."; exit 2; }
  command -v sed >/dev/null 2>&1 || { log_error "sed is required but not installed."; exit 2; }
}

ensure_in_package_directory() {
  if [ ! -f "$flake_file" ]; then
    log_error "flake.nix not found at: $flake_file"
    exit 2
  fi
}

get_current_version() {
  sed -n 's/^[[:space:]]*version = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
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
    | sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' \
    | head -n1
}

update_flake_version() {
  local new_version="$1"
  sed -i.bak -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1${new_version}\\2/" "$flake_file"
}

update_wheel_url() {
  local new_version="$1"
  local new_url="$2"
  sed -i.bak -E "0,/code_review_graph-[^\"]*-py3-none-any\\.whl/s|https://files\\.pythonhosted\\.org/packages/[^\"]*/code_review_graph-[^\"]*-py3-none-any\\.whl|${new_url}|" "$flake_file"
  sed -i.bak -E "0,/code_review_graph-[0-9][^\"]*-py3-none-any\\.whl/s|code_review_graph-[0-9][^\"]*-py3-none-any\\.whl|code_review_graph-${new_version}-py3-none-any.whl|" "$flake_file"
}

update_wheel_hash() {
  local new_hash="$1"
  sed -i.bak -E "0,/^[[:space:]]*hash = \"/s|^([[:space:]]*hash = \")[^\"]*(\";)|\\1${new_hash}\\2|" "$flake_file"
}

cleanup_backups() {
  rm -f "${flake_file}.bak" 2>/dev/null || true
}

trap cleanup_backups EXIT

update_flake_lock() {
  log_info "Updating flake.lock..."
  (cd "$pkg_dir" && nix flake update)
}

verify_build() {
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build .#${PACKAGE_ATTR} --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for ${PACKAGE_ATTR}"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/$BIN_NAME"
    return 1
  fi
  "$out_path/bin/$BIN_NAME" --version >/dev/null
  log_info "Build successful!"
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat flake.nix flake.lock 2>/dev/null || true
  fi
}

build_commit_message() {
  local previous_version="$1"
  local new_version="$2"
  local rehash="${3:-false}"

  local scope
  scope="$(basename "$pkg_dir")"

  if [ "$previous_version" != "$new_version" ]; then
    printf 'chore(%s): bump to %s\n' "$scope" "$new_version"
    return 0
  fi

  if [ "$rehash" = true ]; then
    printf 'chore(%s): rehash %s\n' "$scope" "$new_version"
    return 0
  fi

  printf 'chore(%s): update version\n' "$scope"
}

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

  if git -C "$pkg_dir" diff --quiet -- "${paths[@]}" && git -C "$pkg_dir" diff --cached --quiet -- "${paths[@]}"; then
    return 0
  fi

  git -C "$pkg_dir" add -- "${paths[@]}"

  if git -C "$pkg_dir" diff --cached --quiet -- "${paths[@]}"; then
    return 0
  fi

  git -C "$pkg_dir" commit --only -m "$commit_message" -- "${paths[@]}"
  log_info "Committed: $commit_message"
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Options:
  --version VERSION   Update to a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute the wheel hash for the current version
  --no-build          Skip build verification
  --update-lock       Run 'nix flake update' after updating
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
  local update_lock=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        target_version="${2:-}"
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
      --update-lock)
        update_lock=true
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
    log_error "Failed to determine current version from flake.nix"
    exit 1
  fi

  if [ -z "$target_version" ]; then
    target_version="$(get_latest_version_from_pypi)"
  fi

  log_info "Current version: $current_version"
  log_info "Target version:  $target_version"

  if [ "$check_only" = true ]; then
    if [ "$current_version" = "$target_version" ]; then
      log_info "Package is up to date."
      exit 0
    fi
    log_warn "Update available: $current_version -> $target_version"
    exit 1
  fi

  local commit_message
  commit_message="$(build_commit_message "$current_version" "$target_version" "$rehash")"

  if [ "$current_version" != "$target_version" ]; then
    update_flake_version "$target_version"
    cleanup_backups
  fi

  if [ "$rehash" = true ] || [ "$current_version" != "$target_version" ]; then
    local wheel_url
    wheel_url="$(get_wheel_url_for_version "$target_version")"
    if [ -z "$wheel_url" ]; then
      log_error "Failed to determine wheel URL for ${target_version}"
      exit 1
    fi

    local wheel_hash
    wheel_hash="$(prefetch_sha256_sri "$wheel_url")"
    if [ -z "$wheel_hash" ]; then
      log_error "Failed to prefetch wheel hash for ${target_version}"
      exit 1
    fi

    log_info "Wheel URL:  $wheel_url"
    log_info "Wheel hash: $wheel_hash"
    update_wheel_url "$target_version" "$wheel_url"
    update_wheel_hash "$wheel_hash"
    cleanup_backups
  fi

  if [ "$update_lock" = true ] && [ -f "${pkg_dir}/flake.lock" ]; then
    update_flake_lock
  fi

  show_changes

  if [ "$no_build" != true ]; then
    verify_build
  fi

  maybe_git_commit "$commit_message" flake.nix scripts/update-version.sh
  log_info "Done."
}

main "$@"
