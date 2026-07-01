#!/usr/bin/env bash
# Appends the newest (or an explicit) upstream tag of NYTEMODEONLY/polyterm as a
# new entry in releases.json (the JSON version table read by flake.nix) and sets
# it as .latest. polyterm is TAGGED (github releases vN.N.N), so:
#   key     = the version (e.g. "0.10.0")
#   version = the same version
#   rev     = "v<version>" (the git tag)
#   hash    = fetchFromGitHub source hash (single; source build is arch-agnostic)
# The version data in flake.nix is never touched — only releases.json via jq.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly REPO_OWNER="NYTEMODEONLY"
readonly REPO_NAME="polyterm"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_tools() {
  for tool in curl git nix nix-prefetch-url jq; do
    command -v "$tool" >/dev/null 2>&1 || { log_error "$tool is required"; exit 2; }
  done
}

ensure_in_package_directory() {
  [ -f "$flake_file" ] || { log_error "flake.nix not found in ${pkg_dir}"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at $releases_file"; exit 2; }
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

get_latest_version() {
  git ls-remote --tags --refs "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" \
    | sed -n 's#.*refs/tags/v\([0-9][0-9.]*\)$#\1#p' \
    | sort -V \
    | tail -n1
}

prefetch_source_hash() {
  local version="$1"
  local base32
  base32="$(nix-prefetch-url --unpack "https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/tags/v${version}.tar.gz" | tail -n1)"
  nix hash to-sri --type sha256 "$base32"
}

# sanitize a JSON key into a valid nix attribute-name suffix (mirrors flake.nix)
sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
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
  if ! (cd "$pkg_dir" && nix build ".#polyterm_${sanitized_key}" --no-write-lock-file --no-link --print-out-paths); then
    log_error "nix build failed for polyterm_${sanitized_key}"
    return 1
  fi
  # default must also resolve (it points at the new .latest).
  if ! (cd "$pkg_dir" && nix build ".#default" --no-write-lock-file --no-link); then
    log_error "nix build failed for default"
    return 1
  fi
  log_info "Build successful!"
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

usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [--version VERSION] [--check] [--rehash] [--no-build] [--help]

Appends the newest (or an explicit) polyterm tag to releases.json (the JSON
version table read by flake.nix) as a new entry keyed by version and sets it as
.latest. Existing entries are preserved so consumers can still select past
versions. The version data in flake.nix is never touched.

Options:
  --version VERSION   Append a specific version (default: latest tag)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute the hash for the current latest version
  --no-build          Skip build verification
  --help              Show this help message
EOF
}

main() {
  ensure_tools
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local requested="" check=false rehash=false no_build=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        requested="$2"
        shift 2
        ;;
      --check) check=true; shift ;;
      --rehash) rehash=true; shift ;;
      --no-build) no_build=true; shift ;;
      --help) usage; exit 0 ;;
      *) log_error "Unknown option: $1"; usage; exit 2 ;;
    esac
  done

  local current target
  current="$(get_current_version)"
  if [ -z "$current" ]; then
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi
  target="${requested:-$(get_latest_version)}"
  if [ -z "$target" ]; then
    log_error "Failed to fetch latest version"
    exit 2
  fi
  log_info "Current latest: $current"
  log_info "Target version:  $target"

  if [ "$check" = true ]; then
    if has_version_entry "$target" && [ "$current" = "$target" ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: $current -> $target"
    exit 1
  fi

  if has_version_entry "$target" && [ "$current" = "$target" ] && [ "$rehash" = false ]; then
    log_info "polyterm is already at ${current}"
    exit 0
  fi

  local hash
  hash="$(prefetch_source_hash "$target")"
  [ -n "$hash" ] || { log_error "failed to prefetch source hash"; exit 1; }
  log_info "Source hash: $hash"

  local entry_json
  entry_json="$(jq -n \
    --arg v "$target" \
    --arg rev "v${target}" \
    --arg hash "$hash" \
    '{version: $v, rev: $rev, hash: $hash}')"

  local backup
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  upsert_release_entry "$target" "$entry_json"

  local sanitized_key
  sanitized_key="$(sanitize_key "$target")"

  if [ "$no_build" != true ]; then
    if ! verify_build "$sanitized_key"; then
      log_error "Build verification failed; restoring previous releases.json"
      cp "$backup" "$releases_file"
      rm -f "$backup"
      exit 1
    fi
  fi

  rm -f "$backup"

  local scope msg
  scope="$(basename "$pkg_dir")"
  if [ "$current" = "$target" ]; then
    msg="chore(${scope}): rehash ${target}"
  else
    msg="chore(${scope}): bump to ${target}"
  fi
  maybe_git_commit "$msg" "releases.json"

  log_info "Successfully appended polyterm $target (latest was $current)"
}

main "$@"
