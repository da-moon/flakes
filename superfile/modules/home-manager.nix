# home-manager module for superfile.
{ config, lib, pkgs, ... }:
let
  helpers = import ./superfile-lib.nix { inherit pkgs; };
  cfg = config.programs.superfile;
in
{
  # home-manager >= 25.11 ships its own free-form programs.superfile module
  # (settings/hotkeys as untyped TOML values); its leaf options collide with
  # this module's typed sub-options. Disable the builtin — this flake's
  # module fully replaces it. A no-op on home-manager versions without it.
  disabledModules = [ "programs/superfile.nix" ];

  imports = [ ./superfile-options.nix ];

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    # Manage only the two files as HM symlinks: superfile MkdirAlls the
    # config dir and writes runtime state (theme sync, pinned.json, …) next
    # to them, so the directory itself must stay writable — a read-only
    # ~/.config/superfile crashes superfile at startup.
    xdg.configFile."superfile/config.toml".source = helpers.mkSuperfileConfig { inherit cfg; };
    xdg.configFile."superfile/hotkeys.toml".source = helpers.mkSuperfileHotkeys { inherit cfg; };

    # Upstream's LoadHotkeysFile rejects a hotkey whose first binding is
    # empty; enforce the same at evaluation time.
    assertions = lib.mapAttrsToList (name: keys: {
      assertion = keys != [ ] && builtins.head keys != "";
      message = "programs.superfile.hotkeys.${name}: the first key binding must be a non-empty string.";
    }) cfg.hotkeys;
  };
}
