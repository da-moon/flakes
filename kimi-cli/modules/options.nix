# Typed options for the kimi-cli Home Manager module.
{ config, lib, pkgs, ... }:
let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    ;

  hookSubmodule = import ./hook-type.nix { inherit lib; };
in
{
  options.programs.kimi-cli = {
    enable = mkEnableOption "Kimi Code CLI";

    package = mkOption {
      type = types.package;
      description = "The kimi-cli package to use.";
    };

    enableDefaultRedirectWebToolsHook = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Inject the default PreToolUse hooks that redirect WebSearch and
        FetchURL tool calls to the parallel-search MCP.
      '';
    };

    hooks = mkOption {
      type = types.listOf hookSubmodule;
      default = [ ];
      description = ''
        Additional custom hooks to merge into Kimi's config.toml.
        Existing hooks and hand-edited settings are preserved.
      '';
    };
  };
}
