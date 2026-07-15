{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.serena;
  schema = import ../lib/config-schema.nix { inherit lib; };
  render = import ../lib/render.nix { inherit lib; };

  validDefinitionName = name: builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" name != null;
  validPromptFileName = name: builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*(\\.(yml|yaml))?" name != null;
  promptFileName =
    name: if lib.hasSuffix ".yml" name || lib.hasSuffix ".yaml" name then name else "${name}.yml";

  globalFile = render.mkGlobalYaml {
    inherit pkgs;
    settings = cfg.global;
  };
  contextFiles = lib.mapAttrs (
    name: settings:
    render.mkContextYaml {
      inherit pkgs;
      settings = settings // {
        inherit name;
      };
      name = "serena-context-${name}.yml";
    }
  ) cfg.contexts;
  modeFiles = lib.mapAttrs (
    name: settings:
    render.mkModeYaml {
      inherit pkgs;
      settings = settings // {
        inherit name;
      };
      name = "serena-mode-${name}.yml";
    }
  ) cfg.modes;
  promptFiles = lib.mapAttrs (
    name: settings:
    render.mkPromptYaml {
      inherit pkgs settings;
      name = "serena-prompts-${promptFileName name}";
    }
  ) cfg.promptTemplates;

  wrapperArguments = [
    "--set-default"
    "SERENA_HOME"
    cfg.dataDir
  ]
  ++ lib.optionals (cfg.runtimePackages != [ ]) [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath cfg.runtimePackages)
  ];
  wrappedPackage = pkgs.symlinkJoin {
    name = "${lib.getName cfg.package}-home-manager";
    paths = [ cfg.package ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      for executable in "$out"/bin/*; do
        if [[ -f "$executable" && -x "$executable" ]]; then
          wrapProgram "$executable" ${lib.escapeShellArgs wrapperArguments}
        fi
      done
    '';
  };

  fileInstall = source: relativeTarget: ''
    install_managed_file ${lib.escapeShellArg (toString source)} ${lib.escapeShellArg relativeTarget}
  '';
  contextInstalls = lib.concatStrings (
    lib.mapAttrsToList (name: source: fileInstall source "contexts/${name}.yml") contextFiles
  );
  modeInstalls = lib.concatStrings (
    lib.mapAttrsToList (name: source: fileInstall source "modes/${name}.yml") modeFiles
  );
  promptInstalls = lib.concatStrings (
    lib.mapAttrsToList (
      name: source: fileInstall source "prompt_templates/${promptFileName name}"
    ) promptFiles
  );
  managedRelativePaths = [
    "serena_config.yml"
  ]
  ++ map (name: "contexts/${name}.yml") (builtins.attrNames contextFiles)
  ++ map (name: "modes/${name}.yml") (builtins.attrNames modeFiles)
  ++ map (name: "prompt_templates/${promptFileName name}") (builtins.attrNames promptFiles);
  managedFilesManifest = pkgs.writeText "serena-home-manager-files" (
    lib.concatMapStrings (path: "${path}\n") managedRelativePaths
  );

  nameAssertions =
    lib.mapAttrsToList (name: _: {
      assertion = validDefinitionName name;
      message = "programs.serena.contexts has invalid name ${builtins.toJSON name}; use letters, digits, '_' or '-'.";
    }) cfg.contexts
    ++ lib.mapAttrsToList (name: _: {
      assertion = validDefinitionName name;
      message = "programs.serena.modes has invalid name ${builtins.toJSON name}; use letters, digits, '_' or '-'.";
    }) cfg.modes
    ++ lib.mapAttrsToList (name: _: {
      assertion = validPromptFileName name;
      message = "programs.serena.promptTemplates has invalid filename ${builtins.toJSON name}; use a safe stem, optionally ending in .yml or .yaml.";
    }) cfg.promptTemplates;
  semanticAssertions =
    schema.assertionsFor {
      scope = "global";
      config = cfg.global;
      label = "programs.serena.global";
    }
    ++ lib.concatLists (
      lib.mapAttrsToList (
        name: value:
        schema.assertionsFor {
          scope = "context";
          config = value;
          label = "programs.serena.contexts.${name}";
        }
      ) cfg.contexts
    )
    ++ lib.concatLists (
      lib.mapAttrsToList (
        name: value:
        schema.assertionsFor {
          scope = "mode";
          config = value;
          label = "programs.serena.modes.${name}";
        }
      ) cfg.modes
    );
  semanticWarnings =
    schema.warningsFor {
      scope = "global";
      config = cfg.global;
    }
    ++ lib.concatLists (
      lib.mapAttrsToList (
        _: value:
        schema.warningsFor {
          scope = "context";
          config = value;
        }
      ) cfg.contexts
    )
    ++ lib.concatLists (
      lib.mapAttrsToList (
        _: value:
        schema.warningsFor {
          scope = "mode";
          config = value;
        }
      ) cfg.modes
    );
in
{
  imports = [ ./options.nix ];

  config = lib.mkIf cfg.enable {
    assertions = nameAssertions ++ semanticAssertions;
    warnings = semanticWarnings;

    home.packages = [ wrappedPackage ];
    home.sessionVariables.SERENA_HOME = cfg.dataDir;

    home.activation.serenaConfiguration = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      serena_dir=${lib.escapeShellArg cfg.dataDir}

      if [[ -L "$serena_dir" || ( -e "$serena_dir" && ! -d "$serena_dir" ) ]]; then
        echo "programs.serena: refusing unsafe data directory $serena_dir" >&2
        exit 1
      fi
      $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -d -m 0700 "$serena_dir"
      for managed_directory in contexts modes prompt_templates; do
        target_directory="$serena_dir/$managed_directory"
        if [[ -L "$target_directory" || ( -e "$target_directory" && ! -d "$target_directory" ) ]]; then
          echo "programs.serena: refusing unsafe managed directory $target_directory" >&2
          exit 1
        fi
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -d -m 0700 "$target_directory"
      done

      managed_manifest="$serena_dir/.nix-managed-files"
      if [[ -L "$managed_manifest" || ( -e "$managed_manifest" && ! -f "$managed_manifest" ) ]]; then
        echo "programs.serena: refusing unsafe managed-file manifest $managed_manifest" >&2
        exit 1
      fi
      if [[ -f "$managed_manifest" ]]; then
        while IFS= read -r relative_target; do
          if [[ "$relative_target" == "serena_config.yml" \
            || "$relative_target" =~ ^contexts/[A-Za-z0-9][A-Za-z0-9_-]*\.yml$ \
            || "$relative_target" =~ ^modes/[A-Za-z0-9][A-Za-z0-9_-]*\.yml$ \
            || "$relative_target" =~ ^prompt_templates/[A-Za-z0-9][A-Za-z0-9_-]*\.(yml|yaml)$ ]]; then
            $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f -- "$serena_dir/$relative_target"
          elif [[ -n "$relative_target" ]]; then
            echo "programs.serena: ignoring unsafe path in $managed_manifest: $relative_target" >&2
          fi
        done < "$managed_manifest"
      fi

      install_managed_file() {
        source_file="$1"
        relative_target="$2"
        target_file="$serena_dir/$relative_target"

        if [[ -e "$target_file" && ! -f "$target_file" ]]; then
          echo "programs.serena: refusing to replace non-regular path $target_file" >&2
          return 1
        fi
        if [[ -L "$target_file" ]]; then
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f -- "$target_file"
        fi
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -m 0600 -- "$source_file" "$target_file"
      }

      install_managed_file ${lib.escapeShellArg (toString globalFile)} serena_config.yml
      ${contextInstalls}
      ${modeInstalls}
      ${promptInstalls}
      install_managed_file ${lib.escapeShellArg (toString managedFilesManifest)} .nix-managed-files
    '';
  };
}
