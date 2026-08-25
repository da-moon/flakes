#!/usr/bin/env bash
# Appends the newest (or an explicit) lightdash release to releases.json.
# flake.nix builds darwin from upstream's native GitHub-release binary
# (no npm/lockfile involved) and linux from the npm tarball via
# importNpmLock (npm publishes no linux binary release), so this script
# populates both:
#   1. Prefetches the darwin GitHub-release asset hashes (arm64 + x64) —
#      fetchable from any host, not gated on running this on darwin.
#   2. Downloads the npm tarball, extracts it, strips devDependencies/
#      scripts from package.json, and generates a package-lock.json with
#      `npm install --package-lock-only` (Node 24 from nixpkgs), committing
#      package.json/package-lock.json/.npmrc under deps/<version> so the
#      flake can install every linux dependency offline via importNpmLock.
#
# The version data in flake.nix is never touched.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly NPM_REGISTRY_BASE="https://registry.npmjs.org/@lightdash/cli"
readonly PACKAGE_SCOPE="@lightdash"
readonly NPM_NAME="cli"
readonly GITHUB_RELEASES_BASE="https://github.com/lightdash/lightdash/releases/download"
# nix system -> upstream's darwin asset arch suffix
readonly -A DARWIN_ASSET_ARCH=(
  [aarch64-darwin]="arm64"
  [x86_64-darwin]="x64"
)

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
deps_dir="${pkg_dir}/deps"
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

# Current "latest" key recorded in the version table.
get_current_version() {
  jq -r '.latest // empty' "$releases_file"
}

# Does the table already have an entry for this key?
has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

get_latest_version() {
  curl -fsSL "$NPM_REGISTRY_BASE/latest" | jq -r '.version // empty'
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | jq -r '.hash // empty' \
    | head -n1
}

# Prefetch upstream's native darwin release binaries (arm64 + x64) for one
# version. Outputs a JSON object {aarch64-darwin: "sha256-...", x86_64-darwin:
# "sha256-..."} on stdout. Fails loudly if either asset is missing/unfetchable
# — a real upstream regression, not something to silently skip.
prefetch_darwin_hashes() {
  local version="$1"
  local result="{}"
  local system asset_arch url hash
  for system in "${!DARWIN_ASSET_ARCH[@]}"; do
    asset_arch="${DARWIN_ASSET_ARCH[$system]}"
    url="${GITHUB_RELEASES_BASE}/${version}/lightdash-cli-${version}-macos-${asset_arch}.tar.gz"
    log_info "Prefetching darwin (${system}) hash from ${url}..." >&2
    hash="$(prefetch_sha256_sri "$url")"
    if [ -z "$hash" ]; then
      log_error "Failed to prefetch darwin asset hash for ${system} from $url"
      return 1
    fi
    result="$(jq -n --argjson acc "$result" --arg k "$system" --arg v "$hash" '$acc + {($k): $v}')"
  done
  printf '%s' "$result"
}

# sanitize a JSON key into a valid nix attribute-name suffix (mirrors flake.nix)
sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
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

# Generate a committed dependency lock for the given version.
# Requires network access and writes into deps/<version>.
generate_deps_lock() {
  local version="$1"
  local tarball_url="$2"
  local version_deps_dir="${deps_dir}/${version}"

  log_info "Generating dependency lock for ${version}..."

  local tmp
  tmp="$(mktemp -d -t "${PACKAGE_DIR_NAME}-${version}-deps.XXXXXX")"
  trap 'rm -rf "${tmp:-}"' RETURN

  local tarball="${tmp}/cli-${version}.tgz"
  log_info "Downloading npm tarball..."
  curl -fsSL "$tarball_url" -o "$tarball"

  local extracted="${tmp}/package"
  mkdir -p "$extracted"
  tar -xzf "$tarball" -C "$extracted" --strip-components=1

  if [ ! -f "${extracted}/package.json" ]; then
    log_error "Tarball did not contain package.json"
    return 1
  fi

  # Strip devDependencies and scripts so the committed package.json is stable
  # and only production dependencies are locked.
  jq 'del(.devDependencies, .scripts)' "${extracted}/package.json" >"${tmp}/package.json"

  cp "${tmp}/package.json" "${extracted}/package.json"

  log_info "Running npm install --package-lock-only (Node 24)..."
  (
    cd "$extracted"
    nix shell nixpkgs#nodejs_24 -c \
      npm install --package-lock-only --ignore-scripts --legacy-peer-deps
  )

  if [ ! -f "${extracted}/package-lock.json" ]; then
    log_error "npm did not produce package-lock.json"
    return 1
  fi

  mkdir -p "$version_deps_dir"
  cp "${extracted}/package.json" "${version_deps_dir}/package.json"
  cp "${extracted}/package-lock.json" "${version_deps_dir}/package-lock.json"
  printf 'ignore-scripts=true\nlegacy-peer-deps=true\n' >"${version_deps_dir}/.npmrc"
}

verify_build() {
  local sanitized_key="$1"
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build ".#lightdash_${sanitized_key}" --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for lightdash_${sanitized_key}"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/lightdash" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/lightdash"
    return 1
  fi
  # default must also resolve (it points at the new .latest).
  if ! (cd "$pkg_dir" && nix build ".#default" --no-link --no-write-lock-file); then
    log_error "nix build failed for default"
    return 1
  fi
  timeout 10 "$out_path/bin/lightdash" --help >/dev/null 2>&1 || true
  log_info "Build successful!"
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat releases.json deps 2>/dev/null || true
  fi
}

build_commit_message() {
  local previous_version="$1"
  local new_version="$2"

  local scope
  scope="$(basename "$pkg_dir")"

  if [ "$previous_version" != "$new_version" ]; then
    printf 'chore(%s): bump to %s\n' "$scope" "$new_version"
  else
    printf 'chore(%s): rehash %s\n' "$scope" "$new_version"
  fi
}

# Stage new files so Nix flake evaluation (which reads from the git tree)
# can see them before the build verification runs.
stage_release_files() {
  if ! command -v git >/dev/null 2>&1; then
    return 0
  fi
  if ! git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  local -a paths=("$@")
  git -C "$pkg_dir" add -- "${paths[@]}"
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

Appends the newest (or an explicit) @lightdash/cli npm release to releases.json
and commits a pinned package-lock.json under deps/<version>. Existing entries
are preserved so consumers can still select past versions.

Options:
  --version VERSION   Append a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --no-build          Skip build verification
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 1.188.0
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local target_version=""
  local check_only=false
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
      --no-build)
        no_build=true
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

  local current_version
  current_version="$(get_current_version)"
  if [ -z "$current_version" ]; then
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi

  local latest_version
  if [ -n "$target_version" ]; then
    latest_version="$target_version"
  else
    latest_version="$(get_latest_version)"
  fi
  if [ -z "$latest_version" ]; then
    log_error "Failed to fetch latest version from npm"
    exit 2
  fi

  log_info "Current latest: $current_version"
  log_info "Target version:  $latest_version"

  if [ "$check_only" = true ]; then
    if has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: $current_version -> $latest_version"
    exit 1
  fi

  if has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ]; then
    log_info "Already up to date!"
    exit 0
  fi

  local tarball_url
  tarball_url="${NPM_REGISTRY_BASE}/-/${NPM_NAME}-${latest_version}.tgz"

  log_info "Prefetching tarball hash..."
  local tarball_hash
  tarball_hash="$(prefetch_sha256_sri "$tarball_url")"
  if [ -z "$tarball_hash" ]; then
    log_error "Failed to prefetch tarball hash from $tarball_url"
    exit 2
  fi
  log_info "tarball hash: $tarball_hash"

  local darwin_hashes_json
  if ! darwin_hashes_json="$(prefetch_darwin_hashes "$latest_version")"; then
    log_error "Failed to prefetch darwin release hashes for ${latest_version}"
    exit 2
  fi
  log_info "darwin hashes: $darwin_hashes_json"

  if ! generate_deps_lock "$latest_version" "$tarball_url"; then
    log_error "Failed to generate dependency lock for ${latest_version}"
    exit 1
  fi

  local entry_json
  entry_json="$(jq -n \
    --arg v "$latest_version" \
    --arg rev "$latest_version" \
    --arg tarballHash "$tarball_hash" \
    --argjson darwinHashes "$darwin_hashes_json" \
    '{version: $v, rev: $rev, tarballHash: $tarballHash, darwinHashes: $darwinHashes}')"

  local backup
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  upsert_release_entry "$latest_version" "$entry_json"

  local sanitized_key
  sanitized_key="$(sanitize_key "$latest_version")"

  local -a commit_paths=("releases.json" "deps/${latest_version}")
  stage_release_files "${commit_paths[@]}"

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

  maybe_git_commit "$(build_commit_message "$current_version" "$latest_version")" \
    "${commit_paths[@]}"

  log_info "Successfully appended lightdash ${latest_version} (latest was $current_version)"
}

main "$@"
