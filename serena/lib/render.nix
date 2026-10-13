{ lib }:
let
  schema = import ./config-schema.nix { inherit lib; };

  renameAttrs =
    mapping: value:
    lib.mapAttrs' (nixName: upstreamName: lib.nameValuePair upstreamName value.${nixName}) mapping;

  renamePresentAttrs =
    mapping: value:
    lib.mapAttrs' (nixName: upstreamName: lib.nameValuePair upstreamName value.${nixName}) (
      lib.filterAttrs (nixName: _: value ? ${nixName} && value.${nixName} != null) mapping
    );

  toUpstreamRuntimeDependency =
    dependency: renamePresentAttrs schema.runtimeDependencyFieldMappings dependency;

  toUpstreamJavaRuntime = runtime: renamePresentAttrs schema.javaRuntimeFieldMappings runtime;

  toUpstreamLsLanguage =
    language: settings:
    let
      mapped =
        (settings.extraSettings or { }) // renamePresentAttrs schema.lsFieldMappings.${language} settings;
    in
    if language == "csharp" && mapped ? runtime_dependencies then
      mapped
      // {
        runtime_dependencies = map toUpstreamRuntimeDependency mapped.runtime_dependencies;
      }
    else if language == "java" && mapped ? runtimes then
      mapped // { runtimes = map toUpstreamJavaRuntime mapped.runtimes; }
    else
      mapped;

in
rec {
  inherit
    schema
    toUpstreamJavaRuntime
    toUpstreamLsLanguage
    toUpstreamRuntimeDependency
    ;

  toUpstreamLsSpecificSettings =
    settings:
    (settings.extraSettings or { })
    //
      lib.mapAttrs'
        (
          language: upstreamLanguage:
          lib.nameValuePair upstreamLanguage (toUpstreamLsLanguage language settings.${language})
        )
        (
          lib.filterAttrs (
            language: _: settings ? ${language} && settings.${language} != null
          ) schema.lsLanguageMappings
        );

  toUpstreamGlobal =
    settings:
    let
      complete = schema.globalDefaults // settings;
    in
    if complete.extraSettings ? auth_secret then
      throw "Serena auth_secret is runtime-owned and cannot be declared through global.extraSettings."
    else
      complete.extraSettings
      // renameAttrs schema.globalFieldMappings (
        complete
        // {
          lsSpecificSettings = toUpstreamLsSpecificSettings complete.lsSpecificSettings;
          projects = map toString complete.projects;
        }
      );

  toUpstreamProject =
    settings:
    let
      complete = schema.projectDefaults // settings;
    in
    complete.extraSettings
    // renameAttrs schema.projectFieldMappings (
      complete
      // {
        lsAdditionalWorkspaceFolders = map toString complete.lsAdditionalWorkspaceFolders;
        lsSpecificSettings = toUpstreamLsSpecificSettings complete.lsSpecificSettings;
      }
    );

  toUpstreamContext =
    settings:
    let
      complete = schema.contextDefaults // settings;
    in
    complete.extraSettings
    // renamePresentAttrs schema.contextFieldMappings complete
    # Null is meaningful upstream (auto-detect); always emit the key.
    // {
      structured_tool_output = complete.structuredToolOutput;
    };

  toUpstreamMode =
    settings:
    let
      complete = schema.modeDefaults // settings;
    in
    complete.extraSettings // renamePresentAttrs schema.modeFieldMappings complete;

  toUpstreamPromptFile =
    settings:
    let
      known = renamePresentAttrs schema.promptFieldMappings settings;
    in
    {
      prompts = (settings.extraPrompts or { }) // known;
    };

  mkProjectYaml =
    {
      pkgs,
      settings,
      name ? "serena-project.yml",
    }:
    (pkgs.formats.yaml { }).generate name (toUpstreamProject settings);

  mkGlobalYaml =
    {
      pkgs,
      settings,
      name ? "serena-config.yml",
    }:
    (pkgs.formats.yaml { }).generate name (toUpstreamGlobal settings);

  mkGlobalConfigInstaller =
    {
      pkgs,
      name ? "serena-install-global-config",
    }:
    pkgs.writeShellScript name ''
      set -eu

      source_file="$1"
      target_file="$2"
      target_dir="$(${pkgs.coreutils}/bin/dirname "$target_file")"
      tmp_file=""

      cleanup() {
        if [ -n "$tmp_file" ]; then
          ${pkgs.coreutils}/bin/rm -f -- "$tmp_file"
        fi
      }
      trap cleanup EXIT

      if [ -L "$target_file" ] || { [ -e "$target_file" ] && [ ! -f "$target_file" ]; }; then
        echo "serena: refusing unsafe global configuration $target_file" >&2
        exit 1
      fi
      if ! ${pkgs.yq-go}/bin/yq -e '.' "$source_file" >/dev/null; then
        echo "serena: generated global configuration is invalid YAML" >&2
        exit 1
      fi

      existing_auth_secret=""
      if [ -f "$target_file" ]; then
        if ! existing_auth_secret="$(${pkgs.yq-go}/bin/yq -r '.auth_secret | select(tag == "!!str" and . != "")' "$target_file")"; then
          echo "serena: cannot read auth_secret from $target_file" >&2
          exit 1
        fi
      fi

      tmp_file="$(${pkgs.coreutils}/bin/mktemp "$target_dir/.serena_config.yml.XXXXXX")"
      ${pkgs.coreutils}/bin/install -m 0600 -- "$source_file" "$tmp_file"
      if [ -n "$existing_auth_secret" ]; then
        SERENA_AUTH_SECRET="$existing_auth_secret" ${pkgs.yq-go}/bin/yq -i '.auth_secret = strenv(SERENA_AUTH_SECRET)' "$tmp_file"
      fi
      ${pkgs.coreutils}/bin/mv -f -T -- "$tmp_file" "$target_file"
      tmp_file=""
    '';

  mkContextYaml =
    {
      pkgs,
      settings,
      name ? "serena-context.yml",
    }:
    (pkgs.formats.yaml { }).generate name (toUpstreamContext settings);

  mkModeYaml =
    {
      pkgs,
      settings,
      name ? "serena-mode.yml",
    }:
    (pkgs.formats.yaml { }).generate name (toUpstreamMode settings);

  mkPromptYaml =
    {
      pkgs,
      settings,
      name ? "serena-prompts.yml",
    }:
    (pkgs.formats.yaml { }).generate name (toUpstreamPromptFile settings);
}
