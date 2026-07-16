# Typed configuration schema for Kimi Code CLI.
# Source of truth: https://www.kimi.com/code/docs/en/ (config-files, tui.toml,
# hooks, mcp, providers pages). lib-parametric so consumers (home-manager
# module, flake-parts project module, tests) can re-instantiate it with their
# own lib.
#
# Naming convention: Nix options are lowerCamelCase and map to the snake_case
# keys of config.toml/tui.toml; mcp.json keys stay camelCase as documented.
# Every section additionally accepts `extraSettings` as a freeform passthrough
# (final on-disk key names) for keys the typed schema does not cover yet;
# typed keys win on conflict.
{ lib }:
let
  inherit (lib) mkOption types;

  # Recursive JSON value type used for freeform passthrough options.
  # The constant `description` on the recursive reference is load-bearing:
  # without it, forcing the type's description (the attrsOf merge machinery
  # does this) recurses forever.
  jsonValueType =
    let
      jsonValue = valueType // {
        description = "JSON value";
      };
      valueType = types.nullOr (types.oneOf [
        types.bool
        types.int
        types.float
        types.str
        (types.listOf jsonValue)
        (types.attrsOf jsonValue)
      ]);
    in
    jsonValue;

  extraSettingsOption = mkOption {
    type = types.attrsOf jsonValueType;
    default = { };
    description = ''
      Freeform passthrough merged into the rendered section underneath the
      typed keys (typed keys win on conflict). Use final on-disk key names
      (snake_case for config.toml/tui.toml). Intended for upstream keys the
      typed schema does not cover yet.
    '';
  };

  strOpt = description: mkOption {
    type = types.nullOr types.str;
    default = null;
    inherit description;
  };

  intOpt = description: mkOption {
    type = types.nullOr types.int;
    default = null;
    inherit description;
  };

  boolOpt = description: mkOption {
    type = types.nullOr types.bool;
    default = null;
    inherit description;
  };

  strListOpt = description: mkOption {
    type = types.nullOr (types.listOf types.str);
    default = null;
    inherit description;
  };

  # The 16 hook events documented at
  # https://www.kimi.com/code/docs/en/kimi-code-cli/customization/hooks.html
  hookEvents = [
    "UserPromptSubmit"
    "PreToolUse"
    "Stop"
    "PostToolUse"
    "PostToolUseFailure"
    "PermissionRequest"
    "PermissionResult"
    "SessionStart"
    "SessionEnd"
    "SubagentStart"
    "SubagentStop"
    "StopFailure"
    "Interrupt"
    "PreCompact"
    "PostCompact"
    "Notification"
  ];

  providerType = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [
          "kimi"
          "anthropic"
          "openai"
          "openai_responses"
          "google-genai"
          "vertexai"
        ];
        description = "Provider protocol type.";
      };
      apiKey = strOpt ''
        API key in plain text. Prefer leaving this empty when the provider
        authenticates via OAuth (`/login`); the activation merge grafts the
        runtime-injected `[providers.<name>.oauth]` reference from the live
        config. Note this value lands in the Nix store when set.
      '';
      baseUrl = strOpt "API base URL (falls back to the provider's built-in default when unset).";
      env = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          Fallback credential source rendered as `[providers.<name>.env]`.
          Values are literal strings read only from the config file; they do
          NOT reference the shell environment.
        '';
      };
      customHeaders = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Custom HTTP headers attached to each request.";
      };
      extraSettings = extraSettingsOption;
      # NOTE: `oauth` is deliberately not an option. It is injected by the
      # CLI's login flow and preserved across switches by the merge engine.
    };
  };

  modelOverridesType = types.submodule {
    options = {
      maxContextSize = intOpt "Pinned max context size (survives provider-model refreshes).";
      maxOutputSize = intOpt "Pinned per-request output cap.";
      capabilities = strListOpt "Pinned capabilities list.";
      displayName = strOpt "Pinned display name.";
      reasoningKey = strOpt "Pinned reasoning-content field name (openai only).";
      adaptiveThinking = boolOpt "Pinned adaptive thinking toggle (anthropic only).";
      supportEfforts = strListOpt "Pinned supported thinking effort levels.";
      defaultEffort = strOpt "Pinned default thinking effort.";
      extraSettings = extraSettingsOption;
    };
  };

  modelType = types.submodule {
    options = {
      provider = mkOption {
        type = types.str;
        description = "Name of the provider to use; must exist in `providers`.";
      };
      model = mkOption {
        type = types.str;
        description = "Model identifier sent to the server.";
      };
      maxContextSize = mkOption {
        type = types.ints.positive;
        description = "Maximum context length in tokens.";
      };
      maxOutputSize = intOpt "Per-request output cap (currently honored by the anthropic provider only).";
      capabilities = strListOpt ''
        Additional capabilities: thinking, always_thinking, image_in,
        video_in, audio_in, tool_use. Unioned with auto-detected ones.
      '';
      supportEfforts = strListOpt ''
        Thinking effort levels the model accepts. Registry refreshes may
        rewrite this at runtime; pin it under `overrides` to make it stick,
        or accept that the next switch resets it.
      '';
      defaultEffort = strOpt "Default thinking effort (same runtime-rewrite caveat as supportEfforts).";
      displayName = strOpt "Name shown in the UI (falls back to `model`).";
      reasoningKey = strOpt "Reasoning-content field name override (openai provider only).";
      adaptiveThinking = boolOpt "Force adaptive thinking on/off (anthropic provider only).";
      overrides = mkOption {
        type = types.nullOr modelOverridesType;
        default = null;
        description = ''
          Rendered as `[models."<alias>".overrides]`: user overrides that
          survive provider-model refreshes.
        '';
      };
      extraSettings = extraSettingsOption;
    };
  };

  thinkingType = types.submodule {
    options = {
      enabled = boolOpt "Enable thinking (default true upstream).";
      effort = mkOption {
        type = types.nullOr (types.enum [ "low" "medium" "high" "xhigh" "max" ]);
        default = null;
        description = "Thinking effort level.";
      };
      keep = strOpt ''
        Thinking passthrough policy (default "all"; off-values: false/0/no/off/none/null).
        Overridden by KIMI_MODEL_THINKING_KEEP.
      '';
      extraSettings = extraSettingsOption;
    };
  };

  loopControlType = types.submodule {
    options = {
      maxStepsPerTurn = intOpt "Max agent steps per turn (unset/0 = unlimited).";
      maxRetriesPerStep = intOpt "Retries per step (default 10 upstream).";
      reservedContextSize = intOpt "Auto-compaction triggers when remaining context falls below this.";
      extraSettings = extraSettingsOption;
    };
  };

  backgroundType = types.submodule {
    options = {
      maxRunningTasks = intOpt "Max concurrent background tasks.";
      keepAliveOnExit = boolOpt "Keep background tasks running when the CLI exits (default false).";
      killGracePeriodMs = intOpt "Grace period before killing background tasks (default 5000).";
      bashAutoBackgroundOnTimeout = boolOpt "Auto-background Bash commands that hit the timeout (default true).";
      bashTaskTimeoutS = intOpt "Foreground Bash timeout in seconds (default 600; 0 = no timeout).";
      printBackgroundMode = mkOption {
        type = types.nullOr (types.enum [ "exit" "drain" "steer" ]);
        default = null;
        description = "Background behavior for print (non-interactive) mode (default \"steer\").";
      };
      printWaitCeilingS = intOpt "Max seconds print mode waits for background tasks.";
      printMaxTurns = intOpt "Max turns in print mode (default 100000).";
      extraSettings = extraSettingsOption;
    };
  };

  subagentType = types.submodule {
    options = {
      timeoutMs = intOpt "Sub-agent timeout in milliseconds (default 7200000; 0 = none).";
      extraSettings = extraSettingsOption;
    };
  };

  imageType = types.submodule {
    options = {
      maxEdgePx = intOpt "Images are downscaled to this max edge in pixels (default 2000).";
      readByteBudget = intOpt "Max bytes read per image (default 262144).";
      extraSettings = extraSettingsOption;
    };
  };

  serviceType = types.submodule {
    options = {
      baseUrl = strOpt "Service base URL.";
      apiKey = strOpt "Service API key in plain text (Nix store visible when set).";
      customHeaders = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Custom HTTP headers attached to each request.";
      };
      extraSettings = extraSettingsOption;
      # `oauth` is runtime-owned and grafted, like providers.*.oauth.
    };
  };

  permissionRuleType = types.submodule {
    options = {
      decision = mkOption {
        type = types.enum [ "allow" "deny" "ask" ];
        description = "Rule decision.";
      };
      pattern = mkOption {
        type = types.str;
        description = "Tool pattern: ToolName or ToolName(arg-pattern), e.g. \"Bash(rm -rf*)\".";
      };
      scope = mkOption {
        type = types.enum [
          "turn-override"
          "session-runtime"
          "project"
          "user"
        ];
        default = "user";
        description = "Persistence scope of the rule.";
      };
      reason = strOpt "Audit note recorded with the rule.";
    };
  };

  permissionType = types.submodule {
    options = {
      rules = mkOption {
        type = types.listOf permissionRuleType;
        default = [ ];
        description = "Ordered permission rules; first match wins.";
      };
      extraSettings = extraSettingsOption;
    };
  };

  settingsType = types.submodule {
    options = {
      defaultModel = strOpt "Alias of the default model; must exist in `models`.";
      defaultPermissionMode = mkOption {
        type = types.nullOr (types.enum [ "manual" "auto" "yolo" ]);
        default = null;
        description = "Default permission mode (default \"manual\" upstream).";
      };
      defaultPlanMode = boolOpt "Start new sessions in Plan mode (default false).";
      mergeAllAvailableSkills = boolOpt "Merge Agent Skills from all available directories (default true).";
      extraSkillDirs = strListOpt "Extra skill search directories (added on top of discovered ones).";
      telemetry = boolOpt "Anonymous telemetry (only disabled when explicitly false).";

      providers = mkOption {
        type = types.nullOr (types.attrsOf providerType);
        default = null;
        description = ''
          `[providers.<name>]` tables. When non-null the whole providers
          table is declarative: undeclared providers are dropped on switch;
          runtime-injected `oauth` sub-tables are grafted back for declared
          providers.
        '';
      };
      models = mkOption {
        type = types.nullOr (types.attrsOf modelType);
        default = null;
        description = "`[models.<alias>]` tables (same declarative semantics as providers).";
      };
      thinking = mkOption {
        type = types.nullOr thinkingType;
        default = null;
        description = "[thinking] section (null = unmanaged).";
      };
      loopControl = mkOption {
        type = types.nullOr loopControlType;
        default = null;
        description = "[loop_control] section (null = unmanaged).";
      };
      background = mkOption {
        type = types.nullOr backgroundType;
        default = null;
        description = "[background] section (null = unmanaged).";
      };
      subagent = mkOption {
        type = types.nullOr subagentType;
        default = null;
        description = "[subagent] section (null = unmanaged).";
      };
      image = mkOption {
        type = types.nullOr imageType;
        default = null;
        description = "[image] section (null = unmanaged).";
      };
      services = mkOption {
        type = types.nullOr (types.attrsOf serviceType);
        default = null;
        description = ''
          `[services.<name>]` tables (upstream recognizes moonshot_search and
          moonshot_fetch). Same declarative + oauth-graft semantics as
          providers.
        '';
      };
      permission = mkOption {
        type = types.nullOr permissionType;
        default = null;
        description = "[permission] section with ordered [[permission.rules]] (null = unmanaged).";
      };
      extraSettings = extraSettingsOption // {
        description = ''
          Freeform passthrough for top-level config.toml keys the typed
          schema does not cover. Merged underneath the typed keys.
        '';
      };
    };
  };

  tuiType = types.submodule {
    options = {
      theme = mkOption {
        type = types.str;
        default = "auto";
        description = "Color theme: auto, dark, light, or a custom theme name from ~/.kimi-code/themes/.";
      };
      disablePasteBurst = mkOption {
        type = types.bool;
        default = false;
        description = "Disable the non-bracketed paste-burst fallback.";
      };
      editor.command = mkOption {
        type = types.str;
        default = "";
        description = "External editor command; empty falls back to $VISUAL/$EDITOR.";
      };
      notifications.enabled = mkOption {
        type = types.bool;
        default = true;
        description = "Send desktop notifications.";
      };
      notifications.notificationCondition = mkOption {
        type = types.enum [
          "unfocused"
          "always"
        ];
        default = "unfocused";
        description = "When to notify.";
      };
      upgrade.autoInstall = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether the CLI self-updates its binary. Defaults to false here
          (upstream default is true) because the binary is Nix-managed;
          updates come from bumping this flake.
        '';
      };
      extraSettings = extraSettingsOption;
    };
  };

  mcpServerType = types.submodule {
    options = {
      command = strOpt "Executable for a stdio server (exactly one of command/url required).";
      args = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Arguments for the stdio command.";
      };
      env = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Environment variables injected into the stdio child process.";
      };
      cwd = strOpt "Working directory for the stdio child process.";
      url = strOpt "URL for an HTTP server (or SSE when transport = \"sse\").";
      transport = mkOption {
        type = types.nullOr (types.enum [ "http" "sse" ]);
        default = null;
        description = "Explicit transport; only needed for legacy SSE servers.";
      };
      headers = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Static request headers (HTTP/SSE).";
      };
      bearerTokenEnvVar = strOpt ''
        Name of an environment variable holding the bearer token (HTTP/SSE).
        Preferred over a literal Authorization header: no secret enters the
        rendered file or the Nix store.
      '';
      enabled = mkOption {
        type = types.bool;
        default = true;
        description = "Set to false to disable the server without removing it.";
      };
      startupTimeoutMs = intOpt "Connection timeout (default 30000 upstream).";
      toolTimeoutMs = intOpt "Timeout for a single tool call.";
      enabledTools = strListOpt "Tool allowlist.";
      disabledTools = strListOpt "Tool blocklist.";
      extraSettings = extraSettingsOption;
    };
  };

in
{
  inherit
    hookEvents
    settingsType
    tuiType
    mcpServerType
    jsonValueType
    ;

  # Merge manifest for config.toml consumed by the jq merge engine
  # (modules/lib.nix). Meaning:
  # - scalars: managed individually, only when present in the declared render.
  # - sections: object tables managed key-by-key when the section is declared;
  #   typed-but-undeclared keys are deleted from the live file (reset to
  #   upstream default), unknown keys are preserved.
  # - replaceTables: tables replaced wholesale when declared.
  # - graftTables: replaceTables whose entries get a missing `oauth`
  #   sub-table grafted from the live file (or the external oauth source).
  # - hooksManaged: run the [[hooks]] stale-strip + name-keyed upsert phase.
  manifest = {
    scalars = [
      "default_model"
      "default_permission_mode"
      "default_plan_mode"
      "merge_all_available_skills"
      "extra_skill_dirs"
      "telemetry"
    ];
    sections = {
      thinking = [
        "enabled"
        "effort"
        "keep"
      ];
      loop_control = [
        "max_steps_per_turn"
        "max_retries_per_step"
        "reserved_context_size"
      ];
      background = [
        "max_running_tasks"
        "keep_alive_on_exit"
        "kill_grace_period_ms"
        "bash_auto_background_on_timeout"
        "bash_task_timeout_s"
        "print_background_mode"
        "print_wait_ceiling_s"
        "print_max_turns"
      ];
      subagent = [ "timeout_ms" ];
      image = [
        "max_edge_px"
        "read_byte_budget"
      ];
    };
    replaceTables = [
      "providers"
      "models"
      "services"
      "permission"
    ];
    graftTables = [
      "providers"
      "services"
    ];
    hooksManaged = true;
  };

  # Merge manifest for tui.toml (no hooks phase, no replace tables).
  tuiManifest = {
    scalars = [
      "theme"
      "disable_paste_burst"
    ];
    sections = {
      editor = [ "command" ];
      notifications = [
        "enabled"
        "notification_condition"
      ];
      upgrade = [ "auto_install" ];
    };
    replaceTables = [ ];
    graftTables = [ ];
    hooksManaged = false;
  };
}
