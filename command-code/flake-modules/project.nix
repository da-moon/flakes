# Reusable flake-parts project module for command-code.
{
  mkProjectIntegration,
}:
{ config, lib, self, flake-parts-lib, ... }:
let
  cfg = config.command-code.project;
  inherit (lib)
    mkEnableOption
    mkOption
    types
    mkIf
    ;
  hookSubmodule = import ../modules/hook-type.nix { inherit lib; };
in
{
  options = {
    command-code.project = {
      enable = mkEnableOption "Nix-managed Command Code project configuration and hooks";

      projectRoot = mkOption {
        type = types.str;
        default = ".";
        description = ''
          Path to the project root, relative to the consuming flake's
          working directory. The module will create
          <projectRoot>/.commandcode/settings.json and hooks there.
        '';
      };

      devShellName = mkOption {
        type = types.str;
        default = "default";
        description = ''
          Name of the devShell that should run the hook merge on entry.
        '';
      };

      package = mkOption {
        type = types.nullOr types.package;
        default = null;
        description = ''
          The command-code package to expose in the project shell. When
          null, the flake's default package for the current system is used.
        '';
      };

      enableDefaultStripCoauthorHook = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Inject the default strip-coauthor hook into the project config.
        '';
      };

      hooks = mkOption {
        type = types.listOf hookSubmodule;
        default = [ ];
        description = ''
          Custom hooks to merge into the project-level
          .commandcode/settings.json.
        '';
      };
    };

    perSystem = flake-parts-lib.mkPerSystemOption (
      { pkgs, ... }: {
        options.command-code.project = {
          package = mkOption {
            type = types.nullOr types.package;
            default = self.packages.${pkgs.stdenv.hostPlatform.system}.default or null;
            description = ''
              Per-system command-code package override.
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
        package = cfg.package or config.command-code.project.package or self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      in
      mkIf (package != null) {
        inherit (mkProjectIntegration {
          inherit pkgs package;
          projectRoot = cfg.projectRoot;
          devShellName = cfg.devShellName;
          hooks = cfg.hooks;
          enableDefaultStripCoauthorHook = cfg.enableDefaultStripCoauthorHook;
        }) devShells packages;
      };
  };
}
