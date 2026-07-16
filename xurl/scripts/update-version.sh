#!/usr/bin/env bash
# Upserts the newest upstream release of xdevplatform/xurl as an entry in
# releases.json (the JSON version table the flake reads) and sets it as
# .latest. Never hand-edits the version data in flake.nix.
#
# xurl ships TAGGED GitHub releases with prebuilt per-arch tarballs, so:
#   key     = the release version (e.g. "1.2.2"), tag = "v<version>"
#   version = the same version string
#   rev     = the git tag ("v<version>")
#   hashes  = per-system SRI hashes derived from the release checksums.txt
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly GITHUB_API_BASE="https://api.github.com"
readonly REPO_OWNER="xdevplatform"
readonly REPO_NAME="xurl"
declare -Ar ASSET_NAME_BY_SYSTEM=(
  [aarch64-linux]="xurl_Linux_arm64.tar.gz"
  [x86_64-linux]="xurl_Linux_x86_64.tar.gz"
  [aarch64-darwin]="xurl_Darwin_arm64.tar.gz"
  [x86_64-darwin]="xurl_Darwin_x86_64.tar.gz"
)

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  for t in nix curl jq awk git; do
    command -v "$t" >/dev/null 2>&1 || { log_error "$t is required but not installed."; exit 2; }
  done
}

ensure_in_package_directory() {
  [ -f "${pkg_dir}/flake.nix" ] || { log_error "flake.nix not found in ${pkg_dir}"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at $releases_file"; exit 2; }
}

sanitize_key() {
  # mirror flake.nix: replace . - + with _  ('-' kept last so tr treats it literally)
  printf '%s' "$1" | tr '.+-' '___'
}

get_latest_release_tag() {
  local release_json
  release_json="$(curl -fsSL "$GITHUB_API_BASE/repos/$REPO_OWNER/$REPO_NAME/releases/latest")"
  printf '%s\n' "$release_json" | jq -r '.tag_name'
}

tag_to_version() {
  local tag="$1"
  printf '%s\n' "${tag#v}"
}

get_release_checksums() {
  local tag="$1"
  local version="$2"
  curl -fsSL "https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$tag/xurl_${version}_checksums.txt"
}

get_hex_checksum_for_asset() {
  local checksums="$1"
  local asset_name="$2"
  printf '%s\n' "$checksums" | awk -v asset="$asset_name" '$2 == asset { print $1; exit }'
}

hex_sha256_to_sri() {
  local hex_hash="$1"
  nix hash to-sri --type sha256 "$hex_hash"
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Upserts the newest upstream release of xdevplatform/xurl into releases.json
(the JSON version table read by flake.nix) and sets it as .latest. Per-arch
SRI hashes are derived from the release checksums.txt via jq — the version
data in flake.nix is never touched.

Options:
  --version VERSION   Update to a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute release asset hashes for the current latest
  --no-build          Skip build verification
  --no-commit         Do not auto-commit (default: auto-commit is enabled)
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 1.1.0
EOF
}

# Parallel-safe auto-commit (flock serialises the git index across updaters).
maybe_git_commit() {
  local commit_message="$1"; shift
  local -a paths=("$@")
  command -v git >/dev/null 2>&1 || { log_warn "git not found; skipping commit"; return 0; }
  git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    log_warn "not in a git work tree; skipping commit"; return 0; }
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
    if git -C "$pkg_dir" diff --cached --quiet -- "${paths[@]}"; then exit 0; fi
    git -C "$pkg_dir" commit --only -m "$commit_message" -- "${paths[@]}"
    log_info "Committed: $commit_message"
  ) 9>"$lock_file"
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local target_version="" check_only=false rehash=false no_build=false do_commit=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        target_version="$2"; shift 2 ;;
      --check) check_only=true; shift ;;
      --rehash) rehash=true; shift ;;
      --no-build) no_build=true; shift ;;
      --no-commit) do_commit=false; shift ;;
      --help) print_usage; exit 0 ;;
      *) log_error "Unknown option: $1"; print_usage; exit 2 ;;
    esac
  done

  local cur_latest_key
  cur_latest_key="$(jq -r '.latest' "$releases_file")"
  [ -n "$cur_latest_key" ] && [ "$cur_latest_key" != "null" ] || {
    log_error "Failed to read .latest from releases.json"; exit 2; }

  local latest_tag latest_version
  if [ -n "$target_version" ]; then
    latest_version="$target_version"
    latest_tag="v$target_version"
  else
    latest_tag="$(get_latest_release_tag)"
    [ -n "$latest_tag" ] && [ "$latest_tag" != "null" ] || {
      log_error "Failed to fetch latest release from GitHub"; exit 2; }
    latest_version="$(tag_to_version "$latest_tag")"
    [ -n "$latest_version" ] || { log_error "Failed to derive version from tag: $latest_tag"; exit 2; }
  fi

  log_info "Current latest key: $cur_latest_key"
  log_info "Target version:     $latest_version"

  if [ "$check_only" = true ]; then
    if [ "$cur_latest_key" = "$latest_version" ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: $cur_latest_key -> $latest_version"
    exit 1
  fi

  if [ "$cur_latest_key" = "$latest_version" ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"
    exit 0
  fi

  local checksums
  checksums="$(get_release_checksums "$latest_tag" "$latest_version")"
  [ -n "$checksums" ] || { log_error "Failed to fetch release checksums"; exit 2; }

  local system asset hex_hash hash
  local hashes_json='{}'
  for system in "${!ASSET_NAME_BY_SYSTEM[@]}"; do
    asset="${ASSET_NAME_BY_SYSTEM[$system]}"
    hex_hash="$(get_hex_checksum_for_asset "$checksums" "$asset")"
    if [ -z "$hex_hash" ]; then
      log_error "Failed to locate checksum for $asset ($system)"
      exit 2
    fi
    hash="$(hex_sha256_to_sri "$hex_hash")"
    log_info "$system hash: $hash"
    hashes_json="$(jq -n --argjson hashes "$hashes_json" --arg system "$system" --arg hash "$hash" \
      '$hashes + {($system): $hash}')"
  done

  # jq-upsert the entry and set .latest — flake.nix is never touched.
  local tmp
  tmp="$(mktemp)"
  jq --arg k "$latest_version" \
     --arg ver "$latest_version" \
     --arg rev "$latest_tag" \
     --argjson hashes "$hashes_json" '
       .versions[$k] = {
         version: $ver,
         rev: $rev,
         hashes: $hashes
       }
       | .latest = $k
     ' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  if [ "$no_build" != true ]; then
    log_info "Verifying build..."
    local attr out
    attr="xurl_$(sanitize_key "$latest_version")"
    if ! out="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link --print-out-paths 2>&1)"; then
      log_error "verification build failed:"
      printf '%s\n' "$out" | tail -n 40 >&2
      exit 1
    fi
    log_info "Build OK: $(printf '%s\n' "$out" | tail -n1)"
  fi

  log_info "releases.json now contains:"
  jq -r '.latest as $l | "  latest=" + $l, (.versions | keys[] | "  - " + .)' "$releases_file"

  if [ "$do_commit" = true ]; then
    local scope msg
    scope="$(basename "$pkg_dir")"
    if [ "$cur_latest_key" = "$latest_version" ]; then
      msg="chore(${scope}): rehash ${latest_version}"
    else
      msg="chore(${scope}): add ${latest_version} to version table"
    fi
    maybe_git_commit "$msg" "releases.json"
  fi

  log_info "Successfully updated ${PACKAGE_DIR_NAME} to ${latest_version}"
}

main "$@"
