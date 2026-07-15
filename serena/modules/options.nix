{
  config,
  lib,
  pkgs,
  ...
}:
let
  schema = import ../lib/config-schema.nix { inherit lib; };
in
{
  options.programs.serena = {
    enable = lib.mkEnableOption "Serena semantic coding agent";

    package = lib.mkPackageOption pkgs "serena" { };

    dataDir = lib.mkOption {
      type = lib.types.addCheck lib.types.str (value: lib.hasPrefix "/" value && value != "/");
      default = "${config.home.homeDirectory}/.serena";
      defaultText = lib.literalExpression ''"${config.home.homeDirectory}/.serena"'';
      description = ''
        Absolute writable Serena data directory. The module sets
        {env}`SERENA_HOME` to this value and resets its generated configuration
        files on every Home Manager activation.
      '';
    };

    runtimePackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.nodejs pkgs.jdk21 ]";
      description = ''
        Language runtimes and external language-server packages added to
        Serena's private {env}`PATH`. They are not installed into the user's
        general profile solely by this option.
      '';
    };

    global = lib.mkOption {
      type = schema.globalSettingsType;
      default = { };
      description = ''
        Complete global Serena configuration. Nix attribute names use
        lower camel case and are rendered to Serena's snake_case YAML keys.
      '';
    };

    contexts = lib.mkOption {
      type = lib.types.attrsOf schema.contextSettingsType;
      default = { };
      example = {
        headless = {
          prompt = "Operate without graphical tools.";
          excludedTools = [ "open_dashboard" ];
          singleProject = true;
        };
      };
      description = "Custom or overridden Serena contexts, keyed by context name.";
    };

    modes = lib.mkOption {
      type = lib.types.attrsOf schema.modeSettingsType;
      default = { };
      example = {
        review = {
          prompt = "Review the project without editing it.";
          excludedTools = [ "replace_symbol_body" ];
        };
      };
      description = "Custom or overridden Serena modes, keyed by mode name.";
    };

    promptTemplates = schema.mkPromptTemplatesOption {
      description = ''
        Custom prompt-template YAML files, keyed by filename or filename stem.
        Each file may contain typed built-in prompts and arbitrary
        {option}`extraPrompts`.
      '';
    };
  };
}
