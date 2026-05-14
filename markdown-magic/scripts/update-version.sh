#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly NPM_REGISTRY_URL="https://registry.npmjs.org"
readonly NPM_PACKAGE="markdown-magic"
readonly TARBALL_NAME="markdown-magic"
readonly PACKAGE_ATTR="markdown-magic"
readonly BIN_NAME="md-magic"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v curl >/dev/null 2>&1 || { log_error "curl is required but not installed."; exit 2; }
  command -v sed >/dev/null 2>&1 || { log_error "sed is required but not installed."; exit 2; }
  command -v grep >/dev/null 2>&1 || { log_error "grep is required but not installed."; exit 2; }
}

get_current_version() {
  sed -n 's/^[[:space:]]*version = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
}

get_latest_version_from_npm() {
  curl -fsSL "$NPM_REGISTRY_URL/$NPM_PACKAGE/latest" \
    | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n1
}

get_current_system_key() {
  nix eval --impure --raw --expr builtins.currentSystem
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' \
    | head -n1
}

extract_got_hash_from_build() {
  sed -n 's/.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' | head -n1
}

has_fake_hash() {
  grep -Eq 'outputHash = (pkgs\.lib\.fakeHash|"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=");' "$flake_file"
}

update_flake_version() {
  local new_version="$1"
  sed -i.bak -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1${new_version}\\2/" "$flake_file"
}

update_tarball_hash() {
  local new_hash="$1"
  sed -i.bak -E "/src = pkgs.fetchurl[[:space:]]*\\{/,/\\};/ s|^([[:space:]]*hash = \")[^\"]*(\";)|\\1${new_hash}\\2|" "$flake_file"
}

set_output_hash_placeholder() {
  local placeholder="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  sed -i.bak -E "s|^([[:space:]]*outputHash = )(\"[^\"]*\"|pkgs\\.lib\\.fakeHash)(;)|\\1\"${placeholder}\"\\3|" "$flake_file"
}

update_output_hash() {
  local new_hash_value="$1"
  sed -i.bak -E "s|^([[:space:]]*outputHash = \")[^\"]*(\";)|\\1${new_hash_value}\\2|" "$flake_file"
}

cleanup_backups() {
  rm -f "${flake_file}.bak" 2>/dev/null || true
}
trap cleanup_backups EXIT

compute_and_update_output_hash() {
  local system_key
  system_key="$(get_current_system_key)"
  log_info "Computing npm dependency hash for ${system_key}..."

  set_output_hash_placeholder
  cleanup_backups

  local build_output got_hash
  build_output="$(cd "$pkg_dir" && nix build ".#${PACKAGE_ATTR}" --no-link --no-write-lock-file 2>&1 || true)"
  got_hash="$(printf '%s\n' "$build_output" | extract_got_hash_from_build)"
  if [ -z "$got_hash" ]; then
    log_error "Failed to parse outputHash from nix build output"
    printf '%s\n' "$build_output" | sed -n '1,160p' >&2
    return 1
  fi

  log_info "outputHash (${system_key}): ${got_hash}"
  update_output_hash "$got_hash"
  cleanup_backups
}

verify_build() {
  log_info "Verifying build..."
  local out_path
  out_path="$(cd "$pkg_dir" && nix build ".#${PACKAGE_ATTR}" --no-link --print-out-paths --no-write-lock-file)"
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/$BIN_NAME"
    return 1
  fi
  "$out_path/bin/$BIN_NAME" --version >/dev/null
  log_info "Build successful."
}

update_flake_lock() {
  log_info "Updating flake.lock..."
  (cd "$pkg_dir" && nix flake update)
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat flake.nix flake.lock 2>/dev/null || true
  fi
}

print_usage() {
  cat <<'USAGE'
Usage: ./scripts/update-version.sh [OPTIONS]

Options:
  --version VERSION   Update to a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute tarball hash and npm dependency hash
  --no-build          Skip final build verification
  --update-lock       Run 'nix flake update' after updating
  --help              Show this help message
USAGE
}

main() {
  ensure_required_tools_installed
  [ -f "$flake_file" ] || { log_error "flake.nix not found at: $flake_file"; exit 2; }

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

  local current_version latest_version tarball_url tarball_hash backup
  current_version="$(get_current_version)"
  latest_version="${target_version:-$(get_latest_version_from_npm)}"

  log_info "Current version: $current_version"
  log_info "Target version:  $latest_version"

  if [ "$check_only" = true ]; then
    [ "$current_version" = "$latest_version" ] && exit 0
    log_warn "Update available: $current_version -> $latest_version"
    exit 1
  fi

  if [ "$current_version" = "$latest_version" ] && [ "$rehash" != true ]; then
    if has_fake_hash; then
      rehash=true
    else
      log_info "Already up to date."
      exit 0
    fi
  fi

  tarball_url="$NPM_REGISTRY_URL/$NPM_PACKAGE/-/$TARBALL_NAME-$latest_version.tgz"
  tarball_hash="$(prefetch_sha256_sri "$tarball_url")"
  [ -n "$tarball_hash" ] || { log_error "Failed to prefetch tarball hash"; exit 1; }

  backup="$(mktemp -t flake.nix.backup.XXXXXX)"
  cp "$flake_file" "$backup"

  update_flake_version "$latest_version"
  update_tarball_hash "$tarball_hash"
  cleanup_backups

  if [ "$current_version" != "$latest_version" ] || [ "$rehash" = true ]; then
    if ! compute_and_update_output_hash; then
      cp "$backup" "$flake_file"
      rm -f "$backup"
      exit 1
    fi
  fi

  if [ "$no_build" != true ]; then
    if ! verify_build; then
      cp "$backup" "$flake_file"
      rm -f "$backup"
      exit 1
    fi
  fi

  rm -f "$backup"
  [ "$update_lock" = true ] && update_flake_lock
  show_changes
  log_warn "The dependency hash was refreshed on the current system; re-run --rehash if a future release adds platform-specific dependencies."
}

main "$@"
