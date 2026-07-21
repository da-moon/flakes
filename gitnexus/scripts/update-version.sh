#!/usr/bin/env bash
# Appends the newest (or an explicit) gitnexus npm release to releases.json (the
# JSON version table read by flake.nix) and sets it as .latest. Never hand-edits
# the version data in flake.nix.
#
# gitnexus is published on npm (TAGGED), so:
#   key     = the npm version (e.g. "1.6.9")
#   version = the same version string
#
# Reproducible-deps model (pnpm, content-addressed): dependencies are pinned by
# a COMMITTED pnpm-lock.yaml under deps/<version>/, fetched at build time by
# pnpm.fetchDeps. This script therefore, per version:
#   - .hash          : the npm tarball fetchurl hash (SRI, arch-agnostic), via
#                       nix store prefetch-file
#   - deps/<v>/pnpm-lock.yaml : a freshly resolved, committed lockfile
#   - .pnpmDepsHash  : the single portable pnpm.fetchDeps hash (same on all
#     systems), recomputed via the fakeHash -> nix build -> parse "got:" method
#
# QUIRK: the published npm tarball's package.json is NOT what the committed
# lockfile was resolved against. flake.nix's `src` runCommand replays a mutation
# on package.json before injecting the lockfile at build time: it strips
# scripts.prepare/postinstall, drops devDependencies["gitnexus-shared"] and
# optionalDependencies["tree-sitter-swift"], pins every ^/~ semver range down to
# its exact listed version, bumps a dependencies["onnxruntime-node"] == "1.24.0"
# to "1.26.0", and injects a pnpm.onlyBuiltDependencies/ignoredBuiltDependencies
# allowlist for native addons. generate_pnpm_lock() below MUST replay the exact
# same mutation (see mutate.js, copied verbatim from flake.nix's node -e script)
# BEFORE running `pnpm install --lockfile-only`, or the regenerated lockfile
# will not match the tree pnpm.fetchDeps expects at build time.
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly NPM_REGISTRY_URL="https://registry.npmjs.org"
readonly NPM_PACKAGE="gitnexus"
readonly TARBALL_NAME="gitnexus"
readonly PACKAGE_ATTR="gitnexus"
readonly BIN_NAME="gitnexus"
# nixpkgs ref used to obtain the pnpm/node majors that match flake.nix
# (pnpm_10, nodejs_22 — neither is assumed to be on PATH).
readonly NIXPKGS_REF="github:NixOS/nixpkgs/nixos-26.05"
# lib.fakeHash — the sentinel nix rejects, forcing it to print the real "got:" hash.
readonly FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  for t in nix curl jq tar; do
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

# pnpm/node from the pinned nixpkgs (majors must match flake.nix's pnpm_10 /
# nodejs_22). Neither tool is assumed to be on PATH.
pnpm_run() { nix shell "${NIXPKGS_REF}#pnpm_10" --command pnpm "$@"; }
node_run() { nix shell "${NIXPKGS_REF}#nodejs_22" --command node "$@"; }

# Relative path (from pkg_dir) of a version's committed lockfile.
lockfile_rel() { printf 'deps/%s/pnpm-lock.yaml' "$1"; }

lockfile_exists() { [ -f "${pkg_dir}/$(lockfile_rel "$1")" ]; }

# The exact package.json mutation flake.nix's `src` runCommand replays before
# injecting the committed lockfile — copied verbatim from the `node -e` script
# in flake.nix so the lockfile generated here resolves against the identical
# tree pnpm.fetchDeps will see at build time.
write_mutate_script() {
  local dest="$1"
  cat >"$dest" <<'MUTATE_JS'
const fs = require("fs");
const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));

if (pkg.scripts) {
  delete pkg.scripts.prepare;
  delete pkg.scripts.postinstall;
}

if (pkg.devDependencies) {
  delete pkg.devDependencies["gitnexus-shared"];
}

if (pkg.optionalDependencies) {
  delete pkg.optionalDependencies["tree-sitter-swift"];
}

function exactSpec(spec) {
  if (typeof spec !== "string") return spec;
  if (/^(file:|link:|workspace:|git\+|https?:)/.test(spec)) return spec;
  const bare = spec.match(/^[~^](\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)$/);
  return bare ? bare[1] : spec;
}
function isExactInstallSpec(spec) {
  return /^(file:|link:|workspace:|git\+|https?:)/.test(spec)
    || /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(spec);
}
const unresolved = [];
for (const field of ["dependencies", "devDependencies", "optionalDependencies"]) {
  for (const [name, spec] of Object.entries(pkg[field] || {})) {
    const next = exactSpec(spec);
    pkg[field][name] = next;
    if (typeof next === "string" && !isExactInstallSpec(next)) {
      unresolved.push(field + "." + name + "=" + next);
    }
  }
}
if (unresolved.length > 0) {
  throw new Error("Non-exact dependency specs remain: " + unresolved.join(", "));
}

if (pkg.dependencies && pkg.dependencies["onnxruntime-node"] === "1.24.0") {
  pkg.dependencies["onnxruntime-node"] = "1.26.0";
}

pkg.pnpm = {
  onlyBuiltDependencies: [
    "@ladybugdb/core",
    "tree-sitter",
    "tree-sitter-c",
    "tree-sitter-c-sharp",
    "tree-sitter-cpp",
    "tree-sitter-go",
    "tree-sitter-java",
    "tree-sitter-javascript",
    "tree-sitter-kotlin",
    "tree-sitter-php",
    "tree-sitter-python",
    "tree-sitter-ruby",
    "tree-sitter-rust",
    "tree-sitter-typescript"
  ],
  ignoredBuiltDependencies: [
    "onnxruntime-node",
    "protobufjs",
    "sharp"
  ]
};

fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2));
MUTATE_JS
}

# Resolve a fresh pnpm-lock.yaml for VERSION from its npm tarball and commit it
# under deps/<version>/. Replays the same package.json mutation flake.nix's
# `src` runCommand applies, THEN runs `pnpm install --lockfile-only` so the
# lockfile matches the tree pnpm.fetchDeps expects at build time.
generate_pnpm_lock() {
  local version="$1" tarball_url="$2"
  local dest="${pkg_dir}/deps/${version}"
  local work; work="$(mktemp -d)"
  log_info "Generating pnpm-lock.yaml for ${version} (replaying package.json mutation)..."
  curl -fsSL "$tarball_url" -o "$work/pkg.tgz"
  tar -xzf "$work/pkg.tgz" -C "$work"   # -> $work/package/
  write_mutate_script "$work/mutate.js"
  (
    cd "$work/package"
    node_run "$work/mutate.js"
    export HOME="$work/home"; mkdir -p "$HOME"
    pnpm_run config set manage-package-manager-versions false >/dev/null 2>&1 || true
    pnpm_run install --lockfile-only --ignore-scripts
  )
  [ -f "$work/package/pnpm-lock.yaml" ] || { log_error "lockfile generation produced no pnpm-lock.yaml"; rm -rf "$work"; return 1; }
  mkdir -p "$dest"
  cp "$work/package/pnpm-lock.yaml" "$dest/pnpm-lock.yaml"
  rm -rf "$work"
  log_info "  committed $(lockfile_rel "$version")"
}

get_current_version() { jq -r '.latest // empty' "$releases_file"; }

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

# Recompute the pnpm.fetchDeps hash by building the target attr with a fake hash
# already written into releases.json and parsing nix's "got:" line.
build_and_get_hash() {
  local attr="$1" out
  out="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link 2>&1 || true)"
  printf '%s\n' "$out" | extract_got_hash
}

# Is the recorded pnpmDepsHash a fakeHash sentinel (or missing)?
current_hash_is_fake() {
  local key="$1" h
  h="$(jq -r --arg k "$key" '.versions[$k].pnpmDepsHash // empty' "$releases_file")"
  [ -z "$h" ] || [ "$h" = "$FAKE_HASH" ]
}

verify_build() {
  local attr="$1"
  log_info "Verifying build..."
  local out_path
  if ! out_path="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link --print-out-paths)"; then
    log_error "nix build failed for ${attr}"
    return 1
  fi
  if [ -z "$out_path" ] || [ ! -x "$out_path/bin/$BIN_NAME" ]; then
    log_error "Build succeeded but expected binary not found at: $out_path/bin/$BIN_NAME"
    return 1
  fi
  # default must also resolve (it points at the new .latest).
  if ! (cd "$pkg_dir" && nix build ".#default" --no-write-lock-file --no-link); then
    log_error "nix build failed for default"
    return 1
  fi
  timeout 30 "$out_path/bin/$BIN_NAME" --version >/dev/null 2>&1 || true
  log_info "Build successful!"
}

show_changes() {
  if command -v git >/dev/null 2>&1 && git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "Changes made:"
    git -C "$pkg_dir" diff --stat releases.json 2>/dev/null || true
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

Appends the newest (or an explicit) gitnexus npm release to releases.json (the
JSON version table read by flake.nix) and sets it as .latest. For the new
version it: prefetches the npm tarball hash, replays the package.json mutation
flake.nix applies and generates+commits deps/<version>/pnpm-lock.yaml, and
recomputes the single portable .pnpmDepsHash via the fakeHash -> nix build ->
parse "got:" method. The version data in flake.nix is never touched.

Options:
  --version VERSION   Append a specific version (default: latest npm)
  --check             Only check for updates (exit 1 if update available)
  --rehash            Regenerate lockfile + pnpmDepsHash for the latest entry
  --no-build          Skip build verification
  --no-commit         Do not auto-commit (default: auto-commit is enabled)
  --help              Show this help message

Examples:
  ./scripts/update-version.sh
  ./scripts/update-version.sh --check
  ./scripts/update-version.sh --version 1.6.9
EOF
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

  local current_version
  current_version="$(get_current_version)"
  if [ -z "$current_version" ]; then
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi

  local latest_version
  if [ -n "$target_version" ]; then
    latest_version="$target_version"
  elif [ "$rehash" = true ]; then
    latest_version="$current_version"
  else
    latest_version="$(get_latest_version_from_npm)"
    if [ -z "$latest_version" ]; then
      log_error "Failed to fetch latest version from npm"
      exit 2
    fi
  fi

  log_info "Current latest: $current_version"
  log_info "Target version:  $latest_version"

  # "Up to date" == entry exists, is .latest, has a committed lockfile, and a
  # real (non-fake) pnpmDepsHash.
  local up_to_date=false
  if has_version_entry "$latest_version" && [ "$current_version" = "$latest_version" ] \
    && lockfile_exists "$latest_version" && ! current_hash_is_fake "$latest_version"; then
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
  if [ -z "$tarball_hash" ]; then
    log_error "Failed to prefetch tarball hash"
    exit 2
  fi
  log_info "  tarball hash: $tarball_hash"

  # 2) Generate + commit the pnpm lockfile for this version (replays the
  # package.json mutation flake.nix applies before generating).
  generate_pnpm_lock "$latest_version" "$tarball_url"

  local backup tmp
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  # Seed/upsert the entry with the real tarball hash but a fake deps hash so nix
  # reveals the real one on build. Set it as .latest.
  tmp="$(mktemp)"
  jq --arg k "$latest_version" \
     --arg ver "$latest_version" \
     --arg rev "$latest_version" \
     --arg hash "$tarball_hash" \
     --arg fake "$FAKE_HASH" '
       .versions[$k] = { version: $ver, rev: $rev, hash: $hash, pnpmDepsHash: $fake }
       | .latest = $k
     ' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  # 3) pnpm.fetchDeps hash (single, portable).
  log_info "Computing pnpmDepsHash..."
  local deps_hash
  deps_hash="$(build_and_get_hash "$attr")"
  if [ -z "$deps_hash" ]; then
    log_info "  pnpmDepsHash already correct (no rehash needed)."
  else
    log_info "  pnpmDepsHash: $deps_hash"
    tmp="$(mktemp)"
    jq --arg k "$latest_version" --arg h "$deps_hash" \
      '.versions[$k].pnpmDepsHash = $h' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"
  fi

  if [ "$no_build" != true ]; then
    if ! verify_build "$attr"; then
      log_error "Build verification failed; restoring previous releases.json"
      cp "$backup" "$releases_file"
      rm -f "$backup"
      exit 1
    fi
  fi

  rm -f "$backup"

  log_info "releases.json now contains:"
  jq -r '.latest as $l | "  latest=" + $l, (.versions | keys[] | "  - " + .)' "$releases_file"

  show_changes

  if [ "$do_commit" = true ]; then
    maybe_git_commit "$(build_commit_message "$current_version" "$latest_version")" \
      "releases.json" "$(lockfile_rel "$latest_version")"
  fi

  log_info "Successfully appended ${PACKAGE_ATTR} $latest_version (latest was $current_version)"
}

main "$@"
