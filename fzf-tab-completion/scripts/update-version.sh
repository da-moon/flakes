#!/usr/bin/env bash
# Appends the newest upstream commit of lincheney/fzf-tab-completion as a new
# entry in releases.json (the JSON version table the flake reads). Never
# hand-edits the version data in flake.nix.
#
# fzf-tab-completion has NO release tags, so:
#   key     = short (7-char) upstream commit hash
#   version = "<base>-unstable-<commit-date>" (base taken from the current
#             latest entry; nixpkgs convention uses "0" when a project has
#             never had a tagged release)
#
# The single fetchFromGitHub source hash is recomputed from scratch via the
# reliable fakeHash -> nix build -> parse "got:" method.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly GITHUB_API_BASE="https://api.github.com"
readonly REPO_OWNER="lincheney"
readonly REPO_NAME="fzf-tab-completion"
readonly REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
# lib.fakeHash — the sentinel nix rejects, forcing it to print the real "got:" hash.
readonly FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  for t in nix curl jq git; do
    command -v "$t" >/dev/null 2>&1 || { log_error "$t is required but not installed."; exit 2; }
  done
}

ensure_in_package_directory() {
  [ -f "$flake_file" ] || { log_error "flake.nix not found in ${pkg_dir}"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at $releases_file"; exit 2; }
}

sanitize_key() {
  # mirror flake.nix: replace . - + with _  ('-' kept last so tr treats it literally)
  printf '%s' "$1" | tr '.+-' '___'
}

extract_got_hash() {
  sed -n 's~.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*~\1~p' | head -n1
}

# Resolve a default-branch (or requested) commit: full 40-char sha + date.
resolve_head() {
  local ref="$1" sha commit_json full_sha date
  if [ -n "$ref" ]; then
    sha="$(git ls-remote "$REPO_URL" "$ref" | awk 'NR==1{print $1}')"
    [ -n "$sha" ] || sha="$ref"  # allow a raw (possibly short) rev
  else
    sha="$(git ls-remote "$REPO_URL" HEAD | awk 'NR==1{print $1}')"
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

Appends the newest upstream commit of lincheney/fzf-tab-completion to
releases.json (the JSON version table read by flake.nix) and sets it as .latest.
Recomputes the fetchFromGitHub source hash via jq — the version data in
flake.nix is never touched.

Options:
  --check            Print whether a newer commit exists; exit 1 if it does.
  --rev VALUE        Pin to a specific git ref/branch/rev instead of HEAD
                       (aliases: --revision, --version).
  --no-build         Skip the final verification build.
  --no-commit        Do not auto-commit (default: auto-commit is enabled).
  --help             Show this help.

Notes:
  This repo does not publish versioned releases. Entries are keyed by the short
  (7-char) upstream commit hash; the version string is "<base>-unstable-<date>".
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
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local check_only=false no_build=false do_commit=true target_ref=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check) check_only=true; shift ;;
      --no-build) no_build=true; shift ;;
      --no-commit) do_commit=false; shift ;;
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
  # Base = version part before "-unstable-" (e.g. "0"). fzf-tab-completion has
  # no tags, so preserve whatever base the current latest entry already uses.
  base="${cur_latest_ver%%-unstable-*}"
  [ -n "$base" ] || base="0"

  local info rev date short_key new_version
  info="$(resolve_head "$target_ref")"
  rev="${info%%|*}"
  date="${info##*|}"
  short_key="${rev:0:7}"
  new_version="${base}-unstable-${date}"

  log_info "Current latest key: ${cur_latest_key} (${cur_latest_ver})"
  log_info "Resolved upstream:  ${rev}"
  log_info "New key:            ${short_key}"
  log_info "New version:        ${new_version}"

  if [ "$check_only" = true ]; then
    if [ "$short_key" = "$cur_latest_key" ]; then
      log_info "Already up to date (latest is ${cur_latest_key})."
      exit 0
    fi
    log_info "Update available: ${short_key}"
    exit 1
  fi

  # Seed the entry with a fake hash so nix reveals the real one on build.
  local attr tmp
  attr="fzf-tab-completion_$(sanitize_key "$short_key")"
  tmp="$(mktemp)"
  jq --arg k "$short_key" \
     --arg ver "$new_version" \
     --arg rev "$rev" \
     --arg fake "$FAKE_HASH" '
       .versions[$k] = {
         version: $ver,
         rev: $rev,
         hash: $fake
       }
       | .latest = $k
     ' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  # Recompute the fetchFromGitHub source hash.
  log_info "Computing fetchFromGitHub source hash..."
  local src_hash
  src_hash="$(build_and_get_hash "$attr")"
  if [ -z "$src_hash" ]; then
    # No mismatch printed => build already succeeded (hash was correct).
    log_info "  source hash already correct (no rehash needed)."
  else
    log_info "  src hash: $src_hash"
    tmp="$(mktemp)"
    jq --arg k "$short_key" --arg h "$src_hash" '.versions[$k].hash = $h' \
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
    if [ "$short_key" = "$cur_latest_key" ]; then
      msg="chore(${scope}): rehash ${new_version} (${short_key})"
    else
      msg="chore(${scope}): add ${new_version} (${short_key}) to version table"
    fi
    maybe_git_commit "$msg" "releases.json"
  fi
}

main "$@"
