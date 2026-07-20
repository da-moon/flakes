#!/usr/bin/env bash
# Appends the newest (or an explicit) katanemo/plano release to releases.json
# (the JSON version table the flake reads) as a new entry keyed by version, and
# sets .latest to it. Existing entries are preserved so consumers can still
# select past versions. All hashes are recomputed via `nix store prefetch-file`
# and written with jq — the version data in flake.nix is never touched.
#
# plano ships TAGGED GitHub releases (bare version tags, e.g. "0.4.27"), so:
#   key     = the release version (e.g. "0.4.27")
#   version = the same
#   rev     = the same (used in release-asset URLs)
#
# Each entry carries every hash the flake needs:
#   - wheelHash                  : planoai PyPI wheel (host-independent).
#   - envoyVersion               : Envoy pin read from cli/planoai/consts.py at
#                                  the release tag.
#   - envoyHashes.<system>       : tetratelabs/archive-envoy tarballs.
#   - brightstaffHashes.<system> : katanemo/plano brightstaff-<slug>.gz assets.
#   - wasmHashes.<plugin>        : proxy-wasm filter .gz assets (host-independent).
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly GITHUB_API_BASE="https://api.github.com"
readonly REPO_OWNER="katanemo"
readonly REPO_NAME="plano"
readonly PYPI_NAME="planoai"
readonly ENVOY_REPO="tetratelabs/archive-envoy"
readonly PACKAGE_ATTR="plano"
# Systems with upstream native binaries (matches slugBySystem in flake.nix).
declare -Ar SLUG_BY_SYSTEM=(
  [x86_64-linux]="linux-amd64"
  [aarch64-linux]="linux-arm64"
  [aarch64-darwin]="darwin-arm64"
)
readonly WASM_PLUGINS=(prompt_gateway llm_gateway)

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

# Current "latest" key recorded in the version table.
get_current_version() {
  jq -r '.latest // empty' "$releases_file"
}

# Does the table already have an entry for this key?
has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

get_latest_release_tag() {
  local release_json
  release_json="$(curl -fsSL "$GITHUB_API_BASE/repos/$REPO_OWNER/$REPO_NAME/releases/latest")"
  printf '%s\n' "$release_json" | jq -r '.tag_name // empty'
}

tag_to_version() {
  local tag="$1"
  printf '%s\n' "${tag#v}"
}

# The Envoy version pinned by the CLI at a given release tag.
get_envoy_version() {
  local tag="$1"
  curl -fsSL "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$tag/cli/planoai/consts.py" \
    | sed -n 's/^ENVOY_VERSION = "\(.*\)".*/\1/p' \
    | head -n1
}

# URL of the planoai wheel for a given version on PyPI.
get_wheel_url() {
  local version="$1"
  curl -fsSL "https://pypi.org/pypi/$PYPI_NAME/json" \
    | jq -r --arg v "$version" '.releases[$v][] | select(.packagetype == "bdist_wheel") | .url' \
    | head -n1
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" | jq -r '.hash // empty'
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

verify_build() {
  local sanitized_key="$1"
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build ".#${PACKAGE_ATTR}_${sanitized_key}" --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for ${PACKAGE_ATTR}_${sanitized_key}"
    return 1
  fi
  if [ ! -x "$out_path/bin/planoai" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/planoai"
    return 1
  fi
  # default must also resolve (it points at the new .latest).
  if ! (cd "$pkg_dir" && nix build ".#default" --no-link --no-write-lock-file); then
    log_error "nix build failed for default"
    return 1
  fi
  # The pinned native runtime must carry every component the CLI looks for.
  local runtime_path rel
  if ! runtime_path="$(cd "$pkg_dir" && nix build ".#plano-runtime" --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for plano-runtime"
    return 1
  fi
  for rel in bin/envoy bin/brightstaff bin/envoy.version bin/brightstaff.version \
    plugins/prompt_gateway.wasm plugins/llm_gateway.wasm plugins/wasm.version; do
    if [ ! -e "$runtime_path/$rel" ]; then
      log_error "Runtime is missing expected file: $runtime_path/$rel"
      return 1
    fi
  done
  timeout 30 "$out_path/bin/planoai" --version >/dev/null 2>&1 || true
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

Appends the newest (or an explicit) katanemo/plano release to releases.json as a
new version-table entry (keyed by version) and sets .latest to it. Existing
entries are preserved so consumers can still select past versions. Recomputes
the PyPI wheel hash, the per-system Envoy and brightstaff hashes, and the
proxy-wasm filter hashes via jq — the version data in flake.nix is never
touched.

Options:
  --version VERSION   Append a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --no-build          Skip build verification
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 0.4.27
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

  local latest_tag latest_version
  if [ -n "$target_version" ]; then
    latest_version="$target_version"
    latest_tag="$target_version"
  else
    latest_tag="$(get_latest_release_tag)"
    if [ -z "$latest_tag" ]; then
      log_error "Failed to fetch latest release from GitHub"
      exit 2
    fi
    latest_version="$(tag_to_version "$latest_tag")"
    if [ -z "$latest_version" ]; then
      log_error "Failed to derive version from tag: $latest_tag"
      exit 2
    fi
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

  # The CLI pins an Envoy version per release; read it from consts.py at the tag.
  log_info "Resolving pinned Envoy version..."
  local envoy_version
  envoy_version="$(get_envoy_version "$latest_tag")"
  if [ -z "$envoy_version" ]; then
    log_error "Failed to resolve ENVOY_VERSION from cli/planoai/consts.py at $latest_tag"
    exit 2
  fi
  log_info "Envoy version:    $envoy_version"

  # Host-independent hashes: the planoai PyPI wheel and the proxy-wasm filters.
  log_info "Prefetching planoai wheel hash..."
  local wheel_url wheel_hash
  wheel_url="$(get_wheel_url "$latest_version")"
  if [ -z "$wheel_url" ]; then
    log_error "Failed to find a planoai $latest_version wheel on PyPI"
    exit 2
  fi
  wheel_hash="$(prefetch_sha256_sri "$wheel_url")"
  if [ -z "$wheel_hash" ]; then
    log_error "Failed to prefetch wheel hash from $wheel_url"
    exit 2
  fi
  log_info "wheel hash: $wheel_hash"

  local plugin url sri_hash
  local wasm_hashes_json="{}"
  for plugin in "${WASM_PLUGINS[@]}"; do
    url="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$latest_tag/$plugin.wasm.gz"
    sri_hash="$(prefetch_sha256_sri "$url")"
    if [ -z "$sri_hash" ]; then
      log_error "Failed to prefetch hash for $plugin.wasm.gz"
      exit 2
    fi
    log_info "$plugin.wasm.gz hash: $sri_hash"
    wasm_hashes_json="$(jq -n --argjson h "$wasm_hashes_json" --arg p "$plugin" --arg v "$sri_hash" \
      '$h + {($p): $v}')"
  done

  # Per-system hashes: brightstaff (plano release) and Envoy (archive-envoy).
  log_info "Prefetching per-system binary hashes..."
  local system slug
  local brightstaff_hashes_json="{}"
  local envoy_hashes_json="{}"
  for system in "${!SLUG_BY_SYSTEM[@]}"; do
    slug="${SLUG_BY_SYSTEM[$system]}"

    url="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$latest_tag/brightstaff-$slug.gz"
    sri_hash="$(prefetch_sha256_sri "$url")"
    if [ -z "$sri_hash" ]; then
      log_error "Failed to prefetch hash for brightstaff-$slug.gz ($system)"
      exit 2
    fi
    log_info "brightstaff $system hash: $sri_hash"
    brightstaff_hashes_json="$(jq -n --argjson h "$brightstaff_hashes_json" --arg s "$system" --arg v "$sri_hash" \
      '$h + {($s): $v}')"

    url="https://github.com/$ENVOY_REPO/releases/download/$envoy_version/envoy-$envoy_version-$slug.tar.xz"
    sri_hash="$(prefetch_sha256_sri "$url")"
    if [ -z "$sri_hash" ]; then
      log_error "Failed to prefetch hash for envoy-$envoy_version-$slug.tar.xz ($system)"
      exit 2
    fi
    log_info "envoy $system hash: $sri_hash"
    envoy_hashes_json="$(jq -n --argjson h "$envoy_hashes_json" --arg s "$system" --arg v "$sri_hash" \
      '$h + {($s): $v}')"
  done

  local entry_json
  entry_json="$(jq -n \
    --arg v "$latest_version" \
    --arg rev "$latest_version" \
    --arg wh "$wheel_hash" \
    --arg ev "$envoy_version" \
    --argjson eh "$envoy_hashes_json" \
    --argjson bh "$brightstaff_hashes_json" \
    --argjson wasm "$wasm_hashes_json" \
    '{
      version: $v,
      rev: $rev,
      wheelHash: $wh,
      envoyVersion: $ev,
      envoyHashes: $eh,
      brightstaffHashes: $bh,
      wasmHashes: $wasm
    }')"

  local backup
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  upsert_release_entry "$latest_version" "$entry_json"

  local sanitized_key
  sanitized_key="$(sanitize_key "$latest_version")"

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

  maybe_git_commit "chore(${PACKAGE_DIR_NAME}): bump to ${latest_version}" "releases.json"

  log_info "Successfully appended plano $latest_version (latest was $current_version)"
}

main "$@"
