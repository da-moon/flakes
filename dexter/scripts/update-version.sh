#!/usr/bin/env bash
# Appends the newest upstream release tag of virattt/dexter as a new entry in
# releases.json (the JSON version table the flake reads) and sets it as .latest.
# Never hand-edits the version data in flake.nix.
#
# dexter is TAGGED (upstream ships v<YYYY.M.D> release tags), so:
#   key     = the version (tag without the leading "v")
#   version = the same tag string
#
# Two kinds of hashes are recomputed:
#   - .hash               : fetchFromGitHub source hash (single) via nix-prefetch-url
#   - .npmDepsHashes.*    : per-system npm FOD hash via the reliable fakeHash ->
#                           nix build -> parse "got:" method
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly REPO_URL="https://github.com/virattt/dexter"
readonly PNAME="dexter"
# lib.fakeHash — the sentinel nix rejects, forcing it to print the real "got:" hash.
readonly FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"
# Which system's npmDeps hash to (re)compute — the host we build on.
BUILD_SYSTEM="$(nix eval --raw --impure --expr 'builtins.currentSystem' 2>/dev/null || echo x86_64-linux)"

ensure_tools() {
  for tool in git nix nix-prefetch-url jq; do
    command -v "$tool" >/dev/null 2>&1 || { log_error "$tool is required"; exit 2; }
  done
}

ensure_in_package_directory() {
  [ -f "${pkg_dir}/flake.nix" ] || { log_error "flake.nix not found in ${pkg_dir}"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at $releases_file"; exit 2; }
}

# mirror flake.nix: replace . - + with _  ('-' kept last so tr treats it literally)
sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
}

extract_got_hash() {
  sed -n 's~.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*~\1~p' | head -n1
}

# Current "latest" key recorded in the version table.
current_latest_key() {
  jq -r '.latest // empty' "$releases_file"
}

# Does the table already have an entry for this key?
has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

# Newest v<X.Y.Z> release tag from upstream (with the "v" stripped).
latest_version() {
  git ls-remote --tags "$REPO_URL.git" \
    | awk -F/ '/refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+$/ { print substr($3, 2) }' \
    | sort -V \
    | tail -n1
}

# fetchFromGitHub source hash for a given tag (v<version>).
prefetch_source_hash() {
  local version="$1"
  local base32
  base32="$(nix-prefetch-url --unpack "${REPO_URL}/archive/v${version}.tar.gz" 2>/dev/null | tail -n1)"
  [ -n "$base32" ] || return 1
  nix hash to-sri --type sha256 "$base32"
}

# Recompute a fixed-output hash by building the target attr with FAKE_HASH
# already written into releases.json and parsing nix's "got:" line.
build_and_get_hash() {
  local attr="$1" out
  out="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link 2>&1 || true)"
  printf '%s\n' "$out" | extract_got_hash
}

usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest upstream release tag of virattt/dexter to releases.json (the
JSON version table read by flake.nix) and sets it as .latest. Recomputes both
the fetchFromGitHub source hash and the per-system npm FOD hash via jq — the
version data in flake.nix is never touched.

Options:
  --version VERSION   Append/pin a specific version instead of the latest tag.
  --check             Only check for updates (exit 1 if an update is available).
  --rehash            Recompute hashes even if already at the target version.
  --no-build          Skip the final verification build.
  --no-commit         Do not auto-commit (default: auto-commit is enabled).
  --help              Show this help message.
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
  ensure_tools
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME} (build system: ${BUILD_SYSTEM})"

  local requested="" check=false rehash=false no_build=false do_commit=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        requested="$2"; shift 2 ;;
      --check) check=true; shift ;;
      --rehash) rehash=true; shift ;;
      --no-build) no_build=true; shift ;;
      --no-commit) do_commit=false; shift ;;
      --help) usage; exit 0 ;;
      *) log_error "Unknown option: $1"; usage; exit 2 ;;
    esac
  done

  local cur_latest_key target
  cur_latest_key="$(current_latest_key)"
  [ -n "$cur_latest_key" ] || { log_error "Failed to detect .latest from releases.json"; exit 2; }
  target="${requested:-$(latest_version)}"
  [ -n "$target" ] || { log_error "Failed to resolve latest upstream tag"; exit 2; }

  log_info "Current latest: $cur_latest_key"
  log_info "Target version: $target"

  if [ "$check" = true ]; then
    if has_version_entry "$target" && [ "$cur_latest_key" = "$target" ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: $cur_latest_key -> $target"
    exit 1
  fi

  if has_version_entry "$target" && [ "$cur_latest_key" = "$target" ] && [ "$rehash" != true ]; then
    log_info "dexter already at $target; nothing to do"
    exit 0
  fi

  # 1) source hash (fetchFromGitHub) via nix-prefetch-url.
  log_info "Computing fetchFromGitHub source hash for v${target}..."
  local src_hash
  src_hash="$(prefetch_source_hash "$target")" \
    || { log_error "failed to prefetch source for v${target}"; exit 1; }
  log_info "  src hash: $src_hash"

  # Preserve an existing aarch64 hash if present, else seed a fakeHash there
  # (that arch is not built here; its hash stays fake until built on aarch64).
  local aarch_hash
  aarch_hash="$(jq -r --arg k "$target" \
    '.versions[$k].npmDepsHashes["aarch64-linux"] // empty' "$releases_file")"
  [ -n "$aarch_hash" ] || aarch_hash="$FAKE_HASH"

  # Seed the entry: real source hash + fake npmDeps hash for the build system
  # so nix reveals the real npm FOD hash on build.
  local attr tmp
  attr="${PNAME}_$(sanitize_key "$target")"
  tmp="$(mktemp)"
  jq --arg k "$target" \
     --arg ver "$target" \
     --arg rev "v${target}" \
     --arg hash "$src_hash" \
     --arg fake "$FAKE_HASH" \
     --arg bsys "$BUILD_SYSTEM" \
     --arg aarch "$aarch_hash" '
       .versions[$k] = {
         version: $ver,
         rev: $rev,
         hash: $hash,
         npmDepsHashes: ({ "aarch64-linux": $aarch } + { ($bsys): $fake })
       }
       | .latest = $k
     ' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  # 2) npm FOD hash (for the build system) via fakeHash reveal.
  log_info "Computing npm deps hash for ${BUILD_SYSTEM}..."
  local npm_hash
  npm_hash="$(build_and_get_hash "$attr")"
  if [ -z "$npm_hash" ]; then
    # No mismatch printed => build already succeeded (hash was correct).
    log_info "  npm deps hash already correct (no rehash needed)."
  else
    log_info "  npm deps hash: $npm_hash"
    tmp="$(mktemp)"
    jq --arg k "$target" --arg bsys "$BUILD_SYSTEM" --arg h "$npm_hash" \
      '.versions[$k].npmDepsHashes[$bsys] = $h' \
      "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"
  fi

  if [ "$no_build" = false ]; then
    log_info "Verifying build of ${attr}..."
    local out
    if ! out="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link --print-out-paths 2>&1)"; then
      log_error "verification build failed:"
      printf '%s\n' "$out" | tail -n 40 >&2
      exit 1
    fi
    log_info "Build OK: $(printf '%s\n' "$out" | tail -n1)"
  fi

  log_info "releases.json now contains:"
  jq -r '.latest as $l | "  latest=" + $l, (.versions | keys[] | "  - " + .)' "$releases_file"

  if [ "$do_commit" = true ]; then
    local scope msg
    scope="$(basename "$pkg_dir")"
    if [ "$cur_latest_key" = "$target" ]; then
      msg="chore(${scope}): rehash ${target}"
    else
      msg="chore(${scope}): bump to ${target}"
    fi
    maybe_git_commit "$msg" "releases.json"
  fi
}

main "$@"
