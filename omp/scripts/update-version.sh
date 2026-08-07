#!/usr/bin/env bash
# Appends the newest (or an explicit) omp GitHub release to releases.json
# (the JSON version table read by flake.nix) and sets it as .latest. Never
# hand-edits the version data in flake.nix.
#
# Each release also records .schemaSha256, coupling it to the committed,
# statically extracted schema/upstream.json artifact (see schema/README.md).
# Schema evidence is extracted from the host-platform release binary WITHOUT
# executing it; structural drift (removed keys, type changes, removed enum
# values) aborts the update with exit 3 unless --accept-schema-drift is
# passed after review. A clean update still fails at the end if
# modules/defaults.nix was not reviewed for the new version (its
# schemaVersion marker must match).
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly REPO_OWNER="can1357"
readonly REPO_NAME="oh-my-pi"
readonly BIN_NAME="omp"
readonly TAG_PREFIX="v"

declare -Ar SYSTEM_TO_RELEASE_PLATFORM=(
  [x86_64-linux]="linux-x64"
  [aarch64-linux]="linux-arm64"
  [x86_64-darwin]="darwin-x64"
  [aarch64-darwin]="darwin-arm64"
)

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
schema_dir="${pkg_dir}/schema"
schema_file="${schema_dir}/upstream.json"
schema_hash_file="${schema_dir}/upstream.sha256"
schema_extractor="${script_dir}/extract-config-schema.mjs"
schema_comparator="${script_dir}/compare-config-schema.mjs"
schema_verifier="${script_dir}/verify-config-schema.mjs"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  command -v curl >/dev/null 2>&1 || { log_error "curl is required but not installed."; exit 2; }
  command -v jq >/dev/null 2>&1 || { log_error "jq is required but not installed."; exit 2; }
  command -v node >/dev/null 2>&1 || { log_error "node is required but not installed."; exit 2; }
}

ensure_in_package_directory() {
  [ -f "$flake_file" ] || { log_error "flake.nix not found at: $flake_file"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at: $releases_file"; exit 2; }
  [ -f "$schema_extractor" ] || { log_error "schema extractor not found at: $schema_extractor"; exit 2; }
  [ -f "$schema_comparator" ] || { log_error "schema comparator not found at: $schema_comparator"; exit 2; }
  [ -f "$schema_verifier" ] || { log_error "schema verifier not found at: $schema_verifier"; exit 2; }
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
  local effective_url
  effective_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest")"
  printf '%s\n' "${effective_url##*/}"
}

tag_to_version() {
  local tag="$1"
  tag="${tag#${TAG_PREFIX}}"
  printf '%s\n' "$tag"
}

asset_url() {
  local version="$1"
  local platform="$2"
  printf 'https://github.com/%s/%s/releases/download/%s%s/omp-%s\n' "$REPO_OWNER" "$REPO_NAME" "$TAG_PREFIX" "$version" "$platform"
}

prefetch_sha256_sri() {
  nix store prefetch-file --json --hash-type sha256 "$1" \
    | jq -r '.hash'
}

# Release platform for the machine running this script (schema evidence is
# extracted from the host binary; the embedded sources are arch-independent).
host_release_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os:$arch" in
    Linux:x86_64) printf 'linux-x64' ;;
    Linux:aarch64 | Linux:arm64) printf 'linux-arm64' ;;
    Darwin:x86_64) printf 'darwin-x64' ;;
    Darwin:arm64) printf 'darwin-arm64' ;;
    *) return 1 ;;
  esac
}

# Statically extract the settings-registry evidence from a release binary
# into "$2"/upstream.json + upstream.sha256 (never executes the binary).
extract_schema_evidence() {
  local binary="$1" staging="$2" version="$3"
  node "$schema_extractor" \
    --binary "$binary" \
    --version "$version" \
    --output "$staging/upstream.json" \
    --hash-output "$staging/upstream.sha256" \
    >"$staging/schema-metadata.json"
  node "$schema_verifier" \
    --schema "$staging/upstream.json" \
    --hash "$staging/upstream.sha256" \
    >"$staging/schema-verification.json"
}

classify_schema_drift() {
  local candidate="$1"
  if [ ! -f "$schema_file" ] || [ ! -f "$schema_hash_file" ]; then
    printf '%s\n' '{"classification":"structural","reason":"no-baseline"}'
    return 20
  fi
  node "$schema_verifier" --schema "$schema_file" --hash "$schema_hash_file" >/dev/null
  node "$schema_comparator" --baseline "$schema_file" --candidate "$candidate"
}

install_schema_candidate() {
  local staging="$1" schema_tmp hash_tmp
  mkdir -p "$schema_dir"
  schema_tmp="$(mktemp "${schema_dir}/.upstream.json.XXXXXX")"
  hash_tmp="$(mktemp "${schema_dir}/.upstream.sha256.XXXXXX")"
  cp "$staging/upstream.json" "$schema_tmp"
  cp "$staging/upstream.sha256" "$hash_tmp"
  chmod 0644 "$schema_tmp" "$hash_tmp"
  mv "$schema_tmp" "$schema_file"
  mv "$hash_tmp" "$schema_hash_file"
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
  if ! out_path="$(cd "$pkg_dir" && nix build ".#omp_${sanitized_key}" --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for omp_${sanitized_key}"
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

verify_flake_schema_contract() {
  local expected_version="$1" evaluated_version
  if ! evaluated_version="$(
    nix eval --raw --impure --no-write-lock-file \
      "path:${pkg_dir}#lib.upstreamConfigSchema.package.version"
  )"; then
    log_error "The Nix module defaults have not been reviewed for $expected_version"
    log_error "Review modules/defaults.nix against schema/upstream.json and set its schemaVersion marker to $expected_version."
    return 1
  fi
  if [ "$evaluated_version" != "$expected_version" ]; then
    log_error "Flake schema version mismatch: expected $expected_version, got $evaluated_version"
    return 1
  fi
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat releases.json 2>/dev/null || true
  fi
}

# sanitize a JSON key into a valid nix attribute-name suffix (mirrors flake.nix)
sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
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

Appends the newest (or an explicit) omp GitHub release to releases.json as a
new version-table entry (keyed by version) and sets .latest to it. Existing
entries are preserved so consumers can still select past versions. Each entry
records .schemaSha256, coupling it to the committed schema/upstream.json
artifact; structural schema drift aborts the update unless accepted after
review.

Options:
  --version VERSION   Append a specific version (default: latest)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute release asset hashes for current latest version
  --no-build          Skip build verification
  --accept-schema-drift
                      Continue after reviewing structural schema drift
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 16.3.2
  ./scripts/update-version.sh --version 17.3.0 --accept-schema-drift
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local target_version=""
  local check_only=false
  local rehash=false
  local no_build=false
  local accept_schema_drift=false

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
      --accept-schema-drift)
        accept_schema_drift=true
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

  local current_version latest_version latest_tag
  current_version="$(get_current_version)"
  if [ -z "$current_version" ]; then
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi

  if [ -n "$target_version" ]; then
    latest_version="$target_version"
  else
    latest_tag="$(get_latest_release_tag)"
    latest_version="$(tag_to_version "$latest_tag")"
  fi
  if [ -z "$latest_version" ]; then
    log_error "Failed to fetch latest version"
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

  if has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ] && [ "$rehash" = false ] \
    && [ -n "$(jq -r --arg k "$latest_version" '.versions[$k].schemaSha256 // empty' "$releases_file")" ]; then
    log_info "Already up to date!"
    exit 0
  fi

  # Prefetch per-system hashes.
  local system platform url hash
  local hashes_json="{}"
  for system in "${!SYSTEM_TO_RELEASE_PLATFORM[@]}"; do
    platform="${SYSTEM_TO_RELEASE_PLATFORM[$system]}"
    url="$(asset_url "$latest_version" "$platform")"
    log_info "Prefetching omp asset for $system..."
    hash="$(prefetch_sha256_sri "$url")"
    if [ -z "$hash" ] || [ "$hash" = "null" ]; then
      log_error "Failed to prefetch omp for $system"
      exit 2
    fi
    log_info "  $system hash: $hash"
    hashes_json="$(jq -n --argjson h "$hashes_json" --arg s "$system" --arg v "$hash" \
      '$h + {($s): $v}')"
  done

  # Stage the host-platform binary and statically extract schema evidence.
  local staging host_platform
  staging="$(mktemp -d -t "omp-${latest_version}.schema.XXXXXX")"
  host_platform="$(host_release_platform || true)"
  if [ -z "$host_platform" ]; then
    log_error "Unsupported host platform for schema extraction"
    rm -rf "$staging"
    exit 2
  fi
  log_info "Downloading host binary for schema extraction..."
  if ! curl -fsSL "$(asset_url "$latest_version" "$host_platform")" -o "$staging/omp"; then
    log_error "Failed to download host binary for schema extraction"
    rm -rf "$staging"
    exit 2
  fi
  log_info "Extracting configuration schema without executing omp..."
  if ! extract_schema_evidence "$staging/omp" "$staging" "$latest_version"; then
    log_error "Static schema extraction failed; staging retained for inspection: $staging"
    exit 2
  fi
  local schema_sha
  schema_sha="$(tr -d '\n' <"$staging/upstream.sha256")"
  if [ -z "$schema_sha" ] || ! printf '%s' "$schema_sha" | grep -Eq '^sha256-[A-Za-z0-9+/]+={0,2}$'; then
    log_error "Extractor returned an invalid schemaSha256"
    rm -rf "$staging"
    exit 2
  fi
  log_info "Schema evidence: $(jq -c '{packageVersion,settings,hash}' "$staging/schema-metadata.json")"

  local drift_output drift_status
  if drift_output="$(classify_schema_drift "$staging/upstream.json")"; then
    drift_status=0
  else
    drift_status=$?
  fi
  case "$drift_status" in
    0)
      log_info "Schema drift: $(printf '%s' "$drift_output" | jq -r '.classification')" ;;
    10)
      log_info "Schema drift: catalog-only (allowed)" ;;
    20)
      if [ "$accept_schema_drift" != true ]; then
        log_error "Structural configuration-schema drift requires review."
        log_error "Candidate retained at: $staging/upstream.json"
        log_error "After reviewing modules/defaults.nix, rerun with --accept-schema-drift."
        exit 3
      fi
      log_warn "Accepting reviewed structural schema drift: $drift_output" ;;
    *)
      log_error "Could not validate the checked-in schema baseline"
      rm -rf "$staging"
      exit 2 ;;
  esac

  local recorded_schema_sha
  recorded_schema_sha="$(jq -r --arg k "$latest_version" '.versions[$k].schemaSha256 // empty' "$releases_file")"
  if has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ] && [ "$rehash" = false ] \
    && [ "$recorded_schema_sha" = "$schema_sha" ]; then
    log_info "Already up to date; package metadata and schemaSha256 verified."
    rm -rf "$staging"
    exit 0
  fi

  local entry_json
  entry_json="$(jq -n \
    --arg v "$latest_version" \
    --arg rev "$latest_version" \
    --arg schemaSha256 "$schema_sha" \
    --argjson hashes "$hashes_json" \
    '{version: $v, rev: $rev, hashes: $hashes, schemaSha256: $schemaSha256}')"

  local backup had_schema=false had_schema_hash=false
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"
  if [ -f "$schema_file" ]; then cp "$schema_file" "$backup.upstream.json"; had_schema=true; fi
  if [ -f "$schema_hash_file" ]; then cp "$schema_hash_file" "$backup.upstream.sha256"; had_schema_hash=true; fi

  restore_on_failure() {
    cp "$backup" "$releases_file"
    if [ "$had_schema" = true ]; then cp "$backup.upstream.json" "$schema_file"; else rm -f "$schema_file"; fi
    if [ "$had_schema_hash" = true ]; then cp "$backup.upstream.sha256" "$schema_hash_file"; else rm -f "$schema_hash_file"; fi
    rm -f "$backup" "$backup.upstream.json" "$backup.upstream.sha256"
  }

  upsert_release_entry "$latest_version" "$entry_json"
  install_schema_candidate "$staging"

  local sanitized_key
  sanitized_key="$(sanitize_key "$latest_version")"

  # The eval-time flake contract (artifact version/hash + Nix schemaVersion
  # marker) must hold before the build is even attempted.
  if ! verify_flake_schema_contract "$latest_version"; then
    log_error "Schema contract failed; restoring previous releases.json and schema evidence"
    restore_on_failure
    exit 1
  fi

  if [ "$no_build" != true ]; then
    if ! verify_build "$sanitized_key"; then
      log_error "Build verification failed; restoring previous releases.json and schema evidence"
      restore_on_failure
      exit 1
    fi
  fi

  local installed_schema_sha
  installed_schema_sha="$(jq -r --arg k "$latest_version" '.versions[$k].schemaSha256 // empty' "$releases_file")"
  node "$schema_verifier" \
    --schema "$schema_file" \
    --hash "$schema_hash_file" \
    --expected-version "$latest_version" \
    --expected-sha256 "$installed_schema_sha" \
    >/dev/null

  rm -f "$backup" "$backup.upstream.json" "$backup.upstream.sha256"
  rm -rf "$staging"

  show_changes

  maybe_git_commit "chore(${PACKAGE_DIR_NAME}): bump to ${latest_version}" \
    "releases.json" "schema/upstream.json" "schema/upstream.sha256"

  log_info "Successfully appended omp $latest_version (latest was $current_version)"
}

main "$@"
