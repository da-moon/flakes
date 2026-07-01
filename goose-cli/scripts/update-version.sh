#!/usr/bin/env bash
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
# System whose prebuilt release binary is pulled from GitHub (matches prebuiltBySystem in flake.nix).
readonly PREBUILT_SYSTEM="x86_64-linux"
readonly PREBUILT_ASSET="goose-x86_64-unknown-linux-gnu.tar.gz"
readonly PLACEHOLDER_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

BUILD_SYSTEM=""

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
cargo_lock_file="${pkg_dir}/Cargo.lock"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v curl >/dev/null 2>&1 || { log_error "curl is required but not installed."; exit 2; }
  command -v sed >/dev/null 2>&1 || { log_error "sed is required but not installed."; exit 2; }
}

ensure_in_package_directory() {
  if [ ! -f "$flake_file" ]; then
    log_error "flake.nix not found at: $flake_file"
    exit 2
  fi
}

get_current_version() {
  sed -n 's/^[[:space:]]*version = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
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

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' \
    | head -n1
}

update_flake_version() {
  local new_version="$1"
  sed -i.bak -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1${new_version}\\2/" "$flake_file"
}

update_prebuilt_hash() {
  local new_hash="$1"
  # Scoped to the prebuiltBySystem "<PREBUILT_SYSTEM>" = { ... }; block.
  sed -i.bak -E "/\"${PREBUILT_SYSTEM}\"[[:space:]]*=[[:space:]]*\\{/,/\\};/ s|^([[:space:]]*sha256 = \")[^\"]*(\";)|\\1${new_hash}\\2|" "$flake_file"
  grep -Fq "sha256 = \"${new_hash}\";" "$flake_file"
}

set_src_sha256_placeholder() {
  sed -i.bak -E "/src = pkgs\\.fetchFromGitHub[[:space:]]*\\{/,/\\};/ s|^([[:space:]]*sha256 = \")[^\"]*(\";)|\\1${PLACEHOLDER_HASH}\\2|" "$flake_file"
}

update_src_sha256() {
  local new_sha256="$1"
  sed -i.bak -E "/src = pkgs\\.fetchFromGitHub[[:space:]]*\\{/,/\\};/ s|^([[:space:]]*sha256 = \")[^\"]*(\";)|\\1${new_sha256}\\2|" "$flake_file"
  grep -Fq "sha256 = \"${new_sha256}\";" "$flake_file"
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

# Insert a placeholder outputHashes entry for a git-dep key that importCargoLock demands.
add_outputhash_placeholder() {
  local key="$1"
  grep -qF "\"${key}\" =" "$flake_file" && return 0
  log_info "Adding outputHashes placeholder for git dep: ${key}"
  sed -i.bak -E "/outputHashes[[:space:]]*=[[:space:]]*\{/a\\              \"${key}\" = \"${PLACEHOLDER_HASH}\";" "$flake_file"
  cleanup_backups
}

# Find the outputHashes key currently set to a placeholder whose Cargo.lock rev
# starts with the given short rev (git-fetch FODs are named "<name>-<shortrev>").
placeholder_key_for_shortrev() {
  local shortrev="$1" k r
  while IFS=$'\t' read -r k r; do
    [ -n "$k" ] || continue
    if [[ "$r" == "${shortrev}"* ]] && grep -qF "\"${k}\" = \"${PLACEHOLDER_HASH}\";" "$flake_file"; then
      printf '%s\n' "$k"; return 0
    fi
  done < <(list_git_deps)
  return 1
}

update_outputhash_key() {
  local key="$1" hash="$2"
  sed -i.bak -E "s|(\"${key}\"[[:space:]]*=[[:space:]]*\")[^\"]*(\";)|\\1${hash}\\2|" "$flake_file"
  cleanup_backups
  grep -qF "\"${key}\" = \"${hash}\";" "$flake_file"
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

cleanup_backups() {
  rm -f "${flake_file}.bak" 2>/dev/null || true
}

# ---- restore-on-failure ------------------------------------------------------
REPO_STATE_BACKUP_DIR=""

backup_repo_state() {
  REPO_STATE_BACKUP_DIR="$(mktemp -d -t "${PACKAGE_DIR_NAME}.backup.XXXXXX")"
  cp "$flake_file" "$REPO_STATE_BACKUP_DIR/flake.nix"
  if [ -f "$cargo_lock_file" ]; then
    cp "$cargo_lock_file" "$REPO_STATE_BACKUP_DIR/Cargo.lock"
  fi
}

restore_repo_state() {
  [ -n "$REPO_STATE_BACKUP_DIR" ] && [ -d "$REPO_STATE_BACKUP_DIR" ] || return 0
  cp "$REPO_STATE_BACKUP_DIR/flake.nix" "$flake_file"
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

trap 'cleanup_backups; discard_repo_state_backup' EXIT

# Resolve the source-build hashes (fetchFromGitHub src + every cargoLock git dep)
# WITHOUT compiling Rust. We set the src and any new git-dep hashes to a placeholder,
# then build the source attr with --keep-going: the fixed-output derivations fail with
# their real "got:" hash (before any compile), and --keep-going surfaces all of them in
# one pass. Each got is mapped back to its flake field by the derivation's short rev.
# Host-independent, so this refreshes the aarch64 source hashes even from x86_64.
resolve_source_hashes() {
  log_info "Resolving source (fetchFromGitHub + cargo git deps) hashes; no Rust compile..."
  set_src_sha256_placeholder
  cleanup_backups

  local -a build_cmd
  local pass output changed demanded drv got shortrev mapped
  for pass in $(seq 1 15); do
    grep -qF "$PLACEHOLDER_HASH" "$flake_file" || { log_info "All source hashes resolved."; return 0; }

    build_cmd=(nix build ".#${PACKAGE_ATTR}-source" --no-link --no-write-lock-file --keep-going)
    [ -n "$BUILD_SYSTEM" ] && build_cmd+=(--system "$BUILD_SYSTEM")
    output="$(cd "$pkg_dir" && "${build_cmd[@]}" 2>&1 || true)"

    changed=0

    # (1) Satisfy eval-time demands for a missing git-dep outputHash (one per repo).
    while IFS= read -r demanded; do
      [ -n "$demanded" ] || continue
      if ! grep -qF "\"${demanded}\" =" "$flake_file"; then
        add_outputhash_placeholder "$demanded"
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
        update_src_sha256 "$got" && changed=1
      else
        shortrev="${drv##*-}"
        if mapped="$(placeholder_key_for_shortrev "$shortrev")"; then
          log_info "git dep ${mapped}: $got"
          update_outputhash_key "$mapped" "$got" && changed=1
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

  if grep -qF "$PLACEHOLDER_HASH" "$flake_file"; then
    log_error "Could not resolve all source hashes (placeholders remain)."
    return 1
  fi
}

verify_build() {
  log_info "Verifying build of .#${PACKAGE_ATTR} (prebuilt on ${PREBUILT_SYSTEM}, source elsewhere)..."
  local -a build_cmd=(nix build ".#${PACKAGE_ATTR}" --no-link --print-out-paths --no-write-lock-file)
  if [ -n "$BUILD_SYSTEM" ]; then
    build_cmd+=(--system "$BUILD_SYSTEM")
  fi
  local out_path
  if ! out_path="$(cd "$pkg_dir" && "${build_cmd[@]}")"; then
    log_error "nix build failed for ${PACKAGE_ATTR}"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/goose" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/goose"
    return 1
  fi
  timeout 30 "$out_path/bin/goose" --version >/dev/null 2>&1 || true
  log_info "Build successful!"
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat flake.nix Cargo.lock 2>/dev/null || true
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

Options:
  --version VERSION   Update to a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute prebuilt + source hashes for the current version
  --no-build          Skip build verification
  --system SYSTEM     Optional nix build system for verification (e.g. aarch64-linux)
  --help              Show this help message

Notes:
  On x86_64-linux the package is the prebuilt GitHub release binary; every other
  system builds goose-cli from source. This updater refreshes BOTH the prebuilt
  hash and the source hashes on any host (source hashes are read from fast-failing
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
    log_error "Failed to detect current version from flake.nix"
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

  log_info "Current version: $current_version"
  log_info "Target version:  $latest_version"

  if [ "$check_only" = true ]; then
    if [ "$current_version" = "$latest_version" ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: $current_version -> $latest_version"
    exit 1
  fi

  if [ "$current_version" = "$latest_version" ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"
    exit 0
  fi

  # Prefetch the prebuilt release binary hash (deterministic, no build).
  local prebuilt_url prebuilt_hash
  prebuilt_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${latest_tag}/${PREBUILT_ASSET}"
  log_info "Prefetching prebuilt release binary hash..."
  prebuilt_hash="$(prefetch_sha256_sri "$prebuilt_url")"
  if [ -z "$prebuilt_hash" ]; then
    log_error "Failed to prefetch prebuilt release binary hash from $prebuilt_url"
    exit 2
  fi
  log_info "prebuilt hash: $prebuilt_hash"

  backup_repo_state

  cleanup_backups
  update_flake_version "$latest_version"
  if ! update_prebuilt_hash "$prebuilt_hash"; then
    log_error "Failed to update prebuilt hash; restoring."
    restore_repo_state; discard_repo_state_backup; exit 1
  fi
  cleanup_backups

  # Refresh the vendored Cargo.lock for the source (aarch64) build path.
  if ! fetch_cargo_lock "$latest_tag"; then
    log_error "Failed to refresh Cargo.lock; restoring."
    restore_repo_state; discard_repo_state_backup; exit 1
  fi

  if ! resolve_source_hashes; then
    log_error "Failed to resolve source hashes; restoring."
    restore_repo_state; discard_repo_state_backup; exit 1
  fi

  if [ "$no_build" != true ]; then
    if ! verify_build; then
      log_error "Build verification failed; restoring previous package state"
      restore_repo_state; discard_repo_state_backup; exit 1
    fi
  fi

  discard_repo_state_backup

  show_changes

  local -a commit_paths=("flake.nix")
  if [ -f "$cargo_lock_file" ]; then
    commit_paths+=("Cargo.lock")
  fi
  maybe_git_commit "$(build_commit_message "$current_version" "$latest_version" "$rehash")" "${commit_paths[@]}"

  log_info "Successfully updated $PACKAGE_ATTR from $current_version to $latest_version"
}

main "$@"
