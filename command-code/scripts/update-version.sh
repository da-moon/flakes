#!/usr/bin/env bash
# Appends the newest (or an explicit) command-code npm release to releases.json
# (the JSON version table read by flake.nix) and sets it as .latest. Never
# hand-edits the version data in flake.nix.
#
# command-code IS tagged (npm versions), so:
#   key     = the npm version (e.g. "0.40.17"); kind = tag-based
#   version = the same npm version
#
# Two kinds of fixed-output hashes live in each entry:
#   - .hash             : the npm tarball hash (fetchurl, arch-agnostic)
#   - .npmDepsHashes.*  : per-system "npm install --production" FOD hash. Only
#                         the build system's hash is recomputed here; other
#                         arches keep a lib.fakeHash placeholder until built.
# The release also records .schemaSha256, which couples it to the canonical,
# statically extracted schema/upstream.json artifact.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly NPM_REGISTRY_URL="${COMMAND_CODE_NPM_REGISTRY_URL:-https://registry.npmjs.org}"
readonly NPM_PACKAGE="command-code"
readonly PACKAGE_ATTR="command-code"
readonly BIN_NAME="command-code"
# lib.fakeHash — the sentinel nix rejects, forcing it to print the real "got:" hash.
readonly FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# command-code declares an unfree license; allow it for local build verification.
export NIXPKGS_ALLOW_UNFREE=1

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
PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"
readonly PACKAGE_DIR_NAME
# Which system's npmDeps hash to (re)compute — the host we build on.
BUILD_SYSTEM="$(nix eval --raw --impure --expr 'builtins.currentSystem' 2>/dev/null || echo x86_64-linux)"

# Rollback transaction state. These MUST stay script-global: when `set -e`
# aborts main(), the EXIT trap fires after main's local scope is gone, so a
# local would be unbound (under `set -u`) exactly when rollback needs it.
backup_dir=""
staging=""
transaction_active=false
had_schema=false
had_schema_hash=false

ensure_required_tools_installed() {
  for t in nix curl jq node tar; do
    command -v "$t" >/dev/null 2>&1 || { log_error "$t is required but not installed."; exit 2; }
  done
}

ensure_in_package_directory() {
  [ -f "$flake_file" ] || { log_error "flake.nix not found at: $flake_file"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at: $releases_file"; exit 2; }
  [ -x "$schema_extractor" ] || [ -f "$schema_extractor" ] || { log_error "schema extractor not found at: $schema_extractor"; exit 2; }
  [ -f "$schema_comparator" ] || { log_error "schema comparator not found at: $schema_comparator"; exit 2; }
  [ -f "$schema_verifier" ] || { log_error "schema verifier not found at: $schema_verifier"; exit 2; }
}

extract_schema_evidence() {
  local tarball="$1" staging="$2"
  mkdir -p "$staging/package-root"
  tar -xzf "$tarball" -C "$staging/package-root"
  local package_dir="$staging/package-root/package"
  [ -f "$package_dir/package.json" ] || {
    log_error "npm tarball does not contain package/package.json"
    return 2
  }
  node "$schema_extractor" \
    --package-dir "$package_dir" \
    --output "$staging/upstream.json" \
    --hash-output "$staging/upstream.sha256" \
    >"$staging/schema-metadata.json"
  node "$schema_verifier" \
    --schema "$staging/upstream.json" \
    --hash "$staging/upstream.sha256" \
    --package-dir "$package_dir" \
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

sanitize_key() {
  # mirror flake.nix: replace . - + with _  ('-' kept last so tr treats it literally)
  printf '%s' "$1" | tr '.+-' '___'
}

extract_got_hash() {
  sed -n 's~.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*~\1~p' | head -n1
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

get_latest_version_from_npm() {
  local latest_json
  latest_json="$(curl -fsSL "$NPM_REGISTRY_URL/$NPM_PACKAGE/latest")"
  printf '%s\n' "$latest_json" | jq -r '.version // empty'
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | jq -r '.hash // empty'
}

# Recompute a fixed-output hash by building the target attr with FAKE_HASH
# already written into releases.json and parsing nix's "got:" line.
build_and_get_hash() {
  local attr="$1" out
  out="$(nix build "path:${pkg_dir}#${attr}" --impure --no-write-lock-file --no-link 2>&1 || true)"
  printf '%s\n' "$out" | extract_got_hash
}

verify_build() {
  local attr="$1"
  log_info "Verifying build of ${attr}..."
  local out_path
  if ! out_path="$(nix build "path:${pkg_dir}#${attr}" --impure --no-write-lock-file --no-link --print-out-paths)"; then
    log_error "nix build failed for ${attr}"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/$BIN_NAME"
    return 1
  fi
  # default must also resolve (it points at the new .latest).
  if ! nix build "path:${pkg_dir}#default" --impure --no-write-lock-file --no-link; then
    log_error "nix build failed for default"
    return 1
  fi
  log_info "Build successful!"
}

verify_flake_schema_contract() {
  local expected_version="$1" evaluated_version
  if ! evaluated_version="$(
    nix eval --raw --impure --no-write-lock-file \
      "path:${pkg_dir}#lib.configSchema.package.version"
  )"; then
    log_error "The Nix module schema has not been reviewed for $expected_version"
    return 1
  fi
  if [ "$evaluated_version" != "$expected_version" ]; then
    log_error "Flake schema version mismatch: expected $expected_version, got $evaluated_version"
    return 1
  fi
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) command-code npm release to releases.json
(the JSON version table read by flake.nix) and sets it as .latest. Recomputes
both the npm tarball hash and the per-system npmDeps FOD hash via jq — the
version data in flake.nix is never touched.

Options:
  --version VERSION   Append a specific version (default: latest npm version)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute hashes for the current latest version
  --no-build          Skip build verification
  --accept-schema-drift
                      Continue after reviewing structural schema drift
  --no-commit         Do not auto-commit (default: auto-commit is enabled)
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 0.40.17
  ./scripts/update-version.sh --version 0.51.0 --accept-schema-drift
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
  log_info "Updating package: ${PACKAGE_DIR_NAME} (build system: ${BUILD_SYSTEM})"

  local target_version="" check_only=false rehash=false no_build=false do_commit=true accept_schema_drift=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        target_version="$2"; shift 2 ;;
      --check) check_only=true; shift ;;
      --rehash) rehash=true; shift ;;
      --no-build) no_build=true; shift ;;
      --accept-schema-drift) accept_schema_drift=true; shift ;;
      --no-commit) do_commit=false; shift ;;
      --help) print_usage; exit 0 ;;
      *) log_error "Unknown option: $1"; print_usage; exit 2 ;;
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
    latest_version="$(get_latest_version_from_npm)"
    if [ -z "$latest_version" ]; then
      log_error "Failed to fetch latest version from npm"
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

  local tarball_url
  tarball_url="$NPM_REGISTRY_URL/$NPM_PACKAGE/-/$NPM_PACKAGE-$latest_version.tgz"
  staging="$(mktemp -d -t "command-code-${latest_version}.schema.XXXXXX")"
  log_info "Staging release and schema evidence in: $staging"
  if ! curl -fsSL "$tarball_url" -o "$staging/package.tgz"; then
    log_error "Failed to download npm tarball"
    rm -rf "$staging"
    exit 2
  fi

  log_info "Extracting configuration schema without executing Command Code..."
  if ! extract_schema_evidence "$staging/package.tgz" "$staging"; then
    log_error "Static schema extraction failed; staging retained for inspection: $staging"
    exit 2
  fi
  local schema_sha schema_metadata
  schema_sha="$(tr -d '\n' <"$staging/upstream.sha256")"
  schema_metadata="$(cat "$staging/schema-metadata.json")"
  if [ -z "$schema_sha" ] || ! printf '%s' "$schema_sha" | grep -Eq '^sha256-[A-Za-z0-9+/]+={0,2}$'; then
    log_error "Extractor returned an invalid schemaSha256"
    rm -rf "$staging"
    exit 2
  fi
  log_info "Schema evidence: $(printf '%s' "$schema_metadata" | jq -c '{packageVersion,entrypoint,hash,structuralHash,catalogHash}')"

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
        log_error "After review, rerun with --accept-schema-drift."
        exit 3
      fi
      log_warn "Accepting reviewed structural schema drift: $drift_output" ;;
    *)
      log_error "Could not validate the checked-in schema baseline"
      rm -rf "$staging"
      exit 2 ;;
  esac

  log_info "Prefetching tarball hash..."
  local tarball_hash
  tarball_hash="$(prefetch_sha256_sri "$tarball_url")"
  if [ -z "$tarball_hash" ]; then
    log_error "Failed to prefetch tarball hash"
    rm -rf "$staging"
    exit 2
  fi
  log_info "Tarball hash: $tarball_hash"

  local recorded_schema_sha
  recorded_schema_sha="$(jq -r --arg k "$latest_version" '.versions[$k].schemaSha256 // empty' "$releases_file")"
  if has_version_entry "$latest_version" \
    && [ "$current_version" = "$latest_version" ] \
    && [ "$rehash" != true ] \
    && [ "$recorded_schema_sha" = "$schema_sha" ]; then
    log_info "Already up to date; package metadata and schemaSha256 verified."
    rm -rf "$staging"
    exit 0
  fi

  local prior_hashes
  prior_hashes="$(jq -c --arg k "$latest_version" \
    '.versions[$k].npmDepsHashes // {}' "$releases_file")"

  backup_dir="$(mktemp -d -t command-code-update-backup.XXXXXX)"
  transaction_active=false
  had_schema=false
  had_schema_hash=false
  cp "$releases_file" "$backup_dir/releases.json"
  if [ -f "$schema_file" ]; then cp "$schema_file" "$backup_dir/upstream.json"; had_schema=true; fi
  if [ -f "$schema_hash_file" ]; then cp "$schema_hash_file" "$backup_dir/upstream.sha256"; had_schema_hash=true; fi

  rollback_update() {
    local status=$?
    if [ "$transaction_active" = true ]; then
      log_error "Update failed; restoring releases.json and schema evidence"
      cp "$backup_dir/releases.json" "$releases_file"
      if [ "$had_schema" = true ]; then cp "$backup_dir/upstream.json" "$schema_file"; else rm -f "$schema_file"; fi
      if [ "$had_schema_hash" = true ]; then cp "$backup_dir/upstream.sha256" "$schema_hash_file"; else rm -f "$schema_hash_file"; fi
    fi
    rm -rf "$backup_dir"
    [ "$status" -eq 3 ] || rm -rf "$staging"
  }
  trap rollback_update EXIT

  # Seed the entry: real tarball hash, fake npmDeps hash for the build system so
  # nix reveals the real one on build. Other arches keep their fake placeholder.
  local attr tmp
  attr="${PACKAGE_ATTR}_$(sanitize_key "$latest_version")"
  tmp="$staging/releases.json"
  jq --arg k "$latest_version" \
     --arg ver "$latest_version" \
     --arg rev "$latest_version" \
     --arg hash "$tarball_hash" \
     --arg fake "$FAKE_HASH" \
     --arg schemaSha256 "$schema_sha" \
     --arg bsys "$BUILD_SYSTEM" \
     --argjson prior "$prior_hashes" '
       .versions[$k] = {
         version: $ver,
         rev: $rev,
         hash: $hash,
         schemaSha256: $schemaSha256,
         npmDepsHashes: ({
           "x86_64-linux": $fake,
           "aarch64-linux": $fake,
           "x86_64-darwin": $fake,
           "aarch64-darwin": $fake
         } + $prior + { ($bsys): $fake })
       }
       | .latest = $k
     ' "$releases_file" >"$tmp"

  transaction_active=true
  local releases_tmp
  releases_tmp="$(mktemp "${pkg_dir}/.releases.json.XXXXXX")"
  cp "$staging/releases.json" "$releases_tmp"
  mv "$releases_tmp" "$releases_file"
  install_schema_candidate "$staging"

  # Compute the npmDeps FOD hash for the build system.
  log_info "Computing npmDeps hash for ${BUILD_SYSTEM}..."
  local npm_hash
  npm_hash="$(build_and_get_hash "$attr")"
  if [ -z "$npm_hash" ]; then
    # No mismatch printed => build already succeeded (hash was correct).
    log_info "  npmDeps hash already correct (no rehash needed)."
  else
    log_info "  npmDeps hash: $npm_hash"
    tmp="$(mktemp "${pkg_dir}/.releases.json.XXXXXX")"
    jq --arg k "$latest_version" --arg bsys "$BUILD_SYSTEM" --arg h "$npm_hash" \
      '.versions[$k].npmDepsHashes[$bsys] = $h' \
      "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"
  fi

  if [ "$no_build" != true ]; then
    if ! verify_build "$attr"; then
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
  verify_flake_schema_contract "$latest_version"

  transaction_active=false
  rm -rf "$backup_dir" "$staging"
  trap - EXIT

  log_info "releases.json now contains:"
  jq -r '.latest as $l | "  latest=" + $l, (.versions | keys[] | "  - " + .)' "$releases_file"

  if [ "$do_commit" = true ]; then
    local scope msg
    scope="$(basename "$pkg_dir")"
    if [ "$latest_version" = "$current_version" ]; then
      msg="chore(${scope}): rehash ${latest_version}"
    else
      msg="chore(${scope}): bump to ${latest_version}"
    fi
    maybe_git_commit "$msg" "releases.json" "schema/upstream.json" "schema/upstream.sha256"
  fi

  log_info "Successfully appended command-code $latest_version (latest was $current_version)"
}

main "$@"
