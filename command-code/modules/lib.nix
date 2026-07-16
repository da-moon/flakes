{ pkgs }:
let
  lib = pkgs.lib;
  render = import ./render.nix { inherit lib; };
  managedSync = pkgs.writeText "command-code-managed-sync.mjs" (builtins.readFile ./managed-sync.mjs);

  mkDefaultStripCoauthorHook =
    {
      runtimeInputs ? [
        pkgs.jq
        pkgs.gnugrep
      ],
    }:
    {
      name = "strip-coauthor";
      event = "PreToolUse";
      matcher = "SHELL";
      timeout = 10;
      script = builtins.readFile ./hooks/strip-coauthor.sh;
      command = null;
      inherit runtimeInputs;
      async = false;
      failClosed = false;
    };

  mkHookScript =
    hook:
    let
      scriptText = if builtins.isString hook.script then hook.script else builtins.readFile hook.script;
    in
    pkgs.writeShellApplication {
      name = "${hook.name}.sh";
      runtimeInputs = hook.runtimeInputs;
      text = scriptText;
    };

  mkHooksPackage =
    { hooks }:
    let
      scriptHooks = builtins.filter (hook: hook.script != null) hooks;
    in
    if scriptHooks == [ ] then
      pkgs.runCommand "command-code-hooks-empty" { } ''
        mkdir -p "$out/bin"
      ''
    else
      pkgs.symlinkJoin {
        name = "command-code-hooks";
        paths = map mkHookScript scriptHooks;
      };

  writeJson = name: value: pkgs.writeText name (builtins.toJSON value);

  mkManagedSyncScript =
    {
      name ? "command-code-managed-sync",
      config ? { },
      settings ? { },
      hooks ? [ ],
      mcpServers ? {
        mcpServers = { };
      },
      commandFor,
    }:
    let
      hooksPackage = mkHooksPackage { inherit hooks; };
      hookDefinitions = render.toHookDefinitions { inherit hooks commandFor; };
      hookFiles = map (hook: hook.name) (builtins.filter (hook: hook.script != null) hooks);
      desiredConfig = writeJson "command-code-desired-config.json" config;
      desiredSettings = writeJson "command-code-desired-settings.json" settings;
      desiredHooks = writeJson "command-code-desired-hooks.json" hookDefinitions;
      desiredMcp = writeJson "command-code-desired-mcp.json" mcpServers;
      desiredHookFiles = writeJson "command-code-desired-hook-files.json" hookFiles;
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.nodejs_22
        pkgs.util-linux
      ];
      text = ''
        set -euo pipefail

        state_dir=""
        data_dir=""
        arguments=("$@")
        while (($#)); do
          case "$1" in
            --state-dir)
              (($# >= 2)) || { echo "--state-dir requires a value" >&2; exit 2; }
              state_dir="$2"
              shift 2
              ;;
            --data-dir)
              (($# >= 2)) || { echo "--data-dir requires a value" >&2; exit 2; }
              data_dir="$2"
              shift 2
              ;;
            --force)
              shift
              ;;
            *)
              if [[ "$1" == --* && $# -ge 2 ]]; then shift 2; else shift; fi
              ;;
          esac
        done
        [[ -n "$state_dir" && -n "$data_dir" ]] || {
          echo "--state-dir and --data-dir are required" >&2
          exit 2
        }
        if [[ -L "$data_dir" || ( -e "$data_dir" && ! -d "$data_dir" ) ]]; then
          echo "command-code Nix sync: refusing unsafe data directory $data_dir" >&2
          exit 1
        fi
        install -d -m 0700 "$data_dir"
        state_parent=$(dirname "$state_dir")
        if [[ -L "$state_parent" || ( -e "$state_parent" && ! -d "$state_parent" ) ]]; then
          echo "command-code Nix sync: refusing unsafe state directory $state_parent" >&2
          exit 1
        fi
        install -d -m 0700 "$state_parent"
        if [[ -L "$state_dir" || ( -e "$state_dir" && ! -d "$state_dir" ) ]]; then
          echo "command-code Nix sync: refusing unsafe state directory $state_dir" >&2
          exit 1
        fi
        install -d -m 0700 "$state_dir"
        lock_file="$state_dir/sync.lock"
        if [[ -L "$lock_file" || ( -e "$lock_file" && ! -f "$lock_file" ) ]]; then
          echo "command-code Nix sync: refusing unsafe lock file $lock_file" >&2
          exit 1
        fi

        export CMDC_DESIRED_CONFIG=${lib.escapeShellArg (toString desiredConfig)}
        export CMDC_DESIRED_SETTINGS=${lib.escapeShellArg (toString desiredSettings)}
        export CMDC_DESIRED_HOOKS=${lib.escapeShellArg (toString desiredHooks)}
        export CMDC_DESIRED_MCP=${lib.escapeShellArg (toString desiredMcp)}
        export CMDC_DESIRED_HOOK_FILES=${lib.escapeShellArg (toString desiredHookFiles)}
        export CMDC_HOOKS_PACKAGE=${lib.escapeShellArg (toString hooksPackage)}
        exec flock --exclusive "$lock_file" \
          ${pkgs.nodejs_22}/bin/node ${managedSync} "''${arguments[@]}"
      '';
    };
in
{
  inherit
    mkDefaultStripCoauthorHook
    mkHookScript
    mkHooksPackage
    mkManagedSyncScript
    ;
}
