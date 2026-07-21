#!/usr/bin/env bash
# Appends the newest upstream commit of Gitlawb/memlawb as a new entry in
# releases.json (the JSON version table the flake reads) and sets it as
# .latest. Never hand-edits the version data in flake.nix.
#
# memlawb has NO release tags (and is not published on npm), so:
#   key     = short (7-char) upstream commit hash
#   version = "<base>-unstable-<commit-date>" (base taken from package.json at
#             the resolved rev, e.g. "0.1.0"; "0" if none is present). The rev
#             lives in the entry, so no trailing short-hash is kept in version.
#
# Reproducible-deps model (npm, github source): dependencies are pinned by a
# COMMITTED package-lock.json under deps/<key>/, consumed at build time by
# pkgs.importNpmLock (each module is fetched as its own content-addressed
# derivation keyed to the lockfile's integrity hashes — there is NO aggregate
# deps hash to record). This script therefore, per rev:
#   - .hash : the fetchFromGitHub source hash (SRI, unpacked NAR, arch-
#             agnostic), prefetched via `nix-prefetch-url --unpack`.
#   - deps/<key>/{package.json,package-lock.json,.npmrc} : the committed
#             lockfile.
#
# Lockfile generation deviates from the plain "npm install --package-lock-only"
# recipe in two ways that MUST be preserved by generate_npm_lock():
#   1. It is a FULL `npm install` (not --package-lock-only) — the
#      --package-lock-only fast path can leave packages in the tree without
#      resolved/integrity fields populated; a full install (with
#      ignore-scripts=true so no lifecycle script ever runs) fills them all in.
#   2. zod is added to the committed package.json: src/mcp/server.ts does
#      `import { z } from 'zod'` but upstream never declares it (today it only
#      arrives transitively via @modelcontextprotocol/sdk). EXTRA_DEPS is
#      merged UNDER upstream's dependencies, so upstream's own spec wins if it
#      ever declares the same package.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly REPO_OWNER="Gitlawb"
readonly REPO_NAME="memlawb"
readonly REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
readonly PNAME="memlawb"
readonly BIN_NAME="memlawb"
# nixpkgs ref used to obtain node/npm matching flake.nix (nodejs_22).
readonly NIXPKGS_REF="github:NixOS/nixpkgs/nixos-26.05"
# Runtime deps imported by upstream but not declared in its package.json
# (see header), as JSON merged under .dependencies by generate_npm_lock().
readonly EXTRA_DEPS='{"zod": "^3.25.76"}'

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

# npm from the pinned nixpkgs (major must match flake.nix's nodejs_22).
npm_run() { nix shell "${NIXPKGS_REF}#nodejs_22" --command npm "$@"; }

# mirror flake.nix: replace . - + with _  ('-' kept last so tr treats it literally)
sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
}

lockfile_rel() { printf 'deps/%s/package-lock.json' "$1"; }
lockfile_exists() { [ -f "${pkg_dir}/$(lockfile_rel "$1")" ]; }

current_latest_key() { jq -r '.latest // empty' "$releases_file"; }

get_current_version() {
  local key="$1"
  jq -r --arg k "$key" '.versions[$k].version // empty' "$releases_file"
}

has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

get_latest_commit_sha() {
  git ls-remote "${REPO_URL}.git" HEAD | awk 'NR==1{print $1}'
}

get_commit_date() {
  local sha="$1"
  curl -fsSL "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits/${sha}" \
    | sed -n 's/.*"date":[[:space:]]*"\([0-9-]\{10\}\)T.*/\1/p' \
    | head -n1
}

get_base_version_for_rev() {
  local sha="$1"
  curl -fsSL "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${sha}/package.json" \
    | jq -r '.version // empty'
}

# Canonical no-tag version: "<base>-unstable-<commit-date>" (no trailing hash;
# the rev already lives in the entry).
build_version_string() {
  local base_version="$1"
  local commit_date="$2"
  printf '%s-unstable-%s\n' "$base_version" "$commit_date"
}

# fetchFromGitHub source hash, prefetched (unpacked NAR) independently of the
# build. Uses nix-prefetch-url + to-sri conversion: it works on every nix
# version (unlike `nix store prefetch-file --unpack`, which needs nix >= 2.20).
prefetch_github_src() {
  local rev="$1"
  local hash
  hash="$(nix-prefetch-url --type sha256 --unpack "${REPO_URL}/archive/${rev}.tar.gz" 2>/dev/null | tail -n1)"
  nix hash to-sri --type sha256 "$hash"
}

# Resolve + commit a package-lock.json for KEY (upstream rev REV) under
# deps/<key>/. Generated from a FULL `npm install` (see header for why)
# against the tarball's package.json with devDependencies + packageManager
# stripped and EXTRA_DEPS merged under .dependencies.
generate_npm_lock() {
  local key="$1" rev="$2"
  local dest="${pkg_dir}/deps/${key}"
  local work; work="$(mktemp -d)"
  log_info "Generating package-lock.json for ${key} (${rev})..."
  curl -fsSL "${REPO_URL}/archive/${rev}.tar.gz" -o "$work/src.tgz"
  tar -xzf "$work/src.tgz" -C "$work"
  local srcdir; srcdir="$(find "$work" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n1)"
  [ -n "$srcdir" ] || { log_error "could not locate extracted source dir"; rm -rf "$work"; return 1; }
  (
    cd "$srcdir"
    node -e 'const fs=require("fs");const p=require("./package.json");delete p.devDependencies;delete p.packageManager;const extra=JSON.parse(process.argv[1]);p.dependencies=Object.assign({},extra,p.dependencies||{});fs.writeFileSync("package.json",JSON.stringify(p,null,2)+"\n")' \
      "$EXTRA_DEPS"
    printf 'ignore-scripts=true\n' > .npmrc
    # FULL install (not --package-lock-only): --package-lock-only can leave
    # transitive packages without resolved/integrity populated. Only npm's
    # cache is redirected — exporting HOME would hide the user's nix.conf
    # (experimental-features) from `nix shell` on single-user installs.
    npm_config_cache="$work/npm-cache" npm_run install >/dev/null 2>&1
  )
  [ -f "$srcdir/package-lock.json" ] || { log_error "lockfile generation produced no package-lock.json"; rm -rf "$work"; return 1; }
  local missing
  missing="$(jq '[.packages | to_entries[] | select(.key != "" and .value.link != true) | select(.value.integrity == null)] | length' "$srcdir/package-lock.json")"
  [ "$missing" = "0" ] || { log_error "lockfile has ${missing} packages without integrity hashes"; rm -rf "$work"; return 1; }
  mkdir -p "$dest"
  cp "$srcdir/package.json" "$dest/package.json"
  cp "$srcdir/package-lock.json" "$dest/package-lock.json"
  cp "$srcdir/.npmrc" "$dest/.npmrc"
  rm -rf "$work"
  log_info "  committed deps/${key}/{package.json,package-lock.json,.npmrc}"
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
  if ! out_path="$(cd "$pkg_dir" && nix build ".#${PNAME}_${sanitized_key}" --no-link --print-out-paths --no-write-lock-file)"; then
    log_error "nix build failed for ${PNAME}_${sanitized_key}"
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
  # memlawb has no --version flag; with no arguments it prints usage (exit 1 —
  # so pipe it through `|| true`, not straight into grep under pipefail).
  local cli_out
  cli_out="$("$out_path/bin/$BIN_NAME" 2>&1 || true)"
  case "$cli_out" in
    *"memlawb serve"*) ;;
    *)
      log_error "memlawb binary did not print its usage text"
      return 1
      ;;
  esac
  log_info "Build successful!"
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat releases.json deps 2>/dev/null || true
  fi
}

# Parallel-safe auto-commit. flock serialises the git index across concurrent updaters.
maybe_git_commit() {
  local commit_message="$1"; shift
  local -a paths=("$@")
  command -v git >/dev/null 2>&1 || { log_warn "git not found; skipping auto-commit"; return 0; }
  git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { log_warn "not in a git work tree; skipping auto-commit"; return 0; }

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

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) upstream commit of Gitlawb/memlawb to
releases.json as a new entry keyed by the short commit hash and sets .latest
to it. For the new rev it prefetches the fetchFromGitHub source hash and
generates+commits deps/<key>/{package.json,package-lock.json,.npmrc}.
importNpmLock needs no aggregate deps hash. flake.nix is never touched.

Options:
  --rev VALUE        Pin to a specific git ref/branch/rev instead of HEAD
                       (aliases: --revision, --version)
  --check            Only check for updates (exit 1 if update available)
  --rehash           Regenerate the committed lockfile for the latest entry
  --no-build         Skip build verification
  --no-commit        Do not auto-commit (default: auto-commit is enabled)
  --help             Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --rehash
EOF
}

main() {
  ensure_required_tools_installed
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local target_ref="" check_only=false rehash=false no_build=false do_commit=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rev|--revision|--version)
        [ $# -ge 2 ] || { log_error "$1 requires an argument"; exit 2; }
        target_ref="$2"
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
      --no-commit)
        do_commit=false
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

  local cur_key cur_version
  cur_key="$(current_latest_key)"
  if [ -z "$cur_key" ]; then
    log_error "Failed to detect current latest key from releases.json"
    exit 1
  fi
  cur_version="$(get_current_version "$cur_key")"

  # Resolve the target rev (HEAD unless a ref was pinned).
  local target_rev
  if [ -n "$target_ref" ]; then
    target_rev="$(git ls-remote "${REPO_URL}.git" "$target_ref" | awk 'NR==1{print $1}')"
    [ -n "$target_rev" ] || target_rev="$target_ref"  # allow a raw rev
  else
    target_rev="$(get_latest_commit_sha)"
  fi
  [ -n "$target_rev" ] || { log_error "Failed to resolve upstream rev"; exit 1; }

  local target_base target_date target_version short_key
  target_base="$(get_base_version_for_rev "$target_rev")"
  [ -n "$target_base" ] || target_base="0"
  target_date="$(get_commit_date "$target_rev")"
  [ -n "$target_date" ] || { log_error "Failed to resolve commit date for $target_rev"; exit 1; }

  target_version="$(build_version_string "$target_base" "$target_date")"
  short_key="${target_rev:0:7}"

  log_info "Current latest key:  $cur_key ($cur_version)"
  log_info "Resolved upstream:   $target_rev"
  log_info "New key:             $short_key"
  log_info "New version:         $target_version"

  if [ "$check_only" = true ]; then
    if has_version_entry "$short_key" && [ "$cur_key" = "$short_key" ] && [ "$rehash" != true ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: $cur_key -> $short_key"
    exit 1
  fi

  if has_version_entry "$short_key" && [ "$cur_key" = "$short_key" ] && [ "$rehash" != true ]; then
    log_info "Already up to date!"
    exit 0
  fi

  log_info "Computing fetchFromGitHub source hash..."
  local source_hash
  source_hash="$(prefetch_github_src "$target_rev")"
  [ -n "$source_hash" ] || { log_error "Failed to prefetch source hash for ${target_rev}"; exit 1; }
  log_info "Source hash: $source_hash"

  local entry_json
  entry_json="$(jq -n \
    --arg v "$target_version" \
    --arg rev "$target_rev" \
    --arg hash "$source_hash" \
    '{version: $v, rev: $rev, hash: $hash}')"

  local backup deps_backup=""
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"
  if [ -d "${pkg_dir}/deps/${short_key}" ]; then
    deps_backup="$(mktemp -d -t memlawb-deps.backup.XXXXXX)"
    cp -r "${pkg_dir}/deps/${short_key}/." "$deps_backup"
  fi

  upsert_release_entry "$short_key" "$entry_json"

  if ! generate_npm_lock "$short_key" "$target_rev"; then
    log_error "Lockfile generation failed; restoring previous releases.json and deps/"
    cp "$backup" "$releases_file"
    if [ -n "$deps_backup" ]; then
      rm -rf "${pkg_dir}/deps/${short_key}"
      mkdir -p "${pkg_dir}/deps/${short_key}"
      cp -r "$deps_backup/." "${pkg_dir}/deps/${short_key}/"
    fi
    rm -f "$backup"
    exit 1
  fi

  local sanitized_key
  sanitized_key="$(sanitize_key "$short_key")"

  if [ "$no_build" != true ]; then
    if ! verify_build "$sanitized_key"; then
      log_error "Build verification failed; restoring previous releases.json and deps/"
      cp "$backup" "$releases_file"
      if [ -n "$deps_backup" ]; then
        rm -rf "${pkg_dir}/deps/${short_key}"
        mkdir -p "${pkg_dir}/deps/${short_key}"
        cp -r "$deps_backup/." "${pkg_dir}/deps/${short_key}/"
      else
        rm -rf "${pkg_dir}/deps/${short_key}"
      fi
      rm -f "$backup"
      exit 1
    fi
  fi

  rm -f "$backup"
  [ -z "$deps_backup" ] || rm -rf "$deps_backup"

  show_changes

  local scope msg
  scope="$(basename "$pkg_dir")"
  if [ "$cur_key" = "$short_key" ]; then
    msg="chore(${scope}): rehash ${target_version} (${short_key})"
  else
    msg="chore(${scope}): add ${target_version} (${short_key}) to version table"
  fi

  if [ "$do_commit" = true ]; then
    maybe_git_commit "$msg" "releases.json" "deps"
  fi

  log_info "Done."
}

main "$@"
