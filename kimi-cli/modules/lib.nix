# Shared helpers for Kimi config management.
#
# The module is intentionally generic: no hook scripts are bundled with the
# flake. Consumers pass hook definitions (with inline script strings or paths)
# via the `hooks` option of the home-manager / flake-parts modules.
{ pkgs }:
let
  lib = pkgs.lib;

  # Turn a hook definition into a packaged executable named $out/bin/<name>.sh.
  mkHookScript =
    { name
    , script
    , runtimeInputs ? [ ]
    }:
    let
      scriptText = if builtins.isString script then script else builtins.readFile script;
    in
    pkgs.writeShellApplication {
      name = "${name}.sh";
      inherit runtimeInputs;
      text = scriptText;
    };

  # Combine a list of hook definitions into one derivation with all scripts.
  mkHooksPackage =
    { hooks }:
    pkgs.symlinkJoin {
      name = "kimi-cli-hooks";
      paths = map (h: mkHookScript { inherit (h) name script runtimeInputs; }) hooks;
    };

  # Render a JSON file describing the hooks that Nix should manage.
  mkManagedHooksJson =
    { hooks
    , commandFor
    }:
    let
      entries = map (h: {
        name = h.name;
        event = h.event or "PreToolUse";
        matcher = h.matcher or null;
        command = commandFor h;
        timeout = h.timeout or 30;
      }) hooks;
    in
    pkgs.writeText "kimi-managed-hooks.json" (builtins.toJSON entries);

  mkManifestJson =
    manifest:
    pkgs.writeText "kimi-merge-manifest.json" (builtins.toJSON manifest);

  # Declarative-core merge, implemented in jq. Inputs:
  #   .            = live file content as JSON (config.toml or tui.toml)
  #   $declared[0] = Nix-rendered declared content (object)
  #   $manifest[0] = merge manifest (see modules/config-schema.nix)
  #   $managed[0]  = managed hook definitions (array)
  #   $oauthsrc[0] = external oauth source config as JSON ({} when absent)
  #   $hooksMarker = path marker identifying installed hook script copies
  #
  # Semantics:
  # - scalars: set only when declared.
  # - sections (object tables): when the section is declared, typed-but-
  #   undeclared keys are deleted from the live file (reset to upstream
  #   defaults), declared keys win, unknown keys are preserved.
  # - replaceTables: replaced wholesale when declared; for graftTables a
  #   missing `oauth` sub-table is grafted back per entry (live file first,
  #   then the external oauth source).
  # - hooks (when manifest.hooksManaged): stale nix-store hook entries and
  #   entries referencing installed copies are stripped, then each managed
  #   hook is upserted by name. Foreign hook entries are preserved.
  configMergeJq = pkgs.writeText "kimi-config-merge.jq" ''
    ($declared[0]) as $d
    | ($manifest[0]) as $m
    | ($managed[0] // []) as $defs
    | ($oauthsrc[0] // {}) as $oauthsrc
    | (if $m.hooksManaged then
         ($defs | map(.name)) as $managedNames
         | .hooks //= []
         | .hooks |= map(select(
             (
               (((.command // "") | test("^/nix/store/.+\\.sh$")) and
                (((.command // "") | split("/") | last | split(".") | first) as $bn | ($managedNames | index($bn)) == null))
               or
               ((.command // "") | contains($hooksMarker))
             ) | not
           ))
       else . end)
    | reduce (($m.scalars // [])[]) as $k (.;
        if ($d | has($k)) then .[$k] = $d[$k] else . end)
    | reduce (($m.sections // {}) | keys[]) as $s (.;
        if ($d | has($s)) then
          .[$s] = (
            ((.[$s] // {})
              | reduce (($m.sections[$s] // [])[]) as $k (.;
                  if ($d[$s] | has($k)) | not then del(.[$k]) else . end))
            + $d[$s]
          )
        else . end)
    | reduce (($m.replaceTables // [])[]) as $s (.;
        if ($d | has($s)) then
          (.[$s] // {}) as $oldTable
          | .[$s] = $d[$s]
          | (if ((($m.graftTables // []) | index($s)) != null) then
               reduce (($d[$s]) | keys[]) as $name (.;
                 if ((.[$s][$name] | type) == "object") and ((.[$s][$name] | has("oauth")) | not) then
                   (($oldTable[$name].oauth // null) // ($oauthsrc[$s][$name].oauth // null)) as $g
                   | if $g != null then .[$s][$name].oauth = $g else . end
                 else . end)
             else . end)
        else . end)
    | (if $m.hooksManaged then
         reduce ($defs[]) as $h (.;
           ($h.name) as $name
           | ($h.event) as $event
           | ($h.matcher) as $matcher
           | ($h.command) as $cmd
           | ($h.timeout) as $timeout
           | (
               { event: $event, command: $cmd, timeout: $timeout }
               + (if $matcher == null then {} else { matcher: $matcher } end)
             ) as $entry
           | .hooks |= (
               map(select(((.command // "") | test("/" + $name + "\\.sh$")) | not))
               + [$entry]
             )
         )
       else . end)
  '';

  emptyJson = pkgs.writeText "kimi-empty.json" "{}";

  # One idempotent sync for a Kimi data directory (global ~/.kimi-code or a
  # project-local KIMI_CODE_HOME). Positional args:
  #   $1 = data directory (holds config.toml, tui.toml, mcp.json)
  #   $2 = hooks directory (installed script copies live here)
  #   $3 = optional external config.toml used as oauth graft source
  #        (project isolation with shared credentials passes the global file)
  mkSyncConfigScript =
    { manifestJson
    , tuiManifestJson
    , managedHooksJson
    , hooksPackage
    , declaredConfigJson ? null
    , declaredTuiJson ? null
    , mcpJson ? null
    }:
    let
      declaredConfig = if declaredConfigJson != null then declaredConfigJson else emptyJson;
    in
    pkgs.writeShellApplication {
      name = "kimi-sync-config";
      runtimeInputs = [
        pkgs.jq
        pkgs.remarshal
        pkgs.coreutils
        pkgs.gnugrep
      ];
      text = ''
        set -euo pipefail
        configDir="$1"
        hooksDir="$2"
        oauthSource="''${3:-}"

        mkdir -p "$configDir" "$hooksDir"
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT

        # --- phase 1: install hook script copies; prune removed managed hooks ---
        manifestFile="$hooksDir/.nix-managed-hooks"
        oldManifest="$(cat "$manifestFile" 2>/dev/null || true)"
        newManifest=""
        shopt -s nullglob
        for src in ${hooksPackage}/bin/*.sh; do
          hookName="$(basename "$src" .sh)"
          install -m755 "$src" "$hooksDir/$hookName.sh"
          newManifest="$newManifest$hookName"$'\n'
        done
        shopt -u nullglob
        if [ -n "$oldManifest" ]; then
          while IFS= read -r oldName; do
            [ -n "$oldName" ] || continue
            if ! printf '%s\n' "$newManifest" | grep -qx "$oldName"; then
              rm -f "$hooksDir/$oldName.sh"
            fi
          done <<< "$oldManifest"
        fi
        printf '%s' "$newManifest" > "$manifestFile"

        # --- phase 2: external oauth graft source (optional) ---
        if [ -n "$oauthSource" ] && [ -f "$oauthSource" ]; then
          remarshal -i "$oauthSource" -of json -o "$tmp/oauthsrc.json"
        else
          echo '{}' > "$tmp/oauthsrc.json"
        fi

        merge_toml() {
          local target="$1" declared="$2" manifest="$3"
          if [ -f "$target" ]; then
            remarshal -i "$target" -of json -o "$tmp/live.json"
          else
            echo '{}' > "$tmp/live.json"
          fi
          jq \
            --slurpfile declared "$declared" \
            --slurpfile manifest "$manifest" \
            --slurpfile managed ${managedHooksJson} \
            --slurpfile oauthsrc "$tmp/oauthsrc.json" \
            --arg hooksMarker "$hooksDir/" \
            -f ${configMergeJq} "$tmp/live.json" > "$tmp/merged.json"
          remarshal -i "$tmp/merged.json" -if json -of toml -o "$tmp/merged.toml"
          install -m 0600 "$tmp/merged.toml" "$target.tmp"
          mv "$target.tmp" "$target"
        }

        # config.toml always merges: the [[hooks]] table is managed even when
        # no typed settings are declared (declared = {} then).
        merge_toml "$configDir/config.toml" ${declaredConfig} ${manifestJson}

        ${lib.optionalString (declaredTuiJson != null) ''
          merge_toml "$configDir/tui.toml" ${declaredTuiJson} ${tuiManifestJson}
        ''}

        ${lib.optionalString (mcpJson != null) ''
          install -m 0600 ${mcpJson} "$configDir/mcp.json.tmp"
          mv "$configDir/mcp.json.tmp" "$configDir/mcp.json"
        ''}
      '';
    };
in
{
  inherit
    mkHookScript
    mkHooksPackage
    mkManagedHooksJson
    mkManifestJson
    configMergeJq
    mkSyncConfigScript
    ;
}
