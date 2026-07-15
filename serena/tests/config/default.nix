{
  pkgs,
  lib ? pkgs.lib,
}:
let
  schema = import ../../lib/config-schema.nix { inherit lib; };
  render = import ../../lib/render.nix { inherit lib; };
  upstream = builtins.fromJSON (builtins.readFile ../../schema/upstream.json);
  sortStrings = builtins.sort builtins.lessThan;

  typedLsPairs = lib.concatLists (
    lib.mapAttrsToList (
      nixLanguage: upstreamLanguage:
      map (field: "${upstreamLanguage}.${field}") (
        builtins.attrValues (schema.lsFieldMappings.${nixLanguage} or { })
      )
    ) schema.lsLanguageMappings
  );
  discoveredLsPairs = lib.concatLists (
    lib.mapAttrsToList (
      language: fields: map (field: "${language}.${field}") (builtins.attrNames fields)
    ) upstream.lsSpecificSettings
  );
  missingTypedLsPairs = builtins.filter (pair: !(builtins.elem pair typedLsPairs)) discoveredLsPairs;
  additionalTypedLsPairs = builtins.filter (
    pair: !(builtins.elem pair discoveredLsPairs)
  ) typedLsPairs;
  expectedGenericLsPathPairs = [
    "ada.ls_path"
    "cue.ls_path"
    "fortran.ls_path"
    "json.ls_path"
    "luau.ls_path"
    "python_ty.ls_path"
  ];
  promptKeys = lib.concatLists (
    map (shape: builtins.attrNames shape.fields.prompts.fields) (
      builtins.attrValues upstream.promptFiles
    )
  );
  evaluatedLsSettings =
    (lib.evalModules {
      modules = [
        {
          options.value = lib.mkOption {
            type = (schema.mkLsSpecificSettingsOption { }).type;
          };
          config.value = builtins.mapAttrs (_: _: { }) schema.lsLanguageMappings;
        }
      ];
    }).config.value;
  renderedLsDefaults = render.toUpstreamLsSpecificSettings evaluatedLsSettings;
  lsDefaultsMatch = lib.all (
    language:
    lib.all (
      field:
      let
        discovered = upstream.lsSpecificSettings.${language}.${field};
        defaults = discovered.defaults or [ ];
      in
      builtins.length defaults != 1
      || builtins.head defaults == null
      || (renderedLsDefaults.${language}.${field} or null) == builtins.head defaults
    ) (builtins.attrNames upstream.lsSpecificSettings.${language})
  ) (builtins.attrNames upstream.lsSpecificSettings);

  rendered = render.toUpstreamGlobal {
    extraSettings = {
      future_global_key = true;
      web_dashboard = "must-not-win";
    };
    webDashboard = false;
    lsSpecificSettings = {
      extraSettings.future_language.future_key = 1;
      python = {
        extraSettings.pyright_version = "must-not-win";
        pyrightVersion = "typed-wins";
      };
    };
  };

  checks =
    assert schema.manifest.schemaVersion == upstream.schemaVersion;
    assert builtins.length schema.languageValues == 64;
    assert sortStrings schema.languageValues == sortStrings upstream.languageValues;
    assert render.toUpstreamGlobal { } == upstream.global;
    assert render.toUpstreamProject { } == upstream.project;
    assert sortStrings (builtins.attrValues schema.promptFieldMappings) == sortStrings promptKeys;
    assert missingTypedLsPairs == [ ];
    assert sortStrings additionalTypedLsPairs == sortStrings expectedGenericLsPathPairs;
    assert lsDefaultsMatch;
    assert
      builtins.attrNames (
        render.toUpstreamContext {
          name = "test";
          prompt = "test";
        }
      ) == sortStrings upstream.contextSupportedFields;
    assert
      builtins.attrNames (
        render.toUpstreamMode {
          name = "test";
          prompt = "test";
        }
      ) == sortStrings upstream.modeSupportedFields;
    assert rendered.future_global_key;
    assert rendered.web_dashboard == false;
    assert rendered.ls_specific_settings.future_language.future_key == 1;
    assert rendered.ls_specific_settings.python.pyright_version == "typed-wins";
    assert !(rendered ? extra_settings);
    assert !(rendered.ls_specific_settings.python ? extra_settings);
    true;
in
{
  config-schema-parity =
    assert checks;
    pkgs.runCommand "serena-config-schema-parity" { } ''
      touch "$out"
    '';
}
