#!/usr/bin/env bash
# Appends the newest upstream commit of sterlingcrispin/nothing-ever-happens as a
# new entry in releases.json (the JSON version table the flake reads). Never
# hand-edits the version data in flake.nix.
#
# nothing-ever-happens has NO release tags, so:
#   key     = short (7-char) upstream commit hash
#   version = "<base>-unstable-<commit-date>" (base taken from the current latest
#             entry; nixpkgs uses "0" when a project has no tagged release)
#
# The single fetchFromGitHub source hash is recomputed from scratch via
# nix-prefetch-url and stored on the entry as ".hash".
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly OWNER="sterlingcrispin"
readonly REPO="nothing-ever-happens"
readonly BIN_NAME="nothing-ever-happens"
readonly REPO_URL="https://github.com/${OWNER}/${REPO}.git"
readonly GITHUB_API_BASE="https://api.github.com"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  for t in curl git nix nix-prefetch-url jq python3; do
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

get_latest_commit_sha() {
  git ls-remote "$REPO_URL" HEAD | awk 'NR==1{print $1}'
}

# Resolve a ref/rev to its full 40-char sha via the commits API (also validates).
resolve_full_sha() {
  local ref="$1" sha
  sha="$(git ls-remote "$REPO_URL" "$ref" | awk 'NR==1{print $1}')"
  [ -n "$sha" ] || sha="$ref"  # allow a raw (possibly short) rev
  curl -fsSL "$GITHUB_API_BASE/repos/$OWNER/$REPO/commits/$sha" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])'
}

get_commit_date() {
  local sha="$1"
  curl -fsSL "$GITHUB_API_BASE/repos/$OWNER/$REPO/commits/${sha}" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["commit"]["committer"]["date"][:10])'
}

prefetch_source_hash_sri() {
  local sha="$1"
  local url="https://github.com/${OWNER}/${REPO}/archive/${sha}.tar.gz"
  local hash
  hash="$(nix-prefetch-url --type sha256 --unpack "$url" 2>/dev/null | tail -n1)"
  nix hash to-sri --type sha256 "$hash"
}

# Append/upsert an entry into releases.json and set .latest (atomic tmp+mv).
upsert_release_entry() {
  local key="$1"
  local entry_json="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg k "$key" --argjson e "$entry_json" \
    '.versions[$k] = $e | .latest = $k' "$releases_file" >"$tmp"
  mv "$tmp" "$releases_file"
}

verify_build() {
  local sanitized_key="$1"
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build ".#${BIN_NAME}_${sanitized_key}" --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for ${BIN_NAME}_${sanitized_key}"
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
    git -C "$pkg_dir" diff --stat releases.json 2>/dev/null || true
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
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest upstream commit of sterlingcrispin/nothing-ever-happens to
releases.json (the JSON version table read by flake.nix) and sets it as .latest.
Recomputes the fetchFromGitHub source hash and upserts via jq — the version data
in flake.nix is never touched.

Options:
  --rev VALUE         Pin to a specific git ref/branch/rev instead of HEAD
                        (aliases: --revision, --version)
  --check             Only check for updates (exit 1 if update available)
  --no-build          Skip build verification
  --no-commit         Do not auto-commit (default: auto-commit is enabled)
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --rev main
EOF
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
  if [ -z "$cur_latest_key" ] || [ "$cur_latest_key" = "null" ]; then
    log_error "Failed to detect current latest key from releases.json"
    exit 2
  fi
  # Base = version part before "-unstable-" (e.g. "0"); the project has no tags,
  # so we preserve whatever base the current latest entry already uses.
  base="${cur_latest_ver%%-unstable-*}"
  [ -n "$base" ] || base="0"

  local rev date short_key new_version
  if [ -n "$target_ref" ]; then
    rev="$(resolve_full_sha "$target_ref")"
  else
    rev="$(get_latest_commit_sha)"
  fi
  [ -n "$rev" ] && [ "$rev" != "null" ] || { log_error "could not resolve upstream rev"; exit 2; }
  date="$(get_commit_date "$rev")"
  [ -n "$date" ] || { log_error "could not resolve commit date for $rev"; exit 2; }
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
    log_info "Update available: ${cur_latest_key} -> ${short_key}"
    exit 1
  fi

  log_info "Computing fetchFromGitHub source hash..."
  local src_hash
  src_hash="$(prefetch_source_hash_sri "$rev")"
  [ -n "$src_hash" ] || { log_error "Failed to prefetch source hash for ${rev}"; exit 1; }
  log_info "  src hash: $src_hash"

  local entry_json
  entry_json="$(jq -n \
    --arg v "$new_version" \
    --arg rev "$rev" \
    --arg hash "$src_hash" \
    '{version: $v, rev: $rev, hash: $hash}')"

  local backup
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  upsert_release_entry "$short_key" "$entry_json"

  local sanitized_key
  sanitized_key="$(sanitize_key "$short_key")"

  if [ "$no_build" != true ]; then
    if ! verify_build "$sanitized_key"; then
      log_error "Build verification failed; restoring previous releases.json"
      cp "$backup" "$releases_file"
      rm -f "$backup"
      exit 1
    fi
  fi

  rm -f "$backup"

  show_changes

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

  log_info "Done."
}

main "$@"
