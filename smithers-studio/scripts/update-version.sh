#!/usr/bin/env bash
set -Eeuo pipefail

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

# Snapshot flake.nix before mutating it so a mid-run failure reverts cleanly.
FLAKE_BACKUP=""
restore_flake_on_failure() {
  if [ -n "$FLAKE_BACKUP" ] && [ -f "$FLAKE_BACKUP" ]; then
    cp -f "$FLAKE_BACKUP" "$flake_file"
    log_warn "Restored flake.nix from backup after failure."
  fi
}
cleanup_backup() {
  [ -n "$FLAKE_BACKUP" ] && rm -f "$FLAKE_BACKUP"
  return 0
}
trap 'restore_flake_on_failure' ERR
trap 'cleanup_backup' EXIT

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

# Parallel-safe auto-commit. flock serialises the git index across concurrent updaters.
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

  if git -C "$pkg_dir" diff --quiet -- "${paths[@]}" \
    && git -C "$pkg_dir" diff --cached --quiet -- "${paths[@]}"; then
    return 0
  fi

  local git_dir lock_file
  git_dir="$(git -C "$pkg_dir" rev-parse --absolute-git-dir 2>/dev/null || true)"
  lock_file="${git_dir:-$pkg_dir/.git}/update-version-commit.lock"

  (
    if command -v flock >/dev/null 2>&1; then flock 9 || true; fi
    git -C "$pkg_dir" add -- "${paths[@]}"
    if git -C "$pkg_dir" diff --cached --quiet -- "${paths[@]}"; then
      exit 0
    fi
    git -C "$pkg_dir" commit --only -m "$commit_message" -- "${paths[@]}"
    log_info "Committed: $commit_message"
  ) 9>"$lock_file"
}

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
    "refs/tags/${tag}" | awk '/\^\{\}/{print $1; exit} {last=$1} END{if (last!="") print last}'
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
  update_field "depsHash" "$sentinel" "~"
  local got
  got="$(cd "$pkg_dir" && nix build ".#${PACKAGE_ATTR}-deps" --no-link --rebuild --no-write-lock-file 2>&1 \
    | sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[^ ]*\).*/\1/p' | tail -n1 || true)"
  if [ -z "$got" ]; then
    log_error "Failed to capture node_modules FOD hash. Build output may have changed shape."
    return 1
  fi
  log_info "node_modules FOD hash: $got"
  update_field "depsHash" "$got" "~"
}

verify_build() {
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build ".#${PACKAGE_ATTR}" --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for ${PACKAGE_ATTR}"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/$BIN_NAME"
    return 1
  fi
  timeout 30 "$out_path/bin/$BIN_NAME" --version >/dev/null 2>&1 || true
  log_info "Build successful!"
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Re-pins Smithers Studio to a monorepo release tag and refreshes both the source
hash and the node_modules fixed-output hash.

Options:
  --tag TAG       Pin to this release tag (e.g. v0.24.3). Default: latest release.
  --version VER   Pin to this version (e.g. 0.24.3); mapped to release tag vVER.
  --check         Report current vs. latest release and exit (no changes).
  --rehash        Only re-derive the node_modules FOD hash for the current rev.
  --no-build      Skip the final build verification.
  --help          Show this help message.

Examples:
  ./scripts/update-version.sh --tag v0.24.3
  ./scripts/update-version.sh --version 0.24.3
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --rehash
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local tag="" rehash_only=false no_build=false check_only=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag)
        [ $# -ge 2 ] || { log_error "--tag requires an argument"; exit 2; }
        tag="$2"
        shift 2
        ;;
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        tag="v${2#v}"
        shift 2
        ;;
      --check) check_only=true; shift ;;
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

  if [ "$check_only" = true ]; then
    local latest_tag
    latest_tag="$(get_latest_release_tag)"
    [ -n "$latest_tag" ] || { log_error "Could not determine latest release tag."; exit 1; }
    log_info "Latest release:   ${latest_tag#v}"
    if [ "${latest_tag#v}" != "$current_version" ]; then
      log_info "Update available: $current_version -> ${latest_tag#v}"
    else
      log_info "Up to date."
    fi
    return 0
  fi

  # Snapshot flake.nix so restore_flake_on_failure can revert a half-applied edit.
  FLAKE_BACKUP="$(mktemp)"
  cp "$flake_file" "$FLAKE_BACKUP"

  if [ "$rehash_only" = true ]; then
    rehash_deps
    [ "$no_build" = true ] || verify_build
    maybe_git_commit "$(build_commit_message "$current_version" "$current_version" true)" "flake.nix"
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
  maybe_git_commit "$(build_commit_message "$current_version" "$target_version" false)" "flake.nix"
  log_info "Done."
}

main "$@"
