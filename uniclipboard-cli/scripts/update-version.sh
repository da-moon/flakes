#!/usr/bin/env bash
# Appends the newest stable UniClipboard CLI release to releases.json and sets
# it as .latest. Each Unix archive contains both `uniclip` and the matching
# sibling `uniclipd` daemon, with dedicated Linux and macOS assets per CPU.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly GITHUB_API_BASE="https://api.github.com"
readonly REPO_OWNER="UniClipboard"
readonly REPO_NAME="UniClipboard"

declare -Ar TARGET_BY_SYSTEM=(
  [x86_64-linux]="x86_64-unknown-linux-musl"
  [aarch64-linux]="aarch64-unknown-linux-musl"
  [x86_64-darwin]="x86_64-apple-darwin"
  [aarch64-darwin]="aarch64-apple-darwin"
)
readonly SYSTEM_KEYS=(
  x86_64-linux
  aarch64-linux
  x86_64-darwin
  aarch64-darwin
)

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  for tool in nix curl jq; do
    command -v "$tool" >/dev/null 2>&1 || {
      log_error "$tool is required but not installed."
      exit 2
    }
  done
}

ensure_in_package_directory() {
  [ -f "$flake_file" ] || {
    log_error "flake.nix not found at: $flake_file"
    exit 2
  }
  [ -f "$releases_file" ] || {
    log_error "releases.json not found at: $releases_file"
    exit 2
  }
}

get_current_version() {
  jq -r '.latest // empty' "$releases_file"
}

has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg key "$key" '.versions | has($key)' "$releases_file")" = true ]
}

get_latest_release_tag() {
  curl -fsSL "$GITHUB_API_BASE/repos/$REPO_OWNER/$REPO_NAME/releases/latest" |
    jq -r '.tag_name // empty'
}

prefetch_sha256_sri() {
  nix store prefetch-file --json --hash-type sha256 "$1" |
    jq -r '.hash // empty'
}

sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
}

asset_url() {
  local version="$1"
  local target="$2"
  printf 'https://github.com/%s/%s/releases/download/v%s/uniclipboard-cli-%s-%s.tar.gz\n' \
    "$REPO_OWNER" "$REPO_NAME" "$version" "$version" "$target"
}

upsert_release_entry() {
  local key="$1"
  local entry_json="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg key "$key" --argjson entry "$entry_json" \
    '.versions[$key] = $entry | .latest = $key' "$releases_file" >"$tmp"
  mv "$tmp" "$releases_file"
}

verify_build() {
  local attr="$1"
  local out_path
  log_info "Verifying native build..."
  out_path="$(
    cd "$pkg_dir"
    nix build ".#$attr" --no-link --print-out-paths --no-write-lock-file
  )" || return 1

  [ -x "$out_path/bin/uniclip" ] || {
    log_error "Expected binary not found: $out_path/bin/uniclip"
    return 1
  }
  [ -x "$out_path/bin/uniclipd" ] || {
    log_error "Expected daemon not found: $out_path/bin/uniclipd"
    return 1
  }

  if command -v timeout >/dev/null 2>&1; then
    timeout 30 "$out_path/bin/uniclip" --version >/dev/null
  else
    "$out_path/bin/uniclip" --version >/dev/null
  fi
  log_info "Native build successful."
}

maybe_git_commit() {
  local message="$1"
  if ! command -v git >/dev/null 2>&1 ||
    ! git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_warn "Not in a Git worktree; skipping commit."
    return 0
  fi

  local git_dir lock_file
  git_dir="$(git -C "$pkg_dir" rev-parse --absolute-git-dir 2>/dev/null || true)"
  lock_file="${git_dir:-$pkg_dir/.git}/update-version-commit.lock"
  (
    if command -v flock >/dev/null 2>&1; then
      flock 9
    fi
    git -C "$pkg_dir" add -- releases.json
    if git -C "$pkg_dir" diff --cached --quiet -- releases.json; then
      exit 0
    fi
    git -C "$pkg_dir" commit --only -m "$message" -- releases.json
  ) 9>"$lock_file"
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends a stable UniClipboard CLI release to releases.json, preserving older
entries. Hashes for both Linux architectures and both macOS architectures are
prefetched from the official release archives.

Options:
  --version VERSION   Append a specific stable version (default: latest)
  --check             Check for an update without changing files
  --rehash            Recompute hashes when the version is already current
  --no-build          Skip native build verification
  --no-commit         Do not commit the releases.json update
  --help              Show this help message
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory

  local target_version=""
  local check_only=false
  local rehash=false
  local no_build=false
  local do_commit=true

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version)
        [ "$#" -ge 2 ] || {
          log_error "--version requires an argument"
          exit 2
        }
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
      --no-commit)
        do_commit=false
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

  local current_version latest_tag latest_version
  current_version="$(get_current_version)"
  [ -n "$current_version" ] || {
    log_error "Failed to read the current version."
    exit 2
  }

  if [ -n "$target_version" ]; then
    latest_version="${target_version#v}"
  else
    latest_tag="$(get_latest_release_tag)"
    latest_version="${latest_tag#v}"
  fi
  [ -n "$latest_version" ] || {
    log_error "Failed to resolve the target version."
    exit 2
  }

  log_info "Current latest: $current_version"
  log_info "Target version:  $latest_version"

  if [ "$check_only" = true ]; then
    if has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ]; then
      log_info "Already up to date."
      exit 0
    fi
    log_info "Update available: $current_version -> $latest_version"
    exit 1
  fi

  if has_version_entry "$latest_version" &&
    [ "$current_version" = "$latest_version" ] &&
    [ "$rehash" = false ]; then
    log_info "Already up to date."
    exit 0
  fi

  local hashes_json='{}'
  local system target url hash
  for system in "${SYSTEM_KEYS[@]}"; do
    target="${TARGET_BY_SYSTEM[$system]}"
    url="$(asset_url "$latest_version" "$target")"
    log_info "Prefetching $system archive..."
    hash="$(prefetch_sha256_sri "$url")"
    [ -n "$hash" ] || {
      log_error "Failed to prefetch $url"
      exit 2
    }
    hashes_json="$(
      jq -n --argjson hashes "$hashes_json" --arg system "$system" --arg hash "$hash" \
        '$hashes + {($system): $hash}'
    )"
  done

  local entry_json backup attr
  entry_json="$(
    jq -n --arg version "$latest_version" --argjson hashes "$hashes_json" \
      '{version: $version, rev: $version, hashes: $hashes}'
  )"
  backup="$(mktemp -t uniclipboard-releases.XXXXXX)"
  cp "$releases_file" "$backup"
  upsert_release_entry "$latest_version" "$entry_json"

  attr="uniclipboard-cli_$(sanitize_key "$latest_version")"
  if [ "$no_build" = false ] && ! verify_build "$attr"; then
    log_error "Build verification failed; restoring releases.json."
    cp "$backup" "$releases_file"
    rm -f "$backup"
    exit 1
  fi
  rm -f "$backup"

  if [ "$do_commit" = true ]; then
    maybe_git_commit "chore(${PACKAGE_DIR_NAME}): bump to ${latest_version}"
  fi
  log_info "Successfully updated UniClipboard CLI to $latest_version."
}

main "$@"
