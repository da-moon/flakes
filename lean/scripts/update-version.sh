#!/usr/bin/env bash
# Appends the newest (or an explicit) QuantConnect Lean CLI release to
# releases.json (the JSON version table read by flake.nix) and sets it as
# .latest. The version data in flake.nix is never touched.
#
# lean is PyPI-tagged, so:
#   key     = the Lean CLI version (e.g. "1.0.227")
#
# Each entry records everything the flake needs to build reproducibly:
#   - version / hash                : lean sdist from PyPI
#   - stubsVersion / stubsHash      : quantconnect-stubs wheel from PyPI
#   - engineImageTag                : pinned quantconnect/lean + research tag
#   - engineImageDigest             : quantconnect/lean:<tag> image digest
#   - researchImageDigest           : quantconnect/research:<tag> image digest
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
flake_file="${pkg_dir}/flake.nix"
releases_file="${pkg_dir}/releases.json"
readonly PACKAGE_DIR_NAME="$(basename "${pkg_dir}")"

ensure_tools() {
  for tool in curl nix jq python3; do
    command -v "$tool" >/dev/null 2>&1 || { log_error "$tool is required"; exit 2; }
  done
}

ensure_in_package_directory() {
  [ -f "$flake_file" ] || { log_error "flake.nix not found in ${pkg_dir}"; exit 2; }
  [ -f "$releases_file" ] || { log_error "releases.json not found at $releases_file"; exit 2; }
}

# Current "latest" key recorded in the version table.
current_version() {
  jq -r '.latest // empty' "$releases_file"
}

# Does the table already have an entry for this key?
has_version_entry() {
  local key="$1"
  [ "$(jq -r --arg k "$key" '.versions | has($k)' "$releases_file")" = "true" ]
}

# sanitize a JSON key into a valid nix attribute-name suffix (mirrors flake.nix)
sanitize_key() {
  printf '%s' "$1" | tr '.+-' '___'
}

read_metadata() {
  local requested_cli="$1"
  local requested_engine="$2"
  python3 - "$requested_cli" "$requested_engine" <<'PY'
import json
import sys
import urllib.request

cli_version, engine_tag = sys.argv[1], sys.argv[2]

lean = json.load(urllib.request.urlopen("https://pypi.org/pypi/lean/json"))
if not cli_version:
    cli_version = lean["info"]["version"]
for item in lean["releases"][cli_version]:
    if item["packagetype"] == "sdist":
        lean_hash = item["digests"]["sha256"]
        break
else:
    raise SystemExit(f"no lean sdist found for {cli_version}")

stubs = json.load(urllib.request.urlopen("https://pypi.org/pypi/quantconnect-stubs/json"))
stubs_version = stubs["info"]["version"]
for item in stubs["releases"][stubs_version]:
    if item["packagetype"] == "bdist_wheel":
        stubs_hash = item["digests"]["sha256"]
        break
else:
    raise SystemExit(f"no quantconnect-stubs wheel found for {stubs_version}")

if not engine_tag:
    tags = json.load(urllib.request.urlopen("https://registry.hub.docker.com/v2/repositories/quantconnect/lean/tags?page_size=20"))
    numeric = [tag["name"] for tag in tags["results"] if tag["name"].isdigit()]
    engine_tag = sorted(numeric, key=int)[-1]

engine = json.load(urllib.request.urlopen(f"https://registry.hub.docker.com/v2/repositories/quantconnect/lean/tags/{engine_tag}"))
research = json.load(urllib.request.urlopen(f"https://registry.hub.docker.com/v2/repositories/quantconnect/research/tags/{engine_tag}"))

print(cli_version)
print(lean_hash)
print(stubs_version)
print(stubs_hash)
print(engine_tag)
print(engine["digest"])
print(research["digest"])
PY
}

sha256_hex_to_sri() {
  nix hash to-sri --type sha256 "$1"
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
  if ! (cd "$pkg_dir" && nix build ".#lean_${sanitized_key}" --no-link --no-write-lock-file); then
    log_error "nix build failed for lean_${sanitized_key}"
    return 1
  fi
  # default must also resolve (it points at the new .latest).
  if ! (cd "$pkg_dir" && nix build ".#default" --no-link --no-write-lock-file); then
    log_error "nix build failed for default"
    return 1
  fi
  log_info "Build successful!"
}

build_commit_message() {
  local previous_key="$1"
  local new_key="$2"
  local rehash="${3:-false}"

  local scope
  scope="$(basename "$pkg_dir")"

  if [ "$previous_key" != "$new_key" ]; then
    printf 'chore(%s): add %s to version table\n' "$scope" "$new_key"
    return 0
  fi

  if [ "$rehash" = true ]; then
    printf 'chore(%s): rehash %s\n' "$scope" "$new_key"
    return 0
  fi

  printf 'chore(%s): update version\n' "$scope"
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

usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Appends the newest (or an explicit) Lean CLI release to releases.json as a new
version-table entry (keyed by Lean CLI version) and sets .latest to it. Existing
entries are preserved so consumers can still select past versions. Recomputes the
lean sdist hash, quantconnect-stubs wheel hash, and pinned Docker image digests.

Options:
  --version VERSION   Append a specific Lean CLI version (default: latest)
  --engine-tag TAG    Pin a specific quantconnect/lean engine tag (default: latest)
  --rehash            Force a rehash commit message when the key is unchanged
  --check             Only check for updates (exit 1 if update available)
  --no-build          Skip build verification
  --help              Show this help message
EOF
}

main() {
  ensure_tools
  ensure_in_package_directory
  log_info "Updating package: ${PACKAGE_DIR_NAME}"

  local requested_cli="" requested_engine="" check=false no_build=false rehash=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || { log_error "--version requires an argument"; exit 2; }
        requested_cli="$2"; shift 2 ;;
      --engine-tag)
        [ $# -ge 2 ] || { log_error "--engine-tag requires an argument"; exit 2; }
        requested_engine="$2"; shift 2 ;;
      --rehash) rehash=true; shift ;;
      --check) check=true; shift ;;
      --no-build) no_build=true; shift ;;
      --help) usage; exit 0 ;;
      *) log_error "Unknown option: $1"; usage; exit 2 ;;
    esac
  done

  local current
  current="$(current_version)"
  if [ -z "$current" ]; then
    log_error "Failed to detect current version from releases.json"
    exit 2
  fi

  local metadata
  if ! metadata="$(read_metadata "$requested_cli" "$requested_engine")"; then
    log_error "failed to fetch metadata from PyPI/Docker Hub"
    exit 1
  fi
  mapfile -t fields <<<"$metadata"
  if [ "${#fields[@]}" -ne 7 ]; then
    log_error "expected 7 metadata fields, got ${#fields[@]}"
    exit 1
  fi

  local cli_version="${fields[0]}" lean_hash_hex="${fields[1]}" \
    stubs_version="${fields[2]}" stubs_hash_hex="${fields[3]}" \
    engine_tag="${fields[4]}" engine_digest="${fields[5]}" research_digest="${fields[6]}"

  log_info "Current Lean CLI: $current"
  log_info "Target Lean CLI:  ${cli_version}"
  log_info "Target engine:    quantconnect/lean:${engine_tag}@${engine_digest}"

  if [ "$check" = true ]; then
    if has_version_entry "$cli_version" && [ "$current" = "$cli_version" ]; then
      log_info "Already up to date!"
      exit 0
    fi
    log_info "Update available: $current -> $cli_version"
    exit 1
  fi

  local lean_sri stubs_sri
  lean_sri="$(sha256_hex_to_sri "$lean_hash_hex")"
  stubs_sri="$(sha256_hex_to_sri "$stubs_hash_hex")"

  local entry_json
  entry_json="$(jq -n \
    --arg v "$cli_version" \
    --arg hash "$lean_sri" \
    --arg sv "$stubs_version" \
    --arg sh "$stubs_sri" \
    --arg et "$engine_tag" \
    --arg ed "$engine_digest" \
    --arg rd "$research_digest" \
    '{version: $v, hash: $hash, stubsVersion: $sv, stubsHash: $sh,
      engineImageTag: $et, engineImageDigest: $ed, researchImageDigest: $rd}')"

  local backup
  backup="$(mktemp)"
  cp -- "$releases_file" "$backup"

  upsert_release_entry "$cli_version" "$entry_json"

  local sanitized_key
  sanitized_key="$(sanitize_key "$cli_version")"

  if [ "$no_build" != true ]; then
    if ! verify_build "$sanitized_key"; then
      log_error "Build verification failed; restoring previous releases.json"
      cp -- "$backup" "$releases_file"
      rm -f -- "$backup"
      exit 1
    fi
  fi

  rm -f -- "$backup"

  log_info "releases.json now contains:"
  jq -r '.latest as $l | "  latest=" + $l, (.versions | keys[] | "  - " + .)' "$releases_file"

  maybe_git_commit "$(build_commit_message "$current" "$cli_version" "$rehash")" "releases.json"

  log_info "Updated lean CLI to ${cli_version} with engine tag ${engine_tag}"
}

main "$@"
