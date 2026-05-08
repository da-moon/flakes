#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly REPO_OWNER="ksanjeev284"
readonly REPO_NAME="reddit-universal-scraper"
readonly PACKAGE_ATTR="reddit-universal-scraper"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"

ensure_tools() {
  for tool in date git nix nix-prefetch-url sed; do
    command -v "$tool" >/dev/null 2>&1 || { log_error "$tool is required"; exit 2; }
  done
}

get_current_rev() {
  sed -n 's/^[[:space:]]*rev = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
}

get_latest_rev() {
  git ls-remote "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" HEAD | awk '{ print $1 }'
}

prefetch_source_hash() {
  local rev="$1"
  local base32
  base32="$(nix-prefetch-url --unpack "https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/${rev}.tar.gz" | tail -n1)"
  nix hash to-sri --type sha256 "$base32"
}

update_flake() {
  local rev="$1"
  local hash="$2"
  local date_part
  date_part="$(date -u +%Y-%m-%d)"
  sed -i.bak -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1unstable-${date_part}\\2/" "$flake_file"
  sed -i.bak -E "s/^([[:space:]]*rev = \")[^\"]*(\";)/\\1${rev}\\2/" "$flake_file"
  sed -i.bak -E "/src = pkgs\\.fetchFromGitHub[[:space:]]*\\{/,/\\};/ s|^([[:space:]]*hash = \")[^\"]*(\";)|\\1${hash}\\2|" "$flake_file"
  rm -f "${flake_file}.bak"
}

verify_build() {
  log_info "Verifying build..."
  (cd "$pkg_dir" && nix build ".#${PACKAGE_ATTR}" --no-link --print-out-paths)
}

usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [--revision REV] [--check] [--rehash] [--no-build] [--update-lock]
EOF
}

main() {
  ensure_tools
  local requested="" check=false rehash=false no_build=false update_lock=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --revision) requested="${2:-}"; shift 2 ;;
      --check) check=true; shift ;;
      --rehash) rehash=true; shift ;;
      --no-build) no_build=true; shift ;;
      --update-lock) update_lock=true; shift ;;
      --help) usage; exit 0 ;;
      *) log_error "Unknown option: $1"; usage; exit 2 ;;
    esac
  done

  local current target hash
  current="$(get_current_rev)"
  target="${requested:-$(get_latest_rev)}"
  log_info "Current rev: ${current}"
  log_info "Target rev:  ${target}"

  if [ "$check" = true ]; then
    [ "$current" = "$target" ] && exit 0 || exit 1
  fi

  if [ "$current" = "$target" ] && [ "$rehash" = false ]; then
    log_info "reddit-universal-scraper is already at ${current}"
    exit 0
  fi

  hash="$(prefetch_source_hash "$target")"
  update_flake "$target" "$hash"
  [ "$update_lock" = true ] && (cd "$pkg_dir" && nix flake update)
  [ "$no_build" = true ] || verify_build
  log_info "Updated reddit-universal-scraper to ${target}"
}

main "$@"
