# Render typed Kimi Code settings into on-disk shapes (config.toml/tui.toml as
# JSON merge inputs for the merge engine; mcp.json as a canonical store file).
# Null values are stripped recursively: null means "not managed".
{ lib }:
let
  # Recursively remove null attribute values and null list elements.
  stripNulls =
    v:
    if builtins.isAttrs v then
      lib.filterAttrs (_: x: x != null) (builtins.mapAttrs (_: stripNulls) v)
    else if builtins.isList v then
      map stripNulls v
    else
      v;

  nonEmpty =
    attrs: if attrs == { } then null else attrs;

  toUpstreamProvider =
    p:
    stripNulls (
      p.extraSettings
      // {
        inherit (p) type;
        api_key = p.apiKey;
        base_url = p.baseUrl;
        env = nonEmpty p.env;
        custom_headers = nonEmpty p.customHeaders;
      }
    );

  toUpstreamModelOverrides =
    o:
    stripNulls (
      o.extraSettings
      // {
        max_context_size = o.maxContextSize;
        max_output_size = o.maxOutputSize;
        capabilities = o.capabilities;
        display_name = o.displayName;
        reasoning_key = o.reasoningKey;
        adaptive_thinking = o.adaptiveThinking;
        support_efforts = o.supportEfforts;
        default_effort = o.defaultEffort;
      }
    );

  toUpstreamModel =
    m:
    stripNulls (
      m.extraSettings
      // {
        inherit (m) provider model;
        max_context_size = m.maxContextSize;
        max_output_size = m.maxOutputSize;
        capabilities = m.capabilities;
        support_efforts = m.supportEfforts;
        default_effort = m.defaultEffort;
        display_name = m.displayName;
        reasoning_key = m.reasoningKey;
        adaptive_thinking = m.adaptiveThinking;
        overrides = if m.overrides == null then null else toUpstreamModelOverrides m.overrides;
      }
    );

  toUpstreamThinking =
    t:
    stripNulls (
      t.extraSettings
      // {
        inherit (t) enabled effort keep;
      }
    );

  toUpstreamLoopControl =
    s:
    stripNulls (
      s.extraSettings
      // {
        max_steps_per_turn = s.maxStepsPerTurn;
        max_retries_per_step = s.maxRetriesPerStep;
        reserved_context_size = s.reservedContextSize;
      }
    );

  toUpstreamBackground =
    s:
    stripNulls (
      s.extraSettings
      // {
        max_running_tasks = s.maxRunningTasks;
        keep_alive_on_exit = s.keepAliveOnExit;
        kill_grace_period_ms = s.killGracePeriodMs;
        bash_auto_background_on_timeout = s.bashAutoBackgroundOnTimeout;
        bash_task_timeout_s = s.bashTaskTimeoutS;
        print_background_mode = s.printBackgroundMode;
        print_wait_ceiling_s = s.printWaitCeilingS;
        print_max_turns = s.printMaxTurns;
      }
    );

  toUpstreamSubagent =
    s:
    stripNulls (
      s.extraSettings
      // {
        timeout_ms = s.timeoutMs;
      }
    );

  toUpstreamImage =
    s:
    stripNulls (
      s.extraSettings
      // {
        max_edge_px = s.maxEdgePx;
        read_byte_budget = s.readByteBudget;
      }
    );

  toUpstreamService =
    s:
    stripNulls (
      s.extraSettings
      // {
        base_url = s.baseUrl;
        api_key = s.apiKey;
        custom_headers = nonEmpty s.customHeaders;
      }
    );

  toUpstreamPermissionRule =
    r:
    stripNulls {
      inherit (r) decision pattern scope reason;
    };

  toUpstreamPermission =
    p:
    stripNulls (
      p.extraSettings
      // {
        rules = map toUpstreamPermissionRule p.rules;
      }
    );

  toUpstreamConfig =
    settings:
    stripNulls (
      settings.extraSettings
      // {
        default_model = settings.defaultModel;
        default_permission_mode = settings.defaultPermissionMode;
        default_plan_mode = settings.defaultPlanMode;
        merge_all_available_skills = settings.mergeAllAvailableSkills;
        extra_skill_dirs = settings.extraSkillDirs;
        telemetry = settings.telemetry;
        providers =
          if settings.providers == null then null else builtins.mapAttrs (_: toUpstreamProvider) settings.providers;
        models =
          if settings.models == null then null else builtins.mapAttrs (_: toUpstreamModel) settings.models;
        thinking = if settings.thinking == null then null else toUpstreamThinking settings.thinking;
        loop_control = if settings.loopControl == null then null else toUpstreamLoopControl settings.loopControl;
        background = if settings.background == null then null else toUpstreamBackground settings.background;
        subagent = if settings.subagent == null then null else toUpstreamSubagent settings.subagent;
        image = if settings.image == null then null else toUpstreamImage settings.image;
        services =
          if settings.services == null then null else builtins.mapAttrs (_: toUpstreamService) settings.services;
        permission = if settings.permission == null then null else toUpstreamPermission settings.permission;
      }
    );

  toUpstreamTui =
    t:
    stripNulls (
      t.extraSettings
      // {
        inherit (t) theme;
        disable_paste_burst = t.disablePasteBurst;
        editor = {
          inherit (t.editor) command;
        };
        notifications = {
          inherit (t.notifications) enabled;
          notification_condition = t.notifications.notificationCondition;
        };
        upgrade = {
          auto_install = t.upgrade.autoInstall;
        };
      }
    );

  toUpstreamMcpServer =
    s:
    stripNulls (
      s.extraSettings
      // {
        inherit (s) command url transport cwd bearerTokenEnvVar;
        args = if s.args == [ ] then null else s.args;
        env = nonEmpty s.env;
        headers = nonEmpty s.headers;
        enabled = if s.enabled then null else false;
        startupTimeoutMs = s.startupTimeoutMs;
        toolTimeoutMs = s.toolTimeoutMs;
        enabledTools = s.enabledTools;
        disabledTools = s.disabledTools;
      }
    );

  toUpstreamMcp =
    servers: {
      mcpServers = builtins.mapAttrs (_: toUpstreamMcpServer) servers;
    };

in
{
  inherit
    stripNulls
    toUpstreamConfig
    toUpstreamTui
    toUpstreamMcp
    ;

  # Declared config.toml content as JSON (merge input, NOT a final file).
  mkConfigJson =
    { pkgs, settings }:
    pkgs.writeText "kimi-declared-config.json" (builtins.toJSON (toUpstreamConfig settings));

  # Declared tui.toml content as JSON (merge input, NOT a final file).
  mkTuiJson =
    { pkgs, tui }:
    pkgs.writeText "kimi-declared-tui.json" (builtins.toJSON (toUpstreamTui tui));

  # Canonical mcp.json: deterministic bytes (sorted keys, 2-space indent) so
  # the project drift check can byte-compare the render against the committed
  # file in a consuming repo.
  mkMcpJson =
    { pkgs, servers }:
    pkgs.runCommand "kimi-mcp.json"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        jq --indent 2 -S . ${
          pkgs.writeText "kimi-mcp-raw.json" (builtins.toJSON (toUpstreamMcp servers))
        } > $out
      '';
}
