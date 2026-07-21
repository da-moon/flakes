#!/usr/bin/env bash
# Appends the newest upstream commit of nimbushq/dd-cli as a new entry in
# releases.json (the JSON version table the flake reads). Never hand-edits the
# version data in flake.nix.
#
# dd-cli has NO release tags, so:
#   key     = short (7-char) upstream commit hash
#   version = "<base>-unstable-<commit-date>" (base taken from the current
#             latest entry, e.g. "1.0.0"; nixpkgs uses "0" once past a release)
#
# Reproducible-deps model (yarn classic): dependencies are pinned by a COMMITTED
# yarn.lock under deps/<key>/, fetched at build time into an offline mirror by
# fetchYarnDeps. This script therefore, per commit:
#   - .hash          : fetchFromGitHub source hash (prefetched via
#                      `nix store prefetch-file --unpack`, so it is independent
#                      of the build).
#   - deps/<key>/yarn.lock : a freshly resolved, committed lockfile (complete —
#                      upstream's own yarn.lock may omit devDependencies).
#   - .yarnDepsHash  : the single portable fetchYarnDeps offline-mirror hash,
#                      recomputed via the fakeHash -> nix build -> parse "got:".
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly GITHUB_API_BASE="https://api.github.com"
readonly REPO_OWNER="nimbushq"
readonly REPO_NAME="dd-cli"
readonly REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
readonly BIN_NAME="dd-cli"
# nixpkgs ref used to obtain yarn classic matching flake.nix.
readonly NIXPKGS_REF="github:NixOS/nixpkgs/nixos-26.05"
# lib.fakeHash — the sentinel nix rejects, forcing it to print the real "got:" hash.
readonly FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_required_tools_installed() {
  for t in nix curl jq git tar; do
    command -v "$t" >/dev/null 2>&1 || { log_error "$t is required but not installed."; exit 2; }
  done
}

ensure_in_package_directory() {
  [ -f "${pkg_dir}/flake.nix" ] || { log_error "flake.nix not found in ${pkg_dir}"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at $releases_file"; exit 2; }
}

sanitize_key() { printf '%s' "$1" | tr '.+-' '___'; }

extract_got_hash() {
  sed -n 's~.*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*~\1~p' | head -n1
}

# yarn classic from the pinned nixpkgs.
yarn_run() { nix shell "${NIXPKGS_REF}#yarn" --command yarn "$@"; }

lockfile_rel() { printf 'deps/%s/yarn.lock' "$1"; }
lockfile_exists() { [ -f "${pkg_dir}/$(lockfile_rel "$1")" ]; }

# Resolve the newest default-branch commit (full 40-char sha + committer date).
resolve_head() {
  local ref="$1" sha commit_json full_sha date
  if [ -n "$ref" ]; then
    sha="$(git ls-remote "$REPO_URL" "$ref" | awk 'NR==1{print $1}')"
    [ -n "$sha" ] || sha="$ref"
  else
    sha="$(git ls-remote "$REPO_URL" HEAD | awk 'NR==1{print $1}')"
  fi
  [ -n "$sha" ] || { log_error "could not resolve upstream rev"; exit 2; }
  commit_json="$(curl -fsSL "$GITHUB_API_BASE/repos/$REPO_OWNER/$REPO_NAME/commits/$sha")"
  full_sha="$(printf '%s' "$commit_json" | jq -r '.sha')"
  date="$(printf '%s' "$commit_json" | jq -r '.commit.committer.date' | cut -dT -f1)"
  [ -n "$full_sha" ] && [ "$full_sha" != "null" ] || { log_error "could not resolve full sha for $sha"; exit 2; }
  [ -n "$date" ] && [ "$date" != "null" ] || { log_error "could not resolve commit date for $sha"; exit 2; }
  printf '%s|%s\n' "$full_sha" "$date"
}

# fetchFromGitHub source hash, prefetched (unpacked NAR) independently of the build.
prefetch_github_src() {
  local rev="$1"
  nix store prefetch-file --unpack --json --hash-type sha256 \
    "https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/${rev}.tar.gz" \
    | jq -r '.hash // empty'
}

# Resolve + commit a COMPLETE yarn.lock for REV under deps/<key>/. Generated
# fresh (upstream's committed yarn.lock may omit devDependencies needed to build).
generate_yarn_lock() {
  local rev="$1" key="$2"
  local dest="${pkg_dir}/deps/${key}"
  local work; work="$(mktemp -d)"
  log_info "Generating yarn.lock for ${key}..."
  curl -fsSL "https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/${rev}.tar.gz" -o "$work/src.tgz"
  tar -xzf "$work/src.tgz" -C "$work"
  local srcdir; srcdir="$(find "$work" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n1)"
  [ -n "$srcdir" ] || { log_error "could not locate extracted source dir"; rm -rf "$work"; return 1; }
  (
    cd "$srcdir"
    export HOME="$work/home"; mkdir -p "$HOME"
    yarn_run install --ignore-scripts --non-interactive --no-progress >/dev/null 2>&1
  )
  [ -f "$srcdir/yarn.lock" ] || { log_error "lockfile generation produced no yarn.lock"; rm -rf "$work"; return 1; }
  mkdir -p "$dest"
  cp "$srcdir/yarn.lock" "$dest/yarn.lock"
  rm -rf "$work"
  log_info "  committed $(lockfile_rel "$key")"
}

# Recompute the fetchYarnDeps hash by building the attr with a fake yarnDepsHash
# already written into releases.json and parsing nix's "got:" line. The source
# .hash must already be real so only the fetchYarnDeps FOD mismatches.
build_and_get_hash() {
  local attr="$1" out
  out="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link 2>&1 || true)"
  printf '%s\n' "$out" | extract_got_hash
}

current_hash_is_fake() {
  local key="$1" h
  h="$(jq -r --arg k "$key" '.versions[$k].yarnDepsHash // empty' "$releases_file")"
  [ -z "$h" ] || [ "$h" = "$FAKE_HASH" ]
}

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest upstream commit of nimbushq/dd-cli to releases.json and sets
it as .latest. For the new commit it prefetches the fetchFromGitHub source hash,
generates+commits deps/<key>/yarn.lock, and recomputes the single portable
.yarnDepsHash via the fakeHash -> nix build -> parse "got:" method.

Options:
  --check            Print whether a newer commit exists; exit 1 if it does.
  --rev VALUE        Pin to a specific git ref/branch/rev instead of HEAD
                       (aliases: --revision, --version).
  --rehash           Regenerate lockfile + yarnDepsHash for the latest entry.
  --no-build         Skip the final verification build.
  --no-commit        Do not auto-commit (default: auto-commit is enabled).
  --help             Show this help.
EOF
}

maybe_git_commit() {
  local commit_message="$1"; shift
  local -a paths=("$@")
  command -v git >/dev/null 2>&1 || { log_warn "git not found; skipping commit"; return 0; }
  git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    log_warn "not in a git work tree; skipping commit"; return 0; }
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

  local check_only=false no_build=false do_commit=true rehash=false target_ref=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check) check_only=true; shift ;;
      --no-build) no_build=true; shift ;;
      --no-commit) do_commit=false; shift ;;
      --rehash) rehash=true; shift ;;
      --rev|--revision|--version)
        [ $# -ge 2 ] || { log_error "$1 requires an argument"; exit 2; }
        target_ref="$2"; shift 2 ;;
      --help) print_usage; exit 0 ;;
      *) log_error "Unknown option: $1"; print_usage; exit 2 ;;
    esac
  done

  local cur_latest_key cur_latest_ver base
  cur_latest_key="$(jq -r '.latest' "$releases_file")"
  cur_latest_ver="$(jq -r --arg k "$cur_latest_key" '.versions[$k].version' "$releases_file")"
  base="${cur_latest_ver%%-unstable-*}"
  [ -n "$base" ] || base="0"

  local info rev date short_key new_version
  info="$(resolve_head "$target_ref")"
  rev="${info%%|*}"
  date="${info##*|}"
  short_key="${rev:0:7}"
  new_version="${base}-unstable-${date}"

  log_info "Current latest key: ${cur_latest_key} (${cur_latest_ver})"
  log_info "Resolved upstream:  ${rev}"
  log_info "New key:            ${short_key}"
  log_info "New version:        ${new_version}"

  local up_to_date=false
  if [ "$short_key" = "$cur_latest_key" ] && lockfile_exists "$short_key" \
    && ! current_hash_is_fake "$short_key"; then
    up_to_date=true
  fi

  if [ "$check_only" = true ]; then
    if [ "$up_to_date" = true ]; then log_info "Already up to date (latest is ${cur_latest_key})."; exit 0; fi
    log_info "Update available: ${short_key}"; exit 1
  fi

  if [ "$up_to_date" = true ] && [ "$rehash" != true ]; then
    log_info "Already up to date (latest is ${cur_latest_key})."; exit 0
  fi

  local attr; attr="dd-cli_$(sanitize_key "$short_key")"

  # 1) source hash (prefetched, independent of build).
  log_info "Prefetching fetchFromGitHub source hash..."
  local src_hash; src_hash="$(prefetch_github_src "$rev")"
  [ -n "$src_hash" ] || { log_error "failed to prefetch source hash"; exit 1; }
  log_info "  src hash: $src_hash"

  # 2) generate + commit the yarn.lock.
  generate_yarn_lock "$rev" "$short_key"

  local backup tmp
  backup="$(mktemp -t releases.json.backup.XXXXXX)"
  cp "$releases_file" "$backup"

  # Seed entry with the real source hash but a fake yarnDepsHash so only the
  # fetchYarnDeps FOD mismatches on build. Set it as .latest.
  tmp="$(mktemp)"
  jq --arg k "$short_key" \
     --arg ver "$new_version" \
     --arg rev "$rev" \
     --arg hash "$src_hash" \
     --arg fake "$FAKE_HASH" '
       .versions[$k] = { version: $ver, rev: $rev, hash: $hash, yarnDepsHash: $fake }
       | .latest = $k
     ' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"

  # 3) fetchYarnDeps hash (single, portable).
  log_info "Computing yarnDepsHash..."
  local deps_hash; deps_hash="$(build_and_get_hash "$attr")"
  if [ -z "$deps_hash" ]; then
    log_info "  yarnDepsHash already correct (no rehash needed)."
  else
    log_info "  yarnDepsHash: $deps_hash"
    tmp="$(mktemp)"
    jq --arg k "$short_key" --arg h "$deps_hash" \
      '.versions[$k].yarnDepsHash = $h' "$releases_file" >"$tmp" && mv "$tmp" "$releases_file"
  fi

  if [ "$no_build" = false ]; then
    log_info "Verifying build of ${attr}..."
    local out
    if ! out="$(cd "$pkg_dir" && nix build ".#${attr}" --no-write-lock-file --no-link --print-out-paths 2>&1)"; then
      log_error "verification build failed; restoring previous releases.json"
      printf '%s\n' "$out" | tail -n 40 >&2
      cp "$backup" "$releases_file"; rm -f "$backup"; exit 1
    fi
    out="$(printf '%s\n' "$out" | tail -n1)"
    if [ -z "$out" ] || [ ! -x "$out/bin/$BIN_NAME" ]; then
      log_error "Build succeeded but expected binary not found at: $out/bin/$BIN_NAME"
      cp "$backup" "$releases_file"; rm -f "$backup"; exit 1
    fi
    log_info "Build OK: $out"
  fi

  rm -f "$backup"

  log_info "releases.json now contains:"
  jq -r '.latest as $l | "  latest=" + $l, (.versions | keys[] | "  - " + .)' "$releases_file"

  if [ "$do_commit" = true ]; then
    local scope msg
    scope="$(basename "$pkg_dir")"
    if [ "$short_key" = "$cur_latest_key" ]; then
      msg="chore(${scope}): rehash ${new_version} (${short_key})"
    else
      msg="chore(${scope}): add ${new_version} (${short_key}) to version table"
    fi
    maybe_git_commit "$msg" "releases.json" "$(lockfile_rel "$short_key")"
  fi
}

main "$@"
