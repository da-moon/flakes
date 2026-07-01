#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly GITHUB_REPO="Polymarket/polymarket-cli"
readonly GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
readonly DOWNLOAD_BASE_URL="https://github.com/${GITHUB_REPO}/releases/download"

# nix system -> Rust target triple embedded in the release asset name.
declare -Ar SYSTEM_TO_RUST_TRIPLE=(
  [x86_64-linux]="x86_64-unknown-linux-gnu"
  [aarch64-linux]="aarch64-unknown-linux-gnu"
)

# Optional GitHub token to raise the API rate limit / access private assets.
readonly GITHUB_ENV_FILE="/home/ubuntu/sync/env.d.local/github.sh"
if [ -f "$GITHUB_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$GITHUB_ENV_FILE" || true
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

DOWNLOADER=""

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v jq >/dev/null 2>&1 || { log_error "jq is required but not installed."; exit 2; }

  if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
  else
    log_error "Either curl or wget is required but neither is installed."
    exit 2
  fi
}

ensure_in_package_directory() {
  if [ ! -f "$flake_file" ]; then
    log_error "flake.nix not found at: $flake_file"
    exit 2
  fi
  if [ ! -f "$releases_file" ]; then
    log_error "releases.json not found at: $releases_file"
    exit 2
  fi
}

# Fetch a URL to stdout. Adds the GitHub auth header when a token is present.
download_file() {
  local url="$1"

  if [ "$DOWNLOADER" = "curl" ]; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$url"
    else
      curl -fsSL "$url"
    fi
  else
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      wget -q --header "Authorization: Bearer ${GITHUB_TOKEN}" -O - "$url"
    else
      wget -q -O - "$url"
    fi
  fi
}

# Current "latest" key recorded in the version table.
get_current_version() {
  jq -r '.latest // empty' "$releases_file"
}

# Does the table already have an entry for this key?
has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

# Newest release version (tag without the leading "v").
get_latest_version() {
  download_file "$GITHUB_API_URL" | jq -r '.tag_name // empty' | sed 's/^v//'
}

# Compute the SRI sha256 of a remote release asset (the .tar.gz as fetched).
compute_asset_sri() {
  local url="$1"
  local base32
  base32="$(nix-prefetch-url "$url" 2>/dev/null | tail -n1)"
  if [ -z "$base32" ]; then
    return 1
  fi
  nix hash to-sri --type sha256 "$base32"
}

# Append/upsert an entry into releases.json and set .latest.
upsert_release_entry() {
  local key="$1"
  local entry_json="$2"

  local tmp
  tmp="$(mktemp)"
  jq --arg k "$key" --argjson e "$entry_json" \
    '.versions[$k] = $e | .latest = $k' "$releases_file" >"$tmp"
  mv "$tmp" "$releases_file"
}

verify_build() {
  local sanitized_key="$1"
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build ".#polymarket-cli_${sanitized_key}" --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for polymarket-cli_${sanitized_key}"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/polymarket" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/polymarket"
    return 1
  fi
  # default must also resolve (it points at the new .latest).
  if ! (cd "$pkg_dir" && nix build ".#default" --no-link --no-write-lock-file); then
    log_error "nix build failed for default"
    return 1
  fi
  timeout 30 "$out_path/bin/polymarket" --version >/dev/null 2>&1 || true
  log_info "Build successful!"
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat releases.json 2>/dev/null || true
  fi
}

# sanitize a JSON key into a valid nix attribute-name suffix (mirrors flake.nix)
sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
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

Appends the newest (or an explicit) polymarket-cli release to releases.json as
a new version-table entry (keyed by version) and sets .latest to it. Existing
entries are preserved so consumers can still select past versions.

Options:
  --version VERSION   Append a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --no-build          Skip build verification
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 0.1.5
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local target_version=""
  local check_only=false
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
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi

  local latest_version
  latest_version="$(get_latest_version)"
  if [ -z "$latest_version" ]; then
    log_error "Failed to fetch latest version"
    exit 2
  fi

  if [ -n "$target_version" ]; then
    latest_version="${target_version#v}"
  fi

  log_info "Current latest: $current_version"
  log_info "Target version:  $latest_version"

  if [ "$check_only" = true ]; then
    if has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: $current_version -> $latest_version"
    exit 1
  fi

  if has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ]; then
    log_info "Already up to date!"
    exit 0
  fi

  # Compute per-arch SRI hashes directly from the release tarballs.
  local system triple url sri_hash
  local hashes_json="{}"
  for system in "${!SYSTEM_TO_RUST_TRIPLE[@]}"; do
    triple="${SYSTEM_TO_RUST_TRIPLE[$system]}"
    url="${DOWNLOAD_BASE_URL}/v${latest_version}/polymarket-v${latest_version}-${triple}.tar.gz"
    log_info "Hashing $system asset: $url"
    if ! sri_hash="$(compute_asset_sri "$url")"; then
      log_error "Failed to compute hash for $system ($url)"
      exit 2
    fi
    log_info "$system hash: $sri_hash"
    hashes_json="$(jq -n --argjson h "$hashes_json" --arg s "$system" --arg v "$sri_hash" \
      '$h + {($s): $v}')"
  done

  local entry_json
  entry_json="$(jq -n \
    --arg v "$latest_version" \
    --arg rev "v${latest_version}" \
    --argjson hashes "$hashes_json" \
    '{version: $v, rev: $rev, hashes: $hashes}')"

  local backup
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  upsert_release_entry "$latest_version" "$entry_json"

  local sanitized_key
  sanitized_key="$(sanitize_key "$latest_version")"

  if [ "$no_build" != true ]; then
    if ! verify_build "$sanitized_key"; then
      log_error "Build verification failed; restoring previous releases.json"
      cp "$backup" "$releases_file"
      rm -f "$backup"
      exit 1
    fi
  fi

  rm -f "$backup"

  show_changes

  maybe_git_commit "chore(${PACKAGE_DIR_NAME}): bump to ${latest_version}" "releases.json"

  log_info "Successfully appended polymarket-cli $latest_version (latest was $current_version)"
}

main "$@"
