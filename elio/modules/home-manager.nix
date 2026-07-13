# home-manager module for elio.
self:
{ config, lib, pkgs, ... }:
let
  helpers = import ./elio-lib.nix { inherit pkgs; };
  cfg = config.programs.elio;
in
{
  imports = [ (import ./elio-options.nix { inherit self; }) ];

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    xdg.configFile."elio/config.toml" = lib.mkIf (helpers.hasSettings cfg) {
      source = helpers.mkElioConfig { inherit cfg; };
    };

    xdg.configFile."elio/theme.toml" = lib.mkIf (cfg.theme != { }) {
      source = helpers.mkElioTheme { inherit cfg; };
    };

    programs.bash.initExtra = lib.mkIf cfg.enableBashIntegration ''
      eval "$(${cfg.package}/bin/elio shell init bash)"
    '';

    programs.zsh.initExtra = lib.mkIf cfg.enableZshIntegration ''
      eval "$(${cfg.package}/bin/elio shell init zsh)"
    '';

    programs.fish.interactiveShellInit = lib.mkIf cfg.enableFishIntegration ''
      ${cfg.package}/bin/elio shell init fish | source
    '';
  };
}
