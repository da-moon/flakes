#!/usr/bin/env bash
# Appends the newest tagged release of santifer/career-ops to releases.json (the
# JSON version table read by flake.nix) and sets it as .latest. Never hand-edits
# the version data in flake.nix.
#
# career-ops IS tagged (career-ops-vN.N.N), so:
#   key     = the version (e.g. "1.15.0")
#   version = the same version string
#   rev     = the upstream tag ("career-ops-v<version>")
#
# Reproducible-deps model (npm via importNpmLock, github source): the source is
# fetchFromGitHub (not an npm tarball — upstream ships no lockfile), and
# dependencies are pinned by a COMMITTED package-lock.json under deps/<version>/,
# consumed at build time by pkgs.importNpmLock (each module is fetched as its
# own content-addressed derivation keyed to the lockfile's integrity hashes —
# there is NO aggregate deps hash to record). This script therefore, per version:
#   - .hash : the fetchFromGitHub source hash (prefetched via
#             `nix store prefetch-file --unpack`, independent of the build).
#   - deps/<v>/{package.json,package-lock.json,.npmrc} : the committed, pinned
#     lockfile, generated straight from upstream's package.json (no
#     devDependencies/packageManager to strip today, but the mutation step is
#     kept so it stays correct if upstream ever adds them).
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly REPO_OWNER="santifer"
readonly REPO_NAME="career-ops"
readonly REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
readonly PACKAGE_ATTR="career-ops"
readonly BIN_NAME="career-ops"
# nixpkgs ref used to obtain node/npm matching flake.nix (nodejs_22).
readonly NIXPKGS_REF="github:NixOS/nixpkgs/nixos-26.05"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  for t in nix curl jq git tar; do
    command -v "$t" >/dev/null 2>&1 || { log_error "$t is required but not installed."; exit 2; }
  done
}

ensure_in_package_directory() {
  [ -f "$flake_file" ] || { log_error "flake.nix not found at: $flake_file"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at: $releases_file"; exit 2; }
}

# mirror flake.nix: replace . - + with _  ('-' kept last so tr treats it literally)
sanitize_key() { printf '%s' "$1" | tr '.+-' '___'; }

# npm from the pinned nixpkgs (major must match flake.nix's nodejs_22).
npm_run() { nix shell "${NIXPKGS_REF}#nodejs_22" --command npm "$@"; }
node_run() { nix shell "${NIXPKGS_REF}#nodejs_22" --command node "$@"; }

lockfile_rel() { printf 'deps/%s/package-lock.json' "$1"; }
lockfile_exists() { [ -f "${pkg_dir}/$(lockfile_rel "$1")" ]; }

latest_tag() {
  git ls-remote --tags "$REPO_URL.git" \
    | awk -F/ '
      /refs\/tags\/(career-ops-)?v[0-9]+(\.[0-9]+)*$/ {
        tag = $3
        version = tag
        sub(/^career-ops-v/, "", version)
        sub(/^v/, "", version)
        print version "\t" tag
      }' \
    | sort -V -k1,1 \
    | tail -n1 \
    | cut -f2
}

version_from_tag() {
  local tag="$1"
  tag="${tag#career-ops-v}"
  tag="${tag#v}"
  printf '%s\n' "$tag"
}

get_current_key() { jq -r '.latest // empty' "$releases_file"; }

has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

# fetchFromGitHub source hash, prefetched (unpacked NAR) independently of the build.
prefetch_github_src() {
  local tag="$1"
  nix store prefetch-file --unpack --json --hash-type sha256 \
    "${REPO_URL}/archive/${tag}.tar.gz" \
    | jq -r '.hash // empty'
}

# Resolve + commit a package-lock.json for VERSION from the tagged source
# archive. Upstream ships no lockfile at all, so this generates one from
# scratch — stripping devDependencies/packageManager first (none exist today,
# but kept for parity with the other npm updaters and future-proofing), then
# resolving with --package-lock-only. NOTE: unlike a plain dependency,
# --package-lock-only does NOT skip the root project's own lifecycle scripts
# (verified empirically: without --ignore-scripts, `npm install
# --package-lock-only` still ran career-ops' postinstall, which tries to
# `npx playwright install chromium --with-deps` — downloading a browser and
# apt-get'ing system libs) — so --ignore-scripts is required here too.
generate_npm_lock() {
  local version="$1" tag="$2"
  local dest="${pkg_dir}/deps/${version}"
  local work; work="$(mktemp -d)"
  log_info "Generating package-lock.json for ${version}..."
  curl -fsSL "${REPO_URL}/archive/${tag}.tar.gz" -o "$work/src.tgz"
  tar -xzf "$work/src.tgz" -C "$work"
  local srcdir; srcdir="$(find "$work" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n1)"
  [ -n "$srcdir" ] || { log_error "could not locate extracted source dir"; rm -rf "$work"; return 1; }
  (
    cd "$srcdir"
    export HOME="$work/home"; mkdir -p "$HOME"
    node_run -e 'const fs=require("fs");const p=require("./package.json");delete p.devDependencies;delete p.packageManager;fs.writeFileSync("package.json",JSON.stringify(p,null,2)+"\n")'
    printf 'legacy-peer-deps=true\n' > .npmrc
    npm_run install --package-lock-only --ignore-scripts --legacy-peer-deps >/dev/null 2>&1
  )
  [ -f "$srcdir/package-lock.json" ] || { log_error "lockfile generation produced no package-lock.json"; rm -rf "$work"; return 1; }
  mkdir -p "$dest"
  cp "$srcdir/package.json" "$dest/package.json"
  cp "$srcdir/package-lock.json" "$dest/package-lock.json"
  cp "$srcdir/.npmrc" "$dest/.npmrc"
  rm -rf "$work"
  log_info "  committed deps/${version}/{package.json,package-lock.json,.npmrc}"
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) tagged career-ops release to releases.json
as a new version-table entry (keyed by version) and sets .latest to it. For the
new version it prefetches the fetchFromGitHub source hash and generates+commits
deps/<version>/{package.json,package-lock.json,.npmrc}. importNpmLock needs no
aggregate deps hash. flake.nix is never touched.

Options:
  --version VERSION   Append a specific version (default: newest tag)
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

  local requested="" check_only=false rehash=false no_build=false do_commit=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        requested="$2"; shift 2 ;;
      --check) check_only=true; shift ;;
      --rehash) rehash=true; shift ;;
      --no-build) no_build=true; shift ;;
      --no-commit) do_commit=false; shift ;;
      --help) print_usage; exit 0 ;;
      *) log_error "Unknown option: $1"; print_usage; exit 2 ;;
    esac
  done

  local current_key tag version
  current_key="$(get_current_key)"
  if [ -n "$requested" ]; then
    tag="career-ops-v${requested}"
  else
    tag="$(latest_tag)"
  fi
  [ -n "$tag" ] || { log_error "could not resolve upstream tag"; exit 2; }
  version="$(version_from_tag "$tag")"

  log_info "Current latest key: ${current_key}"
  log_info "Target version:     ${version} (${tag})"

  local up_to_date=false
  if has_version_entry "$version" && [ "$current_key" = "$version" ] \
    && lockfile_exists "$version"; then
    up_to_date=true
  fi

  if [ "$check_only" = true ]; then
    if [ "$up_to_date" = true ]; then log_info "Already up to date!"; exit 0; fi
    log_info "Update available: ${current_key} -> ${version}"; exit 1
  fi

  if [ "$up_to_date" = true ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"; exit 0
  fi

  local attr; attr="${PACKAGE_ATTR}_$(sanitize_key "$version")"

  # 1) source hash (prefetched, independent of build).
  log_info "Prefetching fetchFromGitHub source hash..."
  local src_hash; src_hash="$(prefetch_github_src "$tag")"
  [ -n "$src_hash" ] || { log_error "failed to prefetch source hash"; exit 1; }
  log_info "  src hash: $src_hash"

  # 2) generate + commit the package-lock.json for this version.
  generate_npm_lock "$version" "$tag"

  local backup tmp
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  # Upsert the entry (no deps hash needed for importNpmLock). Set it as .latest.
  tmp="$(mktemp)"
  jq --arg k "$version" \
     --arg ver "$version" \
     --arg rev "$tag" \
     --arg hash "$src_hash" '
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
    log_info "Build OK: $out_path"
  fi

  rm -f "$backup"

  log_info "releases.json now contains:"
  jq -r '.latest as $l | "  latest=" + $l, (.versions | keys[] | "  - " + .)' "$releases_file"

  if [ "$do_commit" = true ]; then
    local scope msg
    scope="$(basename "$pkg_dir")"
    if [ "$current_key" != "$version" ]; then
      msg="chore(${scope}): bump to ${version}"
    else
      msg="chore(${scope}): rehash ${version}"
    fi
    maybe_git_commit "$msg" "releases.json" "deps/${version}"
  fi
}

main "$@"
