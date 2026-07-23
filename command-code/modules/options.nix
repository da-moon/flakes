{ lib, ... }:
let
  schema = import ./schema.nix { inherit lib; };
in
{
  options.programs.command-code = {
    enable = lib.mkEnableOption "Command Code AI coding agent";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The Command Code 1.1.1 package to use.";
    };

    config = lib.mkOption {
      type = schema.globalConfigType;
      default = { };
      description = "Strict declarative subset of ~/.commandcode/config.json.";
    };

    settings = lib.mkOption {
      type = schema.userSettingsType;
      default = { };
      description = "Strict declarative subset of ~/.commandcode/settings.json.";
    };

    hooks = {
      enableDefaultStripCoauthor = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install the default PreToolUse hook that rejects Command Code co-author trailers.";
      };

      definitions = lib.mkOption {
        type = lib.types.listOf schema.hookType;
        default = [ ];
        description = "Ordered global hook definitions.";
      };
    };

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf schema.mcpServerType;
      default = { };
      description = "Public, non-secret global MCP server configuration.";
    };

    migration.force = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Permit conflicting values to be replaced only while adopting an
        installation with no Nix ownership manifest. Disable after the first
        successful activation; later activations reject this option.
      '';
    };
  };
}
