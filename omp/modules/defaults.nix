# Default settings and keybindings for oh-my-pi.
# Generated from https://github.com/can1357/oh-my-pi defaults.
#
# schemaVersion marks the omp release these defaults were last reviewed
# against. flake.nix throws when it does not match the latest release, so
# every version bump forces a human review of the defaults (command-code
# convention). scripts/update-version.sh refreshes it on drift-accept.
#
# Coverage: every registry key with a concrete default is declared below.
# Keys whose upstream default is null (unset) or that are credentials are
# intentionally NOT declared; each such group carries a comment where its
# siblings are declared, plus the ledger near the end of defaultSettings.
{ }:
{
  schemaVersion = "17.4.0";

  defaultSettings = {
    setupVersion = 0;
    autoResume = false;
    power = {
      sleepPrevention = "idle";
    };
    advisor = {
      enabled = false;
      syncBacklog = "off";
      immuneTurns = 3;
    };
    prewalk = {
      enabled = false;
    };
    git = {
      enabled = true;
    };
    extensions = [ ];
    enabledModels = [ ];
    disabledProviders = [ ];
    providers = {
      maxInFlightRequests = { };
      anthropic = {
        serverSideFallback = false;
      };
      # Upstream replaced the single-preference `webSearch`/`image` options
      # ("auto" sentinel) with priority-list orders (empty list = auto).
      webSearchOrder = [ ];
      webSearchExclude = [ ];
      # 17.2.14 added dotted key "searxng.safesearch" (number); its default is
      # null, so nothing is declared here.
      antigravityEndpoint = "auto";
      cacheRetention = "auto";
      imageOrder = [ ];
      fireworksTier = "standard";
      tts = "auto";
      tinyModel = "online";
      tinyModelDevice = "default";
      tinyModelDtype = "default";
      memoryModel = "online";
      autoThinkingModel = "online";
      unexpectedStopModel = "online";
      kimiApiFormat = "anthropic";
      openaiWebsockets = "auto";
      streamFirstEventTimeoutSeconds = -1;
      streamIdleTimeoutSeconds = -1;
      openrouterVariant = "default";
      fetch = "auto";
      autoThinkingMaxEffort = "xhigh";
      # Registry records null: the upstream default is the named constant 60
      # (packages/coding-agent/src/web/search/types.ts).
      webSearchTimeoutSeconds = 60;
      ollama-cloud = {
        maxConcurrency = 3;
      };
      # Null-default, intentionally undeclared: webSearchGeminiModel.
    };
    disabledExtensions = [ ];
    modelRoles = { };
    modelTags = { };
    modelProviderOrder = [ ];
    cycleOrder = [
      "smol"
      "default"
      "slow"
    ];
    theme = {
      dark = "titanium";
      light = "light";
    };
    symbolPreset = "unicode";
    colorBlindMode = false;
    statusLine = {
      preset = "default";
      separator = "powerline-thin";
      sessionAccent = true;
      transparent = false;
      compactThinkingLevel = false;
      showHookStatus = true;
      contextLine = "annotated";
      leftSegments = [ ];
      rightSegments = [ ];
      segmentOptions = { };
    };
    composer = {
      shape = "box";
    };
    tools = {
      artifactSpillThreshold = 50;
      artifactTailBytes = 20;
      artifactHeadBytes = 20;
      outputMaxColumns = 768;
      artifactTailLines = 500;
      format = "auto";
      approval = { };
      approvalMode = "yolo";
      intentTracing = true;
      abortOnFabricatedResult = true;
      maxTimeout = 0;
      # Upstream removed tools.discoveryMode / tools.essentialOverride.
      xdev = true;
      xdevDocs = "builtins";
      xdevInlineDevices = [ ];
    };
    terminal = {
      showImages = true;
      showProgress = false;
    };
    images = {
      autoResize = true;
      blockImages = false;
      describeForTextModels = true;
    };
    tui = {
      maxInlineImageColumns = 100;
      maxInlineImageRows = 20;
      maxInlineImages = 8;
      textSizing = false;
      renderMermaid = true;
      hyperlinks = "auto";
      tight = false;
      scrollbackRebuild = false;
      codexResetFireworks = false;
      imeSafeCursor = false;
      titleState = true;
    };
    display = {
      shimmer = "classic";
      smoothStreaming = true;
      showTokenUsage = false;
      cacheMissMarker = false;
      collapseCompacted = true;
      hideToolActivity = false;
    };
    showHardwareCursor = true;
    defaultThinkingLevel = "high";
    hideThinkingBlock = false;
    proseOnlyThinking = true;
    omitThinking = false;
    # 17.2.14 added top-level externalThinking (boolean, default false).
    externalThinking = false;
    # 17.4.0 added top-level extendedContext (boolean, default true).
    extendedContext = true;
    model = {
      loopGuard = {
        enabled = true;
        checkAssistantContent = true;
        toolCallReminder = true;
      };
      toolCallLoopGuard = {
        enabled = true;
        threshold = 5;
        # Upstream default changed from ["job" "irc"] to ["hub"].
        exemptTools = [
          "hub"
        ];
      };
    };
    inlineToolDescriptors = "auto";
    includeModelInPrompt = true;
    includeWorkspaceTree = false;
    personality = "default";
    temperature = -1;
    topP = -1;
    topK = -1;
    minP = -1;
    presencePenalty = -1;
    repetitionPenalty = -1;
    textVerbosity = "medium";
    tier = {
      openai = "none";
      anthropic = "none";
      google = "none";
      subagent = "inherit";
      advisor = "none";
    };
    retry = {
      enabled = true;
      maxRetries = 10;
      baseDelayMs = 500;
      maxDelayMs = 300000;
      modelFallback = true;
      fallbackChains = { };
      fallbackRevertPolicy = "cooldown-expiry";
      usageAwareFallback = false;
      usageReservePct = 10;
      usageReservePolicy = "confirm";
    };
    steeringMode = "one-at-a-time";
    followUpMode = "one-at-a-time";
    interruptMode = "immediate";
    loop = {
      mode = "prompt";
    };
    doubleEscapeAction = "tree";
    treeFilterMode = "default";
    autocompleteMaxVisible = 5;
    emojiAutocomplete = true;
    paste = {
      largeMenuThreshold = 100;
    };
    startup = {
      quiet = false;
      showSplash = false;
      setupWizard = true;
      checkUpdate = true;
      # Replaces the removed top-level `collapseChangelog` (false -> expanded).
      changelogMode = "expanded";
    };
    marketplace = {
      autoUpdate = "notify";
    };
    magicKeywords = {
      enabled = true;
      ultrathink = true;
      orchestrate = true;
      workflow = true;
    };
    completion = {
      notify = "on";
    };
    ask = {
      timeout = 0;
      notify = "on";
      enabled = true;
    };
    recap = {
      enabled = true;
      idleSeconds = 240;
    };
    collab = {
      relayUrl = "wss://my.omp.sh";
      webUrl = "";
      displayName = "";
    };
    share = {
      serverUrl = "https://my.omp.sh/s";
      store = "blob";
      redactSecrets = true;
    };
    stt = {
      enabled = false;
      language = "en";
      modelName = "parakeet";
      submitTrigger = "never";
    };
    contextPromotion = {
      enabled = false;
    };
    compaction = {
      enabled = true;
      midTurnEnabled = true;
      asyncEnabled = true;
      methodOrder = [ ];
      thresholdPercent = -1;
      thresholdTokens = -1;
      handoffSaveToDisk = false;
      remoteStreamingV2Enabled = true;
      keepRecentTokens = 20000;
      autoContinue = true;
      v2RetainedMessageBudget = 64000;
      idleEnabled = false;
      idleThresholdTokens = 200000;
      idleTimeoutSeconds = 300;
      supersedeReads = true;
      dropUseless = true;
      # Null-default, intentionally undeclared: remoteEndpoint, reserveTokens
      # (pinning reserveTokens would disable the small-window proportional
      # reserve recovery; see the schema comment upstream).
    };
    snapcompact = {
      systemPrompt = "none";
      toolResults = false;
      shape = "auto";
    };
    branchSummary = {
      enabled = false;
      reserveTokens = 16384;
    };
    memories = {
      enabled = false;
      maxRolloutsPerStartup = 64;
      maxRolloutAgeDays = 30;
      minRolloutIdleHours = 12;
      threadScanLimit = 300;
      maxRawMemoriesForGlobal = 200;
      stage1Concurrency = 8;
      stage1LeaseSeconds = 120;
      stage1RetryDelaySeconds = 120;
      phase2LeaseSeconds = 180;
      phase2RetryDelaySeconds = 180;
      phase2HeartbeatSeconds = 30;
      rolloutPayloadPercent = 0.7;
      phase1InputTokenLimit = 4000;
      fallbackTokenLimit = 16000;
      summaryInjectionTokenLimit = 5000;
    };
    memory = {
      backend = "off";
    };
    autolearn = {
      enabled = false;
      autoContinue = false;
      minToolCalls = 5;
    };
    mnemopi = {
      scoping = "per-project";
      embeddingVariant = "en";
      autoRecall = true;
      autoRetain = true;
      polyphonicRecall = false;
      enhancedRecall = false;
      proactiveLinking = false;
      noEmbeddings = false;
      llmMode = "smol";
      retainEveryNTurns = 4;
      recallLimit = 8;
      recallContextTurns = 3;
      recallMaxQueryChars = 4000;
      injectionTokenLimit = 5000;
      debug = false;
      # Null-default, intentionally undeclared: bank, dbPath, embeddingApiUrl,
      # embeddingModel, llmBaseUrl, llmModel. Credentials (never declared):
      # embeddingApiKey, llmApiKey.
    };
    hindsight = {
      apiUrl = "http://localhost:8888";
      scoping = "per-project-tagged";
      autoRecall = true;
      autoRetain = true;
      retainMode = "full-session";
      retainEveryNTurns = 3;
      retainOverlapTurns = 2;
      retainContext = "omp";
      recallBudget = "mid";
      recallMaxTokens = 1024;
      recallContextTurns = 1;
      recallMaxQueryChars = 800;
      recallTypes = [
        "world"
        "experience"
      ];
      debug = false;
      requestTimeoutMs = 30000;
      recallTimeoutMs = 30000;
      retainTimeoutMs = 60000;
      reflectTimeoutMs = 120000;
      mentalModelsEnabled = true;
      mentalModelAutoSeed = true;
      mentalModelRefreshIntervalMs = 300000;
      mentalModelMaxRenderChars = 16000;
      # Null-default, intentionally undeclared: bankId, bankIdPrefix,
      # bankMission, retainMission. Credential (never declared): apiToken.
    };
    ttsr = {
      enabled = true;
      contextMode = "discard";
      interruptMode = "always";
      repeatMode = "once";
      repeatGap = 10;
      builtinRules = true;
      disabledRules = [ ];
    };
    edit = {
      mode = "hashline";
      fuzzyMatch = true;
      fuzzyThreshold = 0.95;
      streamingAbort = false;
      blockAutoGenerated = true;
      enforceSeenLines = false;
      # edit.modelVariants (per-model edit-mode override map) is read from
      # config.yml but is NOT in the settings registry, so it cannot be
      # declared here (the schema check only passes registered keys). Set it
      # via programs.omp.settings if needed.
    };
    readLineNumbers = false;
    read = {
      defaultLimit = 300;
      summarize = {
        enabled = true;
        prose = false;
        minBodyLines = 4;
        minCommentLines = 6;
        minTotalLines = 100;
        unfoldUntil = 50;
        unfoldLimit = 100;
      };
      toolResultPreview = false;
      renderMarkdown = false;
    };
    lsp = {
      enabled = true;
      lazy = true;
      shared = true;
      formatOnWrite = false;
      diagnosticsOnWrite = true;
      diagnosticsOnEdit = false;
      diagnosticsDeduplicate = true;
    };
    bash = {
      enabled = true;
      direnv = "auto";
      direnvLoadTimeoutMs = 30000;
      # Ordered approval rules: [{ match = <glob>; approval = "allow"|"prompt"|"deny"; }]
      patterns = [ ];
      autoBackground = {
        enabled = false;
        thresholdMs = 60000;
      };
    };
    bashInterceptor = {
      enabled = false;
      patterns = [
        {
          pattern = "^\\s*(cat|head|tail|less|more)\\s+";
          tool = "read";
          message = "Use the `read` tool instead of cat/head/tail. It provides better context and handles binary files.";
        }
        {
          pattern = "^\\s*(grep|rg|ripgrep|ag|ack)\\s+";
          tool = "grep";
          message = "Use the `grep` tool instead of grep/rg. It respects .gitignore and provides structured output.";
        }
        {
          pattern = "^\\s*(find|fd|locate)\\s+.*(-name|-iname|-type|--type|-glob)";
          tool = "glob";
          message = "Use the `glob` tool instead of find/fd. It respects .gitignore and is faster for glob patterns.";
        }
        {
          pattern = "^\\s*sed\\s+(-i|--in-place)";
          tool = "edit";
          message = "Use the `edit` tool instead of sed -i. It provides diff preview and fuzzy matching.";
        }
        {
          pattern = "^\\s*perl\\s+.*-[pn]?i";
          tool = "edit";
          message = "Use the `edit` tool instead of perl -i. It provides diff preview and fuzzy matching.";
        }
        {
          pattern = "^\\s*awk\\s+.*-i\\s+inplace";
          tool = "edit";
          message = "Use the `edit` tool instead of awk -i inplace. It provides diff preview and fuzzy matching.";
        }
        {
          pattern = "^\\s*(echo|printf|cat\\s*<<)\\s+(?:(?:[^\"'>]|\"[^\"]*\"|'[^']*')|(?<!\\|)>{1,2}\\|?\\s*(?:\"/dev/(?:null|tty|stdout|stderr)\"|'/dev/(?:null|tty|stdout|stderr)'|/dev/(?:null|tty|stdout|stderr))(?:[\\s;&|]|$))*(?<!\\|)>{1,2}\\|?\\s*(?!(?:\"/dev/(?:null|tty|stdout|stderr)\"|'/dev/(?:null|tty|stdout/|stderr)'|/dev/(?:null|tty|stdout|stderr))(?:[\\s;&|]|$))[$\\w./~\"'-]";
          tool = "write";
          message = "Use the `write` tool instead of echo/cat redirection. It handles encoding and provides confirmation.";
        }
        {
          pattern = "^\\s*nohup\\s+|(?<!&)\\&\\s*$";
          tool = "launch";
          message = "Use the `launch` tool instead of nohup or background shell syntax so the process stays observable and managed.";
        }
        {
          pattern = "^\\s*(?:(?:bun|npm|pnpm|yarn)\\s+(?:run\\s+)?(?:dev|start)(?:\\s|$)|(?:vite|next\\s+dev|nuxt\\s+dev|nodemon|lldb|gdb|tail\\s+-f)(?:\\s|$)|docker\\s+compose\\s+up(?!.*(?:\\s-d(?:\\s|$)|--detach))(?:\\s|$))";
          tool = "launch";
          message = "Use the `launch` tool for services, watchers, and debuggers so other omp instances can observe and control them.";
        }
        {
          pattern = "^\\s*(?:(?:bun|npm|pnpm|yarn)\\s+(?:run\\s+)?\\S+|cargo\\s+watch|watchexec|pytest|vitest|jest|tsc)(?:.|\\n)*(?:--watch|-w)(?:\\s|$)";
          tool = "launch";
          message = "Use the `launch` tool for watch mode so its output, input, and lifecycle stay managed.";
        }
      ];
    };
    shellMinimizer = {
      enabled = true;
      only = [ ];
      except = [ ];
      maxCaptureBytes = 4194304;
      sourceOutlineLevel = "default";
      # Null-default, intentionally undeclared: legacyFilters, settingsPath.
    };
    eval = {
      py = true;
      js = true;
      rb = false;
      jl = false;
      autoBackground = {
        enabled = false;
        thresholdMs = 60000;
      };
    };
    python = {
      kernelMode = "session";
      interpreter = "";
    };
    ruby = {
      interpreter = "";
    };
    julia = {
      interpreter = "";
    };
    todo = {
      enabled = true;
      reminders = true;
      # Upstream renamed "reminders.max" (dotted form) to remindersMax.
      remindersMax = 3;
      eager = "default";
    };
    glob = {
      enabled = true;
    };
    grep = {
      enabled = true;
      contextBefore = 1;
      contextAfter = 3;
    };
    astGrep = {
      enabled = true;
    };
    astEdit = {
      enabled = true;
    };
    debug = {
      enabled = true;
    };
    launch = {
      enabled = true;
    };
    speechgen = {
      enabled = false;
    };
    inspect_image = {
      enabled = false;
      mode = "auto";
      timeoutMs = 300000;
    };
    checkpoint = {
      enabled = false;
    };
    fetch = {
      enabled = true;
    };
    vault = {
      enabled = false;
    };
    github = {
      enabled = false;
      cache = {
        enabled = true;
        softTtlSec = 300;
        hardTtlSec = 604800;
      };
    };
    web_search = {
      enabled = true;
    };
    browser = {
      enabled = true;
      headless = true;
      cmux = true;
      relay = false;
      # Null-default, intentionally undeclared: cdpUrl, relayUrl
      # (falls back to http://127.0.0.1:9224), screenshotDir.
    };
    async = {
      enabled = true;
      maxJobs = 100;
      pollWaitDuration = "smart";
    };
    irc = {
      timeoutMs = 120000;
    };
    mcp = {
      enableProjectConfig = true;
      # Upstream removed mcp.discoveryMode / mcp.discoveryDefaultServers.
      notifications = false;
      notificationDebounceMs = 500;
      renderMarkdownResults = true;
    };
    plan = {
      enabled = true;
      defaultOnStartup = false;
    };
    goal = {
      enabled = true;
      statusInFooter = true;
      continuationModes = [
        "interactive"
      ];
    };
    title = {
      refreshOnReplan = true;
    };
    task = {
      isolation = {
        mode = "none";
        merge = "patch";
        commits = "generic";
        apply = true;
      };
      eager = "default";
      batch = true;
      maxConcurrency = 32;
      enableLsp = false;
      enableEffort = false;
      maxEffort = "max";
      prewalk = false;
      # Per-agent prewalk overrides: { <agent> = "on"|"off"|<model-pattern>; }
      agentPrewalk = { };
      maxRecursionDepth = 2;
      maxRuntimeMs = 0;
      agentIdleTtlMs = 420000;
      softRequestBudget = 200;
      softRequestBudgetNotice = true;
      disabledAgents = [ ];
      agentModelOverrides = { };
      showResolvedModelBadge = false;
      # Upstream changed agentAdvisor from boolean to a per-agent record
      # ({ <agent> = "on"|"off"|<model-pattern>; }; legacy advisor.subagents
      # migrates to agentAdvisor.task).
      agentAdvisor = { };
    };
    tasks = {
      todoClearDelay = 60;
    };
    skills = {
      enabled = true;
      enableSkillCommands = true;
      enableCodexUser = true;
      enableClaudeUser = true;
      enableClaudeProject = true;
      enablePiUser = true;
      enablePiProject = true;
      enableAgentsUser = true;
      enableAgentsProject = true;
      customDirectories = [ ];
      ignoredSkills = [ ];
      includeSkills = [ ];
    };
    commands = {
      enableClaudeUser = true;
      enableClaudeProject = true;
      enableOpencodeUser = true;
      enableOpencodeProject = true;
    };
    secrets = {
      enabled = false;
    };
    tts = {
      localModel = "kokoro";
      localVoice = "af_heart";
    };
    speech = {
      enabled = false;
      mode = "assistant";
      enhanced = false;
      voice = "af_heart";
    };
    features = {
      unexpectedStopDetection = false;
    };
    codexResets = {
      autoRedeem = "unset";
      minBlockedMinutes = 60;
      keepCredits = 0;
      salvageHorizonHours = 12;
    };
    provider = {
      appendOnlyContext = "auto";
    };
    exa = {
      enabled = true;
      searchDelayMs = 1000;
    };
    commit = {
      mapReduceEnabled = true;
      mapReduceMinFiles = 4;
      mapReduceMaxFileTokens = 50000;
      mapReduceTimeoutMs = 120000;
      mapReduceMaxConcurrency = 5;
      changelogMaxDiffChars = 120000;
    };
    dev = {
      autoqa = false;
      # Upstream renamed "autoqa.consent" (dotted form) to autoqaConsent.
      autoqaConsent = "unset";
      autoqaPush = {
        endpoint = "https://qa.omp.sh/v1/grievances";
        # Credential, never declared: autoqaPush.token.
      };
    };
    gc = {
      blobs = true;
      archive = true;
      wal = true;
      coldArchiveAfterDays = 30;
      retainNewestGlobal = 20;
      retainNewestPerCwd = 10;
    };
    # --- 17.3.7 full-registry coverage: groups with no previously declared
    # --- keys (defaults verified against schema/upstream.json + source).
    computer = {
      enabled = false;
      display = "all";
      maxWidth = 3840;
      maxHeight = 2400;
    };
    error = {
      notify = "off";
    };
    extensionHandlers = {
      toolCallTimeoutMs = 30000;
    };
    generate_image = {
      enabled = false;
    };
    live = {
      # Registry records null: the upstream default is the named constant
      # "sol" (packages/coding-agent/src/live/voices.ts).
      voice = "sol";
    };
    modelRoleStorage = "global";
    security = {
      enabled = false;
    };
    workspace = {
      additionalDirectories = [ ];
    };
    # Ledger of registry keys intentionally NOT declared above.
    # Null-default (unset preserves upstream behavior): shellPath,
    #   auth.broker.url, worktree.base (falls back to OMP_WORKTREE_DIR or
    #   ~/.omp/wt), searxng.endpoint/basicUsername/categories/engines/
    #   language (safesearch noted at providers above).
    # Credentials (never declarable in the store): auth.broker.token,
    #   searxng.token, searxng.basicPassword.
    thinkingBudgets = {
      minimal = 1024;
      low = 2048;
      medium = 8192;
      high = 16384;
      xhigh = 32768;
      max = 32768;
    };
  };

  defaultKeybindings = {
    "tui.editor.cursorUp" = "up";
    "tui.editor.cursorDown" = "down";
    "tui.editor.cursorLeft" = [
      "left"
      "ctrl+b"
    ];
    "tui.editor.cursorRight" = [
      "right"
      "ctrl+f"
    ];
    "tui.editor.cursorWordLeft" = [
      "alt+left"
      "ctrl+left"
      "alt+b"
    ];
    "tui.editor.cursorWordRight" = [
      "alt+right"
      "ctrl+right"
      "alt+f"
    ];
    "tui.editor.cursorLineStart" = [
      "home"
      "ctrl+a"
    ];
    "tui.editor.cursorLineEnd" = [
      "end"
      "ctrl+e"
    ];
    "tui.editor.jumpForward" = "ctrl+]";
    "tui.editor.jumpBackward" = "ctrl+alt+]";
    "tui.editor.pageUp" = "pageUp";
    "tui.editor.pageDown" = "pageDown";
    "tui.editor.deleteCharBackward" = "backspace";
    "tui.editor.deleteCharForward" = [
      "delete"
      "ctrl+d"
    ];
    "tui.editor.deleteWordBackward" = [
      "ctrl+w"
      "alt+backspace"
      "ctrl+backspace"
      "super+alt+backspace"
    ];
    "tui.editor.deleteWordForward" = [
      "alt+delete"
      "alt+d"
      "super+alt+delete"
      "super+alt+d"
    ];
    "tui.editor.deleteToLineStart" = "ctrl+u";
    "tui.editor.deleteToLineEnd" = "ctrl+k";
    "tui.editor.yank" = "ctrl+y";
    "tui.editor.yankPop" = "alt+y";
    "tui.editor.undo" = [
      "ctrl+-"
      "ctrl+_"
    ];
    "tui.input.newLine" = [
      "shift+enter"
      "ctrl+j"
    ];
    "tui.input.submit" = "enter";
    "tui.input.tab" = "tab";
    "tui.input.copy" = "ctrl+c";
    "tui.select.up" = "up";
    "tui.select.down" = "down";
    "tui.select.pageUp" = "pageUp";
    "tui.select.pageDown" = "pageDown";
    "tui.select.confirm" = "enter";
    "tui.select.cancel" = [
      "escape"
      "ctrl+c"
    ];
    "app.interrupt" = "escape";
    "app.clear" = "ctrl+c";
    "app.exit" = "ctrl+d";
    "app.suspend" = "ctrl+z";
    # Upstream reassigned ctrl+l to app.live.toggle; display reset is alt+l.
    "app.display.reset" = "alt+l";
    "app.thinking.cycle" = "shift+tab";
    "app.thinking.toggle" = "ctrl+t";
    "app.model.cycleForward" = "ctrl+p";
    "app.model.cycleBackward" = "shift+ctrl+p";
    "app.model.select" = "alt+m";
    "app.model.selectTemporary" = "alt+p";
    "app.tools.expand" = "ctrl+o";
    "app.tools.toggleVisibility" = "ctrl+shift+o";
    "app.editor.external" = "ctrl+g";
    "app.message.followUp" = [
      "ctrl+q"
      "ctrl+enter"
    ];
    "app.retry" = "alt+r";
    # shift+up covers macOS Terminal.app, which consumes alt+up.
    "app.message.dequeue" = [
      "alt+up"
      "shift+up"
    ];
    # Upstream default is platform-dependent (Linux: ctrl+v; macOS adds super+v).
    "app.clipboard.pasteImage" = [ "ctrl+v" ];
    "app.clipboard.pasteTextRaw" = [
      "ctrl+shift+v"
      "alt+shift+v"
    ];
    "app.clipboard.copyLine" = "alt+shift+l";
    "app.clipboard.copyPrompt" = "alt+shift+c";
    "app.session.new" = [ ];
    "app.session.tree" = [ ];
    "app.session.fork" = [ ];
    "app.session.resume" = [ ];
    "app.agents.hub" = "alt+a";
    "app.session.observe" = "ctrl+s";
    "app.session.togglePath" = "ctrl+p";
    "app.session.toggleSort" = "ctrl+s";
    "app.session.rename" = "ctrl+r";
    "app.session.delete" = "ctrl+d";
    "app.session.deleteNoninvasive" = "ctrl+backspace";
    "app.tree.foldOrUp" = [
      "ctrl+left"
      "alt+left"
    ];
    "app.tree.unfoldOrDown" = [
      "ctrl+right"
      "alt+right"
    ];
    "app.plan.toggle" = "alt+shift+p";
    "app.history.search" = "ctrl+r";
    "app.stt.toggle" = [ ];
    "app.live.toggle" = "ctrl+l";
  };
}
