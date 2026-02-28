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
readonly REPO_OWNER="tobi"
readonly REPO_NAME="qmd"
readonly PACKAGE_ATTR="qmd"
readonly BIN_NAME="qmd"

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
  printf '%s\n' "$release_json" | sed -n 's/.*"tag_name":[[:space:]]*"\([^\"]*\)".*/\1/p' | head -n1
}

tag_to_version() {
  local tag="$1"
  tag="${tag#v}"
  printf '%s\n' "$tag"
}

get_current_system_key() {
  nix eval --impure --raw --expr builtins.currentSystem
}

get_source_url() {
  local version="$1"
  printf 'https://github.com/%s/%s/archive/refs/tags/v%s.tar.gz' "$REPO_OWNER" "$REPO_NAME" "$version"
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' \
    | head -n1
}

update_flake_version() {
  local new_version="$1"
  sed -i.bak -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1${new_version}\\2/" "$flake_file"
}

update_source_hash() {
  local system_key="$1"
  local new_hash="$2"
  sed -i.bak -E "/\"sourceHashBySystem\"[[:space:]]*= {/,/\};/ s|^([[:space:]]*\"${system_key}\"[[:space:]]*= \")[^\"]*(\";)|\\1${new_hash}\\2|" "$flake_file"
}

get_source_hash_for_system() {
  local target_system="$1"
  awk -v target="$target_system" '
    /sourceHashBySystem[[:space:]]*= {/ { in_map = 1; next }
    in_map && /};/ { in_map = 0 }
    in_map && $0 ~ "\"" target "\"" { if (match($0, /"[^"]+"[[:space:]]*= "([^"]+)";/, a) > 0) print a[1] }
  ' "$flake_file"
}

get_output_hash_for_system() {
  local target_system="$1"
  awk -v target="$target_system" '
    /outputHashBySystem[[:space:]]*= {/ { in_map = 1; next }
    in_map && /};/ { in_map = 0 }
    in_map && $0 ~ "\"" target "\"" { if (match($0, /"[^"]+"[[:space:]]*= "([^"]+)";/, a) > 0) print a[1] }
  ' "$flake_file"
}

set_output_hash_placeholder_for_system() {
  local system_key="$1"
  local placeholder="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  sed -i.bak -E "/\"outputHashBySystem\"[[:space:]]*= {/,/\};/ s|^([[:space:]]*\"${system_key}\"[[:space:]]*=[[:space:]]*)(pkgs\\.lib\\.fakeHash|\"[^\"]*\")[[:space:]]*;|\\1\"${placeholder}\";|" "$flake_file"
  if ! grep -Fq "\"${system_key}\" = \"${placeholder}\";" "$flake_file"; then
    log_error "Failed to set outputHash placeholder for system: $system_key"
    return 1
  fi
}

update_output_hash() {
  local system_key="$1"
  local new_hash="$2"
  sed -i.bak -E "/\"outputHashBySystem\"[[:space:]]*= {/,/\};/ s|^([[:space:]]*\"${system_key}\"[[:space:]]*= \")[^\"]*(\";)|\\1${new_hash}\\2|" "$flake_file"
  if ! grep -Fq "\"${system_key}\" = \"${new_hash}\";" "$flake_file"; then
    log_error "Failed to update outputHash for system: $system_key"
    return 1
  fi
}

cleanup_backups() {
  rm -f "${flake_file}.bak" 2>/dev/null || true
}

extract_got_hash_from_build() {
  sed -n 's/.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' | head -n1
}

verify_build() {
  log_info "Verifying build..."
  local out_path
  out_path="$(cd "$pkg_dir" && nix build .#${PACKAGE_ATTR} --no-link --print-out-paths)"
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/$BIN_NAME"
    return 1
  fi
  "$out_path/bin/$BIN_NAME" --help >/dev/null 2>&1 || true
  log_info "Build successful!"
}

compute_and_update_output_hash() {
  local system_key
  system_key="$(get_current_system_key)"
  if [ -z "$system_key" ]; then
    log_error "Failed to detect current system key"
    return 1
  fi

  log_info "Computing outputHash (fixed-output npm deps) for system: $system_key"
  if ! set_output_hash_placeholder_for_system "$system_key"; then
    return 1
  fi
  cleanup_backups

  local build_output
  build_output="$(cd "$pkg_dir" && nix build .#${PACKAGE_ATTR} --no-link 2>&1 || true)"
  local got_hash
  got_hash="$(printf '%s\n' "$build_output" | extract_got_hash_from_build)"

  if [ -z "$got_hash" ]; then
    log_error "Failed to parse outputHash from nix build output"
    printf '%s\n' "$build_output" | sed -n '1,120p' >&2 || true
    return 1
  fi

  log_info "outputHash ($system_key): $got_hash"
  if ! update_output_hash "$system_key" "$got_hash"; then
    log_error "Failed to update outputHash in flake.nix"
    return 1
  fi
  cleanup_backups
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
  cat <<'USAGE'
Usage: ./scripts/update-version.sh [OPTIONS]

Options:
  --version VERSION   Update to a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute source hash and outputHash for current architecture
  --no-build          Skip build verification
  --update-lock       Run 'nix flake update' after updating
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 1.0.7
USAGE
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

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
    log_error "Failed to determine current version from flake.nix"
    exit 2
  fi

  local latest_tag
  latest_tag="$(get_latest_release_tag)"
  if [ -z "$latest_tag" ]; then
    log_error "Failed to fetch latest release from GitHub"
    exit 2
  fi

  local latest_version source_tag
  latest_version="$(tag_to_version "$latest_tag")"
  source_tag="$latest_tag"

  if [ -n "$target_version" ]; then
    latest_version="${target_version#v}"
    source_tag="v${latest_version}"
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

  local source_url
  source_url="$(get_source_url "$latest_version")"

  local source_hash
  source_hash="$(prefetch_sha256_sri "$source_url")"
  if [ -z "$source_hash" ]; then
    log_error "Failed to prefetch source hash"
    exit 2
  fi

  log_info "Source tarball hash: $source_hash"

  local current_system_key
  current_system_key="$(get_current_system_key)"
  if [ -z "$current_system_key" ]; then
    log_error "Failed to detect current system"
    exit 2
  fi

  log_info "Current system: $current_system_key"
  if [ -z "$(get_source_hash_for_system "$current_system_key")" ]; then
    log_warn "No sourceHashBySystem entry for ${current_system_key}"
  fi
  if [ -z "$(get_output_hash_for_system "$current_system_key")" ]; then
    log_warn "No outputHashBySystem entry for ${current_system_key}"
  fi

  local backup
  backup="$(mktemp -t flake.nix.backup.XXXXXX)"
  cp "$flake_file" "$backup"

  cleanup_backups
  update_flake_version "$latest_version"
  update_source_hash "aarch64-linux" "$source_hash"
  update_source_hash "x86_64-linux" "$source_hash"
  if [ "$no_build" != true ]; then
    if ! compute_and_update_output_hash; then
      log_error "Failed to update outputHash; restoring previous flake.nix"
      cp "$backup" "$flake_file"
      rm -f "$backup"
      exit 1
    fi
  else
    log_warn "Skipping outputHash update because --no-build was requested"
  fi
  cleanup_backups

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
    log_info "Updating flake.lock..."
    (cd "$pkg_dir" && nix flake update)
  fi

  local -a commit_paths=("flake.nix")
  if [ -f "$pkg_dir/flake.lock" ]; then
    commit_paths+=("flake.lock")
  fi
  maybe_git_commit "$(build_commit_message "$current_version" "$latest_version" "$rehash")" "${commit_paths[@]}"

  log_info "Successfully updated ${PACKAGE_ATTR} from $current_version to $latest_version"
}

main "$@"
