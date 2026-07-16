{ lib }:
let
  withoutNulls = lib.filterAttrs (_: value: value != null);
  nonEmptyAttrs = value: if value == { } then null else value;

  renderInput =
    input:
    nonEmptyAttrs (withoutNulls {
      collapsePastedText = input.collapsePastedText;
    });

  renderAutoApprove =
    value:
    nonEmptyAttrs (withoutNulls {
      create = value.create;
      update = value.update;
      delete = value.delete;
    });

  renderPermissions =
    value:
    nonEmptyAttrs (withoutNulls {
      defaultMode = value.defaultMode;
      autoApprove = renderAutoApprove value.autoApprove;
      allow = if value.allow == [ ] then null else value.allow;
    });

  renderFeatureModels =
    value:
    nonEmptyAttrs (withoutNulls {
      titleGeneration = value.titleGeneration;
      compaction = value.compaction;
      toolDescription = value.toolDescription;
      tasteLearning = value.tasteLearning;
      tasteOnboarding = value.tasteOnboarding;
    });

  renderOauth =
    value:
    if value == null then
      null
    else
      withoutNulls {
        inherit (value) authorizationUrl tokenUrl clientId;
        scopes = if value.scopes == [ ] then null else value.scopes;
      };
in
rec {
  toGlobalConfig =
    value:
    withoutNulls {
      provider = value.provider;
      model = value.model;
      reasoningEffort = if value.reasoningEffort == { } then null else value.reasoningEffort;
      theme = value.theme;
      compactMode = value.compactMode;
      telemetry = value.telemetry;
      tasteLearning = value.tasteLearning;
      featureModels = renderFeatureModels value.featureModels;
      autoInstallExtension = value.autoInstallExtension;
    };

  toUserSettings =
    value:
    withoutNulls {
      disabledSkills = if value.disabledSkills == [ ] then null else value.disabledSkills;
      input = renderInput value.input;
    };

  toProjectSettings =
    value:
    withoutNulls {
      tasteLearning = value.tasteLearning;
      disabledSkills = if value.disabledSkills == [ ] then null else value.disabledSkills;
      input = renderInput value.input;
      permissions = renderPermissions value.permissions;
    };

  toHookDefinitions =
    { hooks, commandFor }:
    map (hook: {
      inherit (hook)
        name
        event
        matcher
        timeout
        async
        failClosed
        ;
      command = if hook.command != null then hook.command else commandFor hook;
    }) hooks;

  toMcpServers = servers: {
    mcpServers = lib.mapAttrs (
      _: server:
      withoutNulls {
        inherit (server) transport enabled;
        command = server.command;
        args = if server.args == [ ] then null else server.args;
        url = server.url;
        oauth = renderOauth server.oauth;
      }
    ) servers;
  };
}
