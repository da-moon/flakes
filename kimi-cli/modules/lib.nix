# Shared helpers for Kimi hook management.
{ pkgs }:
let
  lib = pkgs.lib;

  # Default redirect-web-tools hook packaged from the local script.
  # A single matcher-less entry is used so the script decides which tool
  # names to intercept; this keeps the managed hook filename stable and
  # lets the merge replace any pre-existing manual redirect-web-tools
  # entries regardless of their matcher.
  mkDefaultRedirectWebToolsHooks =
    { runtimeInputs ? [ pkgs.gnugrep pkgs.coreutils ] }:
    [
      {
        name = "redirect-web-tools";
        event = "PreToolUse";
        matcher = null;
        timeout = 5;
        script = builtins.readFile ./hooks/redirect-web-tools.sh;
        inherit runtimeInputs;
      }
    ];

  # Turn a hook definition into a packaged executable named $out/bin/<name>.sh.
  mkHookScript =
    { name
    , script
    , runtimeInputs ? [ pkgs.gnugrep pkgs.coreutils ]
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
        timeout = h.timeout or 5;
      }) hooks;
    in
    pkgs.writeText "kimi-managed-hooks.json" (builtins.toJSON entries);

  mergeHooksJq = pkgs.writeText "kimi-merge-hooks.jq" ''
    $managed[0] as $defs
    | ($defs | map(.name)) as $managedNames
    | .hooks //= []
    | .hooks |= map(select(
        (
          ((.command | test("^/nix/store/.+\\.sh$")) and
           ((.command | split("/") | last | split(".") | first) as $bn | ($managedNames | index($bn)) == null))
          or
          (.command | contains(".kimi-code/hooks/"))
        ) | not
      ))
    | reduce $defs[] as $h (.;
        $h.name as $name
        | $h.event as $event
        | $h.matcher as $matcher
        | $h.command as $cmd
        | $h.timeout as $timeout
        | (
            { event: $event, command: $cmd, timeout: $timeout }
            + (if $matcher == null then {} else { matcher: $matcher } end)
          ) as $entry
        | .hooks |= (
            map(select(.command | test("/" + $name + "\\.sh$") | not))
            + [$entry]
          )
      )
  '';

  # Build the idempotent merge script. It takes two positional args:
  #   $1 = path to config.toml
  #   $2 = path to hooks directory
  mkMergeHooksScript =
    { managedHooksJson
    , hooksPackage
    }:
    pkgs.writeShellApplication {
      name = "kimi-merge-hooks";
      runtimeInputs = [ pkgs.jq pkgs.remarshal pkgs.coreutils ];
      text = ''
        set -euo pipefail
        configFile="$1"
        hooksDir="$2"
        managedHooks=${managedHooksJson}
        hooksPackage=${hooksPackage}

        mkdir -p "$hooksDir"
        manifestFile="$hooksDir/.nix-managed-hooks"
        oldManifest=$(cat "$manifestFile" 2>/dev/null || true)
        newManifest=""

        shopt -s nullglob
        for src in "$hooksPackage"/bin/*.sh; do
          hookName=$(basename "$src" .sh)
          dest="$hooksDir/$hookName.sh"
          install -m755 "$src" "$dest"
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

        mkdir -p "$(dirname "$configFile")"
        tmp=$(${pkgs.coreutils}/bin/mktemp -d)
        if [ -f "$configFile" ]; then
          ${pkgs.remarshal}/bin/remarshal -i "$configFile" -of json -o "$tmp/config.json"
        else
          echo '{"hooks":[]}' > "$tmp/config.json"
        fi

        ${pkgs.jq}/bin/jq --slurpfile managed "$managedHooks" -f ${mergeHooksJq} "$tmp/config.json" > "$tmp/merged.json"
        ${pkgs.remarshal}/bin/remarshal -i "$tmp/merged.json" -if json -of toml -o "$configFile.tmp"
        mv "$configFile.tmp" "$configFile"
        rm -rf "$tmp"
      '';
    };
in
{
  inherit
    mkDefaultRedirectWebToolsHooks
    mkHookScript
    mkHooksPackage
    mkManagedHooksJson
    mkMergeHooksScript
    ;
}
