{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.command-code;
  schema = import ./schema.nix { inherit lib; };
  render = import ./render.nix { inherit lib; };
  helpers = import ./lib.nix { inherit pkgs; };

  dataDir = "${config.home.homeDirectory}/.commandcode";
  hooksDir = "${dataDir}/hooks";
  stateDir = "${dataDir}/nix-state/global";
  defaultHook = helpers.mkDefaultStripCoauthorHook { };
  allHooks = cfg.hooks.definitions ++ lib.optional cfg.hooks.enableDefaultStripCoauthor defaultHook;
  hookCommands = render.toHookDefinitions {
    hooks = allHooks;
    commandFor = hook: "${hooksDir}/${hook.name}.sh";
  };

  syncScript = helpers.mkManagedSyncScript {
    name = "command-code-sync-global";
    config = render.toGlobalConfig cfg.config;
    settings = render.toUserSettings cfg.settings;
    hooks = allHooks;
    mcpServers = render.toMcpServers cfg.mcpServers;
    commandFor = hook: "${hooksDir}/${hook.name}.sh";
  };

  packageVersion = lib.getVersion cfg.package;
in
{
  imports = [ ./options.nix ];

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = packageVersion == schema.schemaVersion;
        message = ''
          programs.command-code is schema-pinned to Command Code ${schema.schemaVersion},
          but package version ${packageVersion} was selected.
        '';
      }
      {
        assertion =
          builtins.length (map (hook: hook.command) hookCommands)
          == builtins.length (lib.unique (map (hook: hook.command) hookCommands));
        message = "programs.command-code.hooks must render unique commands.";
      }
    ]
    ++ schema.hookAssertions {
      hooks = allHooks;
      label = "programs.command-code.hooks.definitions";
    }
    ++ schema.mcpAssertions {
      servers = cfg.mcpServers;
      label = "programs.command-code.mcpServers";
    };

    home.packages = [ cfg.package ];

    home.activation.commandCodeConfiguration = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD ${syncScript}/bin/command-code-sync-global \
        --scope global \
        --data-dir ${lib.escapeShellArg dataDir} \
        --state-dir ${lib.escapeShellArg stateDir} \
        --config ${lib.escapeShellArg "${dataDir}/config.json"} \
        --settings ${lib.escapeShellArg "${dataDir}/settings.json"} \
        --mcp ${lib.escapeShellArg "${dataDir}/mcp.json"} \
        --hooks-dir ${lib.escapeShellArg hooksDir} \
        ${lib.optionalString cfg.migration.force "--force"}
    '';
  };
}
