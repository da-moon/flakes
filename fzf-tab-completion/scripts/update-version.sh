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
readonly REPO_OWNER="lincheney"
readonly REPO_NAME="fzf-tab-completion"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"

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

get_current_rev() {
  sed -n 's/^[[:space:]]*rev = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
}

get_current_version() {
  sed -n 's/^[[:space:]]*version = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
}

get_default_branch() {
  local repo_json
  repo_json="$(curl -fsSL "$GITHUB_API_BASE/repos/$REPO_OWNER/$REPO_NAME")"
  printf '%s\n' "$repo_json" | sed -n 's/.*"default_branch":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

get_latest_commit_info() {
  local branch="$1"
  local commit_json
  commit_json="$(curl -fsSL "$GITHUB_API_BASE/repos/$REPO_OWNER/$REPO_NAME/commits/$branch")"
  local sha date
  sha="$(printf '%s\n' "$commit_json" | sed -n 's/.*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -n1)"
  date="$(printf '%s\n' "$commit_json" | sed -n 's/.*"date":[[:space:]]*"\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)T.*/\1/p' | head -n1)"
  printf '%s|%s\n' "$sha" "$date"
}

extract_got_hash_from_build() {
  sed -n 's/.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' | head -n1
}

update_flake_version() {
  local new_version="$1"
  sed -i.bak -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1${new_version}\\2/" "$flake_file"
}

update_flake_rev() {
  local new_rev="$1"
  sed -i.bak -E "s/^([[:space:]]*rev = \")[^\"]*(\";)/\\1${new_rev}\\2/" "$flake_file"
}

set_sha256_placeholder() {
  local placeholder="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  sed -i.bak -E "s|^([[:space:]]*sha256 = \")[^\"]*(\";)|\\1${placeholder}\\2|" "$flake_file"
}

update_src_sha256() {
  local new_sha256="$1"
  sed -i.bak -E "s|^([[:space:]]*sha256 = \")[^\"]*(\";)|\\1${new_sha256}\\2|" "$flake_file"
}

cleanup_backups() {
  rm -f "${flake_file}.bak" 2>/dev/null || true
}

update_flake_lock() {
  log_info "Updating flake.lock..."
  (cd "$pkg_dir" && nix flake update)
}

verify_build() {
  log_info "Verifying build..."
  local out_path
  out_path="$(cd "$pkg_dir" && nix build .#fzf-tab-completion --no-link --print-out-paths)"
  if [ -z "$out_path" ]; then
    log_error "Build succeeded but out path was empty"
    return 1
  fi
  test -d "$out_path/share/fzf-tab-completion" || true
  log_info "Build successful!"
}

compute_and_update_src_sha256() {
  log_info "Computing fetchFromGitHub sha256..."
  set_sha256_placeholder
  cleanup_backups

  local build_output
  build_output="$(cd "$pkg_dir" && nix build .#fzf-tab-completion --no-link 2>&1 || true)"
  local got_hash
  got_hash="$(printf '%s\n' "$build_output" | extract_got_hash_from_build)"

  if [ -z "$got_hash" ]; then
    log_error "Failed to parse sha256 from nix build output"
    printf '%s\n' "$build_output" | sed -n '1,120p' >&2 || true
    return 1
  fi

  log_info "sha256: $got_hash"
  if ! update_src_sha256 "$got_hash"; then
    log_error "Failed to update sha256 in flake.nix"
    return 1
  fi
  cleanup_backups
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat flake.nix flake.lock 2>/dev/null || true
  fi
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Options:
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute sha256 for current revision
  --no-build          Skip build verification
  --update-lock       Run 'nix flake update' after updating
  --help              Show this help message

Notes:
  This repo does not publish regular versioned releases. This script tracks the
  latest commit on the default branch and sets version to "unstable-YYYY-MM-DD".

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory

  local check_only=false
  local rehash=false
  local no_build=false
  local update_lock=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
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

  local current_rev current_version
  current_rev="$(get_current_rev)"
  current_version="$(get_current_version)"
  if [ -z "$current_rev" ] || [ -z "$current_version" ]; then
    log_error "Failed to detect current rev/version from flake.nix"
    exit 2
  fi

  local default_branch
  default_branch="$(get_default_branch)"
  if [ -z "$default_branch" ]; then
    log_error "Failed to detect default branch from GitHub"
    exit 2
  fi

  local latest_info latest_rev latest_date
  latest_info="$(get_latest_commit_info "$default_branch")"
  latest_rev="${latest_info%%|*}"
  latest_date="${latest_info##*|}"
  if [ -z "$latest_rev" ] || [ -z "$latest_date" ]; then
    log_error "Failed to fetch latest commit info from GitHub"
    exit 2
  fi

  local latest_version
  latest_version="unstable-$latest_date"

  log_info "Current rev:    $current_rev"
  log_info "Latest rev:     $latest_rev"
  log_info "Current version: $current_version"
  log_info "Target version:  $latest_version"

  local rev_changed=false
  local version_changed=false
  if [ "$current_rev" != "$latest_rev" ]; then
    rev_changed=true
  fi
  if [ "$current_version" != "$latest_version" ]; then
    version_changed=true
  fi

  if [ "$check_only" = true ]; then
    if [ "$rev_changed" = false ] && [ "$version_changed" = false ]; then
      log_info "Already up to date!"
      exit 0
    fi
    if [ "$rev_changed" = true ]; then
      log_info "Update available: $current_rev -> $latest_rev"
    else
      log_info "Update available: version label drift ($current_version -> $latest_version)"
    fi
    exit 1
  fi

  if [ "$rev_changed" = false ] && [ "$version_changed" = false ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"
    exit 0
  fi

  local backup
  backup="$(mktemp -t flake.nix.backup.XXXXXX)"
  cp "$flake_file" "$backup"

  cleanup_backups
  update_flake_version "$latest_version"
  update_flake_rev "$latest_rev"
  cleanup_backups

  if [ "$rev_changed" = true ] || [ "$rehash" = true ]; then
    if ! compute_and_update_src_sha256; then
      log_error "Failed to compute sha256; restoring previous flake.nix"
      cp "$backup" "$flake_file"
      rm -f "$backup"
      exit 1
    fi
  fi

  if [ "$no_build" != true ]; then
    if ! verify_build; then
      log_error "Build verification failed; restoring previous flake.nix"
      cp "$backup" "$flake_file"
      rm -f "$backup"
      exit 1
    fi
  fi

  rm -f "$backup"

  if [ "$update_lock" = true ]; then
    update_flake_lock
  fi

  show_changes
  log_info "Successfully updated fzf-tab-completion to $latest_rev ($latest_version)"
}

main "$@"
