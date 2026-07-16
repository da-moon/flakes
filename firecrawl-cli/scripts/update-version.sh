#!/usr/bin/env bash
# Appends the newest (or an explicit) firecrawl-cli npm release to releases.json
# (the JSON version table read by flake.nix) and sets it as .latest. Firecrawl
# CLI is published to npm with version tags, so:
#   key     = the npm version (e.g. "1.19.23")
#   version = same
#   rev     = same (kept for parity with the version-table schema)
#
# Two kinds of hash are recomputed per entry:
#   - .hash              : the npm .tgz tarball hash (single, arch-independent),
#                          prefetched directly.
#   - .outputHashes.*    : per-system fixed-output npm-deps hash, recomputed from
#                          scratch via the reliable fakeHash -> nix build ->
#                          parse "got:" method (npm optionalDependencies make it
#                          system-specific, so it is keyed per system).
#
# The version data in flake.nix is never touched — everything lands in
# releases.json via jq.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly NPM_REGISTRY_URL="https://registry.npmjs.org"
readonly NPM_PACKAGE="firecrawl-cli"
readonly TARBALL_NAME="firecrawl-cli"
readonly PACKAGE_ATTR="firecrawl-cli"
readonly BIN_NAME="firecrawl"
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

# mirror flake.nix: replace . - + with _  ('-' kept last so tr treats it literally)
sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
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
  if ! latest_json="$(curl -fsSL "$NPM_REGISTRY_URL/$NPM_PACKAGE/latest")"; then
    return 1
  fi
  printf '%s\n' "$latest_json" | jq -r '.version // empty'
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | jq -r '.hash // empty' \
    | head -n1 || true
}

extract_got_hash() {
  sed -n 's~.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*~\1~p' | head -n1
}

# Recompute a fixed-output hash by building the target attr with FAKE_HASH
# already written into releases.json and parsing nix's "got:" line.
build_and_get_hash() {
  local attr="$1" out
  out="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link 2>&1 || true)"
  printf '%s\n' "$out" | extract_got_hash
}

verify_build() {
  local attr="$1"
  log_info "Verifying build of ${attr}..."
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
  timeout 30 "$out_path/bin/$BIN_NAME" --help >/dev/null 2>&1 || true
  log_info "Build successful!"
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat releases.json 2>/dev/null || true
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

Appends the newest (or an explicit) firecrawl-cli npm release to releases.json
as a new version-table entry (keyed by version) and sets .latest to it. Existing
entries are preserved so consumers can still select past versions. Recomputes the
npm tarball hash and the per-system npm-deps FOD hash via jq — the version data
in flake.nix is never touched.

Options:
  --version VERSION   Append a specific version (default: latest npm release)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute hashes for the current latest version
  --no-build          Skip build verification
  --no-commit         Do not auto-commit (default: auto-commit is enabled)
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 1.19.23
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME} (build system: ${BUILD_SYSTEM})"

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

  local current_version
  current_version="$(get_current_version)"
  if [ -z "$current_version" ]; then
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi

  local latest_version
  latest_version="$(get_latest_version_from_npm)"
  if [ -z "$latest_version" ]; then
    log_error "Failed to fetch latest version from npm"
    exit 2
  fi

  if [ -n "$target_version" ]; then
    latest_version="$target_version"
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

  local tarball_url
  tarball_url="$NPM_REGISTRY_URL/$NPM_PACKAGE/-/$TARBALL_NAME-$latest_version.tgz"
  log_info "Prefetching tarball hash..."
  local tarball_hash
  tarball_hash="$(prefetch_sha256_sri "$tarball_url")"
  if [ -z "$tarball_hash" ]; then
    log_error "Failed to prefetch tarball hash"
    exit 2
  fi
  log_info "Tarball hash: $tarball_hash"

  local sanitized_key attr
  sanitized_key="$(sanitize_key "$latest_version")"
  attr="${PACKAGE_ATTR}_${sanitized_key}"

  # Preserve any already-known outputHashes for other systems (they are not
  # built here); seed the build system's outputHash with fakeHash so nix reveals
  # the real one on build. If no prior entry exists, seed all other systems with
  # fakeHash too (they stay fake until built on that arch).
  local prior_output_hashes
  prior_output_hashes="$(jq -c --arg k "$latest_version" \
    '.versions[$k].outputHashes // {}' "$releases_file")"

  local backup
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  # Seed/upsert the entry: tarball hash real, build-system outputHash fake.
  local tmp
  tmp="$(mktemp)"
  jq --arg k "$latest_version" \
     --arg ver "$latest_version" \
     --arg rev "$latest_version" \
     --arg thash "$tarball_hash" \
     --arg bsys "$BUILD_SYSTEM" \
     --arg fake "$FAKE_HASH" \
     --argjson prior "$prior_output_hashes" '
       .versions[$k] = {
         version: $ver,
         rev: $rev,
         hash: $thash,
         outputHashes: ({
           "x86_64-linux": $fake,
           "aarch64-linux": $fake,
           "x86_64-darwin": $fake,
           "aarch64-darwin": $fake
         } + $prior + { ($bsys): $fake })
       }
       | .latest = $k
     ' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  # Recompute the build-system outputHash (fakeHash -> build -> "got:").
  log_info "Computing outputHash (fixed-output npm deps) for ${BUILD_SYSTEM}..."
  local out_hash
  out_hash="$(build_and_get_hash "$attr")"
  if [ -z "$out_hash" ]; then
    # No mismatch printed => build already succeeded (hash was already correct).
    log_info "  outputHash already correct (no rehash needed)."
  else
    log_info "  outputHash (${BUILD_SYSTEM}): $out_hash"
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

  local other_systems
  other_systems="$(jq -r --arg k "$latest_version" --arg bsys "$BUILD_SYSTEM" --arg fake "$FAKE_HASH" \
    '.versions[$k].outputHashes | to_entries[] | select(.key != $bsys and .value == $fake) | .key' \
    "$releases_file" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
  if [ -n "$other_systems" ]; then
    log_warn "Only ${BUILD_SYSTEM} outputHash was refreshed here."
    log_warn "Re-run this script on: ${other_systems} to fill those package hashes."
  fi

  show_changes

  log_info "releases.json now contains:"
  jq -r '.latest as $l | "  latest=" + $l, (.versions | keys[] | "  - " + .)' "$releases_file"

  if [ "$do_commit" = true ]; then
    local scope msg
    scope="$(basename "$pkg_dir")"
    if [ "$current_version" != "$latest_version" ]; then
      msg="chore(${scope}): bump to ${latest_version}"
    elif [ "$rehash" = true ]; then
      msg="chore(${scope}): rehash ${latest_version}"
    else
      msg="chore(${scope}): update version"
    fi
    maybe_git_commit "$msg" "releases.json"
  fi

  log_info "Successfully appended $PACKAGE_ATTR $latest_version (latest was $current_version)"
}

main "$@"
