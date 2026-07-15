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
    else
      mapped;

in
rec {
  inherit
    schema
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
        additionalWorkspaceFolders = map toString complete.additionalWorkspaceFolders;
        lsSpecificSettings = toUpstreamLsSpecificSettings complete.lsSpecificSettings;
      }
    );

  toUpstreamContext =
    settings:
    let
      complete = schema.contextDefaults // settings;
    in
    complete.extraSettings // renamePresentAttrs schema.contextFieldMappings complete;

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
