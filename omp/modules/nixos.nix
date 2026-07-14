# NixOS module for oh-my-pi.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.omp;
  defaults = import ./defaults.nix { };

  yamlFormat = pkgs.formats.yaml { };

  mergedSettings = lib.recursiveUpdate defaults.defaultSettings cfg.settings;
  mergedKeybindings = lib.recursiveUpdate defaults.defaultKeybindings cfg.keybindings;

  configFile = yamlFormat.generate "omp-config.yml" mergedSettings;
  keybindingsFile = yamlFormat.generate "omp-keybindings.yml" mergedKeybindings;

  agentDir = if cfg.agentDir != null then cfg.agentDir else "/etc/omp/agent";
in
{
  imports = [ ./options.nix ];

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    environment.etc."omp/agent/config.yml".source = configFile;
    environment.etc."omp/agent/keybindings.yml".source = keybindingsFile;

    environment.sessionVariables = lib.filterAttrs (_: v: v != null) (
      {
        PI_CODING_AGENT_DIR = agentDir;
      }
      // lib.optionalAttrs (cfg.profile != null) {
        OMP_PROFILE = cfg.profile;
        PI_PROFILE = cfg.profile;
      }
      // lib.optionalAttrs (cfg.configDir != null) {
        PI_CONFIG_DIR = cfg.configDir;
      }
      // cfg.environment
    );
  };
}
