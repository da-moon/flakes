# Project-level integration for command-code.
# Returns devShells and packages for the flake-parts project module.
{ pkgs
, projectRoot
, devShellName
, package
, hooks
, enableDefaultStripCoauthorHook ? true
}:
let
  helpers = import ./lib.nix { inherit pkgs; };
  lib = pkgs.lib;

  defaultHook = helpers.mkDefaultStripCoauthorHook { };
  allHooks = hooks ++ lib.optional enableDefaultStripCoauthorHook defaultHook;
  hooksPackage = helpers.mkHooksPackage { hooks = allHooks; };
  managedHooksJson = helpers.mkManagedHooksJson {
    hooks = allHooks;
    commandFor = h: "./.commandcode/hooks/${h.name}.sh";
  };
  mergeScript = helpers.mkMergeHooksScript {
    inherit managedHooksJson hooksPackage;
  };
in
{
  packages.command-code-project-config = mergeScript;

  devShells.${devShellName} = pkgs.mkShell {
    name = "command-code-project";
    packages = [ package ];
    shellHook = ''
      _root=$(cd ${lib.escapeShellArg projectRoot} && pwd)
      ${mergeScript}/bin/command-code-merge-hooks \
        "$_root/.commandcode/settings.json" \
        "$_root/.commandcode/hooks"
    '';
  };
}
