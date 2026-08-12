#!/usr/bin/env bash
# Appends the newest (or an explicit) askii GitHub release to releases.json as a
# new version-table entry (keyed by version) and sets .latest to it. Existing
# entries are preserved so consumers can still select past versions.
#
# askii ships prebuilt x86_64 Linux and macOS binaries per release, so:
#   key     = the release version (tag with the leading "v" stripped)
#   version = same
#   hashes  = SRI hashes of the release assets (prefetched)
#               x86_64-linux   -> askii
#               x86_64-darwin  -> askii-osx
# aarch64-linux has no upstream release binary, so it builds askii from source
# (fetchFromGitHub + buildRustPackage). Each entry therefore also carries:
#   srcHash    = fetchFromGitHub source hash (aarch64 source fallback).
#   cargoHash  = buildRustPackage cargoHash for the vendored deps.
# Both source hashes are host-independent and are read from fast-failing
# fixed-output derivations of .#askii-source, so no Rust compilation is needed to
# refresh them (a future --rehash --no-build resolves both without compiling).
# The tag's Cargo.lock is fetched into askii/Cargo.lock and converted to v3
# format (inline checksums) so fetchCargoVendor can parse it; upstream tags
# may ship a legacy v1 lockfile (checksums in [metadata] only).
#
# The version data in flake.nix is never touched; only releases.json and
# Cargo.lock are edited, and both are restored on failure.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly REPO_OWNER="nytopop"
readonly REPO_NAME="askii"
readonly BIN_NAME="askii"
readonly PACKAGE_ATTR="askii"
readonly TAG_PREFIX="v"
declare -Ar ASSET_BY_SYSTEM=(
  [x86_64-linux]="askii"
  [x86_64-darwin]="askii-osx"
)
# lib.fakeHash — the sentinel nix rejects, forcing it to print the real "got:" hash.
readonly PLACEHOLDER_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
cargo_lock_file="${pkg_dir}/Cargo.lock"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v curl >/dev/null 2>&1 || { log_error "curl is required but not installed."; exit 2; }
  command -v jq >/dev/null 2>&1 || { log_error "jq is required but not installed."; exit 2; }
  command -v python3 >/dev/null 2>&1 || { log_error "python3 is required but not installed."; exit 2; }
}

ensure_in_package_directory() {
  [ -f "$flake_file" ] || { log_error "flake.nix not found at: $flake_file"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at: $releases_file"; exit 2; }
}

# sanitize a JSON key into a valid nix attribute-name suffix (mirrors flake.nix)
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

get_latest_release_tag() {
  local effective_url
  effective_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest")"
  printf '%s\n' "${effective_url##*/}"
}

tag_to_version() {
  local tag="$1"
  tag="${tag#${TAG_PREFIX}}"
  printf '%s\n' "$tag"
}

asset_url() {
  local version="$1"
  local asset="$2"
  printf 'https://github.com/%s/%s/releases/download/%s%s/%s\n' \
    "$REPO_OWNER" "$REPO_NAME" "$TAG_PREFIX" "$version" "$asset"
}

prefetch_sha256_sri() {
  nix store prefetch-file --json --hash-type sha256 "$1" \
    | jq -r '.hash'
}

# Apply a jq filter to releases.json in place.
releases_jq() {
  local filter="$1"; shift
  local tmp
  tmp="$(mktemp)"
  jq "$@" "$filter" "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"
}

# Seed/replace the entry for $key with the prefetched release-asset hashes and
# placeholder source hashes, then set it as .latest. Setting srcHash/cargoHash to
# a placeholder forces a fresh resolution from the fixed-output derivations.
seed_release_entry() {
  local key="$1" version="$2" rev="$3" hashes="$4"
  releases_jq '
      .versions[$k] = {
        version: $ver,
        rev: $rev,
        hashes: $h,
        srcHash: $fake,
        cargoHash: $fake
      }
      | .latest = $k
    ' \
    --arg k "$key" \
    --arg ver "$version" \
    --arg rev "$rev" \
    --argjson h "$hashes" \
    --arg fake "$PLACEHOLDER_HASH"
}

# True if the entry's srcHash or cargoHash is still a placeholder.
entry_has_placeholder() {
  local key="$1"
  [ "$(jq -r --arg k "$key" --arg p "$PLACEHOLDER_HASH" '
        [ .versions[$k].srcHash, .versions[$k].cargoHash ]
        | any(. == $p)
      ' "$releases_file")" = "true" ]
}

set_src_hash() {
  local key="$1" hash="$2"
  releases_jq '.versions[$k].srcHash = $h' --arg k "$key" --arg h "$hash"
}

set_cargo_hash() {
  local key="$1" hash="$2"
  releases_jq '.versions[$k].cargoHash = $h' --arg k "$key" --arg h "$hash"
}

# Convert a Cargo.lock to v3 format (inline checksums, stripped dependency
# source qualifiers) so that fetchCargoVendor's Python util can parse it.
# Handles v1, v2, and v3 input; idempotent on v3.  Uses only the Python
# standard library (no tomllib dependency) for broad compatibility.
convert_cargo_lock() {
  local file="$1"
  python3 - "$file" <<'PYEOF'
import re, sys

with open(sys.argv[1]) as f:
    content = f.read()

# Phase 1: extract checksums from [metadata] section
checksums = {}
in_meta = False
for line in content.splitlines():
    s = line.strip()
    if s == '[metadata]':
        in_meta = True
        continue
    if in_meta:
        m = re.match(r'^"checksum (.+)" = "([0-9a-f]+)"$', s)
        if m:
            checksums[m.group(1)] = m.group(2)

# Phase 2: rebuild with v3 header, inline checksums, stripped dep sources
out = [
    '# This file is automatically @generated by Cargo.',
    '# It is not intended for manual editing.',
    'version = 3',
    '',
]
cur_name = None
cur_ver = None
skip_header = True
for line in content.splitlines():
    s = line.strip()
    if skip_header:
        if s.startswith('#') or s == '' or s.startswith('version ='):
            continue
        skip_header = False
    if s == '[metadata]':
        break
    m = re.match(r'^name = "(.+)"$', s)
    if m:
        cur_name = m.group(1)
    m = re.match(r'^version = "(.+)"$', s)
    if m:
        cur_ver = m.group(1)
    m = re.match(r'^source = "(.+)"$', s)
    if m:
        src = m.group(1)
        out.append(line)
        key = '%s %s (%s)' % (cur_name, cur_ver, src)
        if key in checksums:
            out.append('checksum = "%s"' % checksums[key])
        continue
    if s.startswith('"') and ' (' in s:
        out.append(re.sub(r' \([^)]+\)', '', line))
        continue
    out.append(line)

# Strip trailing empty lines, ensure exactly one trailing newline
while out and out[-1] == '':
    out.pop()
with open(sys.argv[1], 'w') as f:
    f.write('\n'.join(out) + '\n')
PYEOF
}

fetch_cargo_lock() {
  local tag="$1"
  local url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${tag}/Cargo.lock"
  log_info "Fetching Cargo.lock from ${tag}..."
  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL "$url" -o "$tmp"; then
    log_error "Failed to fetch Cargo.lock from $url"
    rm -f "$tmp"
    return 1
  fi
  if [ ! -s "$tmp" ]; then
    log_error "Fetched Cargo.lock is empty"
    rm -f "$tmp"
    return 1
  fi
  convert_cargo_lock "$tmp"
  mv "$tmp" "$cargo_lock_file"
}

# ---- restore-on-failure ------------------------------------------------------
REPO_STATE_BACKUP_DIR=""

backup_repo_state() {
  REPO_STATE_BACKUP_DIR="$(mktemp -d -t "${PACKAGE_DIR_NAME}.backup.XXXXXX")"
  cp "$releases_file" "$REPO_STATE_BACKUP_DIR/releases.json"
  if [ -f "$cargo_lock_file" ]; then
    cp "$cargo_lock_file" "$REPO_STATE_BACKUP_DIR/Cargo.lock"
  fi
}

restore_repo_state() {
  [ -n "$REPO_STATE_BACKUP_DIR" ] && [ -d "$REPO_STATE_BACKUP_DIR" ] || return 0
  cp "$REPO_STATE_BACKUP_DIR/releases.json" "$releases_file"
  if [ -f "$REPO_STATE_BACKUP_DIR/Cargo.lock" ]; then
    cp "$REPO_STATE_BACKUP_DIR/Cargo.lock" "$cargo_lock_file"
  else
    # A newly-fetched Cargo.lock (no prior copy to restore) is removed so a
    # botched run does not leave a stale lock behind.
    rm -f "$cargo_lock_file"
  fi
}

discard_repo_state_backup() {
  if [ -n "$REPO_STATE_BACKUP_DIR" ] && [ -d "$REPO_STATE_BACKUP_DIR" ]; then
    rm -rf "$REPO_STATE_BACKUP_DIR"
  fi
  REPO_STATE_BACKUP_DIR=""
}

# Safety net: if the script exits before a clean discard (an unexpected failure
# rather than a handled one), roll the managed files back. On the success and
# handled-failure paths discard_repo_state_backup() runs first and clears the
# variable, so this is a no-op there.
restore_and_discard_on_exit() {
  if [ -n "$REPO_STATE_BACKUP_DIR" ] && [ -d "$REPO_STATE_BACKUP_DIR" ]; then
    restore_repo_state
    discard_repo_state_backup
  fi
}

trap 'restore_and_discard_on_exit' EXIT

# Resolve the source-build hashes (fetchFromGitHub src + buildRustPackage
# cargoHash) WITHOUT compiling Rust. The entry's srcHash and cargoHash start as
# placeholders; .#askii-source is built with --keep-going and the fixed-output
# derivations fail with their real "got:" hash (before any compile). The
# fetchFromGitHub derivation is named "source"; any other fixed-output derivation
# reporting a got is the cargo vendor dir. The two are independent when the cargo
# vendor reads the committed Cargo.lock (so one pass surfaces both), but the loop
# also handles the dependent ordering by resolving what it can each pass and
# stopping the instant both hashes are known. Host-independent, so this refreshes
# the aarch64 source hashes even from x86_64. Because the updater sets
# .latest = $key first, `.#askii-source` reflects exactly the entry being
# resolved.
resolve_source_hashes() {
  local key="$1"
  log_info "Resolving source hashes (srcHash + cargoHash); no Rust compile..."

  local pass output changed drv got
  for pass in $(seq 1 10); do
    entry_has_placeholder "$key" || { log_info "All source hashes resolved."; return 0; }

    local -a build_cmd=(nix build ".#${PACKAGE_ATTR}-source" --no-link --no-write-lock-file --keep-going)
    output="$(cd "$pkg_dir" && "${build_cmd[@]}" 2>&1 || true)"

    changed=0

    while IFS=$'\t' read -r drv got; do
      [ -n "$got" ] || continue
      if [ "$drv" = source ] || [[ "$drv" == *-source ]]; then
        log_info "srcHash sha256: $got"
        set_src_hash "$key" "$got" && changed=1
      else
        log_info "cargoHash sha256: $got (from $drv)"
        set_cargo_hash "$key" "$got" && changed=1
      fi
    done < <(printf '%s\n' "$output" | awk '
      /hash mismatch in fixed-output derivation/ {
        d=$0; sub(/.*derivation .\/nix\/store\/[a-z0-9]+-/,"",d); sub(/\.drv.*/,"",d); pend=d; next
      }
      /got:/ && pend!="" {
        if (match($0, /sha256-[A-Za-z0-9+\/=]+/)) { print pend"\t"substr($0,RSTART,RLENGTH); pend="" }
      }')

    [ "$changed" -eq 1 ] || break
  done

  if entry_has_placeholder "$key"; then
    log_error "Could not resolve all source hashes (placeholders remain)."
    return 1
  fi
  log_info "All source hashes resolved."
  return 0
}

verify_build() {
  local sanitized_key="$1"
  log_info "Verifying build of .#${PACKAGE_ATTR} (prebuilt on this host)..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build ".#${PACKAGE_DIR_NAME}_${sanitized_key}" --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for ${PACKAGE_DIR_NAME}_${sanitized_key}"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/$BIN_NAME"
    return 1
  fi
  # default must also resolve (it points at the new .latest).
  if ! (cd "$pkg_dir" && nix build ".#default" --no-link --no-write-lock-file); then
    log_error "nix build failed for default"
    return 1
  fi
  timeout 30 "$out_path/bin/$BIN_NAME" --version >/dev/null 2>&1 || true
  log_info "Build successful!"
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat releases.json Cargo.lock 2>/dev/null || true
  fi
}

build_commit_message() {
  local previous_version="$1"
  local new_version="$2"
  local rehash="${3:-false}"
  if [ "$previous_version" != "$new_version" ]; then
    printf 'chore(%s): bump to %s\n' "$PACKAGE_DIR_NAME" "$new_version"
  elif [ "$rehash" = true ]; then
    printf 'chore(%s): rehash %s\n' "$PACKAGE_DIR_NAME" "$new_version"
  else
    printf 'chore(%s): update version\n' "$PACKAGE_DIR_NAME"
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
  cat <<EOF
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) askii release to releases.json as a new
version-table entry (keyed by version) and sets .latest to it. Existing entries
are preserved so consumers can still select past versions. Recomputes the
release-asset hashes and the source-build hashes via jq — the version data in
flake.nix is never touched.

Options:
  --version VERSION   Append a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute release-asset + source hashes for current latest
  --no-build          Skip build verification (hash resolution still runs)
  --help              Show this help message

Notes:
  x86_64-linux and x86_64-darwin use upstream release binaries; aarch64-linux
  builds askii from source. The tag Cargo.lock is fetched into
  askii/Cargo.lock, converted to v3 format (inline checksums for
  fetchCargoVendor), and the source hashes (srcHash, cargoHash) are read from
  fast-failing fixed-output derivations of .#askii-source, so a --rehash --no-build
  refreshes every hash without compiling Rust. Both releases.json and Cargo.lock
  are restored on failure.

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 0.6.0
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local target_version="" check_only=false rehash=false no_build=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        target_version="$2"
        shift 2
        ;;
      --check) check_only=true; shift ;;
      --rehash) rehash=true; shift ;;
      --no-build) no_build=true; shift ;;
      --help) print_usage; exit 0 ;;
      *) log_error "Unknown option: $1"; print_usage; exit 2 ;;
    esac
  done

  local current_version latest_version latest_tag
  current_version="$(get_current_version)"
  if [ -z "$current_version" ]; then
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi

  if [ -n "$target_version" ]; then
    latest_version="$target_version"
    latest_tag="${TAG_PREFIX}${target_version}"
  else
    latest_tag="$(get_latest_release_tag)"
    latest_version="$(tag_to_version "$latest_tag")"
  fi
  if [ -z "$latest_version" ]; then
    log_error "Failed to fetch latest version"
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

  if has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ] && [ "$rehash" = false ]; then
    log_info "${PACKAGE_DIR_NAME} is already at ${current_version}"
    exit 0
  fi

  # Prefetch all release-asset hashes (deterministic, no build).
  local system asset hash
  local hashes_json='{}'
  for system in "${!ASSET_BY_SYSTEM[@]}"; do
    asset="${ASSET_BY_SYSTEM[$system]}"
    log_info "Prefetching $asset ($system)..."
    hash="$(prefetch_sha256_sri "$(asset_url "$latest_version" "$asset")")"
    [ -n "$hash" ] && [ "$hash" != "null" ] || {
      log_error "Failed to prefetch $asset"
      exit 2
    }
    hashes_json="$(jq -n --argjson hashes "$hashes_json" --arg system "$system" --arg hash "$hash" \
      '$hashes + {($system): $hash}')"
  done

  backup_repo_state

  # Seed the new entry (release-asset hashes + placeholder source hashes) and
  # set latest so .#askii-source reflects exactly this entry.
  seed_release_entry "$latest_version" "$latest_version" "$latest_version" "$hashes_json"

  # Refresh the vendored Cargo.lock for the source (aarch64) build path.
  if ! fetch_cargo_lock "$latest_tag"; then
    log_error "Failed to refresh Cargo.lock; restoring managed files."
    restore_repo_state; discard_repo_state_backup; exit 1
  fi

  # Resolve srcHash + cargoHash from the fixed-output derivations (no Rust
  # compile). This MUST run even under --no-build; only the final package build
  # verification below is skippable.
  if ! resolve_source_hashes "$latest_version"; then
    log_error "Failed to resolve source hashes; restoring managed files."
    restore_repo_state; discard_repo_state_backup; exit 1
  fi

  local sanitized_key
  sanitized_key="$(sanitize_key "$latest_version")"

  if [ "$no_build" != true ]; then
    if ! verify_build "$sanitized_key"; then
      log_error "Build verification failed; restoring managed files."
      restore_repo_state; discard_repo_state_backup; exit 1
    fi
  fi

  discard_repo_state_backup

  show_changes

  local -a commit_paths=("releases.json")
  if [ -f "$cargo_lock_file" ]; then
    commit_paths+=("Cargo.lock")
  fi
  maybe_git_commit "$(build_commit_message "$current_version" "$latest_version" "$rehash")" "${commit_paths[@]}"

  log_info "Successfully appended askii $latest_version (latest was $current_version)"
}

main "$@"
