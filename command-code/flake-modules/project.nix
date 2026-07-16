# Reusable flake-parts module for local-only Command Code project configuration.
{
  mkProjectIntegration,
  projectSettingsType,
  hookType,
  mcpServerType,
  commandCodePackage ? null,
}:
{
  config,
  lib,
  flake-parts-lib,
  ...
}:
let
  cfg = config.command-code.project;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  packageFor =
    pkgs:
    if commandCodePackage == null then
      null
    else if builtins.isFunction commandCodePackage then
      commandCodePackage pkgs
    else
      commandCodePackage;
in
{
  options = {
    command-code.project = {
      enable = mkEnableOption "local-only Nix-managed Command Code project configuration";

      projectRoot = mkOption {
        type = types.str;
        default = ".";
        example = "packages/api";
        description = ''
          Normalized path to the Command Code project, relative to the consuming
          flake's canonical Git root. Absolute paths, traversal, and symbolic-link
          components are rejected at synchronization time.
        '';
      };

      settings = mkOption {
        type = projectSettingsType;
        default = { };
        description = ''
          Strict project-local settings merged into
          .commandcode/settings.local.json. Shared .commandcode/settings.json is
          never read or written by this module.
        '';
      };

      hooks = mkOption {
        type = types.listOf hookType;
        default = [ ];
        description = ''
          Ordered project-local hook definitions merged into
          .commandcode/settings.local.json. Nix owns only the resulting hook
          commands and preserves unrelated hook entries.
        '';
      };

      mcpServers = mkOption {
        type = types.attrsOf mcpServerType;
        default = { };
        description = ''
          Non-secret project-local MCP server declarations. They are merged into
          Command Code's private ~/.commandcode/projects/<slug>/mcp.json; the
          shared .mcp.json file is never read or written.
        '';
      };
    };

    perSystem = flake-parts-lib.mkPerSystemOption (
      { pkgs, ... }:
      {
        options.command-code.project = {
          package = mkOption {
            type = types.nullOr types.package;
            default = packageFor pkgs;
            defaultText = lib.literalExpression "the Command Code flake's package for this system";
            description = ''
              Command Code package wrapped by the project app and development
              shell. A null value is permitted for module composition, but an
              enabled project integration requires a package.
            '';
          };

          extraPackages = mkOption {
            type = types.listOf types.package;
            default = [ ];
            example = lib.literalExpression "[ pkgs.nodejs pkgs.python3 ]";
            description = "Additional packages exposed in devShells.command-code.";
          };
        };
      }
    );
  };

  config = mkIf cfg.enable {
    perSystem =
      { config, pkgs, ... }:
      let
        integration = mkProjectIntegration {
          inherit pkgs;
          inherit (cfg)
            projectRoot
            settings
            hooks
            mcpServers
            ;
          inherit (config.command-code.project) package extraPackages;
        };
      in
      {
        inherit (integration)
          apps
          checks
          packages
          devShells
          ;
      };
  };
}
