#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly REPO_URL="https://github.com/tradesdontlie/tradingview-mcp"
readonly RAW_BASE="https://raw.githubusercontent.com/tradesdontlie/tradingview-mcp"
readonly ATTR="tradingview-mcp"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"

ensure_tools() {
  for tool in curl git nix nix-prefetch-url python3 sed; do
    command -v "$tool" >/dev/null 2>&1 || { log_error "$tool is required"; exit 2; }
  done
}

current_rev() {
  sed -n 's/^[[:space:]]*rev = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
}

latest_rev() {
  git ls-remote "$REPO_URL.git" HEAD | awk '{ print $1 }'
}

package_version_for_rev() {
  local rev="$1"
  python3 - "$RAW_BASE/$rev/package.json" <<'PY'
import json
import sys
import urllib.request
print(json.load(urllib.request.urlopen(sys.argv[1]))["version"])
PY
}

prefetch_source_hash() {
  local rev="$1"
  local base32
  base32="$(nix-prefetch-url --unpack "${REPO_URL}/archive/${rev}.tar.gz" | tail -n1)"
  nix hash to-sri --type sha256 "$base32"
}

update_rev_version_hash() {
  local rev="$1" version="$2" hash="$3"
  python3 - "$flake_file" "$rev" "$version" "$hash" <<'PY'
import re
import sys
from pathlib import Path
path = Path(sys.argv[1])
rev, version, source_hash = sys.argv[2:]
short_date = "unstable-" + __import__("datetime").datetime.utcnow().strftime("%Y-%m-%d")
full_version = f"{version}-{short_date}"
text = path.read_text()
text = re.sub(r'(version = ")[^"]+(";)', rf'\g<1>{full_version}\2', text, count=1)
text = re.sub(r'(rev = ")[^"]+(";)', rf'\g<1>{rev}\2', text, count=1)
text = re.sub(r'(inherit rev;\n\s*hash = ")[^"]+(";)', rf'\g<1>{source_hash}\2', text, count=1)
path.write_text(text)
PY
}

set_npm_hash() {
  local hash="$1"
  sed -i.bak -E "s|npmDepsHash = \"[^\"]+\";|npmDepsHash = \"${hash}\";|" "$flake_file"
  rm -f "${flake_file}.bak"
}

extract_got_hash() {
  sed -n 's/.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' | head -n1
}

compute_npm_hash() {
  log_info "Computing npm dependency hash..."
  set_npm_hash "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  local output got
  output="$(cd "$pkg_dir" && nix build .#${ATTR} --no-link 2>&1 || true)"
  got="$(printf '%s\n' "$output" | extract_got_hash)"
  if [ -z "$got" ]; then
    log_error "Could not parse npmDepsHash from nix build output"
    printf '%s\n' "$output" | sed -n '1,160p' >&2
    exit 1
  fi
  set_npm_hash "$got"
}

verify_build() {
  log_info "Verifying build..."
  (cd "$pkg_dir" && nix build .#${ATTR} --no-link)
}

usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [--rev REV] [--check] [--rehash] [--no-build]
EOF
}

main() {
  ensure_tools
  local requested_rev="" check=false rehash=false no_build=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rev) requested_rev="${2:-}"; shift 2 ;;
      --check) check=true; shift ;;
      --rehash) rehash=true; shift ;;
      --no-build) no_build=true; shift ;;
      --help) usage; exit 0 ;;
      *) log_error "Unknown option: $1"; usage; exit 2 ;;
    esac
  done

  local current target version source_hash
  current="$(current_rev)"
  target="${requested_rev:-$(latest_rev)}"
  version="$(package_version_for_rev "$target")"
  log_info "Current rev: $current"
  log_info "Target rev:  $target"
  if [ "$check" = true ]; then
    [ "$current" = "$target" ] && exit 0 || exit 1
  fi

  source_hash="$(prefetch_source_hash "$target")"
  update_rev_version_hash "$target" "$version" "$source_hash"
  if [ "$rehash" = true ] || [ "$current" != "$target" ]; then
    compute_npm_hash
  fi
  [ "$no_build" = true ] || verify_build
  log_info "Updated tradingview-mcp to $target"
}

main "$@"
