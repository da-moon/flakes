#!/usr/bin/env bash
# Appends the newest csso-cli npm release to releases.json (the JSON version
# table read by flake.nix) and sets it as .latest. Never hand-edits the version
# data in flake.nix.
#
# Reproducible-deps model (npm): dependencies are pinned by a COMMITTED
# package-lock.json under deps/<version>/, consumed at build time by
# pkgs.importNpmLock (each module is fetched as its own content-addressed
# derivation keyed to the lockfile's integrity hashes — there is NO aggregate
# deps hash to record). This script therefore, per version:
#   - .hash : the npm tarball fetchurl hash (SRI, arch-agnostic)
#   - deps/<v>/{package.json,package-lock.json,.npmrc} : the committed, pinned
#     lockfile (devDependencies + packageManager stripped, so unbuildable
#     platform dev packages are never fetched).
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly NPM_REGISTRY_URL="https://registry.npmjs.org"
readonly NPM_PACKAGE="csso-cli"
readonly TARBALL_NAME="csso-cli"
readonly PACKAGE_ATTR="csso-cli"
readonly BIN_NAME="csso"
# nixpkgs ref used to obtain node/npm matching flake.nix (nodejs_22).
readonly NIXPKGS_REF="github:NixOS/nixpkgs/nixos-26.05"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  for t in nix curl jq node tar; do
    command -v "$t" >/dev/null 2>&1 || { log_error "$t is required but not installed."; exit 2; }
  done
}

ensure_in_package_directory() {
  [ -f "$flake_file" ] || { log_error "flake.nix not found at: $flake_file"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at: $releases_file"; exit 2; }
}

sanitize_key() { printf '%s' "$1" | tr '.+-' '___'; }

# npm from the pinned nixpkgs (major must match flake.nix's nodejs_22).
npm_run() { nix shell "${NIXPKGS_REF}#nodejs_22" --command npm "$@"; }

lockfile_rel() { printf 'deps/%s/package-lock.json' "$1"; }
lockfile_exists() { [ -f "${pkg_dir}/$(lockfile_rel "$1")" ]; }

# Resolve + commit a package-lock.json for VERSION from its npm tarball. The
# lockfile is generated from the tarball's package.json with devDependencies +
# packageManager stripped, so importNpmLock's `npm ci` installs a lean prod tree.
generate_npm_lock() {
  local version="$1" tarball_url="$2"
  local dest="${pkg_dir}/deps/${version}"
  local work; work="$(mktemp -d)"
  log_info "Generating package-lock.json for ${version}..."
  curl -fsSL "$tarball_url" -o "$work/pkg.tgz"
  tar -xzf "$work/pkg.tgz" -C "$work"   # -> $work/package/
  (
    cd "$work/package"
    export HOME="$work/home"; mkdir -p "$HOME"
    node -e 'const fs=require("fs");const p=require("./package.json");delete p.devDependencies;delete p.packageManager;fs.writeFileSync("package.json",JSON.stringify(p,null,2)+"\n")'
    printf 'legacy-peer-deps=true\n' > .npmrc
    npm_run install --package-lock-only --legacy-peer-deps >/dev/null 2>&1
  )
  [ -f "$work/package/package-lock.json" ] || { log_error "lockfile generation produced no package-lock.json"; rm -rf "$work"; return 1; }
  mkdir -p "$dest"
  cp "$work/package/package.json" "$dest/package.json"
  cp "$work/package/package-lock.json" "$dest/package-lock.json"
  cp "$work/package/.npmrc" "$dest/.npmrc"
  rm -rf "$work"
  log_info "  committed deps/${version}/{package.json,package-lock.json,.npmrc}"
}

get_current_version() { jq -r '.latest // empty' "$releases_file"; }

has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

get_latest_version_from_npm() {
  curl -fsSL "$NPM_REGISTRY_URL/$NPM_PACKAGE/latest" | jq -r '.version // empty'
}

prefetch_sha256_sri() {
  local url="$1"
  nix store prefetch-file --json --hash-type sha256 "$url" | jq -r '.hash // empty'
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) csso-cli npm release to releases.json and
sets it as .latest. For the new version it prefetches the tarball hash and
generates+commits deps/<version>/{package.json,package-lock.json,.npmrc}.
importNpmLock needs no aggregate deps hash. flake.nix is never touched.

Options:
  --version VERSION   Append a specific version (default: latest npm)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Regenerate the committed lockfile for the latest entry
  --no-build          Skip final build verification
  --no-commit         Do not auto-commit (default: auto-commit is enabled)
  --help              Show this help message
EOF
}

maybe_git_commit() {
  local commit_message="$1"; shift
  local -a paths=("$@")
  command -v git >/dev/null 2>&1 || { log_warn "git not found; skipping auto-commit"; return 0; }
  git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { log_warn "not in a git work tree; skipping auto-commit"; return 0; }

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
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local target_version="" check_only=false rehash=false no_build=false do_commit=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        target_version="$2"; shift 2 ;;
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
  [ -n "$current_version" ] || { log_error "Failed to detect current version from releases.json"; exit 2; }
  latest_version="${target_version:-$(get_latest_version_from_npm)}"
  [ -n "$latest_version" ] || { log_error "Failed to fetch latest version"; exit 2; }

  log_info "Current latest: $current_version"
  log_info "Target version:  $latest_version"

  local up_to_date=false
  if has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ] \
    && lockfile_exists "$latest_version"; then
    up_to_date=true
  fi

  if [ "$check_only" = true ]; then
    if [ "$up_to_date" = true ]; then log_info "Already up to date!"; exit 0; fi
    log_info "Update available: $current_version -> $latest_version"; exit 1
  fi

  if [ "$up_to_date" = true ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"; exit 0
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

  # 2) Generate + commit the package-lock.json for this version.
  generate_npm_lock "$latest_version" "$tarball_url"

  local backup tmp
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  # Upsert the entry (no deps hash needed for importNpmLock). Set it as .latest.
  tmp="$(mktemp)"
  jq --arg k "$latest_version" \
     --arg ver "$latest_version" \
     --arg rev "$latest_version" \
     --arg hash "$tarball_hash" '
       .versions[$k] = { version: $ver, rev: $rev, hash: $hash }
       | .latest = $k
     ' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  if [ "$no_build" != true ]; then
    log_info "Verifying build of ${attr}..."
    local out_path
    if ! out_path="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link --print-out-paths 2>&1)"; then
      log_error "verification build failed; restoring previous releases.json"
      printf '%s\n' "$out_path" | tail -n 40 >&2
      cp "$backup" "$releases_file"; rm -f "$backup"; exit 1
    fi
    out_path="$(printf '%s\n' "$out_path" | tail -n1)"
    if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
      log_error "Build succeeded but expected binary not found at: $out_path/bin/$BIN_NAME"
      cp "$backup" "$releases_file"; rm -f "$backup"; exit 1
    fi
    if ! (cd "$pkg_dir" && nix build ".#default" --no-link --no-write-lock-file); then
      log_error "nix build failed for default; restoring previous releases.json"
      cp "$backup" "$releases_file"; rm -f "$backup"; exit 1
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
    maybe_git_commit "$msg" "releases.json" "deps/${latest_version}"
  fi
}

main "$@"
