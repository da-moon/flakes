#!/usr/bin/env bash
# Appends the newest (or an explicit) mcpdoc PyPI release to releases.json (the
# JSON version table read by flake.nix) and sets it as .latest. mcpdoc is a
# TAGGED upstream (PyPI versions), so:
#   key     = the PyPI version (e.g. "0.0.10")
#   version = the same PyPI version
# The fetchPypi source tarball is architecture-independent, so a single .hash is
# stored per entry. The version data in flake.nix is never hand-edited.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly PYPI_API_URL="https://pypi.org/pypi/mcpdoc/json"
readonly PACKAGE_NAME="mcpdoc"
readonly BIN_NAME="mcpdoc"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  for t in nix curl jq; do
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

# Current "latest" key recorded in the version table.
get_current_version() {
  jq -r '.latest // empty' "$releases_file"
}

# Does the table already have an entry for this key?
has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

get_latest_version_from_pypi() {
  local latest_json
  latest_json="$(curl -fsSL "$PYPI_API_URL")"
  printf '%s\n' "$latest_json" | jq -r '.info.version // empty'
}

get_package_url() {
  local version="$1"
  printf 'https://files.pythonhosted.org/packages/source/m/%s/%s-%s.tar.gz' \
    "$PACKAGE_NAME" "$PACKAGE_NAME" "$version"
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | jq -r '.hash // empty' \
    | head -n1
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
  if ! out_path="$(cd "$pkg_dir" && nix build ".#${PACKAGE_DIR_NAME}_${sanitized_key}" --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for ${PACKAGE_DIR_NAME}_${sanitized_key}"
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
  timeout 30 "$out_path/bin/$BIN_NAME" --help >/dev/null 2>&1 || true
  log_info "Build successful."
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
  cat <<'USAGE'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) mcpdoc PyPI release to releases.json as a new
version-table entry (keyed by version) and sets .latest to it. Existing entries
are preserved so consumers can still select past versions. The version data in
flake.nix is never touched.

Options:
  --version VERSION   Append a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute the source hash for the current latest version
  --no-build          Skip build verification
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --version 0.0.10
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --rehash
USAGE
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
      --help)
        print_usage
        exit 0
        ;;
      *)
        log_error "Unknown argument: $1"
        print_usage
        exit 2
        ;;
    esac
  done

  local current_version
  current_version="$(get_current_version)"
  if [ -z "$current_version" ]; then
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi

  local latest_version
  latest_version="$(get_latest_version_from_pypi)"
  if [ -z "$latest_version" ]; then
    log_error "Failed to fetch latest version from PyPI"
    exit 2
  fi

  local new_version="${target_version:-$latest_version}"
  log_info "Current latest: $current_version"
  log_info "Target version:  $new_version"

  local needs_update=false
  if ! has_version_entry "$new_version" || [ "$current_version" != "$new_version" ]; then
    needs_update=true
  fi

  if [ "$check_only" = true ]; then
    if [ "$needs_update" = true ]; then
      log_warn "Update available: $current_version -> $new_version"
      exit 1
    fi
    log_info "Already up to date!"
    exit 0
  fi

  if [ "$needs_update" = false ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"
    exit 0
  fi

  log_info "Computing source hash for $new_version..."
  local package_url new_hash
  package_url="$(get_package_url "$new_version")"
  new_hash="$(prefetch_sha256_sri "$package_url")"
  if [ -z "$new_hash" ]; then
    log_error "Failed to compute source hash for $new_version"
    exit 1
  fi
  log_info "  source hash: $new_hash"

  local entry_json
  entry_json="$(jq -n \
    --arg v "$new_version" \
    --arg rev "$new_version" \
    --arg hash "$new_hash" \
    '{version: $v, rev: $rev, hash: $hash}')"

  local backup
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  upsert_release_entry "$new_version" "$entry_json"

  local sanitized_key
  sanitized_key="$(sanitize_key "$new_version")"

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
  if [ "$current_version" != "$new_version" ]; then
    msg="chore(${scope}): bump to ${new_version}"
  elif [ "$rehash" = true ]; then
    msg="chore(${scope}): rehash ${new_version}"
  else
    msg="chore(${scope}): update version"
  fi
  maybe_git_commit "$msg" "releases.json"

  log_info "Successfully appended mcpdoc $new_version (latest was $current_version)"
}

main "$@"
