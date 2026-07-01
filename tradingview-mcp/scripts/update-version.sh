#!/usr/bin/env bash
# Appends the newest upstream commit of tradesdontlie/tradingview-mcp as a new
# entry in releases.json (the JSON version table the flake reads). Never
# hand-edits the version data in flake.nix.
#
# tradingview-mcp has NO release tags, so:
#   key     = short (7-char) upstream commit hash
#   version = "<base>-unstable-<commit-date>" (base = package.json "version" at
#             that commit, e.g. "1.0.0"; falls back to the current entry's base)
#
# Two fixed-output hashes are recomputed:
#   - .hash        : fetchFromGitHub source hash (via nix-prefetch-url)
#   - .npmDepsHash : buildNpmPackage npm-deps FOD hash (fakeHash -> "got:")
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly REPO_OWNER="tradesdontlie"
readonly REPO_NAME="tradingview-mcp"
readonly REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
readonly RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}"
readonly GITHUB_API_BASE="https://api.github.com"
# lib.fakeHash — the sentinel nix rejects, forcing it to print the real "got:" hash.
readonly FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_tools() {
  for tool in curl git nix nix-prefetch-url jq python3; do
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

extract_got_hash() {
  sed -n 's~.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*~\1~p' | head -n1
}

# Resolve the newest default-branch commit (full 40-char sha + committer date).
resolve_head() {
  local ref="$1" sha commit_json full_sha date
  if [ -n "$ref" ]; then
    sha="$(git ls-remote "${REPO_URL}.git" "$ref" | awk 'NR==1{print $1}')"
    [ -n "$sha" ] || sha="$ref"  # allow a raw (possibly short) rev
  else
    sha="$(git ls-remote "${REPO_URL}.git" HEAD | awk 'NR==1{print $1}')"
  fi
  [ -n "$sha" ] || { log_error "could not resolve upstream rev"; exit 2; }
  # The commits API accepts short shas and returns the full sha + date, so this
  # both validates and canonicalises the rev (fetchFromGitHub needs 40 chars).
  commit_json="$(curl -fsSL "$GITHUB_API_BASE/repos/$REPO_OWNER/$REPO_NAME/commits/$sha")"
  full_sha="$(printf '%s' "$commit_json" | jq -r '.sha')"
  date="$(printf '%s' "$commit_json" | jq -r '.commit.committer.date' | cut -dT -f1)"
  [ -n "$full_sha" ] && [ "$full_sha" != "null" ] || { log_error "could not resolve full sha for $sha"; exit 2; }
  [ -n "$date" ] && [ "$date" != "null" ] || { log_error "could not resolve commit date for $sha"; exit 2; }
  printf '%s|%s\n' "$full_sha" "$date"
}

package_version_for_rev() {
  local rev="$1"
  python3 - "$RAW_BASE/$rev/package.json" <<'PY'
import json
import sys
import urllib.request
try:
    print(json.load(urllib.request.urlopen(sys.argv[1]))["version"])
except Exception:
    print("")
PY
}

prefetch_source_hash() {
  local rev="$1"
  local base32
  base32="$(nix-prefetch-url --unpack "${REPO_URL}/archive/${rev}.tar.gz" | tail -n1)"
  nix hash to-sri --type sha256 "$base32"
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

Appends the newest upstream commit of tradesdontlie/tradingview-mcp to
releases.json (the JSON version table read by flake.nix) and sets it as .latest.
Recomputes both the fetchFromGitHub source hash and the buildNpmPackage npmDeps
FOD hash via jq — the version data in flake.nix is never touched.

Options:
  --check            Print whether a newer commit exists; exit 1 if it does.
  --rev VALUE        Pin to a specific git ref/branch/rev instead of HEAD
                       (aliases: --revision, --version).
  --rehash           Recompute hashes even if the key already exists.
  --no-build         Skip the final verification build.
  --no-commit        Do not auto-commit (default: auto-commit is enabled).
  --help             Show this help.
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
  ensure_tools
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local check_only=false no_build=false do_commit=true rehash=false target_ref=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check) check_only=true; shift ;;
      --no-build) no_build=true; shift ;;
      --no-commit) do_commit=false; shift ;;
      --rehash) rehash=true; shift ;;
      --rev|--revision|--version)
        [ $# -ge 2 ] || { log_error "$1 requires an argument"; exit 2; }
        target_ref="$2"; shift 2 ;;
      --help) print_usage; exit 0 ;;
      *) log_error "Unknown option: $1"; print_usage; exit 2 ;;
    esac
  done

  local cur_latest_key cur_latest_ver base
  cur_latest_key="$(jq -r '.latest' "$releases_file")"
  cur_latest_ver="$(jq -r --arg k "$cur_latest_key" '.versions[$k].version' "$releases_file")"
  # Base = version part before "-unstable-" (e.g. "1.0.0"); nixpkgs uses "0"
  # once a project is past its last tagged release.
  base="${cur_latest_ver%%-unstable-*}"
  [ -n "$base" ] || base="0"

  local info rev date short_key pkg_ver new_version
  info="$(resolve_head "$target_ref")"
  rev="${info%%|*}"
  date="${info##*|}"
  short_key="${rev:0:7}"
  # Prefer the package.json version at that commit; fall back to the current base.
  pkg_ver="$(package_version_for_rev "$rev")"
  [ -n "$pkg_ver" ] || pkg_ver="$base"
  new_version="${pkg_ver}-unstable-${date}"

  log_info "Current latest key: ${cur_latest_key} (${cur_latest_ver})"
  log_info "Resolved upstream:  ${rev}"
  log_info "New key:            ${short_key}"
  log_info "New version:        ${new_version}"

  local already_present=false
  [ "$(jq -r --arg k "$short_key" '.versions | has($k)' "$releases_file")" = "true" ] && already_present=true

  if [ "$check_only" = true ]; then
    if [ "$short_key" = "$cur_latest_key" ] && [ "$already_present" = true ]; then
      log_info "Already up to date (latest is ${cur_latest_key})."
      exit 0
    fi
    log_info "Update available: ${short_key}"
    exit 1
  fi

  if [ "$already_present" = true ] && [ "$short_key" = "$cur_latest_key" ] && [ "$rehash" = false ]; then
    log_info "Already up to date (latest is ${cur_latest_key}); use --rehash to recompute."
    exit 0
  fi

  local backup
  backup="$(mktemp)"
  cp "$releases_file" "$backup"

  local attr tmp
  attr="tradingview-mcp_$(sanitize_key "$short_key")"

  # Seed the entry with fake hashes so nix reveals the real ones on build,
  # and set it as .latest.
  tmp="$(mktemp)"
  jq --arg k "$short_key" \
     --arg ver "$new_version" \
     --arg rev "$rev" \
     --arg fake "$FAKE_HASH" '
       .versions[$k] = {
         version: $ver,
         rev: $rev,
         hash: $fake,
         npmDepsHash: $fake
       }
       | .latest = $k
     ' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  # 1) source hash (fetchFromGitHub) — prefetched directly.
  log_info "Computing fetchFromGitHub source hash..."
  local src_hash
  src_hash="$(prefetch_source_hash "$rev")"
  [ -n "$src_hash" ] || { log_error "failed to prefetch source hash"; cp "$backup" "$releases_file"; rm -f "$backup"; exit 1; }
  log_info "  src hash: $src_hash"
  tmp="$(mktemp)"
  jq --arg k "$short_key" --arg h "$src_hash" '.versions[$k].hash = $h' \
    "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  # 2) npmDeps FOD hash (buildNpmPackage) — via fakeHash "got:" parse.
  log_info "Computing npmDepsHash..."
  local npm_hash
  npm_hash="$(build_and_get_hash "$attr")"
  if [ -z "$npm_hash" ]; then
    # No mismatch printed => build already succeeded (hash was correct).
    log_info "  npmDepsHash already correct (no rehash needed)."
  else
    log_info "  npmDepsHash: $npm_hash"
    tmp="$(mktemp)"
    jq --arg k "$short_key" --arg h "$npm_hash" '.versions[$k].npmDepsHash = $h' \
      "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"
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

  if [ "$do_commit" = true ]; then
    local scope msg
    scope="$(basename "$pkg_dir")"
    if [ "$short_key" = "$cur_latest_key" ]; then
      msg="chore(${scope}): rehash ${new_version} (${short_key})"
    else
      msg="chore(${scope}): add ${new_version} (${short_key}) to version table"
    fi
    maybe_git_commit "$msg" "releases.json"
  fi
}

main "$@"
