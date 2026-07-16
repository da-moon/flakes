# Typed options for the command-code Home Manager and project modules.
{ config, lib, pkgs, ... }:
let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    ;

  hookSubmodule = import ./hook-type.nix { inherit lib; };
in
{
  options.programs.command-code = {
    enable = mkEnableOption "Command Code AI coding agent";

    package = mkOption {
      type = types.package;
      description = "The command-code package to use.";
    };

    enableDefaultStripCoauthorHook = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Inject the default PreToolUse hook that denies git commits
        containing a Command Code co-author trailer.
      '';
    };

    hooks = mkOption {
      type = types.listOf hookSubmodule;
      default = [ ];
      description = ''
        Additional custom hooks to merge into Command Code's
        settings.json. Existing hooks and hand-edited settings are
        preserved.
      '';
    };
  };
}
