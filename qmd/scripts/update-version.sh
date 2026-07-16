#!/usr/bin/env bash
# Appends the newest upstream release of tobi/qmd as a new entry in
# releases.json (the JSON version table the flake reads). Never hand-edits the
# version data in flake.nix.
#
# qmd ships tagged GitHub releases, so:
#   key     = the release version (e.g. "2.5.3")
#   version = the same string
#
# Hashes recomputed from scratch:
#   - .hash            : fetchurl source-tarball hash (arch-agnostic, single)
#   - .outputHashes.*  : per-system bun/npm fixed-output-derivation hash,
#                        computed via the reliable fakeHash -> nix build ->
#                        parse "got:" method (only for the build system; other
#                        supported systems keep their recorded/fake hashes).
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly GITHUB_API_BASE="https://api.github.com"
readonly REPO_OWNER="tobi"
readonly REPO_NAME="qmd"
readonly PACKAGE_ATTR="qmd"
readonly BIN_NAME="qmd"
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

sanitize_key() {
  # mirror flake.nix: replace . - + with _  ('-' kept last so tr treats it literally)
  printf '%s' "$1" | tr '.+-' '___'
}

extract_got_hash() {
  sed -n 's~.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*~\1~p' | head -n1
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

get_latest_release_tag() {
  local release_json
  release_json="$(curl -fsSL "$GITHUB_API_BASE/repos/$REPO_OWNER/$REPO_NAME/releases/latest")"
  printf '%s\n' "$release_json" | jq -r '.tag_name // empty'
}

get_source_url() {
  local version="$1"
  printf 'https://github.com/%s/%s/archive/refs/tags/v%s.tar.gz' "$REPO_OWNER" "$REPO_NAME" "$version"
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" | jq -r '.hash'
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

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) tobi/qmd release to releases.json (the JSON
version table read by flake.nix) and sets it as .latest. Recomputes the fetchurl
source hash and the build-system bun/npm FOD hash via jq — the version data in
flake.nix is never touched.

Options:
  --version VERSION   Append a specific version (default: latest release tag)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute source + outputHash for the current latest entry
  --no-build          Skip build verification (and outputHash recompute)
  --no-commit         Do not auto-commit (default: auto-commit is enabled)
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 2.5.3
EOF
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

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME} (build system: ${BUILD_SYSTEM})"

  local target_version="" check_only=false rehash=false no_build=false do_commit=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        target_version="${2#v}"; shift 2 ;;
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
    log_error "Failed to detect current latest from releases.json"
    exit 2
  fi

  local new_version
  if [ -n "$target_version" ]; then
    new_version="$target_version"
  else
    local latest_tag
    latest_tag="$(get_latest_release_tag)"
    [ -n "$latest_tag" ] || { log_error "Failed to fetch latest release from GitHub"; exit 2; }
    new_version="${latest_tag#v}"
  fi

  local new_key="$new_version"

  log_info "Current latest key: ${current_key}"
  log_info "Target version:     ${new_version}"

  if [ "$check_only" = true ]; then
    if has_version_entry "$new_key" && [ "$current_key" = "$new_key" ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: ${current_key} -> ${new_key}"
    exit 1
  fi

  if has_version_entry "$new_key" && [ "$current_key" = "$new_key" ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"
    exit 0
  fi

  # 1) source tarball hash (arch-agnostic single hash)
  local source_url source_hash
  source_url="$(get_source_url "$new_version")"
  log_info "Prefetching source hash from: $source_url"
  source_hash="$(prefetch_sha256_sri "$source_url")"
  [ -n "$source_hash" ] || { log_error "Failed to prefetch source hash"; exit 2; }
  log_info "  source hash: $source_hash"

  local prior_hashes
  prior_hashes="$(jq -c --arg k "$new_key" \
    '.versions[$k].outputHashes // {}' "$releases_file")"

  # 2) upsert the entry with fake build-system hash + preserved other-arch hash.
  local attr tmp
  attr="${PACKAGE_ATTR}_$(sanitize_key "$new_key")"
  tmp="$(mktemp)"
  jq --arg k "$new_key" \
     --arg ver "$new_version" \
     --arg rev "$new_version" \
     --arg src "$source_hash" \
     --arg fake "$FAKE_HASH" \
     --arg bsys "$BUILD_SYSTEM" \
     --argjson prior "$prior_hashes" '
       .versions[$k] = {
         version: $ver,
         rev: $rev,
         hash: $src,
         outputHashes: ({
           "x86_64-linux": $fake,
           "aarch64-linux": $fake,
           "x86_64-darwin": $fake,
           "aarch64-darwin": $fake
         } + $prior + { ($bsys): $fake })
       }
       | .latest = $k
     ' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  if [ "$no_build" = true ]; then
    log_warn "Skipping outputHash recompute and build verification (--no-build)."
    if [ "$do_commit" = true ]; then
      maybe_git_commit "chore(${PACKAGE_DIR_NAME}): bump to ${new_version}" "releases.json"
    fi
    exit 0
  fi

  # 3) outputHash FOD hash for the build system
  log_info "Computing outputHash for ${BUILD_SYSTEM}..."
  local out_hash
  out_hash="$(build_and_get_hash "$attr")"
  if [ -z "$out_hash" ]; then
    log_info "  outputHash already correct (no rehash needed)."
  else
    log_info "  outputHash: $out_hash"
    tmp="$(mktemp)"
    jq --arg k "$new_key" --arg bsys "$BUILD_SYSTEM" --arg h "$out_hash" \
      '.versions[$k].outputHashes[$bsys] = $h' \
      "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"
  fi

  if ! verify_build "$attr"; then
    log_error "Build verification failed."
    exit 1
  fi

  log_info "releases.json now contains:"
  jq -r '.latest as $l | "  latest=" + $l, (.versions | keys[] | "  - " + .)' "$releases_file"

  if [ "$do_commit" = true ]; then
    local msg
    if [ "$current_key" = "$new_key" ]; then
      msg="chore(${PACKAGE_DIR_NAME}): rehash ${new_version}"
    else
      msg="chore(${PACKAGE_DIR_NAME}): bump to ${new_version}"
    fi
    maybe_git_commit "$msg" "releases.json"
  fi

  log_info "Successfully updated ${PACKAGE_ATTR} (latest was ${current_key}, now ${new_key})"
}

main "$@"
