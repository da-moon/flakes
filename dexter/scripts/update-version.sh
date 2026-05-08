#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly REPO_URL="https://github.com/virattt/dexter"
readonly ATTR="dexter"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"

ensure_tools() {
  for tool in git nix nix-prefetch-url python3 sed; do
    command -v "$tool" >/dev/null 2>&1 || { log_error "$tool is required"; exit 2; }
  done
}

current_version() {
  sed -n 's/^[[:space:]]*version = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
}

latest_version() {
  git ls-remote --tags "$REPO_URL.git" \
    | awk -F/ '/refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+$/ { print substr($3, 2) }' \
    | sort -V \
    | tail -n1
}

prefetch_source_hash() {
  local version="$1"
  local base32
  base32="$(nix-prefetch-url --unpack "${REPO_URL}/archive/v${version}.tar.gz" | tail -n1)"
  nix hash to-sri --type sha256 "$base32"
}

update_version_hash() {
  local version="$1" hash="$2"
  python3 - "$flake_file" "$version" "$hash" <<'PY'
import re
import sys
from pathlib import Path
path = Path(sys.argv[1])
version, source_hash = sys.argv[2:]
text = path.read_text()
text = re.sub(r'(version = ")[^"]+(";)', rf'\g<1>{version}\2', text, count=1)
text = re.sub(r'(rev = ")v[^"]+(";)', rf'\g<1>v{version}\2', text, count=1)
text = re.sub(r'(inherit rev;\n\s*hash = ")[^"]+(";)', rf'\g<1>{source_hash}\2', text, count=1)
path.write_text(text)
PY
}

current_system() {
  nix eval --impure --raw --expr builtins.currentSystem
}

set_output_hash() {
  local system_key="$1"
  local hash="$2"
  sed -i.bak -E "/outputHashBySystem[[:space:]]*=[[:space:]]*\\{/,/\\};/ s~^([[:space:]]*\"${system_key}\"[[:space:]]*=[[:space:]]*)(pkgs\\.lib\\.fakeHash|\"[^\"]+\")[[:space:]]*;~\\1\"${hash}\";~" "$flake_file"
  rm -f "${flake_file}.bak"
}

extract_got_hash() {
  sed -n 's/.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' | head -n1
}

compute_output_hash() {
  local system_key
  system_key="$(current_system)"
  log_info "Computing npm dependency output hash for $system_key..."
  set_output_hash "$system_key" "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  local output got
  output="$(cd "$pkg_dir" && nix build .#${ATTR} --no-link 2>&1 || true)"
  got="$(printf '%s\n' "$output" | extract_got_hash)"
  if [ -z "$got" ]; then
    log_error "Could not parse outputHash from nix build output"
    printf '%s\n' "$output" | sed -n '1,180p' >&2
    exit 1
  fi
  set_output_hash "$system_key" "$got"
}

verify_build() {
  log_info "Verifying build..."
  (cd "$pkg_dir" && nix build .#${ATTR} --no-link)
}

usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [--version VERSION] [--check] [--rehash] [--no-build]
EOF
}

main() {
  ensure_tools
  local requested="" check=false rehash=false no_build=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) requested="${2:-}"; shift 2 ;;
      --check) check=true; shift ;;
      --rehash) rehash=true; shift ;;
      --no-build) no_build=true; shift ;;
      --help) usage; exit 0 ;;
      *) log_error "Unknown option: $1"; usage; exit 2 ;;
    esac
  done

  local current target source_hash
  current="$(current_version)"
  target="${requested:-$(latest_version)}"
  log_info "Current: $current"
  log_info "Target:  $target"
  if [ "$check" = true ]; then
    [ "$current" = "$target" ] && exit 0 || exit 1
  fi

  source_hash="$(prefetch_source_hash "$target")"
  update_version_hash "$target" "$source_hash"
  if [ "$rehash" = true ] || [ "$current" != "$target" ]; then
    compute_output_hash
  fi
  [ "$no_build" = true ] || verify_build
  log_info "Updated dexter to $target"
}

main "$@"
