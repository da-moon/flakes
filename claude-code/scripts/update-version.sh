#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly DOWNLOAD_BASE_URL="https://downloads.claude.ai/claude-code-releases"
declare -Ar SYSTEM_TO_RELEASE_PLATFORM=(
  [x86_64-linux]="linux-x64"
  [aarch64-linux]="linux-arm64"
)

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

DOWNLOADER=""
HAS_JQ=false
temp_flake_file=""

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v sed >/dev/null 2>&1 || { log_error "sed is required but not installed."; exit 2; }
  command -v awk >/dev/null 2>&1 || { log_error "awk is required but not installed."; exit 2; }

  if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
  else
    log_error "Either curl or wget is required but neither is installed."
    exit 2
  fi

  if command -v jq >/dev/null 2>&1; then
    HAS_JQ=true
  fi
}

ensure_in_package_directory() {
  if [ ! -f "$flake_file" ]; then
    log_error "flake.nix not found at: $flake_file"
    exit 2
  fi
}

download_file() {
  local url="$1"
  local output="${2:-}"

  if [ "$DOWNLOADER" = "curl" ]; then
    if [ -n "$output" ]; then
      curl -fsSL -o "$output" "$url"
    else
      curl -fsSL "$url"
    fi
  else
    if [ -n "$output" ]; then
      wget -q -O "$output" "$url"
    else
      wget -q -O - "$url"
    fi
  fi
}

get_current_version() {
  sed -n 's/^[[:space:]]*version = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
}

get_latest_version() {
  download_file "$DOWNLOAD_BASE_URL/latest"
}

get_manifest_json() {
  local version="$1"
  download_file "$DOWNLOAD_BASE_URL/$version/manifest.json"
}

get_manifest_checksum() {
  local manifest_json="$1"
  local platform="$2"

  if [ "$HAS_JQ" = true ]; then
    printf '%s' "$manifest_json" | jq -r ".platforms[\"$platform\"].checksum // empty"
    return 0
  fi

  local normalized_json
  normalized_json="$(printf '%s' "$manifest_json" | tr -d '\n\r\t' | sed 's/ \+/ /g')"

  if [[ $normalized_json =~ \"$platform\"[^}]*\"checksum\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

sha256_hex_to_sri() {
  local hex_hash="$1"
  nix hash to-sri --type sha256 "$hex_hash"
}

update_flake_version() {
  local new_version="$1"
  sed -i.bak -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1${new_version}\\2/" "$flake_file"
}

update_flake_hash_block() {
  local x86_64_hash="$1"
  local aarch64_hash="$2"

  temp_flake_file="$(mktemp "${flake_file}.XXXXXX")"

  if ! awk -v x86="$x86_64_hash" -v arm="$aarch64_hash" '
    BEGIN {
      in_block = 0
      replaced = 0
    }

    /^[[:space:]]*binarySha256BySystem = \{/ {
      print
      print "          # update-version.sh managed hashes."
      print "          x86_64-linux = \"" x86 "\";"
      print "          aarch64-linux = \"" arm "\";"
      in_block = 1
      replaced = 1
      next
    }

    in_block && /^[[:space:]]*};[[:space:]]*$/ {
      in_block = 0
      print
      next
    }

    !in_block {
      print
    }

    END {
      if (!replaced) {
        exit 10
      }
    }
  ' "$flake_file" > "$temp_flake_file"; then
    rm -f "$temp_flake_file"
    temp_flake_file=""
    log_error "Failed to rewrite binarySha256BySystem block in flake.nix"
    exit 2
  fi

  mv "$temp_flake_file" "$flake_file"
  temp_flake_file=""
}

cleanup_backups() {
  rm -f "${flake_file}.bak" 2>/dev/null || true
  if [ -n "$temp_flake_file" ]; then
    rm -f "$temp_flake_file" 2>/dev/null || true
  fi
}

trap cleanup_backups EXIT

update_flake_lock() {
  log_info "Updating flake.lock..."
  (cd "$pkg_dir" && nix flake update)
}

verify_build() {
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build .#claude-code --no-link --print-out-paths)"; then
    log_error "nix build failed for claude-code"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/claude" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/claude"
    return 1
  fi
  "$out_path/bin/claude" --version >/dev/null 2>&1 || true
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
  --version VERSION   Update to a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute Linux release hashes for the current version
  --no-build          Skip build verification
  --update-lock       Run 'nix flake update' after updating
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 2.1.114
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
  latest_version="$(get_latest_version)"
  if [ -z "$latest_version" ]; then
    log_error "Failed to fetch latest version"
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
    log_info "Already up to date!"
    exit 0
  fi

  log_info "Fetching release manifest..."
  local manifest_json
  manifest_json="$(get_manifest_json "$latest_version")"
  if [ -z "$manifest_json" ]; then
    log_error "Failed to fetch manifest for version $latest_version"
    exit 2
  fi

  local x86_64_checksum_hex
  x86_64_checksum_hex="$(get_manifest_checksum "$manifest_json" "${SYSTEM_TO_RELEASE_PLATFORM[x86_64-linux]}")"
  if [ -z "$x86_64_checksum_hex" ]; then
    log_error "Missing manifest checksum for ${SYSTEM_TO_RELEASE_PLATFORM[x86_64-linux]}"
    exit 2
  fi

  local aarch64_checksum_hex
  aarch64_checksum_hex="$(get_manifest_checksum "$manifest_json" "${SYSTEM_TO_RELEASE_PLATFORM[aarch64-linux]}")"
  if [ -z "$aarch64_checksum_hex" ]; then
    log_error "Missing manifest checksum for ${SYSTEM_TO_RELEASE_PLATFORM[aarch64-linux]}"
    exit 2
  fi

  local x86_64_hash
  x86_64_hash="$(sha256_hex_to_sri "$x86_64_checksum_hex")"
  local aarch64_hash
  aarch64_hash="$(sha256_hex_to_sri "$aarch64_checksum_hex")"

  log_info "x86_64-linux hash: $x86_64_hash"
  log_info "aarch64-linux hash: $aarch64_hash"

  local backup
  backup="$(mktemp -t flake.nix.backup.XXXXXX)"
  cp "$flake_file" "$backup"

  cleanup_backups
  update_flake_version "$latest_version"
  update_flake_hash_block "$x86_64_hash" "$aarch64_hash"
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
    update_flake_lock
  fi

  show_changes

  local -a commit_paths=("flake.nix")
  if [ -f "$pkg_dir/flake.lock" ]; then
    commit_paths+=("flake.lock")
  fi
  maybe_git_commit "$(build_commit_message "$current_version" "$latest_version" "$rehash")" "${commit_paths[@]}"

  log_info "Successfully updated claude-code from $current_version to $latest_version"
}

main "$@"
