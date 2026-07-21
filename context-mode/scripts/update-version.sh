#!/usr/bin/env bash
# Appends the newest context-mode npm release to releases.json (the JSON
# version table read by flake.nix) and sets it as .latest. Never hand-edits the
# version data in flake.nix.
#
# context-mode ships tagged npm releases, so:
#   key     = the npm version (e.g. "1.0.169")
#   version = the same npm version
#
# Reproducible-deps model (pnpm): dependencies are pinned by a COMMITTED
# pnpm-lock.yaml under deps/<version>/, fetched at build time by pnpm.fetchDeps.
# This script therefore, per version:
#   - .hash          : the npm tarball fetchurl hash (SRI, arch-agnostic)
#   - deps/<v>/pnpm-lock.yaml : a freshly resolved, committed lockfile
#   - .pnpmDepsHash  : the single portable pnpm.fetchDeps hash (same on all
#     systems — fetchDeps downloads every platform's tarballs), recomputed via
#     the fakeHash -> nix build -> parse "got:" method.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly NPM_REGISTRY_URL="https://registry.npmjs.org"
readonly NPM_PACKAGE="context-mode"
readonly TARBALL_NAME="context-mode"
readonly PACKAGE_ATTR="context-mode"
readonly BIN_NAME="context-mode"
# nixpkgs ref used to obtain Node.js (for corepack) and the pnpm major that
# matches flake.nix (pnpm_10) for the build-verification step.
readonly NIXPKGS_REF="github:NixOS/nixpkgs/nixos-26.05"
# lib.fakeHash — the sentinel nix rejects, forcing it to print the real "got:" hash.
readonly FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  for t in nix curl jq tar; do
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

# pnpm from the pinned nixpkgs (major must match flake.nix's pnpm_10). Used
# only for the final build-verification step, NOT for lockfile generation.
pnpm_run() { nix shell "${NIXPKGS_REF}#pnpm_10" --command pnpm "$@"; }

# Node.js + corepack from the pinned nixpkgs, used to generate lockfiles.
# corepack reads the tarball's own package.json "packageManager" field and
# transparently fetches that exact pnpm version, so the resolved lockfile is
# byte-identical regardless of which pnpm happens to be newest in nixpkgs at
# generation time (nixpkgs' pnpm_10 drifts forward and produces a DIFFERENT
# lockfile shape — e.g. it adds per-platform "libc:" metadata lines that an
# older pinned pnpm does not emit — so it must not be used here).
corepack_pnpm_run() { nix shell "${NIXPKGS_REF}#nodejs_22" --command corepack pnpm "$@"; }

# Relative path (from pkg_dir) of a version's committed lockfile.
lockfile_rel() { printf 'deps/%s/pnpm-lock.yaml' "$1"; }

lockfile_exists() { [ -f "${pkg_dir}/$(lockfile_rel "$1")" ]; }

# Resolve a fresh pnpm-lock.yaml for VERSION from its npm tarball and commit it
# under deps/<version>/. The lockfile is generated from the tarball's unmodified
# package.json (via corepack, honoring its pinned "packageManager" pnpm
# version) so pnpm.fetchDeps' --frozen-lockfile check passes at build time and
# the result is reproducible over time.
generate_pnpm_lock() {
  local version="$1" tarball_url="$2"
  local dest="${pkg_dir}/deps/${version}"
  local work; work="$(mktemp -d)"
  log_info "Generating pnpm-lock.yaml for ${version}..."
  curl -fsSL "$tarball_url" -o "$work/pkg.tgz"
  tar -xzf "$work/pkg.tgz" -C "$work"   # -> $work/package/
  (
    cd "$work/package"
    export HOME="$work/home"; mkdir -p "$HOME"
    corepack_pnpm_run install --lockfile-only --ignore-scripts
  )
  [ -f "$work/package/pnpm-lock.yaml" ] || { log_error "lockfile generation produced no pnpm-lock.yaml"; rm -rf "$work"; return 1; }
  mkdir -p "$dest"
  cp "$work/package/pnpm-lock.yaml" "$dest/pnpm-lock.yaml"
  rm -rf "$work"
  log_info "  committed $(lockfile_rel "$version")"
}

get_current_version() { jq -r '.latest // empty' "$releases_file"; }

has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

get_latest_version_from_npm() {
  curl -fsSL "$NPM_REGISTRY_URL/$NPM_PACKAGE/latest" \
    | jq -r '.version // empty'
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | jq -r '.hash // empty'
}

# Recompute the pnpm.fetchDeps hash by building the target attr with a fake hash
# already written into releases.json and parsing nix's "got:" line.
build_and_get_hash() {
  local attr="$1" out
  out="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link 2>&1 || true)"
  printf '%s\n' "$out" | extract_got_hash
}

# Is the recorded pnpmDepsHash a fakeHash sentinel (or missing)?
current_hash_is_fake() {
  local key="$1" h
  h="$(jq -r --arg k "$key" '.versions[$k].pnpmDepsHash // empty' "$releases_file")"
  [ -z "$h" ] || [ "$h" = "$FAKE_HASH" ]
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) context-mode npm release to releases.json
and sets it as .latest. For the new version it: prefetches the tarball hash,
generates+commits deps/<version>/pnpm-lock.yaml, and recomputes the single
portable .pnpmDepsHash via the fakeHash -> nix build -> parse "got:" method.
The version data in flake.nix is never touched.

Options:
  --version VERSION   Append a specific version (default: latest npm)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Regenerate lockfile + pnpmDepsHash for the latest entry
  --no-build          Skip final build verification
  --no-commit         Do not auto-commit (default: auto-commit is enabled)
  --help              Show this help message
EOF
}

# Parallel-safe auto-commit. flock serialises the git index across concurrent updaters.
maybe_git_commit() {
  local commit_message="$1"; shift
  local -a paths=("$@")

  if ! command -v git >/dev/null 2>&1; then
    log_warn "git not found; skipping auto-commit"; return 0
  fi
  if ! git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_warn "not in a git work tree; skipping auto-commit"; return 0
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
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

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

  local current_version latest_version
  current_version="$(get_current_version)"
  [ -n "$current_version" ] || { log_error "Failed to detect current version from releases.json"; exit 2; }
  latest_version="${target_version:-$(get_latest_version_from_npm)}"
  [ -n "$latest_version" ] || { log_error "Failed to fetch latest version"; exit 2; }

  log_info "Current latest: $current_version"
  log_info "Target version:  $latest_version"

  # "Up to date" == entry exists, is .latest, has a committed lockfile, and a
  # real (non-fake) pnpmDepsHash.
  local up_to_date=false
  if has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ] \
    && lockfile_exists "$latest_version" && ! current_hash_is_fake "$latest_version"; then
    up_to_date=true
  fi

  if [ "$check_only" = true ]; then
    if [ "$up_to_date" = true ]; then log_info "Already up to date!"; exit 0; fi
    log_info "Update available: $current_version -> $latest_version"; exit 1
  fi

  if [ "$up_to_date" = true ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"; exit 0
  fi

  local sanitized_key attr
  sanitized_key="$(sanitize_key "$latest_version")"
  attr="${PACKAGE_ATTR}_${sanitized_key}"

  # 1) npm tarball hash (arch-agnostic).
  local tarball_url tarball_hash
  tarball_url="$NPM_REGISTRY_URL/$NPM_PACKAGE/-/$TARBALL_NAME-$latest_version.tgz"
  log_info "Prefetching npm tarball hash..."
  tarball_hash="$(prefetch_sha256_sri "$tarball_url")"
  [ -n "$tarball_hash" ] || { log_error "Failed to prefetch tarball hash"; exit 1; }
  log_info "  tarball hash: $tarball_hash"

  # 2) Generate + commit the pnpm lockfile for this version.
  generate_pnpm_lock "$latest_version" "$tarball_url"

  local backup tmp
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  # Seed/upsert the entry with the real tarball hash but a fake deps hash so nix
  # reveals the real one on build. Set it as .latest.
  tmp="$(mktemp)"
  jq --arg k "$latest_version" \
     --arg ver "$latest_version" \
     --arg rev "$latest_version" \
     --arg hash "$tarball_hash" \
     --arg fake "$FAKE_HASH" '
       .versions[$k] = { version: $ver, rev: $rev, hash: $hash, pnpmDepsHash: $fake }
       | .latest = $k
     ' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  # 3) pnpm.fetchDeps hash (single, portable).
  log_info "Computing pnpmDepsHash..."
  local deps_hash
  deps_hash="$(build_and_get_hash "$attr")"
  if [ -z "$deps_hash" ]; then
    log_info "  pnpmDepsHash already correct (no rehash needed)."
  else
    log_info "  pnpmDepsHash: $deps_hash"
    tmp="$(mktemp)"
    jq --arg k "$latest_version" --arg h "$deps_hash" \
      '.versions[$k].pnpmDepsHash = $h' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"
  fi

  if [ "$no_build" != true ]; then
    log_info "Verifying build of ${attr}..."
    local out_path
    if ! out_path="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link --print-out-paths 2>&1)"; then
      log_error "verification build failed; restoring previous releases.json"
      printf '%s\n' "$out_path" | tail -n 40 >&2
      cp "$backup" "$releases_file"; rm -f "$backup"; exit 1
    fi
    out_path="$(printf '%s\n' "$out_path" | tail -n1)"
    if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
      log_error "Build succeeded but expected binary not found at: $out_path/bin/$BIN_NAME"
      cp "$backup" "$releases_file"; rm -f "$backup"; exit 1
    fi
    if ! (cd "$pkg_dir" && nix build ".#default" --no-link --no-write-lock-file); then
      log_error "nix build failed for default; restoring previous releases.json"
      cp "$backup" "$releases_file"; rm -f "$backup"; exit 1
    fi
    log_info "Build OK: $out_path"
  fi

  rm -f "$backup"

  log_info "releases.json now contains:"
  jq -r '.latest as $l | "  latest=" + $l, (.versions | keys[] | "  - " + .)' "$releases_file"

  if [ "$do_commit" = true ]; then
    local scope msg
    scope="$(basename "$pkg_dir")"
    if [ "$current_version" != "$latest_version" ]; then
      msg="chore(${scope}): bump to ${latest_version}"
    else
      msg="chore(${scope}): rehash ${latest_version}"
    fi
    maybe_git_commit "$msg" "releases.json" "$(lockfile_rel "$latest_version")"
  fi
}

main "$@"
