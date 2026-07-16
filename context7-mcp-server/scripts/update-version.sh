#!/usr/bin/env bash
# Appends the newest @upstash/context7-mcp npm release as a new entry in
# releases.json (the JSON version table the flake reads) and sets it as
# .latest. Never hand-edits the version data in flake.nix.
#
# context7-mcp is published to npm with SemVer tags, so:
#   key     = the npm version (e.g. "3.2.2")   -> kind=tag-based
#   version = the same version string
#
# Two kinds of hashes are recorded per entry:
#   - .hash                     : fetchurl tarball hash (single)
#   - .outputHashBySystem.<sys> : per-system npm-deps FOD hash (esbuild and
#                                 other optionalDependencies are platform
#                                 specific, so this differs per system).
# The per-system FOD hash is recomputed from scratch via the reliable
# fakeHash -> nix build -> parse "got:" method for the build host.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly NPM_REGISTRY_URL="https://registry.npmjs.org"
readonly NPM_PACKAGE="@upstash/context7-mcp"
readonly TARBALL_NAME="context7-mcp"
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

extract_got_hash() {
  sed -n 's~.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*~\1~p' | head -n1
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | jq -r '.hash'
}

# Current "latest" key recorded in the version table.
get_current_key() {
  jq -r '.latest // empty' "$releases_file"
}

# Does the table already have an entry for this key?
has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

get_latest_version_from_npm() {
  curl -fsSL "$NPM_REGISTRY_URL/$NPM_PACKAGE/latest" \
    | jq -r '.version'
}

# Recompute a fixed-output hash by building the target attr with FAKE_HASH
# already written into releases.json and parsing nix's "got:" line.
build_and_get_hash() {
  local attr="$1" out
  out="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link 2>&1 || true)"
  printf '%s\n' "$out" | extract_got_hash
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) @upstash/context7-mcp npm release to
releases.json (the JSON version table read by flake.nix) and sets it as
.latest. Recomputes the fetchurl tarball hash and the per-system npm-deps FOD
hash via jq — the version data in flake.nix is never touched. Existing entries
are preserved so consumers can still select past versions.

Options:
  --version VERSION   Append a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute hashes for the current latest version
  --no-build          Skip the final verification build
  --no-commit         Do not auto-commit (default: auto-commit is enabled)
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 3.2.2
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

  local current_key
  current_key="$(get_current_key)"
  if [ -z "$current_key" ]; then
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi

  local latest_version
  latest_version="$(get_latest_version_from_npm)"
  if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
    log_error "Failed to fetch latest version from npm"
    exit 2
  fi

  if [ -n "$target_version" ]; then
    latest_version="$target_version"
  fi

  log_info "Current latest: $current_key"
  log_info "Target version:  $latest_version"

  if [ "$check_only" = true ]; then
    if has_version_entry "$latest_version" && [ "$current_key" = "$latest_version" ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: $current_key -> $latest_version"
    exit 1
  fi

  if has_version_entry "$latest_version" && [ "$current_key" = "$latest_version" ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"
    exit 0
  fi

  local tarball_url
  tarball_url="$NPM_REGISTRY_URL/$NPM_PACKAGE/-/$TARBALL_NAME-$latest_version.tgz"
  log_info "Prefetching tarball hash..."
  local tarball_hash
  tarball_hash="$(prefetch_sha256_sri "$tarball_url")"
  if [ -z "$tarball_hash" ] || [ "$tarball_hash" = "null" ]; then
    log_error "Failed to prefetch tarball hash"
    exit 2
  fi
  log_info "Tarball hash: $tarball_hash"

  local prior_hashes
  prior_hashes="$(jq -c --arg k "$latest_version" \
    '.versions[$k].outputHashBySystem // {}' "$releases_file")"

  local backup
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  # Seed the entry with the tarball hash + a fake outputHash for the build
  # system so nix reveals the real one on build. Upsert + set .latest.
  local attr tmp
  attr="context7-mcp-server_$(sanitize_key "$latest_version")"
  tmp="$(mktemp)"
  jq --arg k "$latest_version" \
     --arg ver "$latest_version" \
     --arg tarball "$tarball_hash" \
     --arg fake "$FAKE_HASH" \
     --arg bsys "$BUILD_SYSTEM" \
     --argjson prior "$prior_hashes" '
       .versions[$k] = {
         version: $ver,
         rev: $ver,
         hash: $tarball,
         outputHashBySystem: ({
           "x86_64-linux": $fake,
           "aarch64-linux": $fake,
           "x86_64-darwin": $fake,
           "aarch64-darwin": $fake
         } + $prior + { ($bsys): $fake })
       }
       | .latest = $k
     ' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  # Compute the per-system npm-deps FOD hash for the build system.
  log_info "Computing outputHash (npm deps) for ${BUILD_SYSTEM}..."
  local out_hash
  out_hash="$(build_and_get_hash "$attr")"
  if [ -z "$out_hash" ]; then
    # No mismatch printed => build already succeeded (hash was correct).
    log_info "  outputHash already correct (no rehash needed)."
  else
    log_info "  outputHash: $out_hash"
    tmp="$(mktemp)"
    jq --arg k "$latest_version" --arg bsys "$BUILD_SYSTEM" --arg h "$out_hash" \
      '.versions[$k].outputHashBySystem[$bsys] = $h' \
      "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"
  fi

  if [ "$no_build" != true ]; then
    log_info "Verifying build of ${attr}..."
    local out
    if ! out="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link --print-out-paths 2>&1)"; then
      log_error "verification build failed; restoring previous releases.json"
      printf '%s\n' "$out" | tail -n 40 >&2
      cp "$backup" "$releases_file"
      rm -f "$backup"
      exit 1
    fi
    log_info "Build OK: $(printf '%s\n' "$out" | tail -n1)"
  fi

  rm -f "$backup"

  log_info "releases.json now contains:"
  jq -r '.latest as $l | "  latest=" + $l, (.versions | keys[] | "  - " + .)' "$releases_file"

  if [ "$do_commit" = true ]; then
    local scope msg
    scope="$(basename "$pkg_dir")"
    if [ "$latest_version" = "$current_key" ]; then
      msg="chore(${scope}): rehash ${latest_version}"
    else
      msg="chore(${scope}): bump to ${latest_version}"
    fi
    maybe_git_commit "$msg" "releases.json"
  fi

  log_info "Successfully appended context7-mcp $latest_version (latest was $current_key)"
}

main "$@"
