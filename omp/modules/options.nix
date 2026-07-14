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
  };
}
