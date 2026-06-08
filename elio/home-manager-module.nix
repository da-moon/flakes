{ config, lib, pkgs, ... }:

let
  cfg = config.programs.elio;
in
{
  options.programs.elio = {
    enable = lib.mkEnableOption "elio terminal music player";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.elio;
      defaultText = lib.literalExpression "pkgs.elio";
      description = "The elio package to use.";
    };

    enableBashIntegration = lib.mkEnableOption "bash integration" // {
      default = true;
    };

    enableZshIntegration = lib.mkEnableOption "zsh integration";

    enableFishIntegration = lib.mkEnableOption "fish integration";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

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
