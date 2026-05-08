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
readonly NPM_PACKAGE="gsd-pi"
readonly TARBALL_NAME="gsd-pi"
readonly PACKAGE_ATTR="gsd-2"
readonly BIN_NAME="gsd"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v curl >/dev/null 2>&1 || { log_error "curl is required but not installed."; exit 2; }
  command -v sed >/dev/null 2>&1 || { log_error "sed is required but not installed."; exit 2; }
  command -v awk >/dev/null 2>&1 || { log_error "awk is required but not installed."; exit 2; }
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

get_other_output_hash_systems() {
  local current_system_key="$1"
  awk -v target="$current_system_key" '
    /outputHashBySystem[[:space:]]*=[[:space:]]*\{/ { in_map = 1; next }
    in_map && /\};/ { in_map = 0 }
    in_map {
      if (match($0, /"([^"]+)"[[:space:]]*=/, a) > 0 && a[1] != target) {
        print a[1]
      }
    }
  ' "$flake_file"
}

has_fake_hash() {
  local current_system_key
  current_system_key="$(get_current_system_key)"
  awk -v target="$current_system_key" '
    /outputHashBySystem[[:space:]]*=[[:space:]]*\{/ { in_map = 1; next }
    in_map && /\};/ { in_map = 0 }
    in_map && $0 ~ "\"" target "\"" { print $0 }
  ' "$flake_file" | grep -Eq 'fakeHash|sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
}

update_flake_version() {
  local new_version="$1"
  sed -i.bak -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1${new_version}\\2/" "$flake_file"
}

update_tarball_hash() {
  local new_hash="$1"
  sed -i.bak -E "s|^([[:space:]]*hash = \")[^\"]*(\";)|\\1${new_hash}\\2|" "$flake_file"
}

set_output_hash_placeholder_for_system() {
  local system_key="$1"
  local placeholder="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  sed -i.bak -E "/outputHashBySystem[[:space:]]*=[[:space:]]*\\{/,/\\};/ s~^([[:space:]]*\"${system_key}\"[[:space:]]*=[[:space:]]*)(pkgs\\.lib\\.fakeHash|\"[^\"]*\")[[:space:]]*;~\\1\"${placeholder}\";~" "$flake_file"
}

update_output_hash_for_system() {
  local system_key="$1"
  local new_hash_value="$2"
  sed -i.bak -E "/outputHashBySystem[[:space:]]*=[[:space:]]*\\{/,/\\};/ s|^([[:space:]]*\"${system_key}\"[[:space:]]*=[[:space:]]*\")[^\"]*(\";)|\\1${new_hash_value}\\2|" "$flake_file"
}

mark_other_output_hashes_pending() {
  local current_system_key="$1"
  local other_system
  while IFS= read -r other_system; do
    [ -n "$other_system" ] || continue
    sed -i.bak -E "/outputHashBySystem[[:space:]]*=[[:space:]]*\\{/,/\\};/ s~^([[:space:]]*\"${other_system}\"[[:space:]]*=[[:space:]]*)(pkgs\\.lib\\.fakeHash|\"[^\"]*\")[[:space:]]*;~\\1pkgs.lib.fakeHash;~" "$flake_file"
  done < <(get_other_output_hash_systems "$current_system_key")
}

cleanup_backups() {
  rm -f "${flake_file}.bak" 2>/dev/null || true
}
trap cleanup_backups EXIT

compute_and_update_output_hash() {
  local system_key
  system_key="$(get_current_system_key)"
  log_info "Computing npm dependency hash for ${system_key}..."
  set_output_hash_placeholder_for_system "$system_key"
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
  update_output_hash_for_system "$system_key" "$got_hash"
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
  log_info "Build successful."
}

update_flake_lock() {
  log_info "Updating flake.lock..."
  (cd "$pkg_dir" && nix flake update)
}

print_usage() {
  cat <<'USAGE'
Usage: ./scripts/update-version.sh [OPTIONS]

Options:
  --version VERSION   Update to a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute tarball hash and current-system npm dependency hash
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

  local current_version latest_version current_system_key tarball_url tarball_hash backup
  current_version="$(get_current_version)"
  latest_version="${target_version:-$(get_latest_version_from_npm)}"
  current_system_key="$(get_current_system_key)"

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
  [ "$current_version" != "$latest_version" ] && mark_other_output_hashes_pending "$current_system_key"
  cleanup_backups

  if ! compute_and_update_output_hash; then
    cp "$backup" "$flake_file"
    rm -f "$backup"
    exit 1
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
  log_warn "Only ${current_system_key} outputHash was refreshed; re-run on other Linux architectures if needed."
}

main "$@"
