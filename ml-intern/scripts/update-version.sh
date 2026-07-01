#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly PYPI_PACKAGE="ml-intern"
readonly PACKAGE_ATTR="ml-intern"
readonly BIN_NAME="ml-intern"
readonly WHEEL_URL_VAR="mlInternWheelUrl"
readonly WHEEL_HASH_VAR="mlInternWheelHash"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v python3 >/dev/null 2>&1 || { log_error "python3 is required but not installed."; exit 2; }
  command -v sed >/dev/null 2>&1 || { log_error "sed is required but not installed."; exit 2; }
}

get_current_version() {
  python3 - "$flake_file" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
match = re.search(r'pname = "ml-intern";\s*version = "([^"]+)";', text)
if not match:
    raise SystemExit("Could not find ml-intern version")
print(match.group(1))
PY
}

get_latest_version_from_pypi() {
  python3 - "$PYPI_PACKAGE" <<'PY'
import json
import sys
import urllib.request

package = sys.argv[1]
with urllib.request.urlopen(f"https://pypi.org/pypi/{package}/json") as response:
    data = json.load(response)
print(data["info"]["version"])
PY
}

get_wheel_url_for_version() {
  local version="$1"
  python3 - "$PYPI_PACKAGE" "$version" <<'PY'
import json
import sys
import urllib.request

package, version = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(f"https://pypi.org/pypi/{package}/{version}/json") as response:
    data = json.load(response)

for file_info in data["urls"]:
    if (
        file_info["packagetype"] == "bdist_wheel"
        and file_info["python_version"] == "py3"
        and file_info["filename"].endswith("py3-none-any.whl")
    ):
        print(file_info["url"])
        break
else:
    raise SystemExit("No universal py3 wheel found")
PY
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' \
    | head -n1
}

update_flake_version() {
  local new_version="$1"
  python3 - "$flake_file" "$new_version" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
new_version = sys.argv[2]
text = path.read_text()
text, count = re.subn(
    r'(pname = "ml-intern";\s*version = ")[^"]+(";)',
    rf"\g<1>{new_version}\2",
    text,
    count=1,
)
if count != 1:
    raise SystemExit("Could not update ml-intern version")
path.write_text(text)
PY
}

update_wheel_url() {
  local new_url="$1"
  sed -i.bak -E "s|^([[:space:]]*${WHEEL_URL_VAR} = \")[^\"]*(\";)|\\1${new_url}\\2|" "$flake_file"
}

update_wheel_hash() {
  local new_hash="$1"
  sed -i.bak -E "s|^([[:space:]]*${WHEEL_HASH_VAR} = \")[^\"]*(\";)|\\1${new_hash}\\2|" "$flake_file"
}

cleanup_backups() {
  rm -f "${flake_file}.bak" 2>/dev/null || true
}
trap cleanup_backups EXIT

verify_build() {
  log_info "Verifying build..."
  local out_path
  out_path="$(cd "$pkg_dir" && nix build ".#${PACKAGE_ATTR}" --no-link --print-out-paths --no-write-lock-file)"
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/$BIN_NAME"
    return 1
  fi
  log_info "Build successful."
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

print_usage() {
  cat <<'USAGE'
Usage: ./scripts/update-version.sh [OPTIONS]

Options:
  --version VERSION   Update to a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute the wheel hash for the current version
  --no-build          Skip build verification
  --help              Show this help message
USAGE
}

main() {
  ensure_required_tools_installed
  [ -f "$flake_file" ] || { log_error "flake.nix not found at: $flake_file"; exit 2; }

  local target_version="" check_only=false rehash=false no_build=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        target_version="$2"
        shift 2
        ;;
      --check) check_only=true; shift ;;
      --rehash) rehash=true; shift ;;
      --no-build) no_build=true; shift ;;
      --help) print_usage; exit 0 ;;
      *) log_error "Unknown option: $1"; print_usage; exit 2 ;;
    esac
  done

  local current_version new_version
  current_version="$(get_current_version)"
  new_version="${target_version:-$(get_latest_version_from_pypi)}"
  log_info "Current version: $current_version"
  log_info "Target version:  $new_version"

  if [ "$check_only" = true ]; then
    [ "$current_version" = "$new_version" ] && exit 0
    log_warn "Update available: $current_version -> $new_version"
    exit 1
  fi

  if [ "$current_version" = "$new_version" ] && [ "$rehash" != true ]; then
    log_info "Already up to date."
    exit 0
  fi

  local backup wheel_url wheel_hash
  backup="$(mktemp -t flake.nix.backup.XXXXXX)"
  cp "$flake_file" "$backup"

  wheel_url="$(get_wheel_url_for_version "$new_version")"
  wheel_hash="$(prefetch_sha256_sri "$wheel_url")"
  [ -n "$wheel_hash" ] || { log_error "Failed to prefetch wheel hash"; cp "$backup" "$flake_file"; rm -f "$backup"; exit 1; }

  update_flake_version "$new_version"
  update_wheel_url "$wheel_url"
  update_wheel_hash "$wheel_hash"
  cleanup_backups

  if [ "$no_build" != true ]; then
    if ! verify_build; then
      cp "$backup" "$flake_file"
      rm -f "$backup"
      exit 1
    fi
  fi

  rm -f "$backup"

  maybe_git_commit "$(build_commit_message "$current_version" "$new_version" "$rehash")" "flake.nix"
}

main "$@"
