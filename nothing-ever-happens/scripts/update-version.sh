#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly OWNER="sterlingcrispin"
readonly REPO="nothing-ever-happens"
readonly PACKAGE_ATTR="nothing-ever-happens"
readonly BIN_NAME="nothing-ever-happens"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

# Pristine copy of flake.nix taken before mutation, restored on build failure.
FLAKE_BACKUP=""

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

get_latest_commit_sha() {
  git ls-remote "https://github.com/${OWNER}/${REPO}.git" HEAD | awk '{print $1}'
}

get_commit_date() {
  local sha="$1"
  curl -fsSL "https://api.github.com/repos/${OWNER}/${REPO}/commits/${sha}" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["commit"]["committer"]["date"][:10])'
}

build_version_string() {
  local commit_date="$1"
  local sha="$2"
  printf 'unstable-%s-%s\n' "$commit_date" "${sha:0:7}"
}

prefetch_source_hash_sri() {
  local sha="$1"
  local url="https://github.com/${OWNER}/${REPO}/archive/${sha}.tar.gz"
  local hash
  hash="$(nix-prefetch-url --type sha256 --unpack "$url" 2>/dev/null | tail -n1)"
  nix hash to-sri --type sha256 "$hash"
}

update_flake_version() {
  local new_version="$1"
  # Anchor to the main package's `version = "unstable-…"` line only; the flake
  # also declares four Python wheel sub-packages with their own semver
  # `version = "0.x.y"` lines that must not be rewritten.
  sed -i.bak -E "s/(^[[:space:]]*version = \")unstable-[^\"]*(\";)/\\1${new_version}\\2/" "$flake_file"
}

update_rev() {
  local new_rev="$1"
  sed -i.bak -E "s/^([[:space:]]*rev = \")[^\"]*(\";)/\\1${new_rev}\\2/" "$flake_file"
}

update_src_hash() {
  local new_hash="$1"
  sed -i.bak -E "s~^([[:space:]]*srcHash = \")[^\"]*(\";)~\\1${new_hash}\\2~" "$flake_file"
}

cleanup_backups() {
  rm -f "${flake_file}.bak" 2>/dev/null || true
}

on_exit() {
  cleanup_backups
  if [ -n "${FLAKE_BACKUP:-}" ]; then
    rm -f "$FLAKE_BACKUP" 2>/dev/null || true
  fi
}

trap on_exit EXIT

verify_build() {
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build .#${PACKAGE_ATTR} --no-link --print-out-paths --no-write-lock-file)"; then
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

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat flake.nix 2>/dev/null || true
  fi
}

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

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Options:
  --version VERSION   Set an explicit version string (advanced use)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute the source hash for the current revision
  --no-build          Skip build verification
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --rehash
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local explicit_version=""
  local check_only=false
  local rehash=false
  local no_build=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        explicit_version="$2"
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

  local current_version current_rev
  current_version="$(get_current_version)"
  current_rev="$(get_current_rev)"

  if [ -z "$current_version" ] || [ -z "$current_rev" ]; then
    log_error "Failed to determine current package metadata from flake.nix"
    exit 1
  fi

  local target_rev target_date target_version
  target_rev="$(get_latest_commit_sha)"
  target_date="$(get_commit_date "$target_rev")"
  target_version="$(build_version_string "$target_date" "$target_rev")"

  if [ -n "$explicit_version" ]; then
    target_version="$explicit_version"
  fi

  log_info "Current version:      $current_version"
  log_info "Current revision:     $current_rev"
  log_info "Target version:       $target_version"
  log_info "Target revision:      $target_rev"

  if [ "$check_only" = true ]; then
    if [ "$current_rev" = "$target_rev" ] && [ "$current_version" = "$target_version" ]; then
      log_info "Package is up to date."
      exit 0
    fi
    log_warn "Update available: $current_version -> $target_version"
    exit 1
  fi

  local commit_message
  commit_message="$(build_commit_message "$current_version" "$target_version" "$rehash")"

  FLAKE_BACKUP="$(mktemp)"
  cp -- "$flake_file" "$FLAKE_BACKUP"

  if [ "$current_rev" != "$target_rev" ]; then
    update_rev "$target_rev"
    update_flake_version "$target_version"
    cleanup_backups
  elif [ -n "$explicit_version" ]; then
    # Rev unchanged but the user pinned an explicit version label: still write it.
    update_flake_version "$target_version"
    cleanup_backups
  fi

  if [ "$rehash" = true ] || [ "$current_rev" != "$target_rev" ]; then
    local source_hash
    source_hash="$(prefetch_source_hash_sri "$target_rev")"
    if [ -z "$source_hash" ]; then
      log_error "Failed to prefetch source hash for ${target_rev}"
      exit 1
    fi
    log_info "Source hash: $source_hash"
    update_src_hash "$source_hash"
    cleanup_backups
  fi

  show_changes

  if [ "$no_build" != true ]; then
    if ! verify_build; then
      log_error "Build failed; restoring ${flake_file}"
      cp -- "$FLAKE_BACKUP" "$flake_file"
      exit 1
    fi
  fi

  maybe_git_commit "$commit_message" flake.nix
  log_info "Done."
}

main "$@"
