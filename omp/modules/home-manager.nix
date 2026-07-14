# Home Manager module for oh-my-pi.
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

  optionalVar = cond: val: if cond then val else null;

  envVars = lib.filterAttrs (_: v: v != null) (
    lib.optionalAttrs (cfg.profile != null) {
      OMP_PROFILE = cfg.profile;
      PI_PROFILE = cfg.profile;
    }
    // lib.optionalAttrs (cfg.configDir != null) {
      PI_CONFIG_DIR = cfg.configDir;
    }
    // lib.optionalAttrs (cfg.agentDir != null) {
      PI_CODING_AGENT_DIR = cfg.agentDir;
    }
    // cfg.environment
  );
in
{
  imports = [ ./options.nix ];

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    home.file.".omp/agent/config.yml".source = configFile;
    home.file.".omp/agent/keybindings.yml".source = keybindingsFile;

    home.sessionVariables = envVars;
  };
}
