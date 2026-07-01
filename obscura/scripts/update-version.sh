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
readonly REPO_OWNER="h4ckf0r0day"
readonly REPO_NAME="obscura"
readonly ASSET_NAME="obscura-x86_64-linux.tar.gz"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

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
  # Anchor to the first matching line only so a future second `version = "…"`
  # (e.g. a vendored sub-package) is never clobbered.
  sed -i.bak -E "0,/^[[:space:]]*version = \"/ s/^([[:space:]]*version = \")[^\"]*(\";)/\\1${new_version}\\2/" "$flake_file"
}

update_src_sha256() {
  local new_sha256="$1"
  # SRI hashes contain '/' and '+' but never '|', so '|' is a safe s-delimiter.
  # Anchor to the first matching hash line only.
  sed -i.bak -E "0,/^[[:space:]]*hash = \"/ s|^([[:space:]]*hash = \")[^\"]*(\";)|\\1${new_sha256}\\2|" "$flake_file"
}

# Backup/restore state for the EXIT trap. If a mutation-then-build sequence aborts
# (set -e) after flake.nix is rewritten, the trap restores the original and never
# leaks the mktemp backup.
backup_file=""
restore_flake_on_exit=false

remove_sed_backup() {
  rm -f "${flake_file}.bak" 2>/dev/null || true
}

cleanup_backups() {
  remove_sed_backup
  if [ "$restore_flake_on_exit" = true ] && [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
    log_warn "Restoring flake.nix from backup"
    cp "$backup_file" "$flake_file" 2>/dev/null || true
  fi
  if [ -n "$backup_file" ]; then
    rm -f "$backup_file" 2>/dev/null || true
  fi
}

trap cleanup_backups EXIT

verify_build() {
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build .#obscura --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for obscura"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/obscura" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/obscura"
    return 1
  fi
  "$out_path/bin/obscura" --version >/dev/null 2>&1 || "$out_path/bin/obscura" --help >/dev/null 2>&1 || true
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
  --version VERSION   Update to a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute release asset hashes for current version
  --no-build          Skip build verification
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 0.1.0
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local target_version=""
  local check_only=false
  local rehash=false
  local no_build=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        target_version="$2"
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

  local current_version
  current_version="$(get_current_version)"
  if [ -z "$current_version" ]; then
    log_error "Failed to detect current version from flake.nix"
    exit 2
  fi

  local latest_tag
  latest_tag="$(get_latest_release_tag)" || true
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

  local url
  url="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$latest_tag/$ASSET_NAME"

  log_info "Prefetching tarball hash..."
  local new_hash
  new_hash="$(prefetch_sha256_sri "$url")" || true

  if [ -z "$new_hash" ]; then
    log_error "Failed to prefetch tarball hash"
    exit 2
  fi

  log_info "x86_64 hash: $new_hash"

  backup_file="$(mktemp -t flake.nix.backup.XXXXXX)"
  cp "$flake_file" "$backup_file"
  restore_flake_on_exit=true

  update_flake_version "$latest_version"
  update_src_sha256 "$new_hash"
  remove_sed_backup

  if [ "$no_build" != true ]; then
    if ! verify_build; then
      log_error "Build verification failed; restoring previous flake.nix"
      # The EXIT trap restores flake.nix from backup_file.
      exit 1
    fi
  fi

  # Success: keep the updated flake.nix (trap only removes the backup file).
  restore_flake_on_exit=false

  show_changes

  maybe_git_commit "$(build_commit_message "$current_version" "$latest_version" "$rehash")" "flake.nix"

  log_info "Successfully updated obscura from $current_version to $latest_version"
}

main "$@"
