#!/usr/bin/env bash
# Appends the newest upstream commit of 6551Team/opennews-mcp as a new entry in
# releases.json (the JSON version table the flake reads). Never hand-edits the
# version data in flake.nix.
#
# opennews-mcp has NO release tags, so:
#   key     = short (7-char) upstream commit hash
#   version = "<base>-unstable-<commit-date>" (base taken from pyproject.toml at
#             the resolved rev, e.g. "0.1.0"; "0" if none is present). The rev
#             lives in the entry, so no trailing short-hash is kept in version.
#
# The single fetchFromGitHub source hash is recomputed from scratch via
# nix-prefetch-url on the archive tarball, then written back with jq.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly OWNER="6551Team"
readonly REPO="opennews-mcp"
readonly PACKAGE_ATTR="opennews-mcp"
readonly BIN_NAME="opennews-mcp"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  command -v curl >/dev/null 2>&1 || { log_error "curl is required but not installed."; exit 2; }
  command -v git >/dev/null 2>&1 || { log_error "git is required but not installed."; exit 2; }
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v nix-prefetch-url >/dev/null 2>&1 || { log_error "nix-prefetch-url is required but not installed."; exit 2; }
  command -v jq >/dev/null 2>&1 || { log_error "jq is required but not installed."; exit 2; }
}

ensure_in_package_directory() {
  [ -f "$flake_file" ] || { log_error "flake.nix not found at: $flake_file"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at: $releases_file"; exit 2; }
}

# mirror flake.nix: replace . - + with _  ('-' kept last so tr treats it literally)
sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
}

# Current "latest" key recorded in the version table.
get_current_key() {
  jq -r '.latest // empty' "$releases_file"
}

get_current_version() {
  local key="$1"
  jq -r --arg k "$key" '.versions[$k].version // empty' "$releases_file"
}

has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

get_latest_commit_sha() {
  git ls-remote "https://github.com/${OWNER}/${REPO}.git" HEAD | awk 'NR==1{print $1}'
}

get_commit_date() {
  local sha="$1"
  curl -fsSL "https://api.github.com/repos/${OWNER}/${REPO}/commits/${sha}" \
    | sed -n 's/.*"date":[[:space:]]*"\([0-9-]\{10\}\)T.*/\1/p' \
    | head -n1
}

get_base_version_for_rev() {
  local sha="$1"
  curl -fsSL "https://raw.githubusercontent.com/${OWNER}/${REPO}/${sha}/pyproject.toml" \
    | sed -n 's/^version = "\([^"]*\)".*/\1/p' \
    | head -n1
}

# Canonical no-tag version: "<base>-unstable-<commit-date>" (no trailing hash;
# the rev already lives in the entry).
build_version_string() {
  local base_version="$1"
  local commit_date="$2"
  printf '%s-unstable-%s\n' "$base_version" "$commit_date"
}

prefetch_source_hash_sri() {
  local sha="$1"
  local url="https://github.com/${OWNER}/${REPO}/archive/${sha}.tar.gz"
  local hash
  hash="$(nix-prefetch-url --type sha256 --unpack "$url" 2>/dev/null | tail -n1)"
  nix hash to-sri --type sha256 "$hash"
}

# Append/upsert an entry into releases.json and set .latest.
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
  if ! out_path="$(cd "$pkg_dir" && nix build ".#${PACKAGE_ATTR}_${sanitized_key}" --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for ${PACKAGE_ATTR}_${sanitized_key}"
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

Appends the newest (or an explicit) upstream commit of 6551Team/opennews-mcp to
releases.json (the JSON version table read by flake.nix) as a new entry keyed by
the short commit hash and sets .latest to it. Recomputes the fetchFromGitHub
source hash via jq — the version data in flake.nix is never touched.

Options:
  --rev VALUE        Pin to a specific git ref/branch/rev instead of HEAD
                       (aliases: --revision, --version)
  --check            Only check for updates (exit 1 if update available)
  --rehash           Recompute the source hash for the current latest entry
  --no-build         Skip build verification
  --no-commit        Do not auto-commit (default: auto-commit is enabled)
  --help             Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --rehash
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local target_ref="" check_only=false rehash=false no_build=false do_commit=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rev|--revision|--version)
        [ $# -ge 2 ] || { log_error "$1 requires an argument"; exit 2; }
        target_ref="$2"
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
      --no-commit)
        do_commit=false
        shift
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

  local cur_key cur_version
  cur_key="$(get_current_key)"
  if [ -z "$cur_key" ]; then
    log_error "Failed to detect current latest key from releases.json"
    exit 1
  fi
  cur_version="$(get_current_version "$cur_key")"

  # Resolve the target rev (HEAD unless a ref was pinned).
  local target_rev
  if [ -n "$target_ref" ]; then
    target_rev="$(git ls-remote "https://github.com/${OWNER}/${REPO}.git" "$target_ref" | awk 'NR==1{print $1}')"
    [ -n "$target_rev" ] || target_rev="$target_ref"  # allow a raw rev
  else
    target_rev="$(get_latest_commit_sha)"
  fi
  [ -n "$target_rev" ] || { log_error "Failed to resolve upstream rev"; exit 1; }

  local target_base target_date target_version short_key
  target_base="$(get_base_version_for_rev "$target_rev")"
  [ -n "$target_base" ] || target_base="0"
  target_date="$(get_commit_date "$target_rev")"
  [ -n "$target_date" ] || { log_error "Failed to resolve commit date for $target_rev"; exit 1; }

  target_version="$(build_version_string "$target_base" "$target_date")"
  short_key="${target_rev:0:7}"

  log_info "Current latest key:  $cur_key ($cur_version)"
  log_info "Resolved upstream:   $target_rev"
  log_info "New key:             $short_key"
  log_info "New version:         $target_version"

  if [ "$check_only" = true ]; then
    if has_version_entry "$short_key" && [ "$cur_key" = "$short_key" ] && [ "$rehash" != true ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: $cur_key -> $short_key"
    exit 1
  fi

  if has_version_entry "$short_key" && [ "$cur_key" = "$short_key" ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"
    exit 0
  fi

  log_info "Computing fetchFromGitHub source hash..."
  local source_hash
  source_hash="$(prefetch_source_hash_sri "$target_rev")"
  [ -n "$source_hash" ] || { log_error "Failed to prefetch source hash for ${target_rev}"; exit 1; }
  log_info "Source hash: $source_hash"

  local entry_json
  entry_json="$(jq -n \
    --arg v "$target_version" \
    --arg rev "$target_rev" \
    --arg hash "$source_hash" \
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

  local scope msg
  scope="$(basename "$pkg_dir")"
  if [ "$cur_key" = "$short_key" ]; then
    msg="chore(${scope}): rehash ${target_version} (${short_key})"
  else
    msg="chore(${scope}): add ${target_version} (${short_key}) to version table"
  fi

  if [ "$do_commit" = true ]; then
    maybe_git_commit "$msg" "releases.json"
  fi

  log_info "Done."
}

main "$@"
