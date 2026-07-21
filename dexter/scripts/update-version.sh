#!/usr/bin/env bash
# Appends the newest upstream release tag of virattt/dexter as a new entry in
# releases.json (the JSON version table the flake reads) and sets it as .latest.
# Never hand-edits the version data in flake.nix.
#
# dexter is TAGGED (upstream ships v<YYYY.M.D> release tags), so:
#   key     = the version (tag without the leading "v")
#   version = the same tag string
#
# Reproducible-deps model (npm, github source): dependencies are pinned by a
# COMMITTED package-lock.json under deps/<version>/, consumed at build time by
# pkgs.importNpmLock (each module is fetched as its own content-addressed
# derivation keyed to the lockfile's integrity hashes — there is NO aggregate
# deps hash to record). This script therefore, per version:
#   - .hash : the fetchFromGitHub source hash (SRI, unpacked NAR, arch-agnostic),
#             prefetched via `nix store prefetch-file --unpack`.
#   - deps/<v>/{package.json,package-lock.json,.npmrc} : the committed lockfile.
#
# Lockfile generation deviates from the plain "npm install --package-lock-only"
# recipe in two ways that MUST be preserved by generate_npm_lock():
#   1. It is a FULL `npm install` (not --package-lock-only) — the
#      --package-lock-only fast path leaves ~200 packages in the tree without
#      resolved/integrity fields populated; a full install (with
#      ignore-scripts=true so no lifecycle script ever runs) fills them all in.
#   2. node_modules/@whiskeysockets/baileys depends on `libsignal` via an
#      *unpinned* `git+https://github.com/whiskeysockets/libsignal-node.git`
#      spec upstream (no ref/commit). npm resolves that to whatever commit is
#      live at install time and records it as a git resolved:// URL — but the
#      flake supplies libsignal itself via a pinned fetchFromGitHub
#      packageSourceOverride, so the *edge* (baileys' own recorded dependency
#      on libsignal) must be flattened from that git spec down to a plain
#      semver matching whatever version node_modules/libsignal resolved to
#      (upstream's own package.json version field), so importNpmLock's
#      `npm install --ignore-scripts` can satisfy it by ordinary semver
#      matching against the already-installed/overridden node, with no git/
#      network access needed at build time.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly REPO_OWNER="virattt"
readonly REPO_NAME="dexter"
readonly REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
readonly PNAME="dexter"
readonly BIN_NAME="dexter"
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

lockfile_rel() { printf 'deps/%s/package-lock.json' "$1"; }
lockfile_exists() { [ -f "${pkg_dir}/$(lockfile_rel "$1")" ]; }

# Newest v<X.Y.Z> release tag from upstream (with the "v" stripped).
latest_version() {
  git ls-remote --tags "$REPO_URL.git" \
    | awk -F/ '/refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+$/ { print substr($3, 2) }' \
    | sort -V \
    | tail -n1
}

# fetchFromGitHub source hash, prefetched (unpacked NAR) independently of the build.
prefetch_github_src() {
  local rev="$1"
  nix store prefetch-file --unpack --json --hash-type sha256 \
    "${REPO_URL}/archive/${rev}.tar.gz" \
    | jq -r '.hash // empty'
}

# Resolve + commit a package-lock.json for VERSION (upstream tag "v<version>")
# under deps/<version>/. Generated from a FULL `npm install` (see header
# comment for why) against the tarball's package.json with devDependencies +
# packageManager stripped, then with the baileys->libsignal git edge flattened
# to a plain semver.
generate_npm_lock() {
  local version="$1" rev="$2"
  local dest="${pkg_dir}/deps/${version}"
  local work; work="$(mktemp -d)"
  log_info "Generating package-lock.json for ${version}..."
  curl -fsSL "${REPO_URL}/archive/${rev}.tar.gz" -o "$work/src.tgz"
  tar -xzf "$work/src.tgz" -C "$work"
  local srcdir; srcdir="$(find "$work" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n1)"
  [ -n "$srcdir" ] || { log_error "could not locate extracted source dir"; rm -rf "$work"; return 1; }
  (
    cd "$srcdir"
    export HOME="$work/home"; mkdir -p "$HOME"
    node -e 'const fs=require("fs");const p=require("./package.json");delete p.devDependencies;delete p.packageManager;fs.writeFileSync("package.json",JSON.stringify(p,null,2)+"\n")'
    printf 'ignore-scripts=true\n' > .npmrc
    # FULL install (not --package-lock-only): --package-lock-only leaves
    # ~200 transitive packages without resolved/integrity populated.
    npm_run install >/dev/null 2>&1
  )
  [ -f "$srcdir/package-lock.json" ] || { log_error "lockfile generation produced no package-lock.json"; rm -rf "$work"; return 1; }
  # Flatten the baileys -> libsignal git edge to a plain semver (see header).
  local libsignal_version
  libsignal_version="$(jq -r '.packages["node_modules/libsignal"].version // empty' "$srcdir/package-lock.json")"
  if [ -n "$libsignal_version" ] && jq -e '.packages["node_modules/@whiskeysockets/baileys"].dependencies.libsignal // empty' "$srcdir/package-lock.json" >/dev/null 2>&1; then
    local tmp; tmp="$(mktemp)"
    jq --arg v "$libsignal_version" \
      '.packages["node_modules/@whiskeysockets/baileys"].dependencies.libsignal = $v' \
      "$srcdir/package-lock.json" >"$tmp" && mv "$tmp" "$srcdir/package-lock.json"
    log_info "  patched baileys' libsignal dependency edge -> ${libsignal_version}"
  else
    log_warn "  could not find baileys/libsignal edge to patch (upstream dependency tree may have changed)"
  fi
  mkdir -p "$dest"
  cp "$srcdir/package.json" "$dest/package.json"
  cp "$srcdir/package-lock.json" "$dest/package-lock.json"
  cp "$srcdir/.npmrc" "$dest/.npmrc"
  rm -rf "$work"
  log_info "  committed deps/${version}/{package.json,package-lock.json,.npmrc}"
}

current_latest_key() { jq -r '.latest // empty' "$releases_file"; }

has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest upstream release tag of virattt/dexter to releases.json and
sets it as .latest. For the new version it prefetches the fetchFromGitHub
source hash and generates+commits deps/<version>/{package.json,package-lock.json,.npmrc}.
importNpmLock needs no aggregate deps hash. flake.nix is never touched.

Options:
  --version VERSION   Append/pin a specific version instead of the latest tag.
  --check             Only check for updates (exit 1 if an update is available).
  --rehash            Regenerate the committed lockfile for the latest entry.
  --no-build          Skip the final verification build.
  --no-commit         Do not auto-commit (default: auto-commit is enabled).
  --help              Show this help message.
EOF
}

# Parallel-safe auto-commit. flock serialises the git index across concurrent updaters.
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

  local cur_latest_key latest_ver
  cur_latest_key="$(current_latest_key)"
  [ -n "$cur_latest_key" ] || { log_error "Failed to detect .latest from releases.json"; exit 2; }
  latest_ver="${target_version:-$(latest_version)}"
  [ -n "$latest_ver" ] || { log_error "Failed to resolve latest upstream tag"; exit 2; }

  log_info "Current latest: $cur_latest_key"
  log_info "Target version: $latest_ver"

  local up_to_date=false
  if has_version_entry "$latest_ver" && [ "$cur_latest_key" = "$latest_ver" ] \
    && lockfile_exists "$latest_ver"; then
    up_to_date=true
  fi

  if [ "$check_only" = true ]; then
    if [ "$up_to_date" = true ]; then log_info "Already up to date!"; exit 0; fi
    log_info "Update available: $cur_latest_key -> $latest_ver"; exit 1
  fi

  if [ "$up_to_date" = true ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"; exit 0
  fi

  local rev="v${latest_ver}"
  local attr; attr="${PNAME}_$(sanitize_key "$latest_ver")"

  # 1) fetchFromGitHub source hash (arch-agnostic, independent of the build).
  log_info "Prefetching fetchFromGitHub source hash for ${rev}..."
  local src_hash; src_hash="$(prefetch_github_src "$rev")"
  [ -n "$src_hash" ] || { log_error "Failed to prefetch source hash"; exit 1; }
  log_info "  src hash: $src_hash"

  # 2) Generate + commit the package-lock.json for this version.
  generate_npm_lock "$latest_ver" "$rev"

  local backup tmp
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  # Upsert the entry (no deps hash needed for importNpmLock). Set it as .latest.
  tmp="$(mktemp)"
  jq --arg k "$latest_ver" \
     --arg ver "$latest_ver" \
     --arg rev "$rev" \
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
    if [ "$cur_latest_key" != "$latest_ver" ]; then
      msg="chore(${scope}): bump to ${latest_ver}"
    else
      msg="chore(${scope}): rehash ${latest_ver}"
    fi
    maybe_git_commit "$msg" "releases.json" "deps/${latest_ver}"
  fi
}

main "$@"
