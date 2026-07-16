# Reusable flake-parts project module for kimi-code.
#
# A consuming project flake does:
#   imports = [ inputs.kimi-code.flakeModules.default ];
#   kimi.project = {
#     enable = true;
#     mcpServers = { ... };
#     isolation.enable = true;   # optional: project-local KIMI_CODE_HOME
#   };
{
  mkProjectIntegration
, kimiPackage
}:
{ config, lib, flake-parts-lib, self, ... }:
let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    mkIf
    ;
  schema = import ../modules/config-schema.nix { inherit lib; };
  hookSubmodule = import ../modules/hook-type.nix { inherit lib; };
  topCfg = config.kimi.project;
in
{
  options.kimi.project = {
    enable = mkEnableOption "Nix-managed Kimi Code project configuration";

    projectRoot = mkOption {
      type = types.str;
      default = ".";
      description = ''
        Project root relative to the consuming flake's git root. The module
        manages <projectRoot>/.kimi-code/ there ("." or a normalized relative
        path like "packages/api").
      '';
    };

    settings = mkOption {
      type = types.nullOr schema.settingsType;
      default = null;
      description = ''
        Declarative config.toml content for the project-local KIMI_CODE_HOME
        (only effective when isolation is enabled). Same merge semantics as
        the home-manager module.
      '';
    };

    tui = mkOption {
      type = types.nullOr schema.tuiType;
      default = null;
      description = ''
        Declarative tui.toml content for the project-local KIMI_CODE_HOME
        (only effective when isolation is enabled).
      '';
    };

    mcpServers = mkOption {
      type = types.nullOr (types.attrsOf schema.mcpServerType);
      default = null;
      description = ''
        Declarative MCP servers rendered to the committed
        .kimi-code/mcp.json (via the kimi-project-sync app + drift check).
        Kimi merges it over the user-level mcp.json at runtime; project
        entries win on name conflicts.
      '';
    };

    hooks = mkOption {
      type = types.listOf hookSubmodule;
      default = [ ];
      description = ''
        Project-level hooks. Kimi Code has no native project hook surface, so
        these are written into the project-local KIMI_CODE_HOME's config.toml
        and therefore only take effect when isolation is enabled.
      '';
    };

    isolation = {
      enable = mkEnableOption ''
        project-local KIMI_CODE_HOME at <projectRoot>/.kimi-code/home:
        the devShell exports it and renders the declared config.toml /
        tui.toml / mcp.json / hooks into it on entry. Sessions and logs stay
        per-project. Add .kimi-code/home/ to the project .gitignore.
      '';

      shareCredentials = mkOption {
        type = types.bool;
        default = true;
        description = ''
          When true, the isolated data home symlinks credentials/ to the
          global ~/.kimi-code/credentials and grafts OAuth references from
          the global config.toml, so no per-project re-login is needed.
          When false the project is fully isolated (separate login).
        '';
      };
    };
  };

  options.perSystem = flake-parts-lib.mkPerSystemOption (
    { config, pkgs, ... }:
    let
      cfg = config.kimi.project;
    in
    {
      options.kimi.project = {
        package = mkOption {
          type = types.nullOr types.package;
          default = kimiPackage pkgs;
          description = "The kimi-code package to expose in the project shell.";
        };

        extraPackages = mkOption {
          type = types.listOf types.package;
          default = [ ];
          description = "Extra packages available in the project shell.";
        };

        devShellName = mkOption {
          type = types.str;
          default = "kimi";
          description = "Name of the devShell carrying the integration.";
        };
      };

      config = mkIf topCfg.enable {
        inherit
          (mkProjectIntegration {
            inherit pkgs;
            sourceRoot = self.outPath;
            projectRoot = topCfg.projectRoot;
            package = cfg.package;
            settings = topCfg.settings;
            tui = topCfg.tui;
            mcpServers = topCfg.mcpServers;
            hooks = topCfg.hooks;
            isolation = topCfg.isolation;
            extraPackages = cfg.extraPackages;
            devShellName = cfg.devShellName;
          })
          apps
          checks
          devShells
          packages
          ;
      };
    }
  );
}
