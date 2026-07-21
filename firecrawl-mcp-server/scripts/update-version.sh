#!/usr/bin/env bash
# Appends the newest (or an explicit) firecrawl-mcp npm release to releases.json
# (the JSON version table read by flake.nix) and sets it as .latest. Never
# hand-edits the version data in flake.nix.
#
# firecrawl-mcp is published to the npm registry (npm tarball source, NOT a
# github checkout), so:
#   key     = the npm version (tag-based)
#   version = the same npm version
#
# Reproducible-deps model (yarn classic): dependencies are pinned by a COMMITTED
# yarn.lock under deps/<key>/, fetched at build time into an offline mirror by
# fetchYarnDeps. This script therefore, per version:
#   - .hash          : fetchurl hash of the npm .tgz tarball (prefetched via
#                      plain `nix store prefetch-file`, no --unpack — this is a
#                      fetchurl tarball, not a fetchFromGitHub NAR).
#   - deps/<key>/yarn.lock : a freshly resolved, committed lockfile (the
#                      published tarball ships no yarn.lock at all).
#   - .yarnDepsHash  : the single portable fetchYarnDeps offline-mirror hash,
#                      recomputed via the fakeHash -> nix build -> parse "got:".
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
readonly PACKAGE_ATTR="firecrawl-mcp-server"
readonly BIN_NAME="firecrawl-mcp"
# nixpkgs ref used to obtain yarn classic matching flake.nix.
readonly NIXPKGS_REF="github:NixOS/nixpkgs/nixos-26.05"
# lib.fakeHash — the sentinel nix rejects, forcing it to print the real "got:" hash.
readonly FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  for t in nix curl jq git tar; do
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

# yarn classic from the pinned nixpkgs.
yarn_run() { nix shell "${NIXPKGS_REF}#yarn" --command yarn "$@"; }

# Relative path (from pkg_dir) of a version's committed lockfile.
lockfile_rel() { printf 'deps/%s/yarn.lock' "$1"; }

lockfile_exists() { [ -f "${pkg_dir}/$(lockfile_rel "$1")" ]; }

get_current_version() { jq -r '.latest // empty' "$releases_file"; }

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

# npm tarball fetchurl hash. Plain prefetch (NO --unpack): this is a .tgz that
# nix fetches verbatim via fetchurl, not a NAR-unpacked github checkout.
prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' \
    | head -n1
}

# Resolve + commit a COMPLETE yarn.lock for VERSION under deps/<key>/. The
# published npm tarball ships no lockfile at all, so this is generated fresh
# from the tarball's own package.json.
generate_yarn_lock() {
  local version="$1" tarball_url="$2"
  local dest="${pkg_dir}/deps/${version}"
  local work; work="$(mktemp -d)"
  log_info "Generating yarn.lock for ${version}..."
  curl -fsSL "$tarball_url" -o "$work/src.tgz"
  tar -xzf "$work/src.tgz" -C "$work"   # -> $work/package/
  [ -d "$work/package" ] || { log_error "could not locate extracted source dir"; rm -rf "$work"; return 1; }
  (
    cd "$work/package"
    export HOME="$work/home"; mkdir -p "$HOME"
    yarn_run install --ignore-scripts --non-interactive --no-progress >/dev/null 2>&1
  )
  [ -f "$work/package/yarn.lock" ] || { log_error "lockfile generation produced no yarn.lock"; rm -rf "$work"; return 1; }
  mkdir -p "$dest"
  cp "$work/package/yarn.lock" "$dest/yarn.lock"
  rm -rf "$work"
  log_info "  committed $(lockfile_rel "$version")"
}

# Recompute the fetchYarnDeps hash by building the attr with a fake yarnDepsHash
# already written into releases.json and parsing nix's "got:" line. The source
# .hash must already be real so only the fetchYarnDeps FOD mismatches.
build_and_get_hash() {
  local attr="$1" out
  out="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link 2>&1 || true)"
  printf '%s\n' "$out" | extract_got_hash
}

current_hash_is_fake() {
  local key="$1" h
  h="$(jq -r --arg k "$key" '.versions[$k].yarnDepsHash // empty' "$releases_file")"
  [ -z "$h" ] || [ "$h" = "$FAKE_HASH" ]
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) firecrawl-mcp npm release to releases.json
and sets it as .latest. For the new version it: prefetches the npm tarball
fetchurl hash, generates+commits deps/<version>/yarn.lock, and recomputes the
single portable .yarnDepsHash via the fakeHash -> nix build -> parse "got:"
method. The version data in flake.nix is never touched.

Options:
  --version VERSION   Append a specific version (default: latest npm)
  --check             Only check for updates (exit 1 if update available)
  --rehash             Regenerate lockfile + yarnDepsHash for the latest entry
  --no-build           Skip final build verification
  --no-commit          Do not auto-commit (default: auto-commit is enabled)
  --help               Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 3.22.5
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
  [ -n "$latest_version" ] || { log_error "Failed to fetch latest version from npm"; exit 2; }

  log_info "Current latest: $current_version"
  log_info "Target version:  $latest_version"

  # "Up to date" == entry exists, is .latest, has a committed lockfile, and a
  # real (non-fake) yarnDepsHash.
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

  # 1) npm tarball fetchurl hash (prefetched, independent of the build).
  local tarball_url tarball_hash
  tarball_url="$NPM_REGISTRY_URL/$NPM_PACKAGE/-/$TARBALL_NAME-$latest_version.tgz"
  log_info "Prefetching npm tarball hash..."
  tarball_hash="$(prefetch_sha256_sri "$tarball_url")"
  [ -n "$tarball_hash" ] || { log_error "Failed to prefetch tarball hash"; exit 1; }
  log_info "  tarball hash: $tarball_hash"

  # 2) generate + commit the yarn.lock.
  generate_yarn_lock "$latest_version" "$tarball_url"

  local backup tmp
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  # Seed/upsert the entry with the real source hash but a fake yarnDepsHash so
  # only the fetchYarnDeps FOD mismatches on build. Set it as .latest.
  tmp="$(mktemp)"
  jq --arg k "$latest_version" \
     --arg ver "$latest_version" \
     --arg rev "$latest_version" \
     --arg hash "$tarball_hash" \
     --arg fake "$FAKE_HASH" '
       .versions[$k] = { version: $ver, rev: $rev, hash: $hash, yarnDepsHash: $fake }
       | .latest = $k
     ' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  # 3) fetchYarnDeps hash (single, portable).
  log_info "Computing yarnDepsHash..."
  local deps_hash
  deps_hash="$(build_and_get_hash "$attr")"
  if [ -z "$deps_hash" ]; then
    log_info "  yarnDepsHash already correct (no rehash needed)."
  else
    log_info "  yarnDepsHash: $deps_hash"
    tmp="$(mktemp)"
    jq --arg k "$latest_version" --arg h "$deps_hash" \
      '.versions[$k].yarnDepsHash = $h' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"
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
    if ! (cd "$pkg_dir" && nix build ".#default" --no-write-lock-file --no-link); then
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

  log_info "Successfully processed firecrawl-mcp $latest_version (previous latest was $current_version)"
}

main "$@"
