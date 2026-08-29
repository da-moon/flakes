#!/usr/bin/env bash
# Appends the newest (or an explicit) @kitlangton/stack npm release to
# releases.json and sets it as .latest. Existing entries remain selectable.
#
# The npm tarball ships the fully bundled dist/cli.js (built by upstream's
# `prepack: bun run build`), so there are no runtime node_modules to pin:
# the ONLY hash recorded per version is the arch-agnostic tarball hash.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly NPM_REGISTRY_URL="https://registry.npmjs.org"
readonly NPM_PACKAGE="@kitlangton/stack"
readonly TARBALL_NAME="stack"
readonly PACKAGE_ATTR="stack"
readonly BIN_NAME="stack"

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

get_latest_version_from_npm() {
  curl -fsSL "${NPM_REGISTRY_URL}/${NPM_PACKAGE}/latest" | jq -r '.version // empty'
}

tarball_url() {
  local version="$1"
  printf '%s/%s/-/%s-%s.tgz\n' \
    "$NPM_REGISTRY_URL" "$NPM_PACKAGE" "$TARBALL_NAME" "$version"
}

tarball_http_code() {
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

Appends the newest (or an explicit) @kitlangton/stack npm release to
releases.json and sets it as .latest. Existing entries remain selectable.
The npm tarball is arch-agnostic (bundled dist/cli.js), so each entry records
a single tarball hash shared by all systems.

Options:
  --version VERSION   Append a specific version (default: latest npm)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute the tarball hash for the current latest
  --no-build          Skip build verification
  --no-commit         Do not auto-commit (default: auto-commit is enabled)
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
  local do_commit=true

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

  local current_version latest_version
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
    latest_version="$(get_latest_version_from_npm)"
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

  local url
  url="$(tarball_url "$latest_version")"
  if [ "$(tarball_http_code "$url")" != "200" ]; then
    log_warn "npm tarball for ${latest_version} not found at ${url}; staying on ${current_version}."
    exit 0
  fi

  log_info "Prefetching ${url}"
  local hash
  hash="$(prefetch_sha256_sri "$url")"
  if [ -z "$hash" ] || [ "$hash" = "null" ]; then
    log_error "Failed to prefetch tarball hash for ${latest_version}"
    exit 2
  fi
  log_info "  tarball hash: ${hash}"

  local entry_json
  entry_json="$(jq -n \
    --arg version "$latest_version" \
    --arg rev "$latest_version" \
    --arg hash "$hash" \
    '{version: $version, rev: $rev, hash: $hash}')"

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
  if [ "$do_commit" = true ]; then
    maybe_git_commit "$(build_commit_message "$current_version" "$latest_version")" "releases.json"
  fi
  log_info "Successfully recorded stack $latest_version (previous latest was $current_version)"
}

main "$@"
