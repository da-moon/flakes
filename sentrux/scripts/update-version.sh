#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly REPO_OWNER="sentrux"
readonly REPO_NAME="sentrux"
readonly PACKAGE_ATTR="sentrux"
readonly BIN_NAME="sentrux"

declare -Ar BINARY_ASSET_BY_SYSTEM=(
  [x86_64-linux]="sentrux-linux-x86_64"
  [aarch64-linux]="sentrux-linux-aarch64"
)

declare -Ar GRAMMAR_ASSET_BY_SYSTEM=(
  [x86_64-linux]="grammars-linux-x86_64.tar.gz"
  [aarch64-linux]="grammars-linux-aarch64.tar.gz"
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
  tag="${tag#v}"
  printf '%s\n' "$tag"
}

asset_url() {
  local version="$1"
  local asset="$2"
  printf 'https://github.com/%s/%s/releases/download/v%s/%s\n' "$REPO_OWNER" "$REPO_NAME" "$version" "$asset"
}

prefetch_sha256_sri() {
  nix store prefetch-file --json --hash-type sha256 "$1" \
    | sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' \
    | head -n1
}

update_flake_version() {
  sed -i.bak -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1$1\\2/" "$flake_file"
}

update_system_field_hash() {
  local system_key="$1"
  local field="$2"
  local hash="$3"
  sed -i.bak -E "/\"${system_key}\"[[:space:]]*=[[:space:]]*\\{/,/\\};/ s|^([[:space:]]*${field} = \")[^\"]*(\";)|\\1${hash}\\2|" "$flake_file"
}

cleanup_backups() {
  rm -f "${flake_file}.bak" 2>/dev/null || true
}
trap cleanup_backups EXIT

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
  "$out_path/bin/$BIN_NAME" --version >/dev/null 2>&1 || "$out_path/bin/$BIN_NAME" --help >/dev/null 2>&1 || true
  log_info "Build successful!"
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
EOF
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

  local current_version latest_version
  current_version="$(get_current_version)"
  latest_version="${target_version:-$(tag_to_version "$(get_latest_release_tag)")}"

  if [ "$check_only" = true ]; then
    [ "$current_version" = "$latest_version" ] && { log_info "${PACKAGE_DIR_NAME} is up to date (${current_version})"; exit 0; }
    log_warn "Update available: ${current_version} -> ${latest_version}"
    exit 1
  fi

  if [ "$current_version" = "$latest_version" ] && [ "$rehash" = false ]; then
    log_info "${PACKAGE_DIR_NAME} is already at ${current_version}"
    exit 0
  fi

  update_flake_version "$latest_version"

  local system_key asset hash
  for system_key in "${!BINARY_ASSET_BY_SYSTEM[@]}"; do
    asset="${BINARY_ASSET_BY_SYSTEM[$system_key]}"
    log_info "Prefetching ${asset}"
    hash="$(prefetch_sha256_sri "$(asset_url "$latest_version" "$asset")")"
    update_system_field_hash "$system_key" "binaryHash" "$hash"

    asset="${GRAMMAR_ASSET_BY_SYSTEM[$system_key]}"
    log_info "Prefetching ${asset}"
    hash="$(prefetch_sha256_sri "$(asset_url "$latest_version" "$asset")")"
    update_system_field_hash "$system_key" "grammarHash" "$hash"
  done
  cleanup_backups

  [ "$update_lock" = true ] && (cd "$pkg_dir" && nix flake update)
  [ "$no_build" = false ] && verify_build
  git -C "$pkg_dir" diff --stat flake.nix flake.lock 2>/dev/null || true
}

main "$@"
