# Home Manager module for command-code (global ~/.commandcode/settings.json).
{ config, lib, pkgs, ... }:
let
  helpers = import ./lib.nix { inherit pkgs; };
  cfg = config.programs.command-code;

  defaultHook = helpers.mkDefaultStripCoauthorHook { };
  allHooks = cfg.hooks ++ lib.optional cfg.enableDefaultStripCoauthorHook defaultHook;
  hooksPackage = helpers.mkHooksPackage { hooks = allHooks; };
  managedHooksJson = helpers.mkManagedHooksJson {
    hooks = allHooks;
    commandFor = h: "${hooksPackage}/bin/${h.name}.sh";
  };
  mergeScript = helpers.mkMergeHooksScript {
    inherit managedHooksJson hooksPackage;
  };
in
{
  imports = [ ./options.nix ];

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    home.activation.commandCodeHooks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD ${mergeScript}/bin/command-code-merge-hooks \
        ${lib.escapeShellArg config.home.homeDirectory}/.commandcode/settings.json \
        ${lib.escapeShellArg config.home.homeDirectory}/.commandcode/hooks
    '';
  };
}
