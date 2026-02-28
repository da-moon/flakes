#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly NPM_REGISTRY_URL="https://registry.npmjs.org"
readonly NPM_PACKAGE="@upstash/context7-mcp"
readonly TARBALL_NAME="context7-mcp"
readonly PACKAGE_ATTR="context7-mcp"
readonly BIN_NAME="context7-mcp"

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

get_latest_version_from_npm() {
  local latest_json
  latest_json="$(curl -fsSL "$NPM_REGISTRY_URL/$NPM_PACKAGE/latest")"
  printf '%s\n' "$latest_json" | sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

get_current_system_key() {
  nix eval --impure --raw --expr builtins.currentSystem
}

has_fake_hash() {
  local current_system_key
  local output_hash_line

  current_system_key="$(get_current_system_key)"
  if [ -z "$current_system_key" ]; then
    log_error "Failed to detect current system key"
    return 1
  fi

  output_hash_line="$(awk -v target="$current_system_key" '
    /outputHashBySystem[[:space:]]*=[[:space:]]*\\{/ { in_map = 1; next }
    in_map && /};/ { in_map = 0 }
    in_map && $0 ~ ("\"" target "\"") { print $0 }
  ' "$flake_file" | grep -v '^[[:space:]]*#' | head -n1)"

  if [ -z "$output_hash_line" ]; then
    return 1
  fi

  if printf '%s\n' "$output_hash_line" | grep -q 'fakeHash'; then
    return 0
  fi
  if printf '%s\n' "$output_hash_line" | grep -q 'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='; then
    return 0
  fi
  return 1
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' \
    | head -n1
}

extract_got_hash_from_build() {
  sed -n 's/.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' | head -n1
}

update_flake_version() {
  local new_version="$1"
  sed -i.bak -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1${new_version}\\2/" "$flake_file"
}

update_tarball_hash() {
  local new_hash="$1"
  sed -i.bak -E "s|^([[:space:]]*hash = \")[^\"]*(\";)|\\1${new_hash}\\2|" "$flake_file"
}

set_output_hash_placeholder_for_system() {
  local system_key="$1"
  local placeholder="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  sed -i.bak -E "/outputHashBySystem[[:space:]]*=[[:space:]]*\\{/,/\\};/ s|^([[:space:]]*\"${system_key}\"[[:space:]]*=[[:space:]]*\")[^\"]*(\";)|\\1${placeholder}\\2|" "$flake_file"
  if ! grep -Fq "\"${system_key}\" = \"${placeholder}\";" "$flake_file"; then
    log_error "Failed to set outputHash placeholder for system: $system_key"
    return 1
  fi
}

update_output_hash_for_system() {
  local system_key="$1"
  local new_hash_value="$2"
  sed -i.bak -E "/outputHashBySystem[[:space:]]*=[[:space:]]*\\{/,/\\};/ s|^([[:space:]]*\"${system_key}\"[[:space:]]*=[[:space:]]*\")[^\"]*(\";)|\\1${new_hash_value}\\2|" "$flake_file"
  if ! grep -Fq "\"${system_key}\" = \"${new_hash_value}\";" "$flake_file"; then
    log_error "Failed to update outputHash for system: $system_key"
    return 1
  fi
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
  if ! update_output_hash_for_system "$system_key" "$got_hash"; then
    log_error "Failed to update outputHash in flake.nix"
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
  --rehash            Recompute tarball hash and outputHash for current system
  --no-build          Skip build verification
  --update-lock       Run 'nix flake update' after updating
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 1.0.31
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
    log_error "Failed to detect current version from flake.nix"
    exit 2
  fi

  local latest_version
  latest_version="$(get_latest_version_from_npm)"
  if [ -z "$latest_version" ]; then
    log_error "Failed to fetch latest version from npm"
    exit 2
  fi

  if [ -n "$target_version" ]; then
    latest_version="$target_version"
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
    if has_fake_hash; then
      log_info "Detected fakeHash for current system; proceeding with rehash..."
      rehash=true
    else
      log_info "Already up to date!"
      exit 0
    fi
  fi

  local tarball_url
  tarball_url="$NPM_REGISTRY_URL/$NPM_PACKAGE/-/$TARBALL_NAME-$latest_version.tgz"
  log_info "Prefetching tarball hash..."
  local tarball_hash
  tarball_hash="$(prefetch_sha256_sri "$tarball_url")"
  if [ -z "$tarball_hash" ]; then
    log_error "Failed to prefetch tarball hash"
    exit 2
  fi
  log_info "Tarball hash: $tarball_hash"

  local backup
  backup="$(mktemp -t flake.nix.backup.XXXXXX)"
  cp "$flake_file" "$backup"

  cleanup_backups
  update_flake_version "$latest_version"
  update_tarball_hash "$tarball_hash"
  cleanup_backups

  if ! compute_and_update_output_hash; then
    log_error "Failed to compute outputHash; restoring previous flake.nix"
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
