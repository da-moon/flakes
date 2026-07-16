# Typed options for the kimi-code Home Manager module.
{ config, lib, pkgs, ... }:
let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    ;

  hookSubmodule = import ./hook-type.nix { inherit lib; };
  schema = import ./config-schema.nix { inherit lib; };
in
{
  options.programs.kimi-code = {
    enable = mkEnableOption "Kimi Code CLI";

    package = mkOption {
      type = types.package;
      description = "The kimi-code package to use.";
    };

    settings = mkOption {
      type = types.nullOr schema.settingsType;
      default = null;
      description = ''
        Declarative content for ~/.kimi-code/config.toml with
        declarative-core merge semantics: declared keys win (runtime edits to
        them are reset on the next switch), typed-but-undeclared keys inside a
        declared section are removed (back to upstream defaults), unknown keys
        are preserved, and runtime-injected `[providers.*.oauth]` /
        `[services.*.oauth]` references are grafted back. `null` leaves the
        file's typed surface unmanaged (hooks below are still managed).
      '';
    };

    tui = mkOption {
      type = types.nullOr schema.tuiType;
      default = null;
      description = ''
        Declarative content for ~/.kimi-code/tui.toml. When set, the typed
        tui surface is fully managed (defaults filled; `upgrade.auto_install`
        defaults to false so the CLI does not self-update around the Nix
        binary); unknown keys are preserved. `null` leaves the file
        unmanaged.
      '';
    };

    mcpServers = mkOption {
      type = types.nullOr (types.attrsOf schema.mcpServerType);
      default = null;
      description = ''
        Declarative MCP servers for ~/.kimi-code/mcp.json. When non-null the
        file is fully declarative: it contains exactly the declared servers
        (hand-added servers are dropped on switch). Prefer
        `bearerTokenEnvVar` over literal Authorization headers so no secret
        lands in the file or the Nix store. `null` leaves the file
        unmanaged.
      '';
    };

    hooks = mkOption {
      type = types.listOf hookSubmodule;
      default = [ ];
      description = ''
        Hooks to manage in config.toml's [[hooks]] table. Each hook's script
        is packaged into the Nix store and upserted by name; hand-added
        foreign hooks are preserved, and Nix-managed hooks removed from this
        list are cleaned up on the next switch.
      '';
    };
  };
}
