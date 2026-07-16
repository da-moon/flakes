#!/usr/bin/env bash
# Appends the newest (or an explicit) firecrawl-mcp npm release to releases.json
# (the JSON version table read by flake.nix) and sets it as .latest. The version
# data in flake.nix is never touched — entries are jq-upserted here.
#
# firecrawl-mcp is published to the npm registry, so:
#   key     = the npm version (tag-based)
#   version = the same npm version
#
# Two kinds of hash are stored per entry:
#   - .hash                    : fetchurl hash of the npm .tgz tarball (single)
#   - .outputHashBySystem.*    : per-system fixed-output "yarn install" FOD hash
#                                (npm optionalDependencies can be platform-
#                                 specific, so this is NOT portable across archs).
# Only the current build system's FOD hash is recomputed here; other systems keep
# their existing hash (fakeHash until built natively on that arch).
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly NPM_REGISTRY_URL="https://registry.npmjs.org"
readonly NPM_PACKAGE="firecrawl-mcp"
readonly TARBALL_NAME="firecrawl-mcp"
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
  for t in nix curl jq git; do
    command -v "$t" >/dev/null 2>&1 || { log_error "$t is required but not installed."; exit 2; }
  done
}

ensure_in_package_directory() {
  [ -f "$flake_file" ] || { log_error "flake.nix not found at: $flake_file"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at: $releases_file"; exit 2; }
}

# sanitize a JSON key into a valid nix attribute-name suffix (mirrors flake.nix)
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
  printf '%s\n' "$latest_json" \
    | grep -o '"version":[[:space:]]*"[^"]*"' \
    | head -n1 \
    | sed -E 's/^"version":[[:space:]]*"([^"]*)"$/\1/'
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' \
    | head -n1
}

# Recompute a fixed-output hash by building the target attr with FAKE_HASH
# already written into releases.json and parsing nix's "got:" line.
build_and_get_hash() {
  local attr="$1" out
  out="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link 2>&1 || true)"
  printf '%s\n' "$out" | extract_got_hash
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
  local attr="$1"
  log_info "Verifying build of ${attr}..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link --print-out-paths)"; then
    log_error "nix build failed for ${attr}"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/firecrawl-mcp" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/firecrawl-mcp"
    return 1
  fi
  # default must also resolve (it points at the new .latest).
  if ! (cd "$pkg_dir" && nix build ".#default" --no-write-lock-file --no-link); then
    log_error "nix build failed for default"
    return 1
  fi
  timeout 30 "$out_path/bin/firecrawl-mcp" --help >/dev/null 2>&1 || true
  log_info "Build successful!"
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat releases.json 2>/dev/null || true
  fi
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

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) firecrawl-mcp npm release to releases.json
(the JSON version table read by flake.nix) and sets it as .latest. Recomputes the
tarball hash and the current-system outputHash (FOD) via jq — the version data in
flake.nix is never touched. Existing entries are preserved so consumers can still
select past versions.

Options:
  --version VERSION   Append a specific version (default: latest npm)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute hashes for the current latest entry
  --no-build          Skip build verification
  --no-commit         Do not auto-commit (default: auto-commit is enabled)
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 3.22.2
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

  local tarball_url tarball_hash
  tarball_url="$NPM_REGISTRY_URL/$NPM_PACKAGE/-/$TARBALL_NAME-$latest_version.tgz"
  log_info "Prefetching tarball hash..."
  tarball_hash="$(prefetch_sha256_sri "$tarball_url")"
  if [ -z "$tarball_hash" ]; then
    log_error "Failed to prefetch tarball hash"
    exit 2
  fi
  log_info "Tarball hash: $tarball_hash"

  # Preserve any existing per-system outputHash (from an entry with this key),
  # else seed fakeHash for every non-build system so it is filled in natively
  # when the script is later run on that arch.
  local existing_ohbs
  existing_ohbs="$(jq -c --arg k "$latest_version" \
    '.versions[$k].outputHashBySystem // {}' "$releases_file")"

  local sanitized_key attr tmp
  sanitized_key="$(sanitize_key "$latest_version")"
  attr="firecrawl-mcp-server_${sanitized_key}"

  # Seed the entry: keep existing hashes, force the build system's to fakeHash so
  # nix reveals the real one, and ensure every supported target is represented.
  tmp="$(mktemp)"
  jq --arg k "$latest_version" \
     --arg tar "$tarball_hash" \
     --arg fake "$FAKE_HASH" \
     --arg bsys "$BUILD_SYSTEM" \
     --argjson ohbs "$existing_ohbs" '
       .versions[$k] = {
         version: $k,
         rev: $k,
         hash: $tar,
         outputHashBySystem: (
           {
             "x86_64-linux": $fake,
             "aarch64-linux": $fake,
             "x86_64-darwin": $fake,
             "aarch64-darwin": $fake
           }
           + $ohbs
           + { ($bsys): $fake }
         )
       }
       | .latest = $k
     ' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  local backup
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  # Compute the current build system's outputHash (FOD) via fakeHash -> got:.
  log_info "Computing outputHash (fixed-output npm deps) for ${BUILD_SYSTEM}..."
  local got_hash
  got_hash="$(build_and_get_hash "$attr")"
  if [ -z "$got_hash" ]; then
    log_error "Failed to parse outputHash from nix build output"
    cp "$backup" "$releases_file"; rm -f "$backup"
    exit 1
  fi
  log_info "outputHash (${BUILD_SYSTEM}): $got_hash"
  tmp="$(mktemp)"
  jq --arg k "$latest_version" --arg h "$got_hash" '
    .versions[$k].outputHashBySystem = {
      "x86_64-linux": $h,
      "aarch64-linux": $h,
      "x86_64-darwin": $h,
      "aarch64-darwin": $h
    }
  ' \
    "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  if [ "$no_build" != true ]; then
    if ! verify_build "$attr"; then
      log_error "Build verification failed; restoring previous releases.json"
      cp "$backup" "$releases_file"; rm -f "$backup"
      exit 1
    fi
  fi
  rm -f "$backup"

  log_info "releases.json now contains:"
  jq -r '.latest as $l | "  latest=" + $l, (.versions | keys[] | "  - " + .)' "$releases_file"

  show_changes

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

  log_info "Successfully appended firecrawl-mcp $latest_version (latest was $current_version)"
}

main "$@"
