{
  pkgs,
  lib ? pkgs.lib,
}:
let
  schema = import ../../modules/schema.nix { inherit lib; };
  render = import ../../modules/render.nix { inherit lib; };
  helpers = import ../../modules/lib.nix { inherit pkgs; };

  evalValue =
    type: value:
    builtins.tryEval (
      builtins.deepSeq
        (lib.evalModules {
          modules = [
            {
              options.value = lib.mkOption { inherit type; };
              config.value = value;
            }
          ];
        }).config.value
        true
    );

  validMcp = {
    demo = {
      transport = "http";
      enabled = true;
      command = null;
      args = [ ];
      url = "https://mcp.example.invalid/rpc";
      oauth = {
        authorizationUrl = "https://mcp.example.invalid/authorize";
        tokenUrl = "https://mcp.example.invalid/token";
        clientId = "public-client";
        scopes = [ "tools" ];
      };
    };
  };

  defaultHook = helpers.mkDefaultStripCoauthorHook { };
  hookCommand = "./.commandcode/hooks/strip-coauthor.sh";
  globalV1 = {
    provider = "command-code";
    model = "zai-org/GLM-5.2";
    reasoningEffort."zai-org/GLM-5.2" = "max";
  };
  settingsV1 = {
    disabledSkills = [ "managed-skill" ];
    input.collapsePastedText = false;
  };
  mcpV1 = render.toMcpServers validMcp;

  mkSync =
    name: values:
    helpers.mkManagedSyncScript {
      inherit name;
      config = values.config;
      settings = values.settings;
      hooks = values.hooks;
      mcpServers = values.mcp;
      commandFor = _: hookCommand;
    };

  syncV1 = mkSync "command-code-sync-test-v1" {
    config = globalV1;
    settings = settingsV1;
    hooks = [ defaultHook ];
    mcp = mcpV1;
  };
  syncV2 = mkSync "command-code-sync-test-v2" {
    config = { };
    settings = { };
    hooks = [ ];
    mcp = {
      mcpServers = { };
    };
  };

  rendered = render.toGlobalConfig {
    provider = "command-code";
    model = "dynamic/model";
    reasoningEffort."dynamic/model" = "high";
    theme = "dark";
    compactMode = "fast";
    telemetry = false;
    tasteLearning = true;
    featureModels = {
      titleGeneration = "title/model";
      compaction = null;
      toolDescription = null;
      tasteLearning = null;
      tasteOnboarding = null;
    };
    autoInstallExtension = false;
  };

  schemaAssertions =
    assert schema.schemaVersion == "0.51.0";
    assert rendered.provider == "command-code";
    assert rendered.model == "dynamic/model";
    assert rendered.reasoningEffort."dynamic/model" == "high";
    assert rendered.featureModels == { titleGeneration = "title/model"; };
    assert !(rendered ? installed);
    assert (evalValue schema.globalConfigType { provider = "command-code"; }).success;
    assert !(evalValue schema.globalConfigType { provider = "unknown"; }).success;
    assert !(evalValue schema.globalConfigType { installed = true; }).success;
    assert !(evalValue schema.projectSettingsType { permissions.allow = [ "Read(*)" ]; }).success;
    assert (evalValue schema.projectSettingsType { permissions.allow = [ "Bash(git:*)" ]; }).success;
    assert
      !(evalValue (lib.types.attrsOf schema.mcpServerType) {
        bad = {
          transport = "http";
          url = "https://example.invalid";
          headers.Authorization = "secret-canary";
        };
      }).success;
    assert lib.all (item: item.assertion) (
      schema.mcpAssertions {
        servers = validMcp;
        label = "valid";
      }
    );
    assert
      !(lib.all (item: item.assertion) (
        schema.mcpAssertions {
          servers.bad = validMcp.demo // {
            transport = "stdio";
            command = "server";
          };
          label = "bad";
        }
      ));
    assert
      !(lib.all (item: item.assertion) (
        schema.hookAssertions {
          hooks = [
            (
              defaultHook
              // {
                async = true;
                failClosed = true;
              }
            )
          ];
          label = "bad";
        }
      ));
    true;
in
assert schemaAssertions;
{
  command-code-config-schema = pkgs.runCommand "command-code-config-schema" { } ''
    touch "$out"
  '';

  command-code-managed-sync =
    pkgs.runCommand "command-code-managed-sync-test"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail

        expect_failure() {
          if "$@" >failure.stdout 2>failure.stderr; then
            echo "command unexpectedly succeeded: $*" >&2
            exit 1
          fi
        }

        run_sync() {
          local executable="$1"
          local data_dir="$2"
          shift 2
          "$executable" \
            --scope global \
            --data-dir "$data_dir" \
            --state-dir "$data_dir/nix-state/global" \
            --config "$data_dir/config.json" \
            --settings "$data_dir/settings.json" \
            --mcp "$data_dir/mcp.json" \
            --hooks-dir "$data_dir/hooks" \
            "$@"
        }

        data="$TMPDIR/home/.commandcode"
        mkdir -p "$data/hooks"
        cat >"$data/config.json" <<'JSON'
        {
          "provider": "command-code",
          "model": "zai-org/GLM-5.2",
          "reasoningEffort": { "zai-org/GLM-5.2": "max", "manual/model": "low" },
          "installed": true,
          "runtimeSentinel": "preserve-config"
        }
        JSON
        cat >"$data/settings.json" <<'JSON'
        {
          "disabledSkills": ["manual-skill", "managed-skill"],
          "input": { "collapsePastedText": false, "futureInput": true },
          "runtimeSentinel": "preserve-settings",
          "hooks": {
            "PreToolUse": [{
              "matcher": "SHELL",
              "hooks": [
                { "type": "command", "command": "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-command-code-hooks/bin/strip-coauthor.sh", "timeout": 10 },
                { "type": "command", "command": "./.commandcode/hooks/strip-coauthor.sh", "timeout": 10, "async": false, "failClosed": false },
                { "type": "command", "command": "./.commandcode/hooks/strip-coauthor.sh", "timeout": 10, "async": false, "failClosed": false },
                { "type": "command", "command": "manual-hook", "timeout": 30 }
              ]
            }]
          }
        }
        JSON
        cat >"$data/mcp.json" <<'JSON'
        {
          "mcpServers": {
            "demo": {
              "transport": "http",
              "enabled": true,
              "url": "https://mcp.example.invalid/rpc",
              "headers": { "Authorization": "secret-canary" },
              "env": { "TOKEN": "secret-canary" },
              "oauth": {
                "authorizationUrl": "https://mcp.example.invalid/authorize",
                "tokenUrl": "https://mcp.example.invalid/token",
                "clientId": "public-client",
                "clientSecret": "secret-canary",
                "scopes": ["tools"]
              }
            }
          },
          "runtimeSentinel": "preserve-mcp"
        }
        JSON
        printf 'strip-coauthor\n' >"$data/hooks/.nix-managed-hooks"
        printf 'legacy hook bytes\n' >"$data/hooks/strip-coauthor.sh"

        run_sync ${syncV1}/bin/command-code-sync-test-v1 "$data"
        jq -e '.installed == true and .runtimeSentinel == "preserve-config" and .provider == "command-code"' "$data/config.json" >/dev/null
        jq -e '.reasoningEffort["manual/model"] == "low" and .reasoningEffort["zai-org/GLM-5.2"] == "max"' "$data/config.json" >/dev/null
        jq -e '.disabledSkills == ["manual-skill", "managed-skill"] and .input.futureInput == true' "$data/settings.json" >/dev/null
        jq -e '[.hooks[][] | .hooks[] | select(.command == "./.commandcode/hooks/strip-coauthor.sh")] | length == 1' "$data/settings.json" >/dev/null
        jq -e '[.hooks[][] | .hooks[] | select(.command == "manual-hook")] | length == 1' "$data/settings.json" >/dev/null
        jq -e '.mcpServers.demo.headers.Authorization == "secret-canary" and .mcpServers.demo.env.TOKEN == "secret-canary" and .mcpServers.demo.oauth.clientSecret == "secret-canary"' "$data/mcp.json" >/dev/null
        test ! -e "$data/hooks/.nix-managed-hooks"
        test -x "$data/hooks/strip-coauthor.sh"
        test "$(stat -c %a "$data/config.json")" = 600
        test "$(stat -c %a "$data/settings.json")" = 600
        test "$(stat -c %a "$data/mcp.json")" = 600
        test "$(stat -c %a "$data/nix-state/global/ownership.json")" = 600
        test "$(stat -c %a "$data/hooks/strip-coauthor.sh")" = 700
        if grep -R -q 'secret-canary' ${syncV1}; then
          echo "secret canary leaked into the generated sync package" >&2
          exit 1
        fi

        before=$(sha256sum "$data/config.json" "$data/settings.json" "$data/mcp.json")
        run_sync ${syncV1}/bin/command-code-sync-test-v1 "$data"
        after=$(sha256sum "$data/config.json" "$data/settings.json" "$data/mcp.json")
        test "$before" = "$after"

        run_sync ${syncV2}/bin/command-code-sync-test-v2 "$data"
        jq -e '.installed == true and .runtimeSentinel == "preserve-config" and .reasoningEffort == {"manual/model":"low"}' "$data/config.json" >/dev/null
        jq -e '.disabledSkills == ["manual-skill"] and .input == {"futureInput":true}' "$data/settings.json" >/dev/null
        jq -e '[.hooks[][] | .hooks[] | select(.command == "manual-hook")] | length == 1' "$data/settings.json" >/dev/null
        jq -e '[.hooks[][] | .hooks[] | select(.command == "./.commandcode/hooks/strip-coauthor.sh")] | length == 0' "$data/settings.json" >/dev/null
        jq -e '.mcpServers.demo == {"headers":{"Authorization":"secret-canary"},"env":{"TOKEN":"secret-canary"},"oauth":{"clientSecret":"secret-canary"}}' "$data/mcp.json" >/dev/null
        test ! -e "$data/hooks/strip-coauthor.sh"

        conflict="$TMPDIR/conflict/.commandcode"
        mkdir -p "$conflict"
        printf '{"provider":"anthropic"}\n' >"$conflict/config.json"
        expect_failure run_sync ${syncV1}/bin/command-code-sync-test-v1 "$conflict"
        run_sync ${syncV1}/bin/command-code-sync-test-v1 "$conflict" --force
        jq -e '.provider == "command-code"' "$conflict/config.json" >/dev/null
        expect_failure run_sync ${syncV1}/bin/command-code-sync-test-v1 "$conflict" --force

        invalid="$TMPDIR/invalid/.commandcode"
        mkdir -p "$invalid"
        printf '{' >"$invalid/config.json"
        expect_failure run_sync ${syncV1}/bin/command-code-sync-test-v1 "$invalid"

        structural="$TMPDIR/structural/.commandcode"
        mkdir -p "$structural"
        printf '{"provider":"command-code","reasoningEffort":"invalid"}\n' >"$structural/config.json"
        expect_failure run_sync ${syncV1}/bin/command-code-sync-test-v1 "$structural"

        outside="$TMPDIR/outside"
        unsafe="$TMPDIR/unsafe/.commandcode"
        mkdir -p "$outside" "$(dirname "$unsafe")"
        ln -s "$outside" "$unsafe"
        expect_failure run_sync ${syncV1}/bin/command-code-sync-test-v1 "$unsafe"

        touch "$out"
      '';
}
