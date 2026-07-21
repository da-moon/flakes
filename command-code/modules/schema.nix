{ lib }:
let
  inherit (lib) mkOption types;

  nullable =
    type: description:
    mkOption {
      type = types.nullOr type;
      default = null;
      inherit description;
    };

  nonEmptyString = types.addCheck types.str (value: value != "");
  permissionAllow = types.addCheck nonEmptyString (
    value: builtins.match "Bash\\(.+\\)" value != null
  );
  hookTimeout = types.addCheck types.int (value: value > 0 && value <= 600);
  reasoningEffortType = types.enum [
    "low"
    "medium"
    "high"
    "xhigh"
    "max"
  ];

  featureModelsType = types.submodule {
    options = {
      titleGeneration = nullable nonEmptyString "Model used to generate session titles.";
      compaction = nullable nonEmptyString "Model used to compact long conversations.";
      toolDescription = nullable nonEmptyString "Model used to summarize tool permission prompts.";
      tasteLearning = nullable nonEmptyString "Model used by the background taste-learning agent.";
      tasteOnboarding = nullable nonEmptyString "Model used by the /learn-taste observer.";
    };
  };

  inputSettingsType = types.submodule {
    options.collapsePastedText = nullable types.bool "Whether pasted text is collapsed in the terminal UI.";
  };

  autoApproveType = types.submodule {
    options = {
      create = nullable types.bool "Automatically approve file creation.";
      update = nullable types.bool "Automatically approve file updates.";
      delete = nullable types.bool "Automatically approve file deletion.";
    };
  };

  permissionsType = types.submodule {
    options = {
      defaultMode =
        nullable
          (types.enum [
            "ask"
            "acceptEdits"
          ])
          ''
            Default project edit permission mode understood by Command Code 0.52.2.
          '';
      autoApprove = mkOption {
        type = autoApproveType;
        default = { };
        description = "Fine-grained project edit approvals.";
      };
      allow = mkOption {
        type = types.listOf permissionAllow;
        default = [ ];
        description = "Permission patterns to add to the project allow set.";
      };
    };
  };

  oauthType = types.submodule {
    options = {
      authorizationUrl = mkOption {
        type = nonEmptyString;
        description = "OAuth authorization endpoint. Secrets are intentionally unsupported.";
      };
      tokenUrl = mkOption {
        type = nonEmptyString;
        description = "OAuth token endpoint. Secrets are intentionally unsupported.";
      };
      clientId = mkOption {
        type = nonEmptyString;
        description = "Public OAuth client identifier.";
      };
      scopes = mkOption {
        type = types.listOf nonEmptyString;
        default = [ ];
        description = "OAuth scopes.";
      };
    };
  };
in
rec {
  schemaVersion = "0.52.2";

  globalConfigType = types.submodule {
    options = {
      provider = nullable (types.enum [
        "command-code"
        "anthropic"
        "github-copilot"
        "codex"
      ]) "Authentication/provider route.";
      model = nullable nonEmptyString "Default model identifier.";
      reasoningEffort = mkOption {
        type = types.attrsOf reasoningEffortType;
        default = { };
        description = "Reasoning effort keyed by model identifier.";
      };
      theme = nullable (types.enum [
        "dark"
        "light"
      ]) "Terminal theme.";
      compactMode = nullable (types.enum [
        "default"
        "fast"
      ]) "Conversation compaction mode.";
      telemetry = nullable types.bool "Whether Command Code telemetry is enabled.";
      tasteLearning = nullable types.bool "Whether ongoing global taste learning is enabled.";
      featureModels = mkOption {
        type = featureModelsType;
        default = { };
        description = "Per-feature model overrides supported by Command Code 0.52.2.";
      };
      autoInstallExtension = nullable types.bool "Whether supported editor extensions are installed automatically.";
    };
  };

  userSettingsType = types.submodule {
    options = {
      disabledSkills = mkOption {
        type = types.listOf nonEmptyString;
        default = [ ];
        description = "Skill names managed as members of disabledSkills.";
      };
      input = mkOption {
        type = inputSettingsType;
        default = { };
        description = "Terminal input behavior.";
      };
    };
  };

  projectSettingsType = types.submodule {
    options = {
      tasteLearning = nullable types.bool "Project-local taste-learning override.";
      disabledSkills = mkOption {
        type = types.listOf nonEmptyString;
        default = [ ];
        description = "Skill names managed as members of disabledSkills.";
      };
      input = mkOption {
        type = inputSettingsType;
        default = { };
        description = "Project-local terminal input behavior.";
      };
      permissions = mkOption {
        type = permissionsType;
        default = { };
        description = ''
          Effective project-local permission settings. permissions.deny is
          intentionally absent because Command Code 0.52.2 does not enforce it.
        '';
      };
    };
  };

  hookType = types.submodule {
    options = {
      name = mkOption {
        type = nonEmptyString;
        description = "Stable, filesystem-safe hook identifier.";
      };
      event = mkOption {
        type = types.enum [
          "PreToolUse"
          "PostToolUse"
          "Stop"
          "SessionStart"
        ];
        default = "PreToolUse";
        description = "Command Code hook event.";
      };
      matcher = nullable types.str "Optional tool matcher.";
      script = nullable (types.either types.lines types.path) "Packaged shell script contents or source path.";
      command = nullable nonEmptyString "Command to run instead of a packaged script.";
      runtimeInputs = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = "Packages added to PATH for a packaged script hook.";
      };
      timeout = mkOption {
        type = hookTimeout;
        default = 30;
        description = "Timeout in seconds (1 through 600).";
      };
      async = mkOption {
        type = types.bool;
        default = false;
        description = "Run without waiting for the hook result.";
      };
      failClosed = mkOption {
        type = types.bool;
        default = false;
        description = "Block when the hook fails or returns invalid output.";
      };
    };
  };

  mcpServerType = types.submodule {
    options = {
      transport = mkOption {
        type = types.enum [
          "stdio"
          "http"
        ];
        description = "MCP transport.";
      };
      enabled = mkOption {
        type = types.bool;
        default = true;
        description = "Whether Command Code connects to this server.";
      };
      command = nullable nonEmptyString "Executable for a stdio MCP server.";
      args = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Arguments for a stdio MCP server.";
      };
      url = nullable nonEmptyString "URL for an HTTP MCP server.";
      oauth = mkOption {
        type = types.nullOr oauthType;
        default = null;
        description = ''
          Public OAuth metadata. clientSecret, headers, and env are deliberately
          unsupported so that secrets cannot be copied into the Nix store.
        '';
      };
    };
  };

  validName =
    name: builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" name != null && !(lib.hasInfix "__" name);
  validHttpUrl = value: builtins.match "https?://.+" value != null;
  secureOrLoopbackUrl =
    value:
    builtins.match "https://.+" value != null
    || builtins.match "http://(localhost|127\\.0\\.0\\.1|\\[::1\\])(:[0-9]+)?(/.*)?" value != null;

  hookAssertions =
    {
      hooks,
      label ? "hooks",
    }:
    let
      names = map (hook: hook.name) hooks;
    in
    [
      {
        assertion = builtins.length names == builtins.length (lib.unique names);
        message = "${label} contains duplicate hook names.";
      }
    ]
    ++ lib.concatMap (hook: [
      {
        assertion = validName hook.name;
        message = "${label} has invalid hook name ${builtins.toJSON hook.name}.";
      }
      {
        assertion = (hook.script != null) != (hook.command != null);
        message = "${label}.${hook.name} must set exactly one of script or command.";
      }
      {
        assertion = !(hook.async && hook.failClosed);
        message = "${label}.${hook.name} cannot combine async with failClosed.";
      }
      {
        assertion = hook.script != null || hook.runtimeInputs == [ ];
        message = "${label}.${hook.name}.runtimeInputs is valid only with script.";
      }
    ]) hooks;

  mcpAssertions =
    {
      servers,
      label ? "mcpServers",
    }:
    lib.concatLists (
      lib.mapAttrsToList (
        name: server:
        let
          isStdio = server.transport == "stdio";
          oauthUrlsValid =
            server.oauth == null
            || (
              server.url != null
              && secureOrLoopbackUrl server.oauth.authorizationUrl
              && secureOrLoopbackUrl server.oauth.tokenUrl
              && secureOrLoopbackUrl server.url
            );
        in
        [
          {
            assertion = validName name;
            message = "${label} has invalid server name ${builtins.toJSON name}.";
          }
          {
            assertion =
              if isStdio then
                server.command != null && server.url == null && server.oauth == null
              else
                server.command == null && server.args == [ ] && server.url != null;
            message = "${label}.${name} must use exactly the fields for its ${server.transport} transport.";
          }
          {
            assertion = server.url == null || validHttpUrl server.url;
            message = "${label}.${name}.url must use http:// or https://.";
          }
          {
            assertion = oauthUrlsValid;
            message = "${label}.${name} OAuth endpoints and server URL must use HTTPS or HTTP loopback.";
          }
        ]
      ) servers
    );
}
