# Merge-engine round-trip test: declarative-core semantics, oauth graft,
# unknown-key + foreign-hook preservation, and idempotency.
{ pkgs, lib }:
let
  schema = import ../../modules/config-schema.nix { inherit lib; };
  render = import ../../modules/render.nix { inherit lib; };
  helpers = import ../../modules/lib.nix { inherit pkgs; };

  # Fill schema defaults (the HM/flake-parts modules get this from the module
  # system; raw values here need it explicitly).
  normalize =
    type: value:
    (lib.evalModules {
      modules = [
        {
          options.value = lib.mkOption { inherit type; };
          config.value = value;
        }
      ];
    }).config.value;

  settings = normalize schema.settingsType {
    defaultModel = "kimi-code/k3";
    telemetry = false;
    thinking = {
      enabled = true;
      effort = "max";
      extraSettings.custom_thinking_key = "x";
    };
    loopControl = {
      maxRetriesPerStep = 3;
      extraSettings.max_ralph_iterations = 0;
    };
    providers."managed:kimi-code" = {
      type = "kimi";
      baseUrl = "https://api.kimi.com/coding/v1";
      apiKey = "";
    };
    models."kimi-code/k3" = {
      provider = "managed:kimi-code";
      model = "k3";
      maxContextSize = 1048576;
    };
    permission.rules = [
      {
        decision = "allow";
        pattern = "Read";
      }
    ];
  };

  tui = normalize schema.tuiType { theme = "dark"; };

  mcpServers = normalize (lib.types.attrsOf schema.mcpServerType) {
    test-http = {
      url = "https://example.com/mcp";
      bearerTokenEnvVar = "TEST_TOKEN";
    };
  };

  testHooks = [
    {
      name = "test-hook";
      event = "PreToolUse";
      matcher = "Bash";
      timeout = 7;
      script = "echo test-hook";
      runtimeInputs = [ ];
    }
  ];
  hooksPackage = helpers.mkHooksPackage { hooks = testHooks; };
  managedHooksJson = helpers.mkManagedHooksJson {
    hooks = testHooks;
    commandFor = h: "${hooksPackage}/bin/${h.name}.sh";
  };

  sync = helpers.mkSyncConfigScript {
    manifestJson = helpers.mkManifestJson schema.manifest;
    tuiManifestJson = helpers.mkManifestJson schema.tuiManifest;
    inherit managedHooksJson hooksPackage;
    declaredConfigJson = render.mkConfigJson { inherit pkgs settings; };
    declaredTuiJson = render.mkTuiJson { inherit pkgs tui; };
    mcpJson = render.mkMcpJson { inherit pkgs; servers = mcpServers; };
  };
in
{
  config-merge = pkgs.runCommand "kimi-config-merge-test"
    {
      nativeBuildInputs = [
        pkgs.jq
        pkgs.remarshal
        pkgs.coreutils
        pkgs.gnugrep
      ];
    }
    ''
      cfgDir="$TMPDIR/kimi-home"
      mkdir -p "$cfgDir"
      cat > "$cfgDir/config.toml" <<'EOF'
      default_model = "old/model"
      telemetry = true
      future_top_level_key = "keepme"

      [thinking]
      enabled = false
      effort = "low"
      future_thinking_key = 1

      [loop_control]
      max_retries_per_step = 10
      reserved_context_size = 99999
      max_ralph_iterations = 5

      [providers."managed:kimi-code"]
      type = "kimi"
      api_key = ""
      base_url = "https://api.kimi.com/coding/v1"

      [providers."managed:kimi-code".oauth]
      storage = "file"
      key = "oauth/kimi-code"

      [providers."hand-added"]
      type = "openai"
      api_key = "sk-x"

      [models."hand-added-model"]
      provider = "hand-added"
      model = "x"
      max_context_size = 1

      [[hooks]]
      event = "PreToolUse"
      command = "'/usr/bin/node' '/home/u/.claude/approval-hook.js'"
      timeout = 15

      [[hooks]]
      event = "PreToolUse"
      command = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-kimi-cli-hooks/bin/redirect-web-tools.sh"
      timeout = 5
      EOF

      cat > "$cfgDir/tui.toml" <<'EOF'
      theme = "light"
      future_tui_key = true

      [upgrade]
      auto_install = true
      EOF

      echo '{"mcpServers":{"stale":{"url":"https://stale.example.com/mcp"}}}' > "$cfgDir/mcp.json"

      ${sync}/bin/kimi-sync-config "$cfgDir" "$cfgDir/hooks"

      # idempotency: a second run must be byte-identical
      cp "$cfgDir/config.toml" "$TMPDIR/config.first"
      cp "$cfgDir/tui.toml" "$TMPDIR/tui.first"
      cp "$cfgDir/mcp.json" "$TMPDIR/mcp.first"
      ${sync}/bin/kimi-sync-config "$cfgDir" "$cfgDir/hooks"
      cmp "$TMPDIR/config.first" "$cfgDir/config.toml"
      cmp "$TMPDIR/tui.first" "$cfgDir/tui.toml"
      cmp "$TMPDIR/mcp.first" "$cfgDir/mcp.json"

      cfg() {
        remarshal -i "$cfgDir/config.toml" -of json -o "$TMPDIR/cfg.json"
        jq -r "$1" "$TMPDIR/cfg.json"
      }

      # declared scalars win
      [ "$(cfg '.default_model')" = "kimi-code/k3" ]
      [ "$(cfg '.telemetry')" = "false" ]
      # unknown top-level key preserved
      [ "$(cfg '.future_top_level_key')" = "keepme" ]
      # declared section keys win; unknown section keys preserved
      [ "$(cfg '.thinking.enabled')" = "true" ]
      [ "$(cfg '.thinking.effort')" = "max" ]
      [ "$(cfg '.thinking.custom_thinking_key')" = "x" ]
      [ "$(cfg '.thinking.future_thinking_key')" = "1" ]
      # typed-but-undeclared section key deleted (reset to upstream default)
      [ "$(cfg '.loop_control.reserved_context_size // "gone"')" = "gone" ]
      # declared + passthrough keys win over live
      [ "$(cfg '.loop_control.max_retries_per_step')" = "3" ]
      [ "$(cfg '.loop_control.max_ralph_iterations')" = "0" ]
      # replace tables: hand-added entries dropped, oauth grafted
      [ "$(cfg '.providers["hand-added"] // "gone"')" = "gone" ]
      [ "$(cfg '.models["hand-added-model"] // "gone"')" = "gone" ]
      [ "$(cfg '.providers["managed:kimi-code"].oauth.key')" = "oauth/kimi-code" ]
      [ "$(cfg '.providers["managed:kimi-code"].oauth.storage')" = "file" ]
      # permission rules replaced
      [ "$(cfg '.permission.rules | length')" = "1" ]
      [ "$(cfg '.permission.rules[0].pattern')" = "Read" ]
      # hooks: foreign preserved, stale nix-store entry pruned, managed upserted
      [ "$(cfg '.hooks | length')" = "2" ]
      [ "$(cfg '[.hooks[].command] | map(select(contains("approval-hook.js"))) | length')" = "1" ]
      [ "$(cfg '[.hooks[].command] | map(select(contains("redirect-web-tools"))) | length')" = "0" ]
      [ "$(cfg '[.hooks[].command] | map(select(test("/test-hook\\.sh$"))) | length')" = "1" ]
      [ "$(cfg '.hooks[1].timeout')" = "7" ]
      [ "$(cfg '.hooks[1].matcher')" = "Bash" ]

      tui() {
        remarshal -i "$cfgDir/tui.toml" -of json -o "$TMPDIR/tui.json"
        jq -r "$1" "$TMPDIR/tui.json"
      }

      # tui: declared wins, defaults filled, unknown preserved
      [ "$(tui '.theme')" = "dark" ]
      [ "$(tui '.future_tui_key')" = "true" ]
      [ "$(tui '.upgrade.auto_install')" = "false" ]
      [ "$(tui '.notifications.enabled')" = "true" ]
      [ "$(tui '.notifications.notification_condition')" = "unfocused" ]

      # mcp.json fully declarative and byte-identical to the render
      cmp ${render.mkMcpJson { inherit pkgs; servers = mcpServers; }} "$cfgDir/mcp.json"
      [ "$(jq -r '.mcpServers["test-http"].bearerTokenEnvVar' "$cfgDir/mcp.json")" = "TEST_TOKEN" ]
      [ "$(jq -r '.mcpServers.stale // "gone"' "$cfgDir/mcp.json")" = "gone" ]

      # hook script copies installed + manifest written
      [ -x "$cfgDir/hooks/test-hook.sh" ]
      grep -qx "test-hook" "$cfgDir/hooks/.nix-managed-hooks"

      touch $out
    '';
}
