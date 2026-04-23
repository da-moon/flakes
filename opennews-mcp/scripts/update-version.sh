#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly OWNER="6551Team"
readonly REPO="opennews-mcp"
readonly PACKAGE_ATTR="opennews-mcp"
readonly BIN_NAME="opennews-mcp"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  command -v curl >/dev/null 2>&1 || { log_error "curl is required but not installed."; exit 2; }
  command -v git >/dev/null 2>&1 || { log_error "git is required but not installed."; exit 2; }
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v nix-prefetch-url >/dev/null 2>&1 || { log_error "nix-prefetch-url is required but not installed."; exit 2; }
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

get_current_base_version() {
  sed -n 's/^[[:space:]]*baseVersion = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
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
    | sed -n 's/.*"date":[[:space:]]*"\([0-9-]\{10\}\)T.*/\1/p' \
    | head -n1
}

get_base_version_for_rev() {
  local sha="$1"
  curl -fsSL "https://raw.githubusercontent.com/${OWNER}/${REPO}/${sha}/pyproject.toml" \
    | sed -n 's/^version = "\([^"]*\)".*/\1/p' \
    | head -n1
}

build_version_string() {
  local base_version="$1"
  local commit_date="$2"
  local sha="$3"
  printf '%s-unstable-%s-%s\n' "$base_version" "$commit_date" "${sha:0:7}"
}

prefetch_source_hash_sri() {
  local sha="$1"
  local url="https://github.com/${OWNER}/${REPO}/archive/${sha}.tar.gz"
  local hash
  hash="$(nix-prefetch-url --type sha256 --unpack "$url" 2>/dev/null | tail -n1)"
  nix hash to-sri --type sha256 "$hash"
}

update_base_version() {
  local new_base_version="$1"
  sed -i.bak -E "s/^([[:space:]]*baseVersion = \")[^\"]*(\";)/\\1${new_base_version}\\2/" "$flake_file"
}

update_flake_version() {
  local new_version="$1"
  sed -i.bak -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1${new_version}\\2/" "$flake_file"
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

trap cleanup_backups EXIT

update_flake_lock() {
  log_info "Updating flake.lock..."
  (cd "$pkg_dir" && nix flake update)
}

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
  "$out_path/bin/$BIN_NAME" --version >/dev/null
  log_info "Build successful!"
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat flake.nix flake.lock 2>/dev/null || true
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

  if git -C "$pkg_dir" diff --quiet -- "${paths[@]}" && git -C "$pkg_dir" diff --cached --quiet -- "${paths[@]}"; then
    return 0
  fi

  git -C "$pkg_dir" add -- "${paths[@]}"

  if git -C "$pkg_dir" diff --cached --quiet -- "${paths[@]}"; then
    return 0
  fi

  git -C "$pkg_dir" commit --only -m "$commit_message" -- "${paths[@]}"
  log_info "Committed: $commit_message"
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Options:
  --version VERSION   Set an explicit version string (advanced use)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute the source hash for the current revision
  --no-build          Skip build verification
  --update-lock       Run 'nix flake update' after updating
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
  local update_lock=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        explicit_version="${2:-}"
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
      --update-lock)
        update_lock=true
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

  local current_version current_base_version current_rev
  current_version="$(get_current_version)"
  current_base_version="$(get_current_base_version)"
  current_rev="$(get_current_rev)"

  if [ -z "$current_version" ] || [ -z "$current_base_version" ] || [ -z "$current_rev" ]; then
    log_error "Failed to determine current package metadata from flake.nix"
    exit 1
  fi

  local target_rev target_base_version target_date target_version
  target_rev="$(get_latest_commit_sha)"
  target_base_version="$(get_base_version_for_rev "$target_rev")"
  target_date="$(get_commit_date "$target_rev")"
  target_version="$(build_version_string "$target_base_version" "$target_date" "$target_rev")"

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

  if [ "$current_rev" != "$target_rev" ] || [ "$current_base_version" != "$target_base_version" ]; then
    update_base_version "$target_base_version"
    update_flake_version "$target_version"
    update_rev "$target_rev"
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

  if [ "$update_lock" = true ] && [ -f "${pkg_dir}/flake.lock" ]; then
    update_flake_lock
  fi

  show_changes

  if [ "$no_build" != true ]; then
    verify_build
  fi

  maybe_git_commit "$commit_message" flake.nix scripts/update-version.sh
  log_info "Done."
}

main "$@"
