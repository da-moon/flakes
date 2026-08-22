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

    home.file.".omp/agent/keybindings.yml".source = keybindingsFile;

    # config.yml and mcp.json are omp runtime write targets: every settings
    # save takes a native lock on `${realpath(file)}.lock` and writes an
    # atomic `.tmp` sibling next to the file (upstream
    # packages/utils/src/file-lock.ts; on macOS the lock itself is a
    # flock(2) sidecar file). home.file would symlink them into the
    # read-only Nix store, where lock creation (macOS) and writes (all
    # platforms) fail. Materialize real writable copies at activation
    # instead. A plain file whose content matches this generation is left
    # alone, so runtime edits (e.g. `omp config set`) survive switches that
    # did not change programs.omp; stale HM symlinks and content drift are
    # overwritten.
    home.activation.ompAgentConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      agentDir="${config.home.homeDirectory}/.omp/agent"
      mkdir -p "$agentDir"

      installManaged() {
        if [ ! -L "$2" ] && cmp -s "$1" "$2" 2>/dev/null; then
          return 0
        fi
        rm -f "$2"
        install -m 600 "$1" "$2"
      }

      installManaged "${configFile}" "$agentDir/config.yml"
      ${lib.optionalString (cfg.mcpServers != { }) ''
        installManaged "${mcpServersFile}" "$agentDir/mcp.json"
      ''}
    '';

    home.sessionVariables = envVars;
  };
}
