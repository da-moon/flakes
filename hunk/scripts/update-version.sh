#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly REPO_OWNER="modem-dev"
readonly REPO_NAME="hunk"
readonly PACKAGE_ATTR="hunk"
readonly BIN_NAME="hunk"
readonly TAG_PREFIX="v"

declare -Ar ASSET_BY_SYSTEM=(
  [x86_64-linux]="hunkdiff-linux-x64.tar.gz"
  [aarch64-linux]="hunkdiff-linux-arm64.tar.gz"
)

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v curl >/dev/null 2>&1 || { log_error "curl is required but not installed."; exit 2; }
  command -v sed >/dev/null 2>&1 || { log_error "sed is required but not installed."; exit 2; }
}

get_current_version() {
  sed -n 's/^[[:space:]]*version = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
}

get_latest_release_tag() {
  local effective_url
  effective_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest")"
  printf '%s\n' "${effective_url##*/}"
}

tag_to_version() {
  local tag="$1"
  tag="${tag#${TAG_PREFIX}}"
  printf '%s\n' "$tag"
}

asset_url() {
  local version="$1"
  local asset="$2"
  printf 'https://github.com/%s/%s/releases/download/%s%s/%s\n' "$REPO_OWNER" "$REPO_NAME" "$TAG_PREFIX" "$version" "$asset"
}

prefetch_sha256_sri() {
  nix store prefetch-file --json --hash-type sha256 "$1" \
    | sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' \
    | head -n1
}

update_flake_version() {
  sed -i.bak -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1$1\\2/" "$flake_file"
}

update_system_hash() {
  local system_key="$1"
  local hash="$2"
  sed -i.bak -E "/\"${system_key}\"[[:space:]]*=[[:space:]]*\\{/,/\\};/ s|^([[:space:]]*hash = \")[^\"]*(\";)|\\1${hash}\\2|" "$flake_file"
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
  if ! out_path="$(cd "$pkg_dir" && nix build ".#${PACKAGE_ATTR}" --no-link --print-out-paths)"; then
    log_error "nix build failed for ${PACKAGE_ATTR}"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/$BIN_NAME"
    return 1
  fi
  "$out_path/bin/$BIN_NAME" --help >/dev/null 2>&1 || true
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
  if [ "$previous_version" != "$new_version" ]; then
    printf 'chore(%s): bump to %s\n' "$PACKAGE_DIR_NAME" "$new_version"
  elif [ "$rehash" = true ]; then
    printf 'chore(%s): rehash %s\n' "$PACKAGE_DIR_NAME" "$new_version"
  else
    printf 'chore(%s): update version\n' "$PACKAGE_DIR_NAME"
  fi
}

maybe_git_commit() {
  local commit_message="$1"
  shift
  local -a paths=("$@")

  if ! command -v git >/dev/null 2>&1 || ! git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  if git -C "$pkg_dir" diff --quiet -- "${paths[@]}" && git -C "$pkg_dir" diff --cached --quiet -- "${paths[@]}"; then
    return 0
  fi
  git -C "$pkg_dir" add -- "${paths[@]}"
  if ! git -C "$pkg_dir" diff --cached --quiet -- "${paths[@]}"; then
    git -C "$pkg_dir" commit --only -m "$commit_message" -- "${paths[@]}"
    log_info "Committed: $commit_message"
  fi
}

print_usage() {
  cat <<EOF
Usage: ./scripts/update-version.sh [OPTIONS]

Options:
  --version VERSION   Update to a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute release asset hashes for current version
  --no-build          Skip build verification
  --update-lock       Run 'nix flake update' after updating
  --help              Show this help message
EOF
}

main() {
  ensure_required_tools_installed
  [ -f "$flake_file" ] || { log_error "flake.nix not found at: $flake_file"; exit 2; }
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local target_version="" check_only=false rehash=false no_build=false update_lock=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) target_version="${2:-}"; shift 2 ;;
      --check) check_only=true; shift ;;
      --rehash) rehash=true; shift ;;
      --no-build) no_build=true; shift ;;
      --update-lock) update_lock=true; shift ;;
      --help) print_usage; exit 0 ;;
      *) log_error "Unknown option: $1"; print_usage; exit 2 ;;
    esac
  done

  local current_version latest_version latest_tag
  current_version="$(get_current_version)"
  if [ -n "$target_version" ]; then
    latest_version="$target_version"
  else
    latest_tag="$(get_latest_release_tag)"
    latest_version="$(tag_to_version "$latest_tag")"
  fi

  if [ "$check_only" = true ]; then
    if [ "$current_version" = "$latest_version" ]; then
      log_info "${PACKAGE_DIR_NAME} is up to date (${current_version})"
      exit 0
    fi
    log_warn "Update available: ${current_version} -> ${latest_version}"
    exit 1
  fi

  if [ "$current_version" = "$latest_version" ] && [ "$rehash" = false ]; then
    log_info "${PACKAGE_DIR_NAME} is already at ${current_version}"
    exit 0
  fi

  update_flake_version "$latest_version"

  local system_key asset hash
  for system_key in "${!ASSET_BY_SYSTEM[@]}"; do
    asset="${ASSET_BY_SYSTEM[$system_key]}"
    log_info "Prefetching ${asset}"
    hash="$(prefetch_sha256_sri "$(asset_url "$latest_version" "$asset")")"
    [ -n "$hash" ] || { log_error "Failed to prefetch ${asset}"; exit 2; }
    update_system_hash "$system_key" "$hash"
  done
  cleanup_backups

  if [ "$update_lock" = true ]; then
    update_flake_lock
  fi
  if [ "$no_build" = false ]; then
    verify_build
  fi
  show_changes

  local -a commit_paths=(flake.nix scripts/update-version.sh)
  [ -f "$pkg_dir/flake.lock" ] && commit_paths+=(flake.lock)
  maybe_git_commit "$(build_commit_message "$current_version" "$latest_version" "$rehash")" "${commit_paths[@]}"
}

main "$@"
