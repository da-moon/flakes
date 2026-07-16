# Reusable flake-parts project module for command-code.
{
  mkProjectIntegration,
  commandCodePackage,
}:
{ config, lib, flake-parts-lib, ... }:
let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    mkIf
    ;
  hookSubmodule = import ../modules/hook-type.nix { inherit lib; };
in
{
  options.perSystem = flake-parts-lib.mkPerSystemOption (
    { config, pkgs, ... }:
    {
      options.command-code.project = {
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
          default = commandCodePackage pkgs;
          description = ''
            The command-code package to expose in the project shell.
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

      config = mkIf config.command-code.project.enable {
        inherit (mkProjectIntegration {
          inherit pkgs;
          package = config.command-code.project.package;
          projectRoot = config.command-code.project.projectRoot;
          devShellName = config.command-code.project.devShellName;
          hooks = config.command-code.project.hooks;
          enableDefaultStripCoauthorHook = config.command-code.project.enableDefaultStripCoauthorHook;
        }) devShells packages;
      };
    }
  );
}
