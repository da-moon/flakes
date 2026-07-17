#!/usr/bin/env bash
# Appends the newest (or an explicit) cloudcraft-mcp release to releases.json
# and sets it as .latest. cloudcraft-mcp publishes matching PyPI versions and
# GitHub tags, so the PyPI version selects the GitHub source tag.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly PYPI_API_URL="https://pypi.org/pypi/cloudcraft-mcp/json"
readonly REPO_OWNER="hypark5540"
readonly REPO_NAME="cloudcraft-mcp"
readonly PACKAGE_ATTR="cloudcraft-mcp"
readonly BIN_NAME="cloudcraft-mcp"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"
readonly PACKAGE_DIR_NAME

ensure_required_tools_installed() {
  for tool in curl jq nix nix-prefetch-url timeout; do
    command -v "$tool" >/dev/null 2>&1 \
      || { log_error "$tool is required but not installed."; exit 2; }
  done
}

ensure_in_package_directory() {
  [ -f "$flake_file" ] || { log_error "flake.nix not found at: $flake_file"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at: $releases_file"; exit 2; }
}

# Mirror flake.nix: replace . - + with _ ('-' kept last for tr).
sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
}

get_current_version() {
  jq -r '.latest // empty' "$releases_file"
}

has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

get_latest_version_from_pypi() {
  curl -fsSL "$PYPI_API_URL" | jq -r '.info.version // empty'
}

get_source_url() {
  local version="$1"
  printf 'https://github.com/%s/%s/archive/refs/tags/v%s.tar.gz\n' \
    "$REPO_OWNER" "$REPO_NAME" "$version"
}

prefetch_source_hash_sri() {
  local url="$1"
  local base32
  base32="$(nix-prefetch-url --type sha256 --unpack "$url" 2>/dev/null | tail -n1)"
  nix hash to-sri --type sha256 "$base32"
}

upsert_release_entry() {
  local key="$1"
  local entry_json="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg k "$key" --argjson entry "$entry_json" \
    '.versions[$k] = $entry | .latest = $k' "$releases_file" >"$tmp"
  mv "$tmp" "$releases_file"
}

verify_build() {
  local sanitized_key="$1"
  local attr="${PACKAGE_ATTR}_${sanitized_key}"
  local out_path

  log_info "Verifying build of ${attr}..."
  if ! out_path="$(
    cd "$pkg_dir"
    nix build ".#${attr}" --no-link --print-out-paths --no-write-lock-file
  )"; then
    log_error "nix build failed for ${attr}"
    return 1
  fi

  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
    log_error "Build succeeded but expected binary is missing: $out_path/bin/$BIN_NAME"
    return 1
  fi

  if ! (
    cd "$pkg_dir"
    nix build .#default --no-link --no-write-lock-file
  ); then
    log_error "nix build failed for default"
    return 1
  fi

  # A dummy key lets the module construct FastMCP and register every tool.
  # Closing stdin then stops the stdio server without making an API request.
  if ! timeout 10 env \
    CLOUDCRAFT_API_KEY=nix-offline-smoke \
    CLOUDCRAFT_EXPORT_DIR="${TMPDIR:-/tmp}" \
    "$out_path/bin/$BIN_NAME" </dev/null >/dev/null 2>&1; then
    log_error "Binary failed its offline stdio startup smoke test"
    return 1
  fi

  log_info "Build and smoke test successful."
}

show_changes() {
  if command -v git >/dev/null 2>&1 \
    && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat -- releases.json 2>/dev/null || true
  fi
}

# Parallel-safe auto-commit. flock serializes the git index across updaters.
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
  cat <<'USAGE'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) cloudcraft-mcp release to releases.json,
sets it as .latest, and recomputes the fetchFromGitHub source hash. Existing
entries remain available as versioned package attributes.

Options:
  --version VERSION   Append a specific version (default: latest on PyPI)
  --check             Only check for updates (exit 1 if one is available)
  --rehash            Recompute the source hash for the selected version
  --no-build          Skip build and binary verification
  --no-commit         Do not auto-commit (default: auto-commit is enabled)
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 0.1.5
  ./scripts/update-version.sh --rehash --no-commit
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
  local do_commit=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        target_version="${2#v}"
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

  local current_version
  current_version="$(get_current_version)"
  [ -n "$current_version" ] \
    || { log_error "Failed to read .latest from releases.json"; exit 2; }

  local new_version
  if [ -n "$target_version" ]; then
    new_version="$target_version"
  else
    new_version="$(get_latest_version_from_pypi)"
    [ -n "$new_version" ] \
      || { log_error "Failed to fetch the latest version from PyPI"; exit 2; }
  fi

  log_info "Current latest: $current_version"
  log_info "Target version: $new_version"

  if [ "$check_only" = true ]; then
    if has_version_entry "$new_version" && [ "$current_version" = "$new_version" ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: $current_version -> $new_version"
    exit 1
  fi

  if has_version_entry "$new_version" \
    && [ "$current_version" = "$new_version" ] \
    && [ "$rehash" != true ]; then
    log_info "Already up to date!"
    exit 0
  fi

  local source_url source_hash
  source_url="$(get_source_url "$new_version")"
  log_info "Computing source hash from $source_url"
  source_hash="$(prefetch_source_hash_sri "$source_url")"
  [ -n "$source_hash" ] \
    || { log_error "Failed to prefetch source for $new_version"; exit 1; }
  log_info "Source hash: $source_hash"

  local entry_json
  entry_json="$(jq -n \
    --arg version "$new_version" \
    --arg rev "v$new_version" \
    --arg hash "$source_hash" \
    '{version: $version, rev: $rev, hash: $hash}')"

  local backup
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"
  upsert_release_entry "$new_version" "$entry_json"

  local sanitized_key
  sanitized_key="$(sanitize_key "$new_version")"
  if [ "$no_build" != true ] && ! verify_build "$sanitized_key"; then
    log_error "Verification failed; restoring the previous releases.json"
    cp "$backup" "$releases_file"
    rm -f "$backup"
    exit 1
  fi
  rm -f "$backup"

  show_changes

  if [ "$do_commit" = true ]; then
    local message
    if [ "$current_version" != "$new_version" ]; then
      message="chore(${PACKAGE_DIR_NAME}): bump to ${new_version}"
    elif [ "$rehash" = true ]; then
      message="chore(${PACKAGE_DIR_NAME}): rehash ${new_version}"
    else
      message="chore(${PACKAGE_DIR_NAME}): update version"
    fi
    maybe_git_commit "$message" "releases.json"
  fi

  log_info "Successfully selected cloudcraft-mcp $new_version (was $current_version)"
}

main "$@"
