#!/usr/bin/env bash
# Appends the newest (or an explicit) danielmiessler/Fabric GitHub release to
# releases.json and sets it as .latest. Existing entries remain selectable.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly GITHUB_API_BASE="https://api.github.com"
readonly REPO_OWNER="danielmiessler"
readonly REPO_NAME="Fabric"
readonly PACKAGE_ATTR="fabric"
readonly BIN_NAME="fabric"

declare -Ar ASSET_BY_SYSTEM=(
  [x86_64-linux]="fabric_Linux_x86_64.tar.gz"
  [aarch64-linux]="fabric_Linux_arm64.tar.gz"
  [x86_64-darwin]="fabric_Darwin_x86_64.tar.gz"
  [aarch64-darwin]="fabric_Darwin_arm64.tar.gz"
)

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"
readonly PACKAGE_DIR_NAME

ensure_required_tools_installed() {
  for tool in nix curl jq; do
    command -v "$tool" >/dev/null 2>&1 || {
      log_error "$tool is required but not installed."
      exit 2
    }
  done
}

ensure_in_package_directory() {
  [ -f "$flake_file" ] || { log_error "flake.nix not found at: $flake_file"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at: $releases_file"; exit 2; }
}

sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
}

get_current_version() {
  jq -r '.latest // empty' "$releases_file"
}

has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg key "$key" '.versions | has($key)' "$releases_file")" = "true" ]
}

get_latest_release_tag() {
  curl -fsSL "${GITHUB_API_BASE}/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" \
    | jq -r '.tag_name // empty'
}

tag_to_version() {
  printf '%s\n' "${1#v}"
}

asset_url() {
  local version="$1"
  local asset="$2"
  printf 'https://github.com/%s/%s/releases/download/v%s/%s\n' \
    "$REPO_OWNER" "$REPO_NAME" "$version" "$asset"
}

asset_http_code() {
  curl -sIL -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || printf '000'
}

prefetch_sha256_sri() {
  nix store prefetch-file --json --hash-type sha256 "$1" | jq -r '.hash // empty'
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
  local sanitized_key="$1"
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build ".#${PACKAGE_ATTR}_${sanitized_key}" --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for ${PACKAGE_ATTR}_${sanitized_key}"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
    log_error "Expected binary not found at: $out_path/bin/$BIN_NAME"
    return 1
  fi
  if ! (cd "$pkg_dir" && nix build ".#default" --no-link --no-write-lock-file); then
    log_error "nix build failed for default"
    return 1
  fi
  "$out_path/bin/$BIN_NAME" --version >/dev/null
  log_info "Build successful!"
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat -- releases.json 2>/dev/null || true
  fi
}

build_commit_message() {
  local previous_version="$1"
  local new_version="$2"
  if [ "$previous_version" != "$new_version" ]; then
    printf 'chore(%s): bump to %s\n' "$PACKAGE_DIR_NAME" "$new_version"
  else
    printf 'chore(%s): rehash %s\n' "$PACKAGE_DIR_NAME" "$new_version"
  fi
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

Appends the newest (or an explicit) Fabric release to releases.json and sets it
as .latest. Existing entries remain selectable.

Options:
  --version VERSION   Append a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute release asset hashes for the current latest
  --no-build          Skip build verification
  --help              Show this help message
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

  local current_version latest_version latest_tag
  current_version="$(get_current_version)"
  if [ -z "$current_version" ]; then
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi

  if [ -n "$target_version" ]; then
    latest_version="${target_version#v}"
  elif [ "$rehash" = true ]; then
    latest_version="$current_version"
  else
    latest_tag="$(get_latest_release_tag)"
    latest_version="$(tag_to_version "$latest_tag")"
  fi
  if [ -z "$latest_version" ]; then
    log_error "Failed to determine target version"
    exit 2
  fi

  log_info "Current latest: $current_version"
  log_info "Target version:  $latest_version"

  if [ "$check_only" = true ]; then
    if has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ]; then
      log_info "${PACKAGE_DIR_NAME} is up to date (${current_version})"
      exit 0
    fi
    log_warn "Update available: ${current_version} -> ${latest_version}"
    exit 1
  fi

  if [ "$rehash" = false ] && has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ]; then
    log_info "${PACKAGE_DIR_NAME} is already at ${current_version}"
    exit 0
  fi

  if [ "$rehash" = false ]; then
    local system asset
    for system in "${!ASSET_BY_SYSTEM[@]}"; do
      asset="${ASSET_BY_SYSTEM[$system]}"
      if [ "$(asset_http_code "$(asset_url "$latest_version" "$asset")")" != "200" ]; then
        log_warn "Release v${latest_version} is missing asset ${asset}; staying on ${current_version}."
        exit 0
      fi
    done
  fi

  local system asset hash
  local hashes_json="{}"
  for system in "${!ASSET_BY_SYSTEM[@]}"; do
    asset="${ASSET_BY_SYSTEM[$system]}"
    log_info "Prefetching ${asset}"
    hash="$(prefetch_sha256_sri "$(asset_url "$latest_version" "$asset")")"
    if [ -z "$hash" ] || [ "$hash" = "null" ]; then
      log_error "Failed to prefetch ${asset} for ${system}"
      exit 2
    fi
    log_info "  ${system} hash: ${hash}"
    hashes_json="$(jq -n --argjson hashes "$hashes_json" --arg system "$system" --arg hash "$hash" \
      '$hashes + {($system): $hash}')"
  done

  local entry_json
  entry_json="$(jq -n \
    --arg version "$latest_version" \
    --arg rev "$latest_version" \
    --argjson hashes "$hashes_json" \
    '{version: $version, rev: $rev, hashes: $hashes}')"

  local backup
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"
  upsert_release_entry "$latest_version" "$entry_json"

  local sanitized_key
  sanitized_key="$(sanitize_key "$latest_version")"
  if [ "$no_build" = false ] && ! verify_build "$sanitized_key"; then
    log_error "Build verification failed; restoring previous releases.json"
    cp "$backup" "$releases_file"
    rm -f "$backup"
    exit 1
  fi
  rm -f "$backup"

  show_changes
  maybe_git_commit "$(build_commit_message "$current_version" "$latest_version")" "releases.json"
  log_info "Successfully recorded Fabric $latest_version (previous latest was $current_version)"
}

main "$@"
