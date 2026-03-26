#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly GITHUB_API_BASE="https://api.github.com"
readonly REPO_OWNER="NousResearch"
readonly REPO_NAME="hermes-agent"
readonly PACKAGE_ATTR="hermes-agent"
readonly BIN_NAME="hermes"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v nix-prefetch-url >/dev/null 2>&1 || { log_error "nix-prefetch-url is required but not installed."; exit 2; }
  command -v curl >/dev/null 2>&1 || { log_error "curl is required but not installed."; exit 2; }
  command -v git >/dev/null 2>&1 || { log_error "git is required but not installed."; exit 2; }
  command -v sed >/dev/null 2>&1 || { log_error "sed is required but not installed."; exit 2; }
}

ensure_in_package_directory() {
  if [ ! -f "$flake_file" ]; then
    log_error "flake.nix not found at: $flake_file"
    exit 2
  fi
}

get_current_version() {
  sed -n 's/^[[:space:]]*version = "\([^"]*\)";/\1/p' "$flake_file" | head -n1
}

get_current_revision() {
  sed -n 's/^[[:space:]]*revision = "\([^"]*\)";/\1/p' "$flake_file" | head -n1
}

get_latest_revision() {
  git ls-remote "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" refs/heads/main | awk '{print $1}'
}

get_commit_date() {
  local revision="$1"
  local commit_json
  commit_json="$(curl -fsSL "${GITHUB_API_BASE}/repos/${REPO_OWNER}/${REPO_NAME}/commits/${revision}")"
  printf '%s\n' "$commit_json" | sed -n 's/.*"date":[[:space:]]*"\([0-9-]*\)T.*/\1/p' | head -n1
}

prefetch_sha256_sri() {
  local url="$1"
  local hash_base32
  hash_base32="$(nix-prefetch-url --unpack "$url")"
  if [ -z "$hash_base32" ]; then
    return 1
  fi
  nix hash to-sri --type sha256 "$hash_base32"
}

set_version() {
  local new_version="$1"
  sed -i.bak -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1${new_version}\\2/" "$flake_file"
}

set_revision() {
  local new_revision="$1"
  sed -i.bak -E "s/^([[:space:]]*revision = \")[^\"]*(\";)/\\1${new_revision}\\2/" "$flake_file"
}

set_source_hash_map() {
  local new_hash="$1"
  sed -i.bak -E "s@(\"aarch64-linux\"[[:space:]]*= \")[^\"]*(\";)@\1${new_hash}\2@" "$flake_file"
  sed -i.bak -E "s@(\"x86_64-linux\"[[:space:]]*= \")[^\"]*(\";)@\1${new_hash}\2@" "$flake_file"
}

cleanup_backups() {
  rm -f "${flake_file}.bak" 2>/dev/null || true
}

trap cleanup_backups EXIT

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat flake.nix flake.lock 2>/dev/null || true
  fi
}

verify_build() {
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build .#${PACKAGE_ATTR} --no-link --print-out-paths)"; then
    log_error "nix build failed for ${PACKAGE_ATTR}"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/$BIN_NAME"
    return 1
  fi
  "$out_path/bin/$BIN_NAME" --help >/dev/null 2>&1 || true
  log_info "Build successful."
}

update_flake_lock() {
  log_info "Updating flake.lock..."
  (cd "$pkg_dir" && nix flake update)
}

build_commit_message() {
  local previous_revision="$1"
  local new_revision="$2"
  local previous_version="$3"
  local new_version="$4"
  local rehash="${5:-false}"

  local scope
  scope="$(basename "$pkg_dir")"

  if [ "$previous_version" != "$new_version" ]; then
    printf 'chore(%s): bump to %s\n' "$scope" "$new_version"
    return 0
  fi

  if [ "$previous_revision" != "$new_revision" ]; then
    printf 'chore(%s): update source to %s\n' "$scope" "${new_revision:0:7}"
    return 0
  fi

  if [ "$rehash" = true ]; then
    printf 'chore(%s): rehash %s\n' "$scope" "$new_version"
    return 0
  fi

  printf 'chore(%s): refresh source metadata\n' "$scope"
}

maybe_git_commit() {
  local commit_message="$1"
  shift
  local -a paths=("$@")

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
  cat <<'USAGE'
Usage: ./scripts/update-version.sh [OPTIONS]

Options:
  --revision REV      Update to a specific upstream revision (default: main HEAD)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute source hash for current revision
  --no-build          Skip build verification
  --update-lock       Run 'nix flake update' after updating
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --revision 6d3804770cbf03d4a6519da904ad92ce6b70cb62
  ./scripts/update-version.sh --rehash
USAGE
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local target_revision=""
  local check_only=false
  local rehash=false
  local no_build=false
  local refresh_lock=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --revision)
        target_revision="${2:-}"
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
        refresh_lock=true
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
  local current_revision
  current_revision="$(get_current_revision)"

  if [ -z "$current_version" ] || [ -z "$current_revision" ]; then
    log_error "Failed to determine current version or revision from flake.nix"
    exit 2
  fi

  local latest_revision
  latest_revision="${target_revision:-$(get_latest_revision)}"
  if [ -z "$latest_revision" ]; then
    log_error "Failed to determine latest upstream revision"
    exit 2
  fi

  local commit_date
  commit_date="$(get_commit_date "$latest_revision")"
  if [ -z "$commit_date" ]; then
    log_error "Failed to determine upstream commit date for revision: $latest_revision"
    exit 2
  fi

  local latest_version="unstable-${commit_date}"

  log_info "Current version:  $current_version"
  log_info "Current revision: ${current_revision:0:7}"
  log_info "Target version:   $latest_version"
  log_info "Target revision:  ${latest_revision:0:7}"

  if [ "$check_only" = true ]; then
    if [ "$current_revision" = "$latest_revision" ] && [ "$current_version" = "$latest_version" ]; then
      log_info "Already up to date."
      exit 0
    fi
    log_warn "Update available."
    exit 1
  fi

  if [ "$current_revision" = "$latest_revision" ] && [ "$current_version" = "$latest_version" ] && [ "$rehash" != true ]; then
    log_info "Already up to date."
    exit 0
  fi

  local archive_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/${latest_revision}.tar.gz"
  log_info "Prefetching source hash..."
  local source_hash
  source_hash="$(prefetch_sha256_sri "$archive_url")"
  if [ -z "$source_hash" ]; then
    log_error "Failed to prefetch source hash"
    exit 1
  fi

  local backup
  backup="$(mktemp -t flake.nix.backup.XXXXXX)"
  cp "$flake_file" "$backup"

  set_version "$latest_version"
  set_revision "$latest_revision"
  set_source_hash_map "$source_hash"
  cleanup_backups

  if [ "$no_build" = false ]; then
    if ! verify_build; then
      log_error "Build verification failed; restoring previous flake.nix"
      cp "$backup" "$flake_file"
      rm -f "$backup"
      exit 1
    fi
  fi

  rm -f "$backup"

  if [ "$refresh_lock" = true ]; then
    update_flake_lock
  fi

  show_changes

  local commit_message
  commit_message="$(build_commit_message "$current_revision" "$latest_revision" "$current_version" "$latest_version" "$rehash")"
  local -a commit_paths=("flake.nix")
  if [ -f "$pkg_dir/flake.lock" ]; then
    commit_paths+=("flake.lock")
  fi
  maybe_git_commit "$commit_message" "${commit_paths[@]}"

  log_info "Update complete."
}

main "$@"
