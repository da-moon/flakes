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
  jsonFormat = pkgs.formats.json { };

  mergedSettings = lib.recursiveUpdate defaults.defaultSettings cfg.settings;
  mergedKeybindings = lib.recursiveUpdate defaults.defaultKeybindings cfg.keybindings;

  configFile = yamlFormat.generate "omp-config.yml" mergedSettings;
  keybindingsFile = yamlFormat.generate "omp-keybindings.yml" mergedKeybindings;

  stripNulls = lib.filterAttrs (_: v: v != null);

  mcpServerJson = server: stripNulls {
    inherit (server) type enabled;
    command = server.command;
    args = if server.args == [ ] then null else server.args;
    env = if server.env == { } then null else server.env;
    cwd = server.cwd;
    url = server.url;
    headers = if server.headers == { } then null else server.headers;
    requestIdFormat = server.requestIdFormat;
  };

  mcpServersFile = jsonFormat.generate "omp-mcp.json" {
    mcpServers = lib.mapAttrs (_: mcpServerJson) cfg.mcpServers;
  };

  mcpAssertions = lib.mapAttrsToList (name: s: {
    assertion = (s.type == "stdio") -> (s.command != null);
    message = ''
      programs.omp.mcpServers."${name}": `command` is required when `type = "stdio"`.
    '';
  }) cfg.mcpServers
  ++ lib.mapAttrsToList (name: s: {
    assertion = (s.type == "http" || s.type == "sse") -> (s.url != null);
    message = ''
      programs.omp.mcpServers."${name}": `url` is required when `type` is "http" or "sse".
    '';
  }) cfg.mcpServers;

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
    assertions = mcpAssertions;

    home.packages = [ cfg.package ];

    home.file = {
      ".omp/agent/config.yml".source = configFile;
      ".omp/agent/keybindings.yml".source = keybindingsFile;
    }
    // lib.optionalAttrs (cfg.mcpServers != { }) {
      ".omp/agent/mcp.json".source = mcpServersFile;
    };

    home.sessionVariables = envVars;
  };
}
