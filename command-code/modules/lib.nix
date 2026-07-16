# Shared helpers for Command Code hook management.
{ pkgs }:
let
  lib = pkgs.lib;

  # Default strip-coauthor hook packaged from the local script.
  mkDefaultStripCoauthorHook =
    { runtimeInputs ? [ pkgs.jq pkgs.gnugrep ] }:
    {
      name = "strip-coauthor";
      event = "PreToolUse";
      matcher = "SHELL";
      timeout = 10;
      script = builtins.readFile ./hooks/strip-coauthor.sh;
      inherit runtimeInputs;
    };

  # Turn a hook definition into a packaged executable named $out/bin/<name>.sh.
  mkHookScript =
    { name
    , script
    , runtimeInputs ? [ pkgs.jq pkgs.gnugrep ]
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
      name = "command-code-hooks";
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
        timeout = h.timeout or 10;
      }) hooks;
    in
    pkgs.writeText "command-code-managed-hooks.json" (builtins.toJSON entries);

  mergeHooksJq = pkgs.writeText "command-code-merge-hooks.jq" ''
    $managed[0] as $defs
    | ($defs | map(.name)) as $managedNames
    | .hooks //= {}
    | .hooks |= map_values(
        map(
          .hooks |= map(select(
            (
              ((.command | test("^/nix/store/.+\\.sh$")) and
               ((.command | split("/") | last | split(".") | first) as $bn | ($managedNames | index($bn)) == null))
              or
              (.command | contains(".commandcode/hooks/"))
            ) | not
          ))
        )
        | map(select((.hooks | length) > 0))
        | reduce .[] as $g ({};
            ($g.matcher // null) as $m
            | .[$m | tostring] += $g.hooks
          )
        | to_entries
        | map(
            (if .key == "null" then {} else { matcher: .key } end)
            + { hooks: .value }
          )
      )
    | reduce $defs[] as $h (.;
        $h.name as $name
        | $h.event as $event
        | $h.matcher as $matcher
        | $h.command as $cmd
        | $h.timeout as $timeout
        | .hooks[$event] //= []
        | (.hooks[$event] | to_entries | map(((.value.matcher // null) == ($matcher // null))) | index(true)) as $gi
        | if $gi == null then
            .hooks[$event] += [
              (if $matcher == null then {} else { matcher: $matcher } end)
              + { hooks: [{ type: "command", command: $cmd, timeout: $timeout }] }
            ]
          else
            .hooks[$event][$gi].hooks |= (
              map(select(.command | test("/" + $name + "\\.sh$") | not))
              + [{ type: "command", command: $cmd, timeout: $timeout }]
            )
          end
      )
  '';

  # Build the idempotent merge script. It takes two positional args:
  #   $1 = path to settings.json
  #   $2 = path to hooks directory
  mkMergeHooksScript =
    { managedHooksJson
    , hooksPackage
    }:
    pkgs.writeShellApplication {
      name = "command-code-merge-hooks";
      runtimeInputs = [ pkgs.jq pkgs.coreutils ];
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
        tmp=$(${pkgs.coreutils}/bin/mktemp)
        if [ -f "$configFile" ]; then
          cp "$configFile" "$tmp"
        else
          echo '{}' > "$tmp"
        fi

        ${pkgs.jq}/bin/jq --slurpfile managed "$managedHooks" -f ${mergeHooksJq} "$tmp" > "$configFile.tmp"
        mv "$configFile.tmp" "$configFile"
        rm -f "$tmp"
      '';
    };
in
{
  inherit
    mkDefaultStripCoauthorHook
    mkHookScript
    mkHooksPackage
    mkManagedHooksJson
    mkMergeHooksScript
    ;
}
