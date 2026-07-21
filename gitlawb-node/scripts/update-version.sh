#!/usr/bin/env bash
# Appends the newest (or an explicit) Gitlawb/node GitHub release to
# releases.json (the JSON version table read by flake.nix) and sets it as
# .latest. gitlawb-node ships tagged releases (v<semver>) with per-arch
# prebuilt tarballs, so:
#   key     = the version (e.g. "0.5.1")
#   version = the same
#   rev     = the git tag ("v<version>")
#   hashes  = per-system SRI hashes derived from the per-asset .sha256
#             sidecar files published next to each tarball
# The version data in flake.nix is never hand-edited; jq upserts the entry.
#
# Assets are named gitlawb-node-<version>-<target>.tar.gz (the windows
# x86_64-pc-windows-msvc.zip asset is ignored — it maps to no nix system).
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly GITHUB_API_BASE="https://api.github.com"
readonly REPO_OWNER="Gitlawb"
readonly REPO_NAME="node"
readonly PNAME="gitlawb-node"
declare -Ar TARGET_BY_SYSTEM=(
  [aarch64-linux]="aarch64-unknown-linux-musl"
  [x86_64-linux]="x86_64-unknown-linux-musl"
  [aarch64-darwin]="aarch64-apple-darwin"
  [x86_64-darwin]="x86_64-apple-darwin"
)

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v jq >/dev/null 2>&1 || { log_error "jq is required but not installed."; exit 2; }
  command -v curl >/dev/null 2>&1 || { log_error "curl is required but not installed."; exit 2; }
  command -v awk >/dev/null 2>&1 || { log_error "awk is required but not installed."; exit 2; }
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

# Current "latest" key recorded in the version table.
get_current_version() {
  jq -r '.latest // empty' "$releases_file"
}

# Does the table already have an entry for this key?
has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

get_latest_release_tag() {
  local release_json
  release_json="$(curl -fsSL "$GITHUB_API_BASE/repos/$REPO_OWNER/$REPO_NAME/releases/latest")"
  printf '%s\n' "$release_json" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

tag_to_version() {
  local tag="$1"
  tag="${tag#v}"
  printf '%s\n' "$tag"
}

asset_name() {
  local version="$1" target="$2"
  printf 'gitlawb-node-%s-%s.tar.gz\n' "$version" "$target"
}

# First field of the per-asset .sha256 sidecar ("<hex>  <filename>").
get_asset_hex_checksum() {
  local tag="$1" asset="$2"
  curl -fsSL "https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$tag/$asset.sha256" \
    | awk '{print $1; exit}'
}

hex_sha256_to_sri() {
  local hex_hash="$1"
  nix hash to-sri --type sha256 "$hex_hash"
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

# sanitize a JSON key into a valid nix attribute-name suffix (mirrors flake.nix)
sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
}

verify_build() {
  local sanitized_key="$1"
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build ".#${PNAME}_${sanitized_key}" --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for ${PNAME}_${sanitized_key}"
    return 1
  fi
  local bin
  for bin in gitlawb-node gl git-remote-gitlawb; do
    if [ ! -x "$out_path/bin/$bin" ]; then
      log_error "Build succeeded but expected binary not found at: $out_path/bin/$bin"
      return 1
    fi
  done
  # default must also resolve (it points at the new .latest).
  if ! (cd "$pkg_dir" && nix build ".#default" --no-link --no-write-lock-file); then
    log_error "nix build failed for default"
    return 1
  fi
  timeout 30 "$out_path/bin/gitlawb-node" --version >/dev/null 2>&1 || true
  log_info "Build successful!"
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat releases.json 2>/dev/null || true
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

Appends the newest (or an explicit) Gitlawb/node release to releases.json as a
new version-table entry (keyed by version) and sets .latest to it. Existing
entries are preserved so consumers can still select past versions. The
per-arch SRI hashes are derived from the per-asset .sha256 sidecar files;
flake.nix is never touched.

Options:
  --version VERSION   Append a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Re-upsert hashes for the current version
  --no-build          Skip build verification
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 0.5.1
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

  local current_version
  current_version="$(get_current_version)"
  if [ -z "$current_version" ]; then
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi

  local latest_tag latest_version
  if [ -n "$target_version" ]; then
    latest_version="$target_version"
    latest_tag="v$target_version"
  else
    latest_tag="$(get_latest_release_tag)"
    if [ -z "$latest_tag" ]; then
      log_error "Failed to fetch latest release from GitHub"
      exit 2
    fi
    latest_version="$(tag_to_version "$latest_tag")"
    if [ -z "$latest_version" ]; then
      log_error "Failed to derive version from tag: $latest_tag"
      exit 2
    fi
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

  if has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"
    exit 0
  fi

  # Compute per-arch SRI hashes from the per-asset .sha256 sidecars.
  local system target asset checksum_hex sri_hash
  local hashes_json="{}"
  for system in "${!TARGET_BY_SYSTEM[@]}"; do
    target="${TARGET_BY_SYSTEM[$system]}"
    asset="$(asset_name "$latest_version" "$target")"
    checksum_hex="$(get_asset_hex_checksum "$latest_tag" "$asset")"
    if [ -z "$checksum_hex" ]; then
      log_error "Missing checksum sidecar for $asset ($system)"
      exit 2
    fi
    sri_hash="$(hex_sha256_to_sri "$checksum_hex")"
    if [ -z "$sri_hash" ]; then
      log_error "Failed to convert checksum to SRI for $system"
      exit 2
    fi
    log_info "$system hash: $sri_hash"
    hashes_json="$(jq -n --argjson h "$hashes_json" --arg s "$system" --arg v "$sri_hash" \
      '$h + {($s): $v}')"
  done

  local entry_json
  entry_json="$(jq -n \
    --arg v "$latest_version" \
    --arg rev "$latest_tag" \
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

  maybe_git_commit "$(build_commit_message "$current_version" "$latest_version" "$rehash")" "releases.json"

  log_info "Successfully appended $PNAME $latest_version (latest was $current_version)"
}

main "$@"
