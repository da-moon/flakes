#!/usr/bin/env bash
# Appends the newest (or an explicit) gitnexus npm release to releases.json (the
# JSON version table read by flake.nix) and sets it as .latest. Never hand-edits
# the version data in flake.nix.
#
# gitnexus is published on npm (TAGGED), so:
#   key     = the npm version (e.g. "1.6.8")
#   version = the same version string
#
# Two kinds of fixed-output hashes are recomputed:
#   - .hash          : the npm tarball (fetchurl) hash, via nix store prefetch-file
#   - .outputHashes.*: per-system pnpm FOD hash, via the fakeHash -> build ->
#                      parse "got:" method (only the build system is refreshed
#                      here; other arches are preserved or seeded with fakeHash).
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly NPM_REGISTRY_URL="https://registry.npmjs.org"
readonly NPM_PACKAGE="gitnexus"
readonly TARBALL_NAME="gitnexus"
readonly PNAME="gitnexus"
readonly BIN_NAME="gitnexus"
# lib.fakeHash — the sentinel nix rejects, forcing it to print the real "got:" hash.
readonly FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"
# Which system's outputHash to (re)compute — the host we build on.
BUILD_SYSTEM="$(nix eval --raw --impure --expr 'builtins.currentSystem' 2>/dev/null || echo x86_64-linux)"

ensure_required_tools_installed() {
  for t in nix curl jq; do
    command -v "$t" >/dev/null 2>&1 || { log_error "$t is required but not installed."; exit 2; }
  done
}

ensure_in_package_directory() {
  [ -f "$flake_file" ] || { log_error "flake.nix not found at: $flake_file"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at: $releases_file"; exit 2; }
}

# mirror flake.nix: replace . - + with _
sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
}

extract_got_hash() {
  sed -n 's~.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*~\1~p' | head -n1
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

get_latest_version_from_npm() {
  local latest_json
  latest_json="$(curl -fsSL "$NPM_REGISTRY_URL/$NPM_PACKAGE/latest")"
  printf '%s\n' "$latest_json" | jq -r '.version // empty'
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | jq -r '.hash // empty'
}

# Recompute a fixed-output hash by building the target attr (with FAKE_HASH
# already written into releases.json) and parsing nix's "got:" line.
build_and_get_hash() {
  local attr="$1" out
  out="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link 2>&1 || true)"
  printf '%s\n' "$out" | extract_got_hash
}

verify_build() {
  local attr="$1"
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link --print-out-paths)"; then
    log_error "nix build failed for ${attr}"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/$BIN_NAME"
    return 1
  fi
  # default must also resolve (it points at the new .latest).
  if ! (cd "$pkg_dir" && nix build ".#default" --no-write-lock-file --no-link); then
    log_error "nix build failed for default"
    return 1
  fi
  timeout 30 "$out_path/bin/$BIN_NAME" --version >/dev/null 2>&1 || true
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
  local scope
  scope="$(basename "$pkg_dir")"
  if [ "$previous_version" != "$new_version" ]; then
    printf 'chore(%s): bump to %s\n' "$scope" "$new_version"
  else
    printf 'chore(%s): rehash %s\n' "$scope" "$new_version"
  fi
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

Appends the newest (or an explicit) gitnexus npm release to releases.json (the
JSON version table read by flake.nix) and sets it as .latest. Recomputes the npm
tarball hash and the per-system pnpm FOD outputHash via jq — the version data in
flake.nix is never touched. Existing entries are preserved so consumers can still
select past versions.

Options:
  --version VERSION   Append a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute hashes for the current latest version
  --no-build          Skip build verification
  --no-commit         Do not auto-commit (default: auto-commit is enabled)
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 1.6.8
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME} (build system: ${BUILD_SYSTEM})"

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

  local current_version
  current_version="$(get_current_version)"
  if [ -z "$current_version" ]; then
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi

  local latest_version
  if [ -n "$target_version" ]; then
    latest_version="$target_version"
  elif [ "$rehash" = true ]; then
    latest_version="$current_version"
  else
    latest_version="$(get_latest_version_from_npm)"
    if [ -z "$latest_version" ]; then
      log_error "Failed to fetch latest version from npm"
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

  local tarball_url tarball_hash
  tarball_url="$NPM_REGISTRY_URL/$NPM_PACKAGE/-/$TARBALL_NAME-$latest_version.tgz"
  log_info "Prefetching tarball hash..."
  tarball_hash="$(prefetch_sha256_sri "$tarball_url")"
  if [ -z "$tarball_hash" ]; then
    log_error "Failed to prefetch tarball hash"
    exit 2
  fi
  log_info "Tarball hash: $tarball_hash"

  # Preserve an existing non-build-system outputHash if present, else seed
  # fakeHash there (that arch is not built here; its hash stays fake until built
  # on that arch).
  local aarch_hash
  aarch_hash="$(jq -r --arg k "$latest_version" \
    '.versions[$k].outputHashes["aarch64-linux"] // empty' "$releases_file")"
  [ -n "$aarch_hash" ] || aarch_hash="$FAKE_HASH"

  # Seed the entry with the real tarball hash and a fake outputHash for the build
  # system so nix reveals the real one on build.
  local attr tmp
  attr="${PNAME}_$(sanitize_key "$latest_version")"
  local backup
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  tmp="$(mktemp)"
  jq --arg k "$latest_version" \
     --arg ver "$latest_version" \
     --arg rev "$latest_version" \
     --arg hash "$tarball_hash" \
     --arg fake "$FAKE_HASH" \
     --arg bsys "$BUILD_SYSTEM" \
     --arg aarch "$aarch_hash" '
       .versions[$k] = {
         version: $ver,
         rev: $rev,
         hash: $hash,
         outputHashes: ({ "aarch64-linux": $aarch } + { ($bsys): $fake })
       }
       | .latest = $k
     ' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  # Recompute the pnpm FOD outputHash for the build system.
  log_info "Computing outputHash (pnpm FOD) for ${BUILD_SYSTEM}..."
  local out_hash
  out_hash="$(build_and_get_hash "$attr")"
  if [ -z "$out_hash" ]; then
    log_info "  outputHash already correct (no rehash needed)."
  else
    log_info "  outputHash: $out_hash"
    tmp="$(mktemp)"
    jq --arg k "$latest_version" --arg bsys "$BUILD_SYSTEM" --arg h "$out_hash" \
      '.versions[$k].outputHashes[$bsys] = $h' \
      "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"
  fi

  if [ "$no_build" != true ]; then
    if ! verify_build "$attr"; then
      log_error "Build verification failed; restoring previous releases.json"
      cp "$backup" "$releases_file"
      rm -f "$backup"
      exit 1
    fi
  fi

  rm -f "$backup"

  if [ "$aarch_hash" = "$FAKE_HASH" ]; then
    log_warn "aarch64-linux outputHash is a placeholder; re-run this script on aarch64-linux to fill it."
  fi

  log_info "releases.json now contains:"
  jq -r '.latest as $l | "  latest=" + $l, (.versions | keys[] | "  - " + .)' "$releases_file"

  show_changes

  if [ "$do_commit" = true ]; then
    maybe_git_commit "$(build_commit_message "$current_version" "$latest_version")" "releases.json"
  fi

  log_info "Successfully appended ${PNAME} $latest_version (latest was $current_version)"
}

main "$@"
