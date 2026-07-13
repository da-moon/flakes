# Shared typed options for the elio home-manager and NixOS modules.
self:
{ config, lib, pkgs, ... }:
let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    ;

  mkBoolOption = description:
    mkOption { type = types.nullOr types.bool; default = null; inherit description; };

  mkIntOption = description:
    mkOption { type = types.nullOr types.int; default = null; inherit description; };

  mkStrOption = description:
    mkOption { type = types.nullOr types.str; default = null; inherit description; };

  entrySubmodule = types.submodule {
    options = {
      builtin = mkStrOption "Built-in place/goto id (e.g. \"downloads\").";
      title = mkStrOption "Custom entry title.";
      path = mkStrOption "Custom entry path (absolute or ~/...).";
      icon = mkStrOption "Nerd Font glyph icon for places entries.";
      key = mkStrOption "Single-key shortcut for goto entries.";
    };
  };

  entryType = types.nullOr (types.either types.str entrySubmodule);

  openRuleSubmodule = types.submodule {
    options = {
      ext = mkStrOption "File extension to match (e.g. \"md\").";
      type = mkOption {
        type = types.nullOr (types.either types.str (types.listOf types.str));
        default = null;
        description = "elio file type(s) to match (e.g. [\"text\" \"code\"]).";
      };
      command = mkOption {
        type = types.str;
        description = "Command used to open matched files. Use {path} if the app needs paths inline.";
      };
      terminal = mkBoolOption "Set to true for terminal apps so elio suspends, waits, and restores.";
      platform = mkOption {
        type = types.nullOr (types.either types.str (types.listOf types.str));
        default = null;
        description = "Operating system(s) this rule applies to (e.g. \"linux\" or [\"linux\" \"bsd\"]).";
      };
    };
  };

  tomlType = (pkgs.formats.toml { }).type;
in
{
  options.programs.elio = {
    enable = mkEnableOption "elio terminal file manager";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "inputs.elio.packages.\${pkgs.stdenv.hostPlatform.system}.default";
      description = "The elio package to use.";
    };

    enableBashIntegration = mkEnableOption "bash cd-on-quit integration" // {
      default = true;
    };

    enableZshIntegration = mkEnableOption "zsh cd-on-quit integration";

    enableFishIntegration = mkEnableOption "fish cd-on-quit integration";

    ui = {
      showTopBar = mkBoolOption "Show the top bar on startup.";
      gridZoom = mkOption {
        type = types.nullOr (types.ints.between 0 2);
        default = null;
        description = "Starting grid zoom level: 0, 1, or 2.";
      };
      showHidden = mkBoolOption "Show dotfiles and hidden files on startup.";
      startInGrid = mkBoolOption "Open in grid view on startup.";
    };

    places = {
      showDevices = mkBoolOption "Show the auto-detected Devices section below pinned places.";
      entries = mkOption {
        type = types.nullOr (types.listOf entryType);
        default = null;
        description = ''
          Pinned sidebar entries in order. Each entry can be a built-in id
          string (e.g. "downloads") or an attribute set with
          { builtin, title, path, icon }.
        '';
      };
    };

    goto = {
      entries = mkOption {
        type = types.nullOr (types.listOf entryType);
        default = null;
        description = ''
          Go To menu entries in order. Each entry can be a built-in id
          string (e.g. "downloads") or an attribute set with
          { builtin, title, path, key }.
        '';
      };
    };

    open = {
      rules = mkOption {
        type = types.nullOr (types.listOf openRuleSubmodule);
        default = null;
        description = ''
          Override rules for elio's open action. Rules are checked top-down;
          put specific extension rules before broad type rules.
        '';
      };
    };

    layout = {
      panes = {
        places = mkIntOption "Relative weight of the Places pane (0 hides it).";
        files = mkIntOption "Relative weight of the Files pane; must be greater than 0.";
        preview = mkIntOption "Relative weight of the Preview pane (0 hides it).";
      };
    };

    keys = mkOption {
      type = types.nullOr (types.attrsOf (types.either types.str (types.listOf types.str)));
      default = null;
      description = ''
        Browser action key bindings. Values may be a single key string, a list
        of key strings, or [] to unbind an action.
      '';
    };

    extraSettings = mkOption {
      type = tomlType;
      default = { };
      description = ''
        Additional free-form TOML settings merged into config.toml. Use this
        for any options not covered by the typed options above.
      '';
    };

    theme = mkOption {
      type = tomlType;
      default = { };
      description = ''
        Free-form theme attrset written to elio/theme.toml. See upstream's
        default theme for the full set of available keys.
      '';
    };
  };
}
