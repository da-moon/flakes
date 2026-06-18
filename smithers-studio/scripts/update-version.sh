#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Source monorepo. Studio is apps/smithers-studio-2 inside it; releases are
# tagged vX.Y.Z and the published smithers-orchestrator line matches the tag.
readonly OWNER="smithersai"
readonly REPO="smithers"
readonly PACKAGE_ATTR="smithers-studio"
readonly BIN_NAME="smithers-studio"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  command -v curl >/dev/null 2>&1 || { log_error "curl is required but not installed."; exit 2; }
  command -v git >/dev/null 2>&1 || { log_error "git is required but not installed."; exit 2; }
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v nix-prefetch-url >/dev/null 2>&1 || { log_error "nix-prefetch-url is required but not installed."; exit 2; }
  command -v python3 >/dev/null 2>&1 || { log_error "python3 is required but not installed."; exit 2; }
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

get_current_rev() {
  sed -n 's/^[[:space:]]*rev = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
}

# Resolve a release tag (e.g. v0.24.3) to its commit sha. The Studio pin tracks
# the monorepo's published smithers-orchestrator line, so a version bump pins
# the matching vX.Y.Z tag, keeping Studio and the gateway/CLI consistent.
resolve_tag_sha() {
  local tag="$1"
  git ls-remote "https://github.com/${OWNER}/${REPO}.git" "refs/tags/${tag}^{}" \
    "refs/tags/${tag}" | awk '{print $1; exit}'
}

get_latest_release_tag() {
  curl -fsSL "https://api.github.com/repos/${OWNER}/${REPO}/releases/latest" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null
}

prefetch_source_hash_sri() {
  local sha="$1"
  local url="https://github.com/${OWNER}/${REPO}/archive/${sha}.tar.gz"
  local hash
  hash="$(nix-prefetch-url --type sha256 --unpack "$url" 2>/dev/null | tail -n1)"
  nix hash to-sri --type sha256 "$hash"
}

update_field() {
  # update_field <field> <value> [delim]
  local field="$1" value="$2" delim="${3:-/}"
  sed -i.bak -E "s${delim}^([[:space:]]*${field} = \")[^\"]*(\";)${delim}\\1${value}\\2${delim}" "$flake_file"
  rm -f "${flake_file}.bak"
}

# Re-derive the fixed-output node_modules hash by building with a sentinel hash
# and capturing Nix's "got:" line.
rehash_deps() {
  log_info "Rehashing node_modules FOD (forces a network install)..."
  local sentinel="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  update_field "depsHash" "$sentinel"
  local got
  got="$(cd "$pkg_dir" && nix build ".#${PACKAGE_ATTR}-deps" --no-link --rebuild 2>&1 \
    | sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[^ ]*\).*/\1/p' | tail -n1 || true)"
  if [ -z "$got" ]; then
    log_error "Failed to capture node_modules FOD hash. Build output may have changed shape."
    return 1
  fi
  log_info "node_modules FOD hash: $got"
  update_field "depsHash" "$got"
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
  "$out_path/bin/$BIN_NAME" --version >/dev/null
  log_info "Build successful!"
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Re-pins Smithers Studio to a monorepo release tag and refreshes both the source
hash and the node_modules fixed-output hash.

Options:
  --tag TAG       Pin to this release tag (e.g. v0.24.3). Default: latest release.
  --rehash        Only re-derive the node_modules FOD hash for the current rev.
  --no-build      Skip the final build verification.
  --help          Show this help message.

Examples:
  ./scripts/update-version.sh --tag v0.24.3
  ./scripts/update-version.sh --rehash
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local tag="" rehash_only=false no_build=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag) tag="${2:-}"; shift 2 ;;
      --rehash) rehash_only=true; shift ;;
      --no-build) no_build=true; shift ;;
      --help) print_usage; exit 0 ;;
      *) log_error "Unknown option: $1"; print_usage; exit 2 ;;
    esac
  done

  local current_version current_rev
  current_version="$(get_current_version)"
  current_rev="$(get_current_rev)"
  log_info "Current version:  $current_version"
  log_info "Current revision: $current_rev"

  if [ "$rehash_only" = true ]; then
    rehash_deps
    [ "$no_build" = true ] || verify_build
    log_info "Done."
    return 0
  fi

  if [ -z "$tag" ]; then
    tag="$(get_latest_release_tag)"
    [ -n "$tag" ] || { log_error "Could not determine latest release tag; pass --tag."; exit 1; }
  fi
  local target_version="${tag#v}"
  local target_rev
  target_rev="$(resolve_tag_sha "$tag")"
  [ -n "$target_rev" ] || { log_error "Could not resolve tag '$tag' to a commit."; exit 1; }

  log_info "Target tag:       $tag"
  log_info "Target version:   $target_version"
  log_info "Target revision:  $target_rev"

  update_field "version" "$target_version"
  update_field "rev" "$target_rev"

  local src_hash
  src_hash="$(prefetch_source_hash_sri "$target_rev")"
  [ -n "$src_hash" ] || { log_error "Failed to prefetch source hash."; exit 1; }
  log_info "Source hash: $src_hash"
  update_field "srcHash" "$src_hash" "~"

  rehash_deps
  [ "$no_build" = true ] || verify_build
  log_info "Done. Review the flake.nix diff and commit:"
  echo "  chore(${PACKAGE_DIR_NAME}): bump to ${target_version}"
}

main "$@"
