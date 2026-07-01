#!/usr/bin/env bash
# Appends the newest @opengsd/gsd-pi npm release to releases.json (the JSON
# version table read by flake.nix) and sets it as .latest. Never hand-edits the
# version data in flake.nix.
#
# gsd-pi ships tagged npm releases, so:
#   key     = the npm version (e.g. "1.4.0")
#   version = the same npm version
#
# Two kinds of hashes are recomputed via jq:
#   - .hash            : the npm tarball fetchurl hash (single, arch-agnostic)
#   - .npmDepsHashes.* : per-system pnpm/npm fixed-output-derivation hash
#     (recomputed from the fakeHash -> nix build -> parse "got:" method for the
#      build host; other arches keep their existing hash or a fakeHash sentinel).
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly NPM_REGISTRY_URL="https://registry.npmjs.org"
readonly NPM_PACKAGE="@opengsd/gsd-pi"
readonly TARBALL_NAME="gsd-pi"
readonly PACKAGE_ATTR="gsd-2"
readonly BIN_NAME="gsd"
# lib.fakeHash — the sentinel nix rejects, forcing it to print the real "got:" hash.
readonly FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"
# Which system's npmDeps hash to (re)compute — the host we build on.
BUILD_SYSTEM="$(nix eval --raw --impure --expr 'builtins.currentSystem' 2>/dev/null || echo x86_64-linux)"

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
  curl -fsSL "$NPM_REGISTRY_URL/$NPM_PACKAGE/latest" \
    | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n1
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" \
    | sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' \
    | head -n1
}

# Recompute a fixed-output hash by building the target attr with a fake hash
# already written into releases.json and parsing nix's "got:" line.
build_and_get_hash() {
  local attr="$1" out
  out="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link 2>&1 || true)"
  printf '%s\n' "$out" | extract_got_hash
}

# Is the build-host's npmDeps hash currently a fakeHash sentinel?
current_hash_is_fake() {
  local key="$1"
  local h
  h="$(jq -r --arg k "$key" --arg s "$BUILD_SYSTEM" \
    '.versions[$k].npmDepsHashes[$s] // empty' "$releases_file")"
  [ -z "$h" ] || [ "$h" = "$FAKE_HASH" ]
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) @opengsd/gsd-pi npm release to releases.json
(the JSON version table read by flake.nix) and sets it as .latest. Recomputes the
npm tarball hash and the build-host npmDeps FOD hash via jq — the version data in
flake.nix is never touched.

Options:
  --version VERSION   Append a specific version (default: latest npm)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Recompute tarball + current-system npmDeps hash for latest
  --no-build          Skip final build verification
  --no-commit         Do not auto-commit (default: auto-commit is enabled)
  --help              Show this help message
EOF
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

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME} (build system: ${BUILD_SYSTEM})"

  local target_version="" check_only=false rehash=false no_build=false do_commit=true
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
      --no-commit) do_commit=false; shift ;;
      --help) print_usage; exit 0 ;;
      *) log_error "Unknown option: $1"; print_usage; exit 2 ;;
    esac
  done

  local current_version latest_version
  current_version="$(get_current_version)"
  if [ -z "$current_version" ]; then
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi
  latest_version="${target_version:-$(get_latest_version_from_npm)}"
  if [ -z "$latest_version" ]; then
    log_error "Failed to fetch latest version"
    exit 2
  fi

  log_info "Current latest: $current_version"
  log_info "Target version:  $latest_version"

  # Treat as "up to date" when the entry already exists, is the latest, and its
  # build-host hash is real (unless --rehash was requested).
  local up_to_date=false
  if has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ] \
    && ! current_hash_is_fake "$latest_version"; then
    up_to_date=true
  fi

  if [ "$check_only" = true ]; then
    if [ "$up_to_date" = true ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: $current_version -> $latest_version"
    exit 1
  fi

  if [ "$up_to_date" = true ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"
    exit 0
  fi

  local sanitized_key attr
  sanitized_key="$(sanitize_key "$latest_version")"
  attr="${PACKAGE_ATTR}_${sanitized_key}"

  # 1) npm tarball hash (arch-agnostic).
  local tarball_url tarball_hash
  tarball_url="$NPM_REGISTRY_URL/$NPM_PACKAGE/-/$TARBALL_NAME-$latest_version.tgz"
  log_info "Prefetching npm tarball hash..."
  tarball_hash="$(prefetch_sha256_sri "$tarball_url")"
  [ -n "$tarball_hash" ] || { log_error "Failed to prefetch tarball hash"; exit 1; }
  log_info "  tarball hash: $tarball_hash"

  # Preserve an existing aarch64 hash if present, else seed a fakeHash there
  # (that arch is not built here; its hash stays fake until built on aarch64).
  local aarch_hash
  aarch_hash="$(jq -r --arg k "$latest_version" \
    '.versions[$k].npmDepsHashes["aarch64-linux"] // empty' "$releases_file")"
  [ -n "$aarch_hash" ] || aarch_hash="$FAKE_HASH"

  local backup tmp
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  # Seed/upsert the entry with the real tarball hash but a fake build-host FOD
  # hash so nix reveals the real one on build. Set it as .latest.
  tmp="$(mktemp)"
  jq --arg k "$latest_version" \
     --arg ver "$latest_version" \
     --arg rev "$latest_version" \
     --arg hash "$tarball_hash" \
     --arg fake "$FAKE_HASH" \
     --arg bsys "$BUILD_SYSTEM" \
     --arg aarch "$aarch_hash" '
       .versions[$k] = {
         version: $ver,
         rev: $rev,
         hash: $hash,
         npmDepsHashes: ({ "aarch64-linux": $aarch } + { ($bsys): $fake })
       }
       | .latest = $k
     ' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  # 2) npmDeps FOD hash for the build system.
  log_info "Computing npmDeps hash for ${BUILD_SYSTEM}..."
  local npm_hash
  npm_hash="$(build_and_get_hash "$attr")"
  if [ -z "$npm_hash" ]; then
    # No mismatch printed => build already succeeded (hash was correct).
    log_info "  npmDeps hash already correct (no rehash needed)."
  else
    log_info "  npmDeps hash: $npm_hash"
    tmp="$(mktemp)"
    jq --arg k "$latest_version" --arg bsys "$BUILD_SYSTEM" --arg h "$npm_hash" \
      '.versions[$k].npmDepsHashes[$bsys] = $h' \
      "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"
  fi

  if [ "$no_build" != true ]; then
    log_info "Verifying build of ${attr}..."
    local out_path
    if ! out_path="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link --print-out-paths 2>&1)"; then
      log_error "verification build failed; restoring previous releases.json"
      printf '%s\n' "$out_path" | tail -n 40 >&2
      cp "$backup" "$releases_file"
      rm -f "$backup"
      exit 1
    fi
    out_path="$(printf '%s\n' "$out_path" | tail -n1)"
    if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
      log_error "Build succeeded but expected binary not found at: $out_path/bin/$BIN_NAME"
      cp "$backup" "$releases_file"
      rm -f "$backup"
      exit 1
    fi
    # default must also resolve (it points at the new .latest).
    if ! (cd "$pkg_dir" && nix build ".#default" --no-link --no-write-lock-file); then
      log_error "nix build failed for default; restoring previous releases.json"
      cp "$backup" "$releases_file"
      rm -f "$backup"
      exit 1
    fi
    log_info "Build OK: $out_path"
  fi

  rm -f "$backup"

  log_info "releases.json now contains:"
  jq -r '.latest as $l | "  latest=" + $l, (.versions | keys[] | "  - " + .)' "$releases_file"

  if [ "$do_commit" = true ]; then
    local scope msg
    scope="$(basename "$pkg_dir")"
    if [ "$current_version" != "$latest_version" ]; then
      msg="chore(${scope}): bump to ${latest_version}"
    else
      msg="chore(${scope}): rehash ${latest_version}"
    fi
    maybe_git_commit "$msg" "releases.json"
  fi

  log_warn "Only ${BUILD_SYSTEM} npmDeps hash was refreshed; re-run on other Linux architectures if needed."
}

main "$@"
