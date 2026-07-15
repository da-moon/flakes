# Reusable flake-parts module factory for project-scoped Serena configuration.
#
# Import contract:
#
#   import ./project.nix {
#     mkProjectIntegration = projectIntegration.mkProjectIntegration;
#     projectSettingsType = ...; # shared typed project-schema option type
#     serenaPackage = pkgs: ...; # optional per-system default
#   }
#
# Consumer contract:
#
#   serena.project = {
#     enable = true;
#     projectRoot = ".";
#     settings = {
#       projectName = "example";
#       languages = [ "nix" ];
#     };
#   };
#
# Package selection is intentionally per-system:
#
#   perSystem = { pkgs, ... }: {
#     serena.project.package = ...;
#     serena.project.extraPackages = [ pkgs.nodejs ];
#   };
{
  mkProjectIntegration,
  projectSettingsType,
  serenaPackage ? null,
}:
{
  config,
  lib,
  self,
  flake-parts-lib,
  ...
}:
let
  cfg = config.serena.project;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  packageFor =
    pkgs:
    if serenaPackage == null then
      null
    else if builtins.isFunction serenaPackage then
      serenaPackage pkgs
    else
      serenaPackage;
in
{
  options = {
    serena.project = {
      enable = mkEnableOption "Nix-managed Serena project configuration and project-flake outputs";

      projectRoot = mkOption {
        type = types.str;
        default = ".";
        example = "packages/api";
        description = ''
          Normalized path to the Serena project, relative to the consuming
          flake's Git root. Absolute paths and traversal components are
          rejected. Version 1 intentionally supports only root flakes.
        '';
      };

      settings = mkOption {
        type = projectSettingsType;
        description = ''
          Complete typed Serena project configuration. `projectName` and
          `languages` are required; all other values use upstream defaults
          through the shared renderer.
        '';
      };
    };

    perSystem = flake-parts-lib.mkPerSystemOption (
      { pkgs, ... }: {
        options.serena.project = {
          package = mkOption {
            type = types.nullOr types.package;
            default = packageFor pkgs;
            defaultText = lib.literalExpression "the Serena flake's package for this system";
            description = ''
              Serena package used by the raw app and named development shell.
              A null value is allowed for module composition, but evaluation of
              enabled Serena outputs requires a package.
            '';
          };

          extraPackages = mkOption {
            type = types.listOf types.package;
            default = [ ];
            example = lib.literalExpression "[ pkgs.nodejs pkgs.python3 ]";
            description = ''
              Additional language runtimes and language-server packages exposed
              in the named `serena` development shell.
            '';
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
          sourceRoot = self.outPath;
          inherit (cfg) projectRoot settings;
          inherit (config.serena.project) package extraPackages;
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
