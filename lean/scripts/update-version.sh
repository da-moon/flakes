#!/usr/bin/env bash
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

ensure_tools() {
  for tool in curl nix python3 sed; do
    command -v "$tool" >/dev/null 2>&1 || { log_error "$tool is required"; exit 2; }
  done
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

current_version() {
  sed -n '/pname = "lean";/,/format = "setuptools";/ s/^[[:space:]]*version = "\([^"]*\)".*/\1/p' "$flake_file" | head -n1
}

update_flake() {
  local cli_version="$1" lean_hash="$2" stubs_version="$3" stubs_hash="$4" engine_tag="$5" engine_digest="$6" research_digest="$7"
  local lean_sri stubs_sri
  lean_sri="$(nix hash to-sri --type sha256 "$lean_hash")"
  stubs_sri="$(nix hash to-sri --type sha256 "$stubs_hash")"

  python3 - "$flake_file" "$cli_version" "$lean_sri" "$stubs_version" "$stubs_sri" "$engine_tag" "$engine_digest" "$research_digest" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
cli_version, lean_hash, stubs_version, stubs_hash, engine_tag, engine_digest, research_digest = sys.argv[2:]
text = path.read_text()

text = re.sub(r'(engineImageTag = ")[^"]+(";)', rf'\g<1>{engine_tag}\2', text)
text = re.sub(r'(engineImageDigest = ")[^"]+(";)', rf'\g<1>{engine_digest}\2', text)
text = re.sub(r'(researchImageDigest = ")[^"]+(";)', rf'\g<1>{research_digest}\2', text)
text = re.sub(r'(pname = "quantconnect-stubs";\n\s*version = ")[^"]+(";)', rf'\g<1>{stubs_version}\2', text)
text = re.sub(r'(pname = "quantconnect_stubs";\n\s*version = ")[^"]+(";)', rf'\g<1>{stubs_version}\2', text)
text = re.sub(r'(pname = "quantconnect_stubs";(?:.|\n)*?hash = ")[^"]+(";)', rf'\g<1>{stubs_hash}\2', text, count=1)
text = re.sub(r'(pname = "lean";\n\s*version = ")[^"]+(";)', rf'\g<1>{cli_version}\2', text)
text = re.sub(r'(inherit pname version;\n\s*hash = ")[^"]+(";)', rf'\g<1>{lean_hash}\2', text, count=1)

path.write_text(text)
PY
}

verify_build() {
  log_info "Verifying build..."
  (cd "$pkg_dir" && nix build .#lean --no-link)
}

usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [--version LEAN_CLI_VERSION] [--engine-tag TAG] [--check] [--no-build]
EOF
}

main() {
  ensure_tools
  local requested_cli="" requested_engine="" check=false no_build=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) requested_cli="${2:-}"; shift 2 ;;
      --engine-tag) requested_engine="${2:-}"; shift 2 ;;
      --check) check=true; shift ;;
      --no-build) no_build=true; shift ;;
      --help) usage; exit 0 ;;
      *) log_error "Unknown option: $1"; usage; exit 2 ;;
    esac
  done

  local current
  current="$(current_version)"
  mapfile -t fields < <(read_metadata "$requested_cli" "$requested_engine")

  log_info "Current Lean CLI: $current"
  log_info "Target Lean CLI:  ${fields[0]}"
  log_info "Target engine:    quantconnect/lean:${fields[4]}@${fields[5]}"
  if [ "$check" = true ]; then
    [ "$current" = "${fields[0]}" ] && exit 0 || exit 1
  fi

  update_flake "${fields[@]}"
  [ "$no_build" = true ] || verify_build
  log_info "Updated lean CLI to ${fields[0]} with engine tag ${fields[4]}"
}

main "$@"
