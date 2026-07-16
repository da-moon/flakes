# Home Manager module for kimi-cli (global ~/.kimi-code/config.toml).
{ config, lib, pkgs, ... }:
let
  helpers = import ./lib.nix { inherit pkgs; };
  cfg = config.programs.kimi-cli;

  defaultHooks = helpers.mkDefaultRedirectWebToolsHooks { };
  allHooks = cfg.hooks ++ lib.optionals cfg.enableDefaultRedirectWebToolsHook defaultHooks;
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

    home.activation.kimiHooks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD ${mergeScript}/bin/kimi-merge-hooks \
        ${lib.escapeShellArg config.home.homeDirectory}/.kimi-code/config.toml \
        ${lib.escapeShellArg config.home.homeDirectory}/.kimi-code/hooks
    '';
  };
}
