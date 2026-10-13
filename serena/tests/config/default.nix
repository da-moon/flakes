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
    agentInterface = "tools";
    excludedApis = [ "lsp.find_symbol" ];
    includedApis = [ "lsp.get_diagnostics_for_symbol" ];
    lsSpecificSettings = {
      extraSettings.future_language.future_key = 1;
      python = {
        extraSettings.pyright_version = "must-not-win";
        pyrightVersion = "typed-wins";
      };
    };
  };
  globalConfigInstaller = render.mkGlobalConfigInstaller { inherit pkgs; };

  checks =
    assert schema.manifest.schemaVersion == upstream.schemaVersion;
    assert builtins.length schema.languageValues == 77;
    assert sortStrings schema.languageValues == sortStrings upstream.languageValues;
    assert
      render.toUpstreamGlobal { }
      == ((builtins.removeAttrs upstream.global [ "auth_secret" ]) // { agent_interface = "tools"; });
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
    assert rendered.agent_interface == "tools";
    assert rendered.excluded_apis == [ "lsp.find_symbol" ];
    assert rendered.included_apis == [ "lsp.get_diagnostics_for_symbol" ];
    assert !(rendered ? auth_secret);
    assert
      !(builtins.tryEval (
        builtins.deepSeq (render.toUpstreamGlobal { extraSettings.auth_secret = "test-secret"; }) true
      )).success;
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

  auth-secret-runtime-preservation =
    pkgs.runCommand "serena-auth-secret-runtime-preservation"
      {
        nativeBuildInputs = [
          pkgs.diffutils
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.yq-go
        ];
      }
      ''
        set -euo pipefail

        config="$TMPDIR/serena_config.yml"
        generated="$TMPDIR/generated.yml"
        installer=${lib.escapeShellArg (toString globalConfigInstaller)}
        printf 'auth_secret: dummy-secret\nother: old\n' >"$config"
        chmod 600 "$config"
        printf 'agent_interface: tools\n' >"$generated"

        "$installer" "$generated" "$config"
        test "$(stat -c '%a' "$config")" = 600
        ${pkgs.yq-go}/bin/yq -e '.auth_secret == "dummy-secret" and .agent_interface == "tools"' "$config" >/dev/null

        first_run="$TMPDIR/first-run.yml"
        "$installer" "$generated" "$first_run"
        test "$(stat -c '%a' "$first_run")" = 600
        ! ${pkgs.yq-go}/bin/yq -e 'has("auth_secret")' "$first_run" >/dev/null

        before="$TMPDIR/before.yml"
        ${pkgs.coreutils}/bin/cp "$config" "$before"
        malformed="$TMPDIR/malformed.yml"
        printf 'agent_interface: [broken\n' >"$malformed"
        if "$installer" "$malformed" "$config"; then
          echo "malformed generated configuration unexpectedly installed" >&2
          exit 1
        fi
        ${pkgs.diffutils}/bin/cmp "$before" "$config"

        outside="$TMPDIR/outside.yml"
        unsafe="$TMPDIR/unsafe.yml"
        printf 'outside\n' >"$outside"
        ${pkgs.coreutils}/bin/ln -s "$outside" "$unsafe"
        if "$installer" "$generated" "$unsafe"; then
          echo "unsafe global configuration target unexpectedly installed" >&2
          exit 1
        fi
        ${pkgs.gnugrep}/bin/grep -qx 'outside' "$outside"
        touch "$out"
      '';
}
