#!/usr/bin/env bash
# Appends the newest tagged release of santifer/career-ops to releases.json (the
# JSON version table read by flake.nix) and sets it as .latest. Never hand-edits
# the version data in flake.nix.
#
# career-ops IS tagged (career-ops-vN.N.N), so:
#   key     = the version (e.g. "1.15.0")
#   version = the same version string
#   rev     = the upstream tag ("career-ops-v<version>")
#
# Two hashes are recomputed from scratch:
#   - .hash            : fetchFromGitHub source hash (prefetched via nix-prefetch-url)
#   - .npmDepsHashes.* : per-system npm FOD hash (fakeHash -> nix build -> parse "got:")
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly REPO_URL="https://github.com/santifer/career-ops"
# lib.fakeHash — the sentinel nix rejects, forcing it to print the real "got:" hash.
readonly FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
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
  [ -f "$flake_file" ] || { log_error "flake.nix not found in ${pkg_dir}"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at $releases_file"; exit 2; }
}

# mirror flake.nix: replace . - + with _  ('-' kept last so tr treats it literally)
sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
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

latest_tag() {
  git ls-remote --tags "$REPO_URL.git" \
    | awk -F/ '
      /refs\/tags\/(career-ops-)?v[0-9]+(\.[0-9]+)*$/ {
        tag = $3
        version = tag
        sub(/^career-ops-v/, "", version)
        sub(/^v/, "", version)
        print version "\t" tag
      }' \
    | sort -V -k1,1 \
    | tail -n1 \
    | cut -f2
}

version_from_tag() {
  local tag="$1"
  tag="${tag#career-ops-v}"
  tag="${tag#v}"
  printf '%s\n' "$tag"
}

prefetch_source_hash() {
  local tag="$1"
  local base32
  base32="$(nix-prefetch-url --unpack "${REPO_URL}/archive/${tag}.tar.gz" | tail -n1)"
  nix hash to-sri --type sha256 "$base32"
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

# Upsert an entry into releases.json and set .latest.
upsert_release_entry() {
  local key="$1"
  local entry_json="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg k "$key" --argjson e "$entry_json" \
    '.versions[$k] = $e | .latest = $k' "$releases_file" >"$tmp"
  mv "$tmp" "$releases_file"
}

set_entry_field() {
  local key="$1" filter="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg k "$key" "$filter" "$releases_file" >"$tmp"
  mv "$tmp" "$releases_file"
}

# Parallel-safe auto-commit. flock serialises the git index across updaters.
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

usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) tagged career-ops release to releases.json as
a new version-table entry (keyed by version) and sets .latest to it. Recomputes
the fetchFromGitHub source hash and the per-system npm FOD hash via jq — the
version data in flake.nix is never touched.

Options:
  --version VERSION   Append a specific version (default: newest tag)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute hashes even if version is unchanged
  --no-build          Skip build verification
  --help              Show this help
EOF
}

main() {
  ensure_tools
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME} (build system: ${BUILD_SYSTEM})"

  local requested="" check=false rehash=false no_build=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        requested="$2"; shift 2 ;;
      --check) check=true; shift ;;
      --rehash) rehash=true; shift ;;
      --no-build) no_build=true; shift ;;
      --help) usage; exit 0 ;;
      *) log_error "Unknown option: $1"; usage; exit 2 ;;
    esac
  done

  local current_key tag version
  current_key="$(get_current_key)"
  if [ -n "$requested" ]; then
    tag="career-ops-v${requested}"
  else
    tag="$(latest_tag)"
  fi
  [ -n "$tag" ] || { log_error "could not resolve upstream tag"; exit 2; }
  version="$(version_from_tag "$tag")"

  log_info "Current latest key: ${current_key}"
  log_info "Target version:     ${version} (${tag})"

  if [ "$check" = true ]; then
    if has_version_entry "$version" && [ "$current_key" = "$version" ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: ${current_key} -> ${version}"
    exit 1
  fi

  if has_version_entry "$version" && [ "$current_key" = "$version" ] && [ "$rehash" = false ]; then
    log_info "Already up to date! (use --rehash to force)"
    exit 0
  fi

  local attr backup
  attr="career-ops_$(sanitize_key "$version")"
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  # Preserve an existing aarch64 npmDeps hash if present, else seed a fakeHash
  # there (that arch is not built here; its hash stays fake until built on aarch64).
  local aarch_hash
  aarch_hash="$(jq -r --arg k "$version" \
    '.versions[$k].npmDepsHashes["aarch64-linux"] // empty' "$releases_file")"
  [ -n "$aarch_hash" ] || aarch_hash="$FAKE_HASH"

  # 1) source hash (prefetch — deterministic, no build needed)
  log_info "Prefetching fetchFromGitHub source hash..."
  local src_hash
  src_hash="$(prefetch_source_hash "$tag")"
  [ -n "$src_hash" ] || { log_error "failed to prefetch source hash"; exit 1; }
  log_info "  src hash: $src_hash"

  # Seed the entry with a fake npmDeps hash for the build system so nix reveals
  # the real one on build.
  local entry_json
  entry_json="$(jq -n \
    --arg v "$version" \
    --arg rev "$tag" \
    --arg h "$src_hash" \
    --arg fake "$FAKE_HASH" \
    --arg bsys "$BUILD_SYSTEM" \
    --arg aarch "$aarch_hash" \
    '{version: $v, rev: $rev, hash: $h,
      npmDepsHashes: ({ "aarch64-linux": $aarch } + { ($bsys): $fake })}')"
  upsert_release_entry "$version" "$entry_json"

  # 2) npmDeps FOD hash (for the build system)
  log_info "Computing npmDeps hash for ${BUILD_SYSTEM}..."
  local npm_hash
  npm_hash="$(build_and_get_hash "$attr")"
  if [ -z "$npm_hash" ]; then
    # No mismatch printed => build already succeeded (hash was correct).
    log_info "  npmDeps hash already correct (no rehash needed)."
  else
    log_info "  npmDeps hash: $npm_hash"
    set_entry_field "$version" \
      "$(printf '.versions[$k].npmDepsHashes["%s"] = "%s"' "$BUILD_SYSTEM" "$npm_hash")"
  fi

  if [ "$no_build" = false ]; then
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

  local scope msg
  scope="$(basename "$pkg_dir")"
  if [ "$current_key" = "$version" ]; then
    msg="chore(${scope}): rehash ${version}"
  else
    msg="chore(${scope}): bump to ${version}"
  fi
  maybe_git_commit "$msg" "releases.json"
}

main "$@"
