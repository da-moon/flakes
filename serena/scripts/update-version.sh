#!/usr/bin/env bash
# Select one stable Serena tag, refresh its immutable upstream pin and schema
# evidence, verify the staged flake, then apply and optionally commit the change.
#
# There is deliberately no --no-build escape hatch. A release update is only
# applied after the candidate package and every flake check succeed.
set -Eeuo pipefail

readonly REPO_OWNER="oraios"
readonly REPO_NAME="serena"
readonly REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
readonly PIN_BEGIN="# BEGIN GENERATED SERENA UPSTREAM INPUT"
readonly PIN_END="# END GENERATED SERENA UPSTREAM INPUT"
readonly SCHEMA_DRIFT_EXIT=3

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${script_dir}/.." && pwd)"
releases_file="${pkg_dir}/releases.json"

readonly -a fixture_rel_paths=(
  "schema/fixtures/serena_config.template.yml"
  "schema/fixtures/project.template.yml"
  "schema/fixtures/project.local.template.yml"
  "schema/fixtures/context.template.yml"
  "schema/fixtures/mode.template.yml"
  "schema/fixtures/prompt_templates/info_prompts.yml"
  "schema/fixtures/prompt_templates/simple_tool_outputs.yml"
  "schema/fixtures/prompt_templates/system_prompt.yml"
)

readonly -a fixture_source_paths=(
  "src/serena/resources/serena_config.template.yml"
  "src/serena/resources/project.template.yml"
  "src/serena/resources/project.local.template.yml"
  "src/serena/resources/config/contexts/context.template.yml"
  "src/serena/resources/config/modes/mode.template.yml"
  "src/serena/resources/config/prompt_templates/info_prompts.yml"
  "src/serena/resources/config/prompt_templates/simple_tool_outputs.yml"
  "src/serena/resources/config/prompt_templates/system_prompt.yml"
)

readonly -a generated_rel_paths=(
  "flake.nix"
  "releases.json"
  "schema/upstream.json"
  "${fixture_rel_paths[@]}"
)

stage_root=""
stage_pkg=""
baseline_pkg=""
keep_stage=false

log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

die() {
  local message="$1"
  local code="${2:-2}"
  log_error "$message"
  exit "$code"
}

cleanup() {
  local status=$?
  if [[ -n "$stage_root" && -d "$stage_root" ]]; then
    if [[ "$keep_stage" == true ]]; then
      log_warn "Candidate staging directory retained for review: ${stage_root}"
    else
      rm -rf -- "$stage_root"
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

print_usage() {
  cat <<'EOF'
Usage: ./scripts/update-version.sh [OPTIONS]

Select the highest final SemVer tag from oraios/serena, replace the sole entry
in releases.json, refresh the exact-revision flake input and source-derived
schema evidence, verify in an isolated staging tree, and apply atomically.

Options:
  --tag TAG       Select an explicit final SemVer tag, including an older tag
                  for rollback. Both v1.5.3 and 1.5.3 are accepted.
  --check         Read-only comparison. Exit 0 if exact, 1 if an update or
                  fixture refresh is available, 2 on error, and 3 on schema
                  drift requiring human review.
  --rehash        Keep the recorded tag and exact revision; recompute source
                  and schema hashes, refresh fixtures, and fully verify.
  --no-commit     Apply verified files without creating the scoped Git commit.
  -h, --help      Show this help.

The generated input block in flake.nix must use these exact marker comments:

  # BEGIN GENERATED SERENA UPSTREAM INPUT
  serena-upstream.url = "github:oraios/serena/<40-character-revision>";
  # END GENERATED SERENA UPSTREAM INPUT

There is intentionally no --no-build option.
EOF
}

ensure_tools() {
  local tool
  for tool in awk cmp cp diff flock git install jq mktemp mv nix python3 sha256sum sort tail yq; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool is not installed: ${tool}"
  done
}

validate_final_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

load_current_release() {
  [[ -f "$releases_file" ]] || die "Missing releases.json: ${releases_file}"
  jq -e '
    (.latest | type == "string") and
    (.versions | type == "object" and length == 1) and
    (.versions[.latest] | type == "object")
  ' "$releases_file" >/dev/null || die "releases.json must contain exactly one selected version"

  current_version="$(jq -r '.latest' "$releases_file")"
  current_tag="$(jq -r '.versions[.latest].tag' "$releases_file")"
  current_rev="$(jq -r '.versions[.latest].rev' "$releases_file")"
  current_nar_hash="$(jq -r '.versions[.latest].narHash' "$releases_file")"
  current_schema_sha="$(jq -r '.versions[.latest].schemaSha256' "$releases_file")"

  validate_final_version "$current_version" || die "Invalid selected final SemVer: ${current_version}"
  [[ "$current_tag" == "v${current_version}" ]] || die "Selected tag/version mismatch in releases.json"
  [[ "$current_rev" =~ ^[0-9a-f]{40}$ ]] || die "Invalid selected revision in releases.json"
  [[ "$current_nar_hash" == sha256-* ]] || die "Invalid selected narHash in releases.json"
  [[ "$current_schema_sha" =~ ^[0-9a-f]{64}$ ]] || die "Invalid schemaSha256 in releases.json"
}

discover_highest_final_tag() {
  local line
  line="$({
    git ls-remote --tags --refs "$REPO_URL" \
      | awk '
          $2 ~ /^refs\/tags\/v?[0-9]+\.[0-9]+\.[0-9]+$/ {
            tag = $2
            sub(/^refs\/tags\//, "", tag)
            version = tag
            sub(/^v/, "", version)
            print version "\t" tag
          }
        ' \
      | sort -t $'\t' -k1,1V -k2,2 \
      | tail -n 1
  } || true)"
  [[ -n "$line" ]] || die "No final SemVer tag found in ${REPO_URL}"
  target_version="${line%%$'\t'*}"
  target_tag="${line#*$'\t'}"
}

resolve_explicit_tag() {
  local requested="$1"
  local version="${requested#v}"
  local candidate output
  validate_final_version "$version" || die "--tag requires a final SemVer tag such as v1.5.3"

  for candidate in "v${version}" "${version}"; do
    if output="$(git ls-remote --tags "$REPO_URL" "refs/tags/${candidate}" 2>/dev/null)" \
      && [[ -n "$output" ]]; then
      target_version="$version"
      target_tag="$candidate"
      return 0
    fi
  done
  die "Tag does not exist upstream: ${requested}"
}

resolve_tag_revision() {
  local tag="$1"
  local refs dereferenced direct
  refs="$(git ls-remote --tags "$REPO_URL" "refs/tags/${tag}" "refs/tags/${tag}^{}")"
  dereferenced="$(printf '%s\n' "$refs" | awk '$2 ~ /\^\{\}$/ { print $1; exit }')"
  direct="$(printf '%s\n' "$refs" | awk '$2 !~ /\^\{\}$/ { print $1; exit }')"
  target_rev="${dereferenced:-$direct}"
  [[ "$target_rev" =~ ^[0-9a-f]{40}$ ]] || die "Could not resolve ${tag} to a commit revision"
}

prefetch_candidate() {
  local prefetch_json
  log_info "Prefetching immutable upstream revision ${target_rev}"
  prefetch_json="$(nix flake prefetch --json "github:${REPO_OWNER}/${REPO_NAME}/${target_rev}")"
  target_nar_hash="$(printf '%s' "$prefetch_json" | jq -er '.hash')"
  target_store_path="$(printf '%s' "$prefetch_json" | jq -er '.storePath')"
  [[ "$target_nar_hash" == sha256-* ]] || die "nix flake prefetch returned an invalid hash"
  [[ -d "$target_store_path" ]] || die "Prefetched source path does not exist: ${target_store_path}"

  local pyproject_version
  pyproject_version="$(awk -F '"' '/^version[[:space:]]*=[[:space:]]*"/ { print $2; exit }' \
    "${target_store_path}/pyproject.toml")"
  [[ "$pyproject_version" == "$target_version" ]] \
    || die "Tag ${target_tag} reports pyproject version ${pyproject_version:-<missing>}, expected ${target_version}"
}

copy_normalized_fixture() {
  local source="$1"
  local destination="$2"
  [[ -f "$source" ]] || die "Upstream schema fixture is missing: ${source}"
  mkdir -p -- "$(dirname -- "$destination")"
  # Normalise incidental trailing blanks and the final newline so upstream
  # prompt block scalars remain safe for git diff --check.
  awk '{ sub(/[[:blank:]]+$/, ""); print }' "$source" >"${destination}.tmp"
  mv -f -- "${destination}.tmp" "$destination"
}

generate_source_inventory() {
  local source_root="$1"
  local prompt_json_dir="$2"
  local output="$3"

  python3 - "$source_root" "$prompt_json_dir" "$output" <<'PY'
import ast
import hashlib
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
prompt_json_dir = Path(sys.argv[2])
output_path = Path(sys.argv[3])


def parse(path: Path) -> ast.AST:
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def literal(node: ast.AST, constants: dict[str, object]) -> object:
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.Name) and node.id in constants:
        return constants[node.id]
    if isinstance(node, (ast.List, ast.Tuple, ast.Set)):
        values = [literal(item, constants) for item in node.elts]
        return sorted(values, key=lambda value: json.dumps(value, sort_keys=True)) if isinstance(node, ast.Set) else values
    if isinstance(node, ast.Dict):
        return {
            str(literal(key, constants)): literal(value, constants)
            for key, value in zip(node.keys, node.values, strict=True)
            if key is not None
        }
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
        value = literal(node.operand, constants)
        if isinstance(value, (int, float)):
            return -value
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left = literal(node.left, constants)
        right = literal(node.right, constants)
        if isinstance(left, (str, int, float, list)) and isinstance(right, type(left)):
            return left + right
    return {"expression": ast.unparse(node)}


def module_constants(tree: ast.AST) -> dict[str, object]:
    constants: dict[str, object] = {}
    pending: list[tuple[str, ast.AST]] = []
    for statement in getattr(tree, "body", []):
        if isinstance(statement, ast.Assign) and len(statement.targets) == 1 and isinstance(statement.targets[0], ast.Name):
            pending.append((statement.targets[0].id, statement.value))
        elif isinstance(statement, ast.AnnAssign) and isinstance(statement.target, ast.Name) and statement.value is not None:
            pending.append((statement.target.id, statement.value))
    for _ in range(len(pending) + 1):
        changed = False
        for name, value_node in pending:
            value = literal(value_node, constants)
            if not (isinstance(value, dict) and set(value) == {"expression"}):
                if constants.get(name) != value:
                    constants[name] = value
                    changed = True
        if not changed:
            break
    return constants


ls_config_path = root / "src/solidlsp/ls_config.py"
ls_config_tree = parse(ls_config_path)
language_names: dict[str, str] = {}
module_languages: dict[str, str] = {}
for node in getattr(ls_config_tree, "body", []):
    if isinstance(node, ast.ClassDef) and node.name == "Language":
        for statement in node.body:
            if (
                isinstance(statement, ast.Assign)
                and len(statement.targets) == 1
                and isinstance(statement.targets[0], ast.Name)
                and isinstance(statement.value, ast.Constant)
                and isinstance(statement.value.value, str)
            ):
                language_names[statement.targets[0].id] = statement.value.value
        for statement in node.body:
            if isinstance(statement, ast.FunctionDef) and statement.name == "get_ls_class":
                for match in (item for item in ast.walk(statement) if isinstance(item, ast.Match)):
                    for case in match.cases:
                        enum_name = None
                        pattern = case.pattern
                        if (
                            isinstance(pattern, ast.MatchValue)
                            and isinstance(pattern.value, ast.Attribute)
                            and isinstance(pattern.value.value, ast.Name)
                            and pattern.value.value.id == "self"
                        ):
                            enum_name = pattern.value.attr
                        if enum_name not in language_names:
                            continue
                        for child in case.body:
                            if isinstance(child, ast.ImportFrom) and child.module and child.module.startswith("solidlsp.language_servers."):
                                module_languages[child.module] = language_names[enum_name]

language_values = list(language_names.values())

serena_config_tree = parse(root / "src/serena/config/serena_config.py")
tool_fields: list[str] = []
for node in getattr(serena_config_tree, "body", []):
    if isinstance(node, ast.ClassDef) and node.name == "ToolInclusionDefinition":
        for statement in node.body:
            if isinstance(statement, ast.AnnAssign) and isinstance(statement.target, ast.Name):
                tool_fields.append(statement.target.id)

context_mode_tree = parse(root / "src/serena/config/context_mode.py")
context_fields: list[str] = []
mode_fields: list[str] = []
for node in getattr(context_mode_tree, "body", []):
    if not isinstance(node, ast.ClassDef):
        continue
    own_fields = [
        statement.target.id
        for statement in node.body
        if isinstance(statement, ast.AnnAssign)
        and isinstance(statement.target, ast.Name)
        and not statement.target.id.startswith("_")
    ]
    if node.name == "SerenaAgentContext":
        context_fields = own_fields + tool_fields
    elif node.name == "SerenaAgentMode":
        mode_fields = own_fields + tool_fields


def shape(value: object) -> object:
    if isinstance(value, dict):
        return {"type": "attrs", "fields": {key: shape(value[key]) for key in sorted(value)}}
    if isinstance(value, list):
        element_shapes = []
        for item in value:
            item_shape = shape(item)
            if item_shape not in element_shapes:
                element_shapes.append(item_shape)
        return {"type": "list", "elementShapes": element_shapes}
    if value is None:
        return {"type": "null"}
    if isinstance(value, bool):
        return {"type": "bool"}
    if isinstance(value, int):
        return {"type": "int"}
    if isinstance(value, float):
        return {"type": "float"}
    if isinstance(value, str):
        return {"type": "string"}
    raise TypeError(type(value))


prompt_files = {}
for path in sorted(prompt_json_dir.glob("*.json")):
    prompt_files[path.stem.removesuffix(".yml")] = shape(json.loads(path.read_text(encoding="utf-8")))


def receiver_is_settings(expression: ast.AST) -> bool:
    text = ast.unparse(expression)
    lower = text.lower()
    if "[" in text and not lower.endswith(".settings"):
        return False
    return (
        "custom_settings" in lower
        or "specific_settings" in lower
        or lower.endswith("_settings")
        or lower.endswith("_config")
        or lower.endswith(".settings")
    )


def key_from_get(call: ast.Call) -> str | None:
    if (
        isinstance(call.func, ast.Attribute)
        and call.func.attr == "get"
        and call.args
        and isinstance(call.args[0], ast.Constant)
        and isinstance(call.args[0].value, str)
        and receiver_is_settings(call.func.value)
    ):
        return call.args[0].value
    return None


settings: dict[str, dict[str, dict[str, object]]] = {}
source_evidence: dict[str, set[str]] = {}
for path in sorted((root / "src/solidlsp/language_servers").rglob("*.py")):
    relative_module = ".".join(path.relative_to(root / "src").with_suffix("").parts)
    language = module_languages.get(relative_module)
    if language is None:
        continue
    tree = parse(path)
    constants = module_constants(tree)
    variable_keys: dict[str, tuple[str, str]] = {}
    settings.setdefault(language, {})
    receiver_languages: dict[str, str] = {}

    for node in ast.walk(tree):
        if not isinstance(node, (ast.Assign, ast.AnnAssign)) or not isinstance(node.value, ast.Call):
            continue
        call = node.value
        if (
            not isinstance(call.func, ast.Attribute)
            or call.func.attr != "get_ls_specific_settings"
            or not call.args
            or not isinstance(call.args[0], ast.Attribute)
            or not isinstance(call.args[0].value, ast.Name)
            or call.args[0].value.id != "Language"
        ):
            continue
        receiver_language = language_names.get(call.args[0].attr)
        if receiver_language is None:
            continue
        targets = node.targets if isinstance(node, ast.Assign) else [node.target]
        for target in targets:
            receiver_languages[ast.unparse(target)] = receiver_language

    def language_for_get(call: ast.Call) -> str:
        if isinstance(call.func, ast.Attribute):
            return receiver_languages.get(ast.unparse(call.func.value), language)
        return language

    for node in ast.walk(tree):
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            value = node.value
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            if isinstance(value, ast.Call):
                key = key_from_get(value)
                if key:
                    setting_language = language_for_get(value)
                    for target in targets:
                        if isinstance(target, ast.Name):
                            variable_keys[target.id] = (setting_language, key)

        if not isinstance(node, ast.Call):
            continue
        key = key_from_get(node)
        default_node = node.args[1] if key and len(node.args) > 1 else None
        if key is None:
            for keyword in node.keywords:
                if keyword.arg == "version_setting_key" and isinstance(keyword.value, ast.Constant) and isinstance(keyword.value.value, str):
                    key = keyword.value.value
                    default_node = next((kw.value for kw in node.keywords if kw.arg == "default_version"), None)
                    break
        if key is None:
            continue
        setting_language = language_for_get(node)
        default = literal(default_node, constants) if default_node is not None else None
        entry = settings.setdefault(setting_language, {}).setdefault(
            key, {"defaults": [], "enum": [], "fallbackExpressions": []}
        )
        if isinstance(default, dict) and set(default) == {"expression"}:
            if default["expression"] not in entry["fallbackExpressions"]:
                entry["fallbackExpressions"].append(default["expression"])
        elif default not in entry["defaults"]:
            entry["defaults"].append(default)
        source_evidence.setdefault(f"{setting_language}.{key}", set()).add(
            f"{path.relative_to(root).as_posix()}:{getattr(node, 'lineno', 0)}"
        )

    for node in ast.walk(tree):
        if not isinstance(node, ast.Compare) or not isinstance(node.left, ast.Name):
            continue
        setting = variable_keys.get(node.left.id)
        if setting is None or len(node.comparators) != 1:
            continue
        setting_language, key = setting
        values = literal(node.comparators[0], constants)
        if isinstance(values, list) and all(isinstance(value, str) for value in values):
            entry = settings.setdefault(setting_language, {}).setdefault(
                key, {"defaults": [], "enum": [], "fallbackExpressions": []}
            )
            entry["enum"] = sorted(set(entry["enum"]) | set(values))

# ls_path is implemented in the common SinglePath provider. Keep it separate
# from language-specific inventories because not every server uses that base.
generic_settings = {"ls_path": {"defaults": [None], "enum": [], "evidence": ["src/solidlsp/ls.py"]}}

# Parse documented keys/defaults and union them with source access evidence.
heading_languages = {
    "AL": "al", "Angular": "angular", "Ansible": "ansible", "Bash": "bash",
    "BSL (1C:Enterprise / OneScript)": "bsl", "Clojure": "clojure",
    "C/C++ (`clangd`)": "cpp", "C/C++ via `ccls`": "cpp_ccls",
    "C# (Roslyn Language Server)": "csharp", "C# (`OmniSharp`)": "csharp_omnisharp",
    "Dart": "dart", "Elixir": "elixir", "Elm": "elm", "F#": "fsharp",
    "GDScript (Godot Engine)": "gdscript", "Go (`gopls`)": "go", "Groovy": "groovy",
    "HLSL": "hlsl", "Haxe": "haxe", "HTML": "html", "Java (`eclipse.jdt.ls`)": "java",
    "Kotlin": "kotlin", "Lean 4": "lean4", "Lua": "lua", "Luau": "luau",
    "Markdown": "markdown", "MATLAB": "matlab", "Pascal (`pasls`)": "pascal",
    "PHP (`Intelephense`)": "php", "PHP (`Phpactor`)": "php_phpactor",
    "PowerShell": "powershell", "Python": "python", "Ruby": "ruby", "Rust": "rust",
    "Scala": "scala", "SCSS / Sass / CSS": "scss", "Solidity": "solidity",
    "SystemVerilog": "systemverilog", "Terraform": "terraform", "TOML": "toml",
    "TypeScript": "typescript", "Svelte": "svelte", "TypeScript via `vtsls`": "typescript_vts",
    "Vue": "vue", "YAML": "yaml",
}
docs_path = root / "docs/02-usage/050_configuration.md"
heading = None
settings_table = False
for line_number, line in enumerate(docs_path.read_text(encoding="utf-8").splitlines(), start=1):
    if line.startswith("#### "):
        heading = line[5:].strip()
        settings_table = False
        continue
    language = heading_languages.get(heading or "")
    if language is None:
        continue
    if not line.startswith("|"):
        if line.strip():
            settings_table = False
        continue
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if len(cells) >= 2 and cells[0] == "Setting" and cells[1] == "Default":
        settings_table = True
        continue
    if not settings_table or len(cells) < 2 or not re.fullmatch(r"`[^`]+`", cells[0]):
        continue
    key = cells[0][1:-1]
    default_text = cells[1]
    entry = settings.setdefault(language, {}).setdefault(
        key, {"defaults": [], "enum": [], "fallbackExpressions": []}
    )
    entry["documentedDefault"] = default_text
    source_evidence.setdefault(f"{language}.{key}", set()).add(
        f"docs/02-usage/050_configuration.md:{line_number}"
    )

# Source-declared enums not always appear as direct comparisons on the setting
# getter. Record the enum classes/constants used by known settings explicitly.
scala_tree = parse(root / "src/solidlsp/language_servers/scala_language_server.py")
for node in getattr(scala_tree, "body", []):
    if isinstance(node, ast.ClassDef) and node.name == "StaleLockMode":
        values = [
            statement.value.value
            for statement in node.body
            if isinstance(statement, ast.Assign)
            and isinstance(statement.value, ast.Constant)
            and isinstance(statement.value.value, str)
        ]
        settings.setdefault("scala", {}).setdefault(
            "on_stale_lock", {"defaults": [], "enum": [], "fallbackExpressions": []}
        )["enum"] = values

luau_constants = module_constants(parse(root / "src/solidlsp/language_servers/luau_lsp.py"))
settings.setdefault("luau", {}).setdefault(
    "platform", {"defaults": [], "enum": [], "fallbackExpressions": []}
)["enum"] = sorted(
    luau_constants.get("SUPPORTED_PLATFORMS", [])
)
settings.setdefault("luau", {}).setdefault(
    "roblox_security_level", {"defaults": [], "enum": [], "fallbackExpressions": []}
)["enum"] = sorted(
    luau_constants.get("SUPPORTED_ROBLOX_SECURITY_LEVELS", [])
)

for language, fields in settings.items():
    for key, entry in fields.items():
        entry["evidence"] = sorted(source_evidence.get(f"{language}.{key}", set()))
        entry["defaults"] = sorted(entry["defaults"], key=lambda value: json.dumps(value, sort_keys=True))
        entry["enum"] = sorted(set(entry["enum"]))
        entry["fallbackExpressions"] = sorted(set(entry.get("fallbackExpressions", [])))

# Any change to configuration classes/templates, LS dispatch/implementations,
# prompt inputs, or configuration documentation changes this guard even when
# conservative parsing cannot infer the semantic delta.
guard_files = {
    root / "src/serena/config/serena_config.py",
    root / "src/serena/config/context_mode.py",
    root / "src/serena/prompt_factory.py",
    root / "src/solidlsp/ls.py",
    root / "src/solidlsp/ls_config.py",
    root / "src/solidlsp/settings.py",
}
guard_files.update((root / "src/serena/resources").rglob("*.yml"))
guard_files.update((root / "src/solidlsp/language_servers").rglob("*.py"))
guard_files.update((root / "docs/01-about").rglob("*.md"))
guard_files.update((root / "docs/02-usage").rglob("*.md"))
guard_files.update((root / "docs/03-special-guides").rglob("*.md"))
guard_hashes = {}
combined = hashlib.sha256()
for path in sorted((path for path in guard_files if path.is_file()), key=lambda item: item.relative_to(root).as_posix()):
    relative = path.relative_to(root).as_posix()
    content = path.read_bytes()
    digest = hashlib.sha256(content).hexdigest()
    guard_hashes[relative] = digest
    combined.update(relative.encode("utf-8"))
    combined.update(b"\0")
    combined.update(content)
    combined.update(b"\0")

manifest = {
    "languageValues": language_values,
    "contextSupportedFields": sorted(set(context_fields)),
    "modeSupportedFields": sorted(set(mode_fields)),
    "promptFiles": prompt_files,
    "lsSpecificSettings": {language: settings[language] for language in sorted(settings)},
    "genericLsSpecificSettings": generic_settings,
    "sourceGuard": {
        "sha256": combined.hexdigest(),
        "files": guard_hashes,
    },
    "sourceGuardSha256": combined.hexdigest(),
}
output_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

generate_schema_evidence() {
  local source_root="$1"
  local destination_schema_dir="$2"
  local scratch="${stage_root}/schema-scratch"
  local prompt_json_dir="${scratch}/prompt-json"
  local index derived
  mkdir -p -- "$destination_schema_dir/fixtures/prompt_templates" "$prompt_json_dir"

  for index in "${!fixture_rel_paths[@]}"; do
    copy_normalized_fixture \
      "${source_root}/${fixture_source_paths[$index]}" \
      "${destination_schema_dir}/${fixture_rel_paths[$index]#schema/}"
  done

  yq eval -o=json '.' "${source_root}/${fixture_source_paths[0]}" >"${scratch}/global.json"
  yq eval -o=json '.' "${source_root}/${fixture_source_paths[1]}" >"${scratch}/project.json"
  yq eval -o=json '.' "${source_root}/${fixture_source_paths[3]}" >"${scratch}/context.json"
  yq eval -o=json '.' "${source_root}/${fixture_source_paths[4]}" >"${scratch}/mode.json"

  local prompt_source
  for prompt_source in "${source_root}/src/serena/resources/config/prompt_templates/"*.yml; do
    yq eval -o=json '.' "$prompt_source" >"${prompt_json_dir}/$(basename -- "$prompt_source").json"
  done

  derived="${scratch}/derived.json"
  generate_source_inventory "$source_root" "$prompt_json_dir" "$derived"

  jq -S -n \
    --slurpfile global "${scratch}/global.json" \
    --slurpfile project "${scratch}/project.json" \
    --slurpfile context "${scratch}/context.json" \
    --slurpfile mode "${scratch}/mode.json" \
    --slurpfile derived "$derived" '
      {
        schemaVersion: 2,
        global: $global[0],
        project: $project[0],
        context: $context[0],
        mode: $mode[0]
      } + $derived[0]
    ' >"${destination_schema_dir}/upstream.json"

  jq -e '
    .schemaVersion == 2 and
    (.global | type == "object") and
    (.project | type == "object") and
    (.context | type == "object") and
    (.mode | type == "object") and
    (.contextSupportedFields | index("fixed_tools") != null) and
    (.modeSupportedFields | index("fixed_tools") != null) and
    (.languageValues | type == "array" and length > 0) and
    (.promptFiles | type == "object" and length > 0) and
    (.lsSpecificSettings | type == "object" and length > 0) and
    (.sourceGuard.sha256 | test("^[0-9a-f]{64}$")) and
    (.sourceGuardSha256 == .sourceGuard.sha256)
  ' "${destination_schema_dir}/upstream.json" >/dev/null \
    || die "Generated upstream schema inventory failed structural validation"
}

rewrite_generated_pin() {
  local flake_file="$1"
  local revision="$2"
  local rewritten="${flake_file}.pin-rewrite"

  awk -v begin="$PIN_BEGIN" -v end="$PIN_END" -v rev="$revision" '
    $0 ~ "^[[:space:]]*" begin "$" {
      if (seen_begin++) exit 40
      match($0, /^[[:space:]]*/)
      indent = substr($0, RSTART, RLENGTH)
      print
      print indent "serena-upstream.url = \"github:oraios/serena/" rev "\";"
      inside = 1
      next
    }
    $0 ~ "^[[:space:]]*" end "$" {
      if (!inside || seen_end++) exit 41
      inside = 0
      print
      next
    }
    inside { next }
    { print }
    END {
      if (inside || seen_begin != 1 || seen_end != 1) exit 42
    }
  ' "$flake_file" >"$rewritten" \
    || { rm -f -- "$rewritten"; die "flake.nix does not contain exactly one valid generated Serena input block"; }
  mv -f -- "$rewritten" "$flake_file"
}

write_candidate_release() {
  local destination="$1"
  local schema_sha="$2"
  jq -S -n \
    --arg version "$target_version" \
    --arg tag "$target_tag" \
    --arg rev "$target_rev" \
    --arg narHash "$target_nar_hash" \
    --arg schemaSha256 "$schema_sha" '
      {
        latest: $version,
        versions: {
          ($version): {
            version: $version,
            tag: $tag,
            rev: $rev,
            narHash: $narHash,
            schemaSha256: $schemaSha256
          }
        }
      }
    ' >"$destination"
}

prepare_stage() {
  stage_root="$(mktemp -d -t serena-update.XXXXXX)"
  stage_pkg="${stage_root}/candidate"
  baseline_pkg="${stage_root}/baseline"
  cp -a -- "$pkg_dir/." "$stage_pkg"
  cp -a -- "$pkg_dir/." "$baseline_pkg"

  generate_schema_evidence "$target_store_path" "${stage_pkg}/schema"

  if ! cmp -s -- "${pkg_dir}/schema/upstream.json" "${stage_pkg}/schema/upstream.json"; then
    log_error "Upstream configuration surface drifted; typed Nix coverage must be reviewed before advancing."
    diff -u -- "${pkg_dir}/schema/upstream.json" "${stage_pkg}/schema/upstream.json" >&2 || true
    keep_stage=true
    exit "$SCHEMA_DRIFT_EXIT"
  fi

  local schema_sha
  schema_sha="$(sha256sum "${stage_pkg}/schema/upstream.json" | awk '{ print $1 }')"
  write_candidate_release "${stage_pkg}/releases.json" "$schema_sha"
  rewrite_generated_pin "${stage_pkg}/flake.nix" "$target_rev"
}

file_states_match() {
  local left="$1"
  local right="$2"
  if [[ -e "$left" && -e "$right" ]]; then
    cmp -s -- "$left" "$right"
  else
    [[ ! -e "$left" && ! -e "$right" ]]
  fi
}

collect_changed_paths() {
  changed_paths=()
  local relative
  for relative in "${generated_rel_paths[@]}"; do
    if ! file_states_match "${pkg_dir}/${relative}" "${stage_pkg}/${relative}"; then
      changed_paths+=("$relative")
    fi
  done
}

verify_stage() {
  log_info "Building the staged Serena package"
  local build_output package_path version_output
  build_output="$(nix build \
    --no-link \
    --no-write-lock-file \
    --print-out-paths \
    "path:${stage_pkg}#serena")"
  package_path="$(printf '%s\n' "$build_output" | awk 'NF { value=$0 } END { print value }')"
  [[ -x "${package_path}/bin/serena" ]] || die "Staged build did not produce bin/serena"
  version_output="$("${package_path}/bin/serena" --version)"
  [[ "$version_output" == "Serena ${target_version}" ]] \
    || die "Staged binary reported '${version_output}', expected 'Serena ${target_version}'"

  log_info "Running all staged flake checks"
  nix flake check --no-write-lock-file "path:${stage_pkg}"
}

ensure_baseline_unchanged() {
  local relative
  for relative in "${generated_rel_paths[@]}"; do
    file_states_match "${baseline_pkg}/${relative}" "${pkg_dir}/${relative}" \
      || die "Managed file changed while verification ran; refusing to apply: ${relative}"
  done
}

atomic_install() {
  local source="$1"
  local destination="$2"
  local temporary
  mkdir -p -- "$(dirname -- "$destination")"
  temporary="$(mktemp "${destination}.tmp.XXXXXX")"
  install -m 0644 -- "$source" "$temporary"
  mv -f -- "$temporary" "$destination"
}

rollback_apply() {
  local backup_dir="$1"
  local relative
  log_warn "Restoring managed files after an apply failure"
  for relative in "${generated_rel_paths[@]}"; do
    if [[ -e "${backup_dir}/${relative}" ]]; then
      atomic_install "${backup_dir}/${relative}" "${pkg_dir}/${relative}" || true
    else
      rm -f -- "${pkg_dir}/${relative}" || true
    fi
  done
}

apply_stage() {
  local backup_dir="${stage_root}/apply-backup"
  local relative
  mkdir -p -- "$backup_dir"
  for relative in "${generated_rel_paths[@]}"; do
    if [[ -e "${pkg_dir}/${relative}" ]]; then
      mkdir -p -- "${backup_dir}/$(dirname -- "$relative")"
      cp -a -- "${pkg_dir}/${relative}" "${backup_dir}/${relative}"
    fi
  done

  if ! (
    set -e
    for relative in "${generated_rel_paths[@]}"; do
      atomic_install "${stage_pkg}/${relative}" "${pkg_dir}/${relative}"
    done
  ); then
    rollback_apply "$backup_dir"
    die "Failed to apply the verified Serena update"
  fi

  jq empty "$releases_file" || {
    rollback_apply "$backup_dir"
    die "Applied releases.json failed validation"
  }
  jq empty "${pkg_dir}/schema/upstream.json" || {
    rollback_apply "$backup_dir"
    die "Applied schema/upstream.json failed validation"
  }
}

acquire_update_lock() {
  local git_dir lock_file
  git_dir="$(git -C "$pkg_dir" rev-parse --absolute-git-dir 2>/dev/null || true)"
  lock_file="${git_dir:-${TMPDIR:-/tmp}}/serena-update-version.lock"
  exec 9>"$lock_file"
  flock 9
}

ensure_auto_commit_is_safe() {
  [[ "$do_commit" == true ]] || return 0
  git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local dirty
  dirty="$(git -C "$pkg_dir" status --porcelain=v1 -- .)"
  [[ -z "$dirty" ]] || die "Serena has pre-existing changes; rerun with --no-commit to preserve commit boundaries"
}

maybe_commit() {
  [[ "$do_commit" == true ]] || return 0
  if ! git -C "$pkg_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_warn "Not in a Git worktree; leaving verified changes uncommitted"
    return 0
  fi

  git -C "$pkg_dir" diff --check -- "${generated_rel_paths[@]}"
  git -C "$pkg_dir" add -- "${generated_rel_paths[@]}"
  if git -C "$pkg_dir" diff --cached --quiet -- "${generated_rel_paths[@]}"; then
    return 0
  fi

  local message
  if [[ "$rehash" == true ]]; then
    message="chore(serena): rehash ${target_version}"
  else
    message="chore(serena): select stable ${target_version}"
  fi
  git -C "$pkg_dir" commit --only -m "$message" -- "${generated_rel_paths[@]}"
  log_info "Committed: ${message}"
}

main() {
  ensure_tools

  local check_only=false
  rehash=false
  do_commit=true
  local explicit_tag=""

  while (($# > 0)); do
    case "$1" in
      --tag)
        (($# >= 2)) || die "--tag requires a value"
        explicit_tag="$2"
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
      --no-commit)
        do_commit=false
        shift
        ;;
      -h|--help)
        print_usage
        return 0
        ;;
      *)
        print_usage >&2
        die "Unknown option: $1"
        ;;
    esac
  done

  [[ ! ("$rehash" == true && -n "$explicit_tag") ]] \
    || die "--rehash and --tag are mutually exclusive"
  [[ ! ("$check_only" == true && "$rehash" == true) ]] \
    || die "--check and --rehash are mutually exclusive"
  [[ ! ("$check_only" == true && "$do_commit" == false) ]] \
    || die "--no-commit has no meaning with --check"

  load_current_release

  if [[ "$rehash" == true ]]; then
    target_version="$current_version"
    target_tag="$current_tag"
    target_rev="$current_rev"
  elif [[ -n "$explicit_tag" ]]; then
    resolve_explicit_tag "$explicit_tag"
    resolve_tag_revision "$target_tag"
  else
    discover_highest_final_tag
    resolve_tag_revision "$target_tag"
  fi

  if [[ "$rehash" != true && "$target_tag" == "$current_tag" && "$target_rev" != "$current_rev" ]]; then
    die "Upstream tag ${target_tag} moved from ${current_rev} to ${target_rev}; refusing automatic retag acceptance"
  fi

  log_info "Current stable: ${current_tag} (${current_rev})"
  log_info "Target stable:  ${target_tag} (${target_rev})"
  prefetch_candidate
  prepare_stage
  collect_changed_paths

  if [[ "$check_only" == true ]]; then
    if ((${#changed_paths[@]} == 0)); then
      log_info "Serena ${target_version} metadata, pin, and schema evidence are current"
      return 0
    fi
    log_info "Update available; generated paths that would change:"
    printf '  %s\n' "${changed_paths[@]}"
    return 1
  fi

  if ((${#changed_paths[@]} == 0)) && [[ "$rehash" != true ]]; then
    log_info "Already at the highest stable Serena tag (${target_tag})"
    return 0
  fi

  ensure_auto_commit_is_safe
  verify_stage
  acquire_update_lock
  ensure_baseline_unchanged
  apply_stage
  maybe_commit

  if ((${#changed_paths[@]} == 0)); then
    log_info "Serena ${target_version} hashes and schema evidence verified; no files changed"
  else
    log_info "Serena stable selection updated to ${target_tag}"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
