#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly PYPI_API_URL="https://pypi.org/pypi/mcpdoc/json"
readonly PACKAGE_NAME="mcpdoc"
readonly PACKAGE_ATTR="mcpdoc"
readonly BIN_NAME="mcpdoc"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v curl >/dev/null 2>&1 || { log_error "curl is required but not installed."; exit 2; }
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

get_latest_version_from_pypi() {
  local latest_json
  latest_json="$(curl -fsSL "$PYPI_API_URL")"
  printf '%s\n' "$latest_json" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

get_source_hash_for_system() {
  local target_system="$1"
  awk -v target="$target_system" '
    /sourceHashBySystem = {/ { in_map = 1; next }
    in_map && /};/ { in_map = 0 }
    in_map && $0 ~ "\"" target "\"" {
      if (match($0, /"[^"]+"[[:space:]]*= "([^"]+)";/, a) > 0) {
        print a[1]
      }
    }
  ' "$flake_file"
}

get_package_url() {
  local version="$1"
  printf 'https://files.pythonhosted.org/packages/source/m/%s/%s-%s.tar.gz' \
    "$PACKAGE_NAME" "$PACKAGE_NAME" "$version"
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' \
    | head -n1
}

set_version() {
  local new_version="$1"
  sed -i.bak -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1${new_version}\\2/" "$flake_file"
}

set_source_hash_map() {
  local new_hash="$1"
  sed -i.bak -E "s@(\"aarch64-linux\"[[:space:]]*= \")[^\"]*(\";)@\1${new_hash}\2@" "$flake_file"
  sed -i.bak -E "s@(\"x86_64-linux\"[[:space:]]*= \")[^\"]*(\";)@\1${new_hash}\2@" "$flake_file"
}

cleanup_backups() {
  rm -f "${flake_file}.bak" 2>/dev/null || true
}

verify_build() {
  log_info "Verifying build..."
  local out_path
  out_path="$(cd "$pkg_dir" && nix build .#${PACKAGE_ATTR} --no-link --print-out-paths)"
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
  cat <<'USAGE'
Usage: ./scripts/update-version.sh [OPTIONS]

Options:
  --version VERSION   Update to a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute source hash for current version
  --no-build          Skip build verification
  --update-lock       Run 'nix flake update' after updating
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --version 0.0.10
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --rehash
USAGE
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local target_version=""
  local check_only=false
  local rehash=false
  local no_build=false
  local refresh_lock=false

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
      refresh_lock=true
        shift
        ;;
      --help)
        print_usage
        exit 0
        ;;
      *)
        log_error "Unknown argument: $1"
        print_usage
        exit 2
        ;;
    esac
  done

  local current_version
  current_version="$(get_current_version)"
  if [ -z "$current_version" ]; then
    log_error "Could not determine current version from flake.nix"
    exit 2
  fi

  local latest_version
  latest_version="$(get_latest_version_from_pypi)"
  if [ -z "$latest_version" ]; then
    log_error "Failed to fetch latest version from PyPI"
    exit 2
  fi

  local new_version="${target_version:-$latest_version}"

  local needs_update=false
  if [ "$current_version" != "$new_version" ]; then
    needs_update=true
  fi

  if [ "$check_only" = true ]; then
    if [ "$needs_update" = true ]; then
      log_warn "Update available: $current_version -> $new_version"
      exit 1
    fi
    log_info "No update needed. Current version is $current_version"
    exit 0
  fi

  if [ "$needs_update" = false ] && [ "$rehash" = false ]; then
    log_warn "No update requested. Version is already $current_version"
    exit 0
  fi

  local current_aarch_hash
  local current_x86_hash
  current_aarch_hash="$(get_source_hash_for_system aarch64-linux | head -n1)"
  current_x86_hash="$(get_source_hash_for_system x86_64-linux | head -n1)"

  if [ "$needs_update" = true ]; then
    set_version "$new_version"
  fi

  local package_url
  local new_hash
  package_url="$(get_package_url "$new_version")"
  new_hash="$(prefetch_sha256_sri "$package_url")"

  if [ -z "$new_hash" ]; then
    log_error "Failed to compute source hash for $new_version"
    exit 1
  fi

  if [ "$needs_update" = true ] || [ "$rehash" = true ] || [ "$current_aarch_hash" != "$new_hash" ] || [ "$current_x86_hash" != "$new_hash" ]; then
    set_source_hash_map "$new_hash"
  fi

  cleanup_backups

  if [ "$no_build" = false ]; then
    verify_build
  fi

  if [ "$refresh_lock" = true ]; then
    update_flake_lock
  fi

  local commit_message
  commit_message="$(build_commit_message "$current_version" "$new_version" "$rehash")"
  maybe_git_commit "$commit_message" flake.nix flake.lock
}

main "$@"
