#!/usr/bin/env bash
# Appends the newest upstream release of block/goose as a new entry in
# releases.json (the JSON version table read by flake.nix) and sets it as
# .latest. Existing entries are preserved so consumers can still select past
# versions. The version data in flake.nix is never hand-edited.
#
# goose IS release-tagged, so:
#   key     = the version (tag with the leading "v" stripped, e.g. "1.39.0")
#   rev     = the git tag (e.g. "v1.39.0") — used for both the prebuilt asset
#             URL and the fetchFromGitHub source rev.
#
# Each entry carries every hash the dual-path flake needs:
#   - prebuiltHashes.<system>        : prefetched GitHub release-binary hashes.
#   - srcHash                       : fetchFromGitHub source hash (source path).
#   - cargoOutputHashes.<dep>       : per git-dep cargoLock FOD hash.
# The source hashes are host-independent and are read from fast-failing
# fixed-output derivations, so no Rust compilation is needed to update them.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly GITHUB_API_BASE="https://api.github.com"
readonly REPO_OWNER="block"
readonly REPO_NAME="goose"
readonly PACKAGE_ATTR="goose-cli"
# Systems with upstream CLI archives (matches prebuiltBySystem in flake.nix).
declare -Ar PREBUILT_ASSET_BY_SYSTEM=(
  [x86_64-linux]="goose-x86_64-unknown-linux-gnu.tar.gz"
  [x86_64-darwin]="goose-x86_64-apple-darwin.tar.gz"
  [aarch64-darwin]="goose-aarch64-apple-darwin.tar.gz"
)
# lib.fakeHash — the sentinel nix rejects, forcing it to print the real "got:" hash.
readonly PLACEHOLDER_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

BUILD_SYSTEM=""

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
cargo_lock_file="${pkg_dir}/Cargo.lock"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  for t in nix curl jq; do
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

# Current "latest" version recorded in the version table.
get_current_version() {
  jq -r '.versions[.latest].version // empty' "$releases_file"
}

# Does the table already have an entry for this key?
has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

get_latest_release_tag() {
  local release_json
  release_json="$(curl -fsSL "$GITHUB_API_BASE/repos/$REPO_OWNER/$REPO_NAME/releases/latest")"
  printf '%s\n' "$release_json" | jq -r '.tag_name // empty'
}

tag_to_version() {
  local tag="$1"
  printf '%s\n' "${tag#v}"
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | jq -r '.hash // empty'
}

extract_got_hash() {
  sed -n 's~.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*~\1~p' | head -n1
}

# Apply a jq filter to releases.json in place.
releases_jq() {
  local filter="$1"; shift
  local tmp
  tmp="$(mktemp)"
  jq "$@" "$filter" "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"
}

# Seed/replace the entry for $key with the prebuilt hash and placeholder source
# hashes, then set it as .latest. An existing entry's cargoOutputHashes are
# preserved so already-resolved git-dep hashes are not needlessly recomputed.
seed_release_entry() {
  local key="$1" version="$2" rev="$3" prebuilt_hashes="$4"
  local existing_cargo
  existing_cargo="$(jq -c --arg k "$key" '.versions[$k].cargoOutputHashes // {}' "$releases_file")"
  releases_jq '
      .versions[$k] = {
        version: $ver,
        rev: $rev,
        prebuiltHashes: $pb,
        srcHash: $fake,
        cargoOutputHashes: $cargo
      }
      | .latest = $k
    ' \
    --arg k "$key" \
    --arg ver "$version" \
    --arg rev "$rev" \
    --argjson pb "$prebuilt_hashes" \
    --arg fake "$PLACEHOLDER_HASH" \
    --argjson cargo "$existing_cargo"
}

# Emit "<name>-<version><TAB><rev>" for every git dependency in Cargo.lock.
# The key "<name>-<version>" is exactly what cargoLock.outputHashes expects.
list_git_deps() {
  [ -f "$cargo_lock_file" ] || return 0
  python3 - "$cargo_lock_file" <<'PY'
import sys, re
txt = open(sys.argv[1]).read()
for blk in txt.split('[[package]]'):
    name = re.search(r'^name = "([^"]+)"', blk, re.M)
    ver  = re.search(r'^version = "([^"]+)"', blk, re.M)
    src  = re.search(r'^source = "git\+[^"]*#([0-9a-fA-F]+)"', blk, re.M)
    if name and ver and src:
        print(f"{name.group(1)}-{ver.group(1)}\t{src.group(1)}")
PY
}

# True if the entry's srcHash or any cargoOutputHashes value is still a placeholder.
entry_has_placeholder() {
  local key="$1"
  [ "$(jq -r --arg k "$key" --arg p "$PLACEHOLDER_HASH" '
        [ .versions[$k].srcHash, (.versions[$k].cargoOutputHashes // {} | .[]) ]
        | any(. == $p)
      ' "$releases_file")" = "true" ]
}

# True if this git-dep key currently holds a placeholder in the entry.
cargo_key_is_placeholder() {
  local key="$1" dep="$2"
  [ "$(jq -r --arg k "$key" --arg d "$dep" --arg p "$PLACEHOLDER_HASH" \
        '(.versions[$k].cargoOutputHashes[$d] // "") == $p' "$releases_file")" = "true" ]
}

# Insert a placeholder cargoOutputHashes entry for a git-dep key.
add_cargo_placeholder() {
  local key="$1" dep="$2"
  [ "$(jq -r --arg k "$key" --arg d "$dep" '.versions[$k].cargoOutputHashes | has($d)' "$releases_file")" = "true" ] && return 0
  log_info "Adding cargoOutputHashes placeholder for git dep: ${dep}"
  releases_jq '.versions[$k].cargoOutputHashes[$d] = $p' \
    --arg k "$key" --arg d "$dep" --arg p "$PLACEHOLDER_HASH"
}

# Find the cargoOutputHashes key currently set to a placeholder whose Cargo.lock
# rev starts with the given short rev (git-fetch FODs are named "<name>-<shortrev>").
placeholder_key_for_shortrev() {
  local key="$1" shortrev="$2" k r
  while IFS=$'\t' read -r k r; do
    [ -n "$k" ] || continue
    if [[ "$r" == "${shortrev}"* ]] && cargo_key_is_placeholder "$key" "$k"; then
      printf '%s\n' "$k"; return 0
    fi
  done < <(list_git_deps)
  return 1
}

set_src_hash() {
  local key="$1" hash="$2"
  releases_jq '.versions[$k].srcHash = $h' --arg k "$key" --arg h "$hash"
}

set_cargo_hash() {
  local key="$1" dep="$2" hash="$3"
  releases_jq '.versions[$k].cargoOutputHashes[$d] = $h' \
    --arg k "$key" --arg d "$dep" --arg h "$hash"
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
  fi
}

discard_repo_state_backup() {
  if [ -n "$REPO_STATE_BACKUP_DIR" ] && [ -d "$REPO_STATE_BACKUP_DIR" ]; then
    rm -rf "$REPO_STATE_BACKUP_DIR"
  fi
  REPO_STATE_BACKUP_DIR=""
}

trap 'discard_repo_state_backup' EXIT

# Resolve the source-build hashes (fetchFromGitHub src + every cargoLock git dep)
# WITHOUT compiling Rust. The entry's srcHash and any new git-dep hashes are set to
# a placeholder, then the source attr is built with --keep-going: the fixed-output
# derivations fail with their real "got:" hash (before any compile), and --keep-going
# surfaces all of them in one pass. Each got is mapped back to its releases.json
# field by the derivation's short rev. Host-independent, so this refreshes the
# aarch64 source hashes even from x86_64. Because the updater sets .latest = $key
# first, `.#goose-cli-source` reflects exactly the entry being resolved.
resolve_source_hashes() {
  local key="$1"
  log_info "Resolving source (fetchFromGitHub + cargo git deps) hashes; no Rust compile..."

  local -a build_cmd
  local pass output changed demanded drv got shortrev mapped
  for pass in $(seq 1 15); do
    entry_has_placeholder "$key" || { log_info "All source hashes resolved."; return 0; }

    build_cmd=(nix build ".#${PACKAGE_ATTR}-source" --no-link --no-write-lock-file --keep-going)
    [ -n "$BUILD_SYSTEM" ] && build_cmd+=(--system "$BUILD_SYSTEM")
    output="$(cd "$pkg_dir" && "${build_cmd[@]}" 2>&1 || true)"

    changed=0

    # (1) Satisfy eval-time demands for a missing git-dep outputHash (one per repo).
    while IFS= read -r demanded; do
      [ -n "$demanded" ] || continue
      if [ "$(jq -r --arg k "$key" --arg d "$demanded" '.versions[$k].cargoOutputHashes | has($d)' "$releases_file")" != "true" ]; then
        add_cargo_placeholder "$key" "$demanded"
        changed=1
      fi
    done < <(printf '%s\n' "$output" \
      | sed -n 's/.*vendoring the git dependency \(.*\)\. You can.*/\1/p' | sort -u)
    if [ "$changed" -eq 1 ]; then continue; fi

    # (2) Apply the "got:" hashes reported by the failing fixed-output derivations.
    while IFS=$'\t' read -r drv got; do
      [ -n "$got" ] || continue
      if [ "$drv" = source ] || [[ "$drv" == *-source ]]; then
        log_info "src sha256: $got"
        set_src_hash "$key" "$got" && changed=1
      else
        shortrev="${drv##*-}"
        if mapped="$(placeholder_key_for_shortrev "$key" "$shortrev")"; then
          log_info "git dep ${mapped}: $got"
          set_cargo_hash "$key" "$mapped" "$got" && changed=1
        else
          log_warn "Unmapped fixed-output derivation '${drv}' (got: ${got}); skipping"
        fi
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
}

verify_build() {
  local sanitized_key="$1"
  log_info "Verifying build of .#${PACKAGE_ATTR} (prebuilt where available, source otherwise)..."
  local -a build_cmd=(nix build ".#${PACKAGE_ATTR}_${sanitized_key}" --no-link --print-out-paths --no-write-lock-file)
  if [ -n "$BUILD_SYSTEM" ]; then
    build_cmd+=(--system "$BUILD_SYSTEM")
  fi
  local out_path
  if ! out_path="$(cd "$pkg_dir" && "${build_cmd[@]}")"; then
    log_error "nix build failed for ${PACKAGE_ATTR}_${sanitized_key}"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/goose" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/goose"
    return 1
  fi
  # default must also resolve (it points at the new .latest).
  if ! (cd "$pkg_dir" && nix build ".#default" --no-link --no-write-lock-file); then
    log_error "nix build failed for default"
    return 1
  fi
  timeout 30 "$out_path/bin/goose" --version >/dev/null 2>&1 || true
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

  local scope
  scope="$(basename "$pkg_dir")"

  if [ "$previous_version" != "$new_version" ]; then
    printf 'chore(%s): add %s to version table\n' "$scope" "$new_version"
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

Appends the newest (or an explicit) block/goose release to releases.json as a new
version-table entry (keyed by version) and sets .latest to it. Existing entries
are preserved so consumers can still select past versions. Recomputes the
prebuilt release-binary hash and the per-arch source hashes via jq — the version
data in flake.nix is never touched.

Options:
  --version VERSION   Append a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute prebuilt + source hashes for the current latest
  --no-build          Skip build verification
  --system SYSTEM     Optional nix build system for verification (e.g. aarch64-linux)
  --help              Show this help message

Notes:
  Linux x86_64 and both Darwin systems use upstream release binaries;
  aarch64-linux builds goose-cli from source. This updater refreshes all prebuilt
  hashes and the source hashes on any host (source hashes are read from fast-failing
  fixed-output derivations, so no Rust compilation is needed to update them).

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 1.39.0
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
      --system)
        [ $# -ge 2 ] || { log_error "--system requires an argument"; exit 2; }
        BUILD_SYSTEM="$2"
        shift 2
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

  local latest_tag
  latest_tag="$(get_latest_release_tag)"
  if [ -z "$latest_tag" ]; then
    log_error "Failed to fetch latest release from GitHub"
    exit 2
  fi

  local latest_version
  latest_version="$(tag_to_version "$latest_tag")"
  if [ -z "$latest_version" ]; then
    log_error "Failed to derive version from tag: $latest_tag"
    exit 2
  fi

  if [ -n "$target_version" ]; then
    latest_version="$target_version"
    latest_tag="v$target_version"
  fi

  log_info "Current latest:  $current_version"
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

  # Prefetch all prebuilt release binary hashes (deterministic, no build).
  local system asset prebuilt_url prebuilt_hash
  local prebuilt_hashes='{}'
  for system in "${!PREBUILT_ASSET_BY_SYSTEM[@]}"; do
    asset="${PREBUILT_ASSET_BY_SYSTEM[$system]}"
    prebuilt_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${latest_tag}/${asset}"
    log_info "Prefetching $asset ($system)..."
    prebuilt_hash="$(prefetch_sha256_sri "$prebuilt_url")"
    if [ -z "$prebuilt_hash" ]; then
      log_error "Failed to prefetch prebuilt release binary hash from $prebuilt_url"
      exit 2
    fi
    prebuilt_hashes="$(jq -n --argjson hashes "$prebuilt_hashes" --arg system "$system" --arg hash "$prebuilt_hash" \
      '$hashes + {($system): $hash}')"
  done

  backup_repo_state

  # Seed the new entry (prebuilt hash + placeholder source hashes) and set latest.
  seed_release_entry "$latest_version" "$latest_version" "$latest_tag" "$prebuilt_hashes"

  # Refresh the vendored Cargo.lock for the source (aarch64) build path.
  if ! fetch_cargo_lock "$latest_tag"; then
    log_error "Failed to refresh Cargo.lock; restoring."
    restore_repo_state; discard_repo_state_backup; exit 1
  fi

  if ! resolve_source_hashes "$latest_version"; then
    log_error "Failed to resolve source hashes; restoring."
    restore_repo_state; discard_repo_state_backup; exit 1
  fi

  local sanitized_key
  sanitized_key="$(sanitize_key "$latest_version")"

  if [ "$no_build" != true ]; then
    if ! verify_build "$sanitized_key"; then
      log_error "Build verification failed; restoring previous package state"
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

  log_info "Successfully updated $PACKAGE_ATTR from $current_version to $latest_version"
}

main "$@"
