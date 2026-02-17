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
readonly REPO_OWNER="block"
readonly REPO_NAME="goose"
readonly PACKAGE_ATTR="goose-cli"

BUILD_SYSTEM=""

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

get_current_version() {
  sed -n 's/^[[:space:]]*version = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
}

get_latest_release_tag() {
  local release_json
  release_json="$(curl -fsSL "$GITHUB_API_BASE/repos/$REPO_OWNER/$REPO_NAME/releases/latest")"
  printf '%s\n' "$release_json" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

run_nix_build() {
  local build_args=(nix build ".#${PACKAGE_ATTR}")

  if [ -n "$BUILD_SYSTEM" ]; then
    build_args+=(--system "$BUILD_SYSTEM")
  fi

  build_args+=(--no-link --print-out-paths)

  if [ "$1" = with_cd ]; then
    shift
    (cd "$pkg_dir" && "${build_args[@]}" "$@")
    return
  fi

  (cd "$pkg_dir" && "${build_args[@]}" "$@")
}

extract_nix_store_path() {
  printf '%s\n' "$1" | awk '/^\/nix\/store\// { last=$1 } END { if (last != "") print last }'
}

tag_to_version() {
  local tag="$1"
  tag="${tag#v}"
  printf '%s\n' "$tag"
}

extract_got_hash_from_build() {
  sed -n 's/.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' | head -n1
}

update_flake_version() {
  local new_version="$1"
  sed -i.bak -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1${new_version}\\2/" "$flake_file"
}

set_src_sha256_placeholder() {
  local placeholder="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  sed -i.bak -E "/src = pkgs\\.fetchFromGitHub[[:space:]]*\\{/,/\\};/ s|^([[:space:]]*sha256 = \")[^\"]*(\";)|\\1${placeholder}\\2|" "$flake_file"
}

update_src_sha256() {
  local new_sha256="$1"
  sed -i.bak -E "/src = pkgs\\.fetchFromGitHub[[:space:]]*\\{/,/\\};/ s|^([[:space:]]*sha256 = \")[^\"]*(\";)|\\1${new_sha256}\\2|" "$flake_file"
}

set_cargo_hash_placeholder() {
  local placeholder="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  sed -i.bak -E "s|^([[:space:]]*cargoHash = \")[^\"]*(\";)|\\1${placeholder}\\2|" "$flake_file"
}

update_cargo_hash() {
  local new_hash="$1"
  sed -i.bak -E "s|^([[:space:]]*cargoHash = \")[^\"]*(\";)|\\1${new_hash}\\2|" "$flake_file"
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
  local build_output
  local old_lc_all="$LC_ALL"
  LC_ALL=C
  if ! build_output="$(run_nix_build with_cd 2>&1)"; then
    log_error "Nix build failed for package verification"
    printf '%s\n' "$build_output" | sed -n '1,200p'
    LC_ALL="$old_lc_all"
    return 1
  fi
  LC_ALL="$old_lc_all"

  out_path="$(extract_nix_store_path "$build_output")"
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/goose" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/goose"
    log_warn "Build output:"
    printf '%s\n' "$build_output" | sed -n '1,120p'
    if [ -n "$out_path" ] && [ -e "$out_path" ]; then
      log_warn "Listing output path:"
      (ls -la "$out_path" | sed 's/^/[out] /') || true
      if [ -d "$out_path/bin" ]; then
        log_warn "Listing bin/:"
        (ls -la "$out_path/bin" | sed 's/^/[bin] /') || true
      fi
    elif [ -n "$out_path" ]; then
      log_warn "Output path does not exist: $out_path"
    fi
    return 1
  fi
  if ! "$out_path/bin/goose" --help >/dev/null 2>&1; then
    log_warn "goose binary exists but --help returned non-zero; continuing as this may be acceptable in offline checks"
  fi
  log_info "Build successful!"
}

compute_and_update_src_sha256() {
  log_info "Computing fetchFromGitHub sha256..."
  set_src_sha256_placeholder
  cleanup_backups

  local build_output
  build_output="$(run_nix_build with_cd 2>&1 || true)"
  local got_hash
  got_hash="$(printf '%s\n' "$build_output" | extract_got_hash_from_build)"

  if [ -z "$got_hash" ]; then
    log_error "Failed to parse sha256 from nix build output"
    printf '%s\n' "$build_output" | sed -n '1,160p' >&2 || true
    return 1
  fi

  log_info "src sha256: $got_hash"
  if ! update_src_sha256 "$got_hash"; then
    log_error "Failed to update src sha256 in flake.nix"
    return 1
  fi
  cleanup_backups
}

compute_and_update_cargo_hash() {
  log_info "Computing cargoHash..."
  set_cargo_hash_placeholder
  cleanup_backups

  local build_output
  build_output="$(run_nix_build with_cd 2>&1 || true)"
  local got_hash
  got_hash="$(printf '%s\n' "$build_output" | extract_got_hash_from_build)"

  if [ -z "$got_hash" ]; then
    log_error "Failed to parse cargoHash from nix build output"
    printf '%s\n' "$build_output" | sed -n '1,160p' >&2 || true
    return 1
  fi

  log_info "cargoHash: $got_hash"
  if ! update_cargo_hash "$got_hash"; then
    log_error "Failed to update cargoHash in flake.nix"
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
  --version VERSION   Update to a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute src sha256 and cargoHash for current version
  --no-build          Skip build verification
  --system SYSTEM     Optional nix build system (for hash/update/verify)
  --update-lock       Run 'nix flake update' after updating
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 1.13.2
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory

  local target_version=""
  local check_only=false
  local rehash=false
  local no_build=false
  local update_lock=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        target_version="${2:-}"
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
      --system)
        BUILD_SYSTEM="${2:-}"
        if [ -z "$BUILD_SYSTEM" ]; then
          log_error "Missing argument for --system"
          print_usage
          exit 2
        fi
        shift 2
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

  local current_version
  current_version="$(get_current_version)"
  if [ -z "$current_version" ]; then
    log_error "Failed to detect current version from flake.nix"
    exit 2
  fi

  local latest_tag
  latest_tag="$(get_latest_release_tag)"
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

  local backup
  backup="$(mktemp -t flake.nix.backup.XXXXXX)"
  cp "$flake_file" "$backup"

  cleanup_backups
  update_flake_version "$latest_version"
  cleanup_backups

  if ! compute_and_update_src_sha256; then
    log_error "Failed to compute src sha256; restoring previous flake.nix"
    cp "$backup" "$flake_file"
    rm -f "$backup"
    exit 1
  fi

  if ! compute_and_update_cargo_hash; then
    log_error "Failed to compute cargoHash; restoring previous flake.nix"
    cp "$backup" "$flake_file"
    rm -f "$backup"
    exit 1
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

  local -a commit_paths=("flake.nix")
  if [ -f "$pkg_dir/flake.lock" ]; then
    commit_paths+=("flake.lock")
  fi
  maybe_git_commit "$(build_commit_message "$current_version" "$latest_version" "$rehash")" "${commit_paths[@]}"

  log_info "Successfully updated $PACKAGE_ATTR from $current_version to $latest_version"
}

main "$@"
