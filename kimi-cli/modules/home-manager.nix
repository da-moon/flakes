# Home Manager module for kimi-cli: declarative management of the global
# ~/.kimi-code data directory (config.toml, tui.toml, mcp.json, hooks).
{ config, lib, pkgs, ... }:
let
  helpers = import ./lib.nix { inherit pkgs; };
  render = import ./render.nix { inherit lib; };
  schema = import ./config-schema.nix { inherit lib; };
  cfg = config.programs.kimi-cli;

  hooksPackage = helpers.mkHooksPackage { hooks = cfg.hooks; };
  managedHooksJson = helpers.mkManagedHooksJson {
    hooks = cfg.hooks;
    commandFor = h: "${hooksPackage}/bin/${h.name}.sh";
  };

  syncScript = helpers.mkSyncConfigScript {
    manifestJson = helpers.mkManifestJson schema.manifest;
    tuiManifestJson = helpers.mkManifestJson schema.tuiManifest;
    inherit managedHooksJson hooksPackage;
    declaredConfigJson =
      if cfg.settings != null then render.mkConfigJson { inherit pkgs; settings = cfg.settings; } else null;
    declaredTuiJson =
      if cfg.tui != null then render.mkTuiJson { inherit pkgs; tui = cfg.tui; } else null;
    mcpJson =
      if cfg.mcpServers != null then render.mkMcpJson { inherit pkgs; servers = cfg.mcpServers; } else null;
  };

  mcpAssertions = lib.flatten (
    lib.mapAttrsToList
      (name: s: [
        {
          assertion = (s.command == null) != (s.url == null);
          message = ''
            programs.kimi-cli.mcpServers."${name}": exactly one of `command`
            (stdio server) or `url` (HTTP/SSE server) must be set.
          '';
        }
      ])
      (if cfg.mcpServers == null then { } else cfg.mcpServers)
  );
in
{
  imports = [ ./options.nix ];

  config = lib.mkIf cfg.enable {
    assertions = mcpAssertions;

    home.packages = [ cfg.package ];

    home.activation.kimiSyncConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD ${syncScript}/bin/kimi-sync-config \
        ${lib.escapeShellArg config.home.homeDirectory}/.kimi-code \
        ${lib.escapeShellArg config.home.homeDirectory}/.kimi-code/hooks
    '';
  };
}
