# Shared options for the oh-my-pi Nix modules.
{ lib, pkgs, ... }:
let
  inherit (lib)
    mkOption
    mkPackageOption
    types
    ;
in
{
  options.programs.omp = {
    enable = lib.mkEnableOption "oh-my-pi (omp) AI coding agent";

    package = mkPackageOption pkgs "omp" { };

    profile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Profile name to use for oh-my-pi configuration.
        Sets {env}`OMP_PROFILE` and {env}`PI_PROFILE`.
        Leave unset to use the default profile and respect any existing value.
      '';
    };

    configDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Override the oh-my-pi config root directory (normally {file}`~/.omp`).
        Sets {env}`PI_CONFIG_DIR`.
        Leave unset to respect any existing value.
      '';
    };

    agentDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Override the oh-my-pi agent directory (normally {file}`~/.omp/agent`).
        Sets {env}`PI_CODING_AGENT_DIR`.
        Leave unset to respect any existing value.
        On NixOS this is managed system-wide and defaults to {file}`/etc/omp/agent`.
      '';
    };

    settings = mkOption {
      type = types.attrs;
      default = { };
      description = ''
        oh-my-pi settings written to {file}`config.yml`.
        Values are merged over the documented defaults.
        Use nested Nix attribute sets to produce nested YAML mappings.
      '';
    };

    keybindings = mkOption {
      type = types.attrs;
      default = { };
      description = ''
        Oh-my-pi keybindings written to {file}`keybindings.yml`.
        Values are merged over the documented defaults.
        Each value is either a single chord string or a list of chord strings;
        an empty list disables the binding.
      '';
    };

    environment = mkOption {
      type = types.attrsOf (types.nullOr types.str);
      default = { };
      description = ''
        Additional environment variables to set when running oh-my-pi.
        Variables set to {nix}`null` are omitted, so existing environment
        variables are respected.
      '';
    };

    mcpServers = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              type = mkOption {
                type = types.enum [
                  "stdio"
                  "http"
                  "sse"
                ];
                default = "stdio";
                description = "MCP server transport.";
              };

              command = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Executable for a stdio server (required when {nix}`type = \"stdio\"`).";
              };

              args = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Arguments for the stdio command.";
              };

              env = mkOption {
                type = types.attrsOf types.str;
                default = { };
                description = "Environment variables injected into the stdio child process.";
              };

              cwd = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Working directory for the stdio child process.";
              };

              url = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "URL for an HTTP or SSE server (required when {nix}`type` is {nix}`\"http\"` or {nix}`\"sse\"`).";
              };

              headers = mkOption {
                type = types.attrsOf types.str;
                default = { };
                description = "Static request headers (HTTP/SSE).";
              };

              enabled = mkOption {
                type = types.bool;
                default = true;
                description = "Set to false to disable the server without removing it.";
              };

              requestIdFormat = mkOption {
                type = types.nullOr (
                  types.enum [
                    "string"
                    "number"
                  ]
                );
                default = null;
                description = ''
                  JSON-RPC request id encoding. omp defaults to per-connection
                  sequential integers; set to {nix}`"string"` for servers that
                  need collision-resistant string ids.
                '';
              };
            };
          }
        )
      );
      default = { };
      description = ''
        Declarative MCP servers written to {file}`~/.omp/agent/mcp.json`
        (omp's global, non-project MCP config; see {file}`.omp/mcp.json` /
        project {file}`.mcp.json` for per-project servers). The file is fully
        declarative: it contains exactly the servers declared here.
      '';
    };
  };
}
