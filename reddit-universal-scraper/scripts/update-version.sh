#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly REPO_OWNER="ksanjeev284"
readonly REPO_NAME="reddit-universal-scraper"
readonly PACKAGE_ATTR="reddit-universal-scraper"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"

ensure_tools() {
  for tool in date git nix nix-prefetch-url sed; do
    command -v "$tool" >/dev/null 2>&1 || { log_error "$tool is required"; exit 2; }
  done
}

get_current_rev() {
  sed -n 's/^[[:space:]]*rev = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
}

get_current_version_label() {
  sed -n 's/^[[:space:]]*version = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
}

get_latest_rev() {
  git ls-remote "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" HEAD | awk '{ print $1 }'
}

prefetch_source_hash() {
  local rev="$1"
  local base32
  base32="$(nix-prefetch-url --unpack "https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/${rev}.tar.gz" | tail -n1)"
  nix hash to-sri --type sha256 "$base32"
}

update_flake() {
  local rev="$1"
  local hash="$2"
  local version_label="$3"
  cp -p "$flake_file" "${flake_file}.bak"
  sed -i -E "s/^([[:space:]]*version = \")[^\"]*(\";)/\\1${version_label}\\2/" "$flake_file"
  sed -i -E "s/^([[:space:]]*rev = \")[^\"]*(\";)/\\1${rev}\\2/" "$flake_file"
  sed -i -E "/src = pkgs\\.fetchFromGitHub[[:space:]]*\\{/,/\\};/ s|^([[:space:]]*hash = \")[^\"]*(\";)|\\1${hash}\\2|" "$flake_file"
}

verify_build() {
  log_info "Verifying build..."
  (cd "$pkg_dir" && nix build ".#${PACKAGE_ATTR}" --no-link --print-out-paths --no-write-lock-file)
}

build_commit_message() {
  local previous_version="$1"
  local new_version="$2"
  local rehash="${3:-false}"

  local scope
  scope="$(basename "$pkg_dir")"

  if [ "$previous_version" != "$new_version" ]; then
    printf 'chore(%s): bump to %s\n' "$scope" "$new_version"
    return 0
  fi

  if [ "$rehash" = true ]; then
    printf 'chore(%s): rehash %s\n' "$scope" "$new_version"
    return 0
  fi

  printf 'chore(%s): update version\n' "$scope"
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

usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [--revision REV | --version REV] [--check] [--rehash] [--no-build] [--help]

  --revision REV, --version REV  Pin to a specific git rev/ref (default: remote HEAD)
  --check                        Exit 0 if already up to date, 1 otherwise
  --rehash                       Re-fetch and rehash the current rev
  --no-build                     Skip the verification build
  --help                         Show this help
EOF
}

main() {
  ensure_tools
  local requested="" check=false rehash=false no_build=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --revision|--version)
        [ $# -ge 2 ] || { log_error "$1 requires an argument"; exit 2; }
        requested="$2"
        shift 2
        ;;
      --check) check=true; shift ;;
      --rehash) rehash=true; shift ;;
      --no-build) no_build=true; shift ;;
      --help) usage; exit 0 ;;
      *) log_error "Unknown option: $1"; usage; exit 2 ;;
    esac
  done

  local current current_version_label target hash new_version_label
  current="$(get_current_rev)"
  current_version_label="$(get_current_version_label)"
  target="${requested:-$(get_latest_rev)}"
  log_info "Current rev: ${current}"
  log_info "Target rev:  ${target}"

  if [ "$check" = true ]; then
    [ "$current" = "$target" ] && exit 0 || exit 1
  fi

  if [ "$current" = "$target" ] && [ "$rehash" = false ]; then
    log_info "reddit-universal-scraper is already at ${current}"
    exit 0
  fi

  # Only bump the version label when the rev actually changes; a pure rehash
  # keeps the existing unstable-DATE label.
  if [ "$current" != "$target" ]; then
    new_version_label="unstable-$(date -u +%Y-%m-%d)"
  else
    new_version_label="$current_version_label"
  fi

  hash="$(prefetch_source_hash "$target")"
  update_flake "$target" "$hash" "$new_version_label"

  if [ "$no_build" != true ]; then
    if ! verify_build; then
      log_error "build failed; restoring flake.nix"
      mv -f "${flake_file}.bak" "$flake_file"
      exit 1
    fi
  fi
  rm -f "${flake_file}.bak"

  log_info "Updated reddit-universal-scraper to ${target}"
  show_changes
  maybe_git_commit "$(build_commit_message "$current_version_label" "$new_version_label" "$rehash")" "flake.nix"
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$pkg_dir" --no-pager diff --stat flake.nix || true
  fi
}

main "$@"
