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
readonly REPO_OWNER="steveyegge"
readonly REPO_NAME="beads"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"

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
  sed -n 's/^[[:space:]]*version = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
}

get_latest_release_tag() {
  local release_json
  release_json="$(curl -fsSL "$GITHUB_API_BASE/repos/$REPO_OWNER/$REPO_NAME/releases/latest")"
  printf '%s\n' "$release_json" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

tag_to_version() {
  local tag="$1"
  tag="${tag#v}"
  printf '%s\n' "$tag"
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

update_arch_sha256() {
  local system_key="$1" # "aarch64-linux" or "x86_64-linux"
  local new_sha256="$2"
  sed -i.bak -E "/\"${system_key}\"[[:space:]]*=[[:space:]]*\\{/,/\\};/ s|^([[:space:]]*sha256 = \")[^\"]*(\";)|\\1${new_sha256}\\2|" "$flake_file"
}

cleanup_backups() {
  rm -f "${flake_file}.bak" 2>/dev/null || true
}

update_flake_lock() {
  log_info "Updating flake.lock..."
  (cd "$pkg_dir" && nix flake update)
}

verify_build() {
  log_info "Verifying build..."
  local out_path
  out_path="$(cd "$pkg_dir" && nix build .#beads --no-link --print-out-paths)"
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/bd" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/bd"
    return 1
  fi
  "$out_path/bin/bd" --help >/dev/null 2>&1 || true
  log_info "Build successful!"
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat flake.nix flake.lock 2>/dev/null || true
  fi
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Options:
  --version VERSION   Update to a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute release asset hashes for current version
  --no-build          Skip build verification
  --update-lock       Run 'nix flake update' after updating
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 0.29.0
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory

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
    log_error "Failed to detect current version from flake.nix"
    exit 2
  fi

  local latest_tag
  latest_tag="$(get_latest_release_tag)"
  if [ -z "$latest_tag" ]; then
    log_error "Failed to fetch latest release from GitHub"
    exit 2
  fi

  local latest_version
  latest_version="$(tag_to_version "$latest_tag")"
  if [ -z "$latest_version" ]; then
    log_error "Failed to derive version from tag: $latest_tag"
    exit 2
  fi

  if [ -n "$target_version" ]; then
    latest_version="$target_version"
    latest_tag="v$target_version"
  fi

  log_info "Current version: $current_version"
  log_info "Target version:  $latest_version"

  if [ "$check_only" = true ]; then
    if [ "$current_version" = "$latest_version" ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: $current_version -> $latest_version"
    exit 1
  fi

  if [ "$current_version" = "$latest_version" ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"
    exit 0
  fi

  local url_aarch64 url_x86_64
  url_aarch64="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$latest_tag/beads_${latest_version}_linux_arm64.tar.gz"
  url_x86_64="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$latest_tag/beads_${latest_version}_linux_amd64.tar.gz"

  log_info "Prefetching tarball hashes..."
  local hash_aarch64 hash_x86_64
  hash_aarch64="$(prefetch_sha256_sri "$url_aarch64")"
  hash_x86_64="$(prefetch_sha256_sri "$url_x86_64")"

  if [ -z "$hash_aarch64" ] || [ -z "$hash_x86_64" ]; then
    log_error "Failed to prefetch one or more tarball hashes"
    exit 2
  fi

  log_info "aarch64 hash: $hash_aarch64"
  log_info "x86_64 hash:  $hash_x86_64"

  local backup
  backup="$(mktemp -t flake.nix.backup.XXXXXX)"
  cp "$flake_file" "$backup"

  cleanup_backups
  update_flake_version "$latest_version"
  update_arch_sha256 "aarch64-linux" "$hash_aarch64"
  update_arch_sha256 "x86_64-linux" "$hash_x86_64"
  cleanup_backups

  if [ "$no_build" != true ]; then
    if ! verify_build; then
      log_error "Build verification failed; restoring previous flake.nix"
      cp "$backup" "$flake_file"
      rm -f "$backup"
      exit 1
    fi
  fi

  rm -f "$backup"

  if [ "$update_lock" = true ]; then
    update_flake_lock
  fi

  show_changes
  log_info "Successfully updated beads from $current_version to $latest_version"
}

main "$@"
