# Default settings and keybindings for oh-my-pi.
# Generated from https://github.com/can1357/oh-my-pi defaults.
#
# schemaVersion marks the omp release these defaults were last reviewed
# against. flake.nix throws when it does not match the latest release, so
# every version bump forces a human review of the defaults (command-code
# convention). scripts/update-version.sh does NOT rewrite this file: it aborts
# until the review below has set schemaVersion to the new release.
#
# Coverage: every registry key with a concrete default is declared below.
# Keys whose upstream default is null (unset) or that are credentials are
# intentionally NOT declared; each such group carries a comment where its
# siblings are declared, plus the ledger near the end of defaultSettings.
{ }:
{
  schemaVersion = "18.4.2";

  defaultSettings = {
    advisor = {
      enabled = false;
      evictStaleResults = true;
      immuneTurns = 3;
      syncBacklog = "off";
    };
    ask = {
      notify = "on";
      timeout = 0;
    };
    autoResume = false;
    autocompleteMaxVisible = 10;
    browser = {
      cmux = true;
      enabled = true;
      freezeOnTurnEnd = true;
      headless = true;
      idleCloseSec = 1800;
      relay = false;
    };
    collab = {
      autoStart = "off";
      displayName = "";
      webUrl = "";
    };
    colorBlindMode = false;
    commit = {
      cacheEnabled = true;
      cacheTtlDays = 14;
      changelogMaxDiffChars = 120000;
      mapBatchTokenBudget = 16000;
      mapReduceEnabled = true;
      mapReduceThreshold = 5000;
    };
    completion = {
      notify = "on";
    };
    composer = {
      recallClearedDrafts = true;
      shape = "band";
      tokenRate = false;
    };
    display = {
      cacheMissMarker = false;
      collapseCompacted = true;
      hideToolActivity = false;
      pinnedAgents = "collapsed";
      shimmer = "classic";
      showTokenUsage = false;
      showTurnTime = false;
      smoothStreaming = true;
    };
    doubleEscapeAction = "rewind";
    emojiAutocomplete = true;
    error = {
      notify = "off";
    };
    exa = {
      enabled = true;
      searchDelayMs = 1000;
    };
    followUpMode = "one-at-a-time";
    gc = {
      archive = true;
      blobs = true;
      coldArchiveAfterDays = 30;
      retainNewestGlobal = 20;
      retainNewestPerCwd = 10;
      wal = true;
    };
    git = {
      enabled = true;
    };
    goal = {
      continuationModes = [
        "interactive"
      ];
      enabled = true;
      statusInFooter = true;
    };
    hindsight = {
      apiUrl = "http://localhost:8888";
      autoRecall = true;
      autoRetain = true;
      debug = false;
      mentalModelAutoSeed = true;
      mentalModelMaxRenderChars = 16000;
      mentalModelsEnabled = true;
      recallBudget = "mid";
      recallContextTurns = 1;
      recallMaxQueryChars = 800;
      recallMaxTokens = 1024;
      recallTimeoutMs = 30000;
      reflectTimeoutMs = 120000;
      requestTimeoutMs = 30000;
      retainContext = "omp";
      retainEveryNTurns = 3;
      retainMode = "full-session";
      retainOverlapTurns = 2;
      retainTimeoutMs = 60000;
      scoping = "per-project-tagged";
    };
    images = {
      autoResize = true;
      blockImages = false;
      urls = {
        bindHost = "127.0.0.1";
        enabled = false;
        sshRemotePort = 8787;
        ttlHours = 72;
      };
    };
    interruptMode = "immediate";
    loop = {
      conditionTimeoutMs = 30000;
      mode = "prompt";
    };
    magicKeywords = {
      enabled = true;
    };
    marketplace = {
      autoUpdate = "notify";
    };
    mcp = {
      enableProjectConfig = true;
      notificationDebounceMs = 500;
      notifications = false;
      renderMarkdownResults = true;
      startupTimeoutMs = 250;
    };
    memories = {
      enabled = false;
      fallbackTokenLimit = 16000;
      maxRawMemoriesForGlobal = 200;
      maxRolloutAgeDays = 30;
      maxRolloutsPerStartup = 64;
      minRolloutIdleHours = 12;
      phase1InputTokenLimit = 4000;
      phase2HeartbeatSeconds = 30;
      phase2LeaseSeconds = 180;
      phase2RetryDelaySeconds = 180;
      rolloutPayloadPercent = 0.7;
      stage1Concurrency = 8;
      stage1LeaseSeconds = 120;
      stage1RetryDelaySeconds = 120;
      summaryInjectionTokenLimit = 5000;
      threadScanLimit = 300;
    };
    memory = {
      backend = "off";
    };
    mnemopi = {
      autoRecall = true;
      autoRetain = true;
      debug = false;
      embeddingVariant = "en";
      enhancedRecall = false;
      injectionTokenLimit = 5000;
      llmMode = "smol";
      noEmbeddings = false;
      polyphonicRecall = false;
      proactiveLinking = false;
      recallContextTurns = 3;
      recallLimit = 8;
      recallMaxQueryChars = 4000;
      retainEveryNTurns = 4;
      scoping = "per-project";
    };
    paste = {
      largeMenuThreshold = 100;
    };
    plan = {
      autosave = false;
      defaultOnStartup = false;
      enabled = true;
    };
    recap = {
      enabled = true;
      idleSeconds = 240;
    };
    secrets = {
      enabled = false;
    };
    setupVersion = 0;
    share = {
      redactSecrets = true;
      store = "blob";
    };
    sharpshooter = {
      injectionTokenLimit = 15000;
      intervalMinutes = 5;
    };
    showHardwareCursor = true;
    speech = {
      enabled = false;
      enhanced = false;
      mode = "assistant";
    };
    spelling = {
      autocomplete = "auto";
      autocorrect = false;
      typoDetection = true;
    };
    startup = {
      changelogMode = "summary";
      checkUpdate = true;
      quiet = false;
      setupWizard = true;
      showSplash = false;
    };
    statusLine = {
      compactThinkingLevel = true;
      contextLine = "embedded";
      preset = "default";
      separator = "powerline-thin";
      sessionAccent = true;
      showHookStatus = true;
      transparent = false;
    };
    steeringMode = "one-at-a-time";
    stt = {
      enabled = false;
      language = "en";
      submitTrigger = "never";
    };
    symbolPreset = "unicode";
    telemetry = {
      otlpExportEnabled = true;
    };
    terminal = {
      showImages = true;
      showProgress = false;
    };
    theme = {
      dark = "titanium";
      light = "light";
    };
    title = {
      refreshOnReplan = true;
    };
    treeFilterMode = "default";
    ttsr = {
      builtinRules = true;
      contextMode = "discard";
      disabledRules = [ ];
      enabled = true;
      interruptMode = "always";
      judge = "auto";
      repeatGap = 10;
      repeatMode = "once";
    };
    tui = {
      codexResetFireworks = false;
      hyperlinks = "auto";
      imeSafeCursor = false;
      maxInlineImageColumns = 100;
      maxInlineImageRows = 20;
      maxInlineImages = 8;
      mouse = false;
      reactions = true;
      renderMermaid = true;
      resizeScrollback = "rebuild";
      textSizing = false;
      tight = false;
      titleSpinner = "braille";
      titleState = true;
      vimMode = false;
      vimModeDisplay = "text";
    };
    update = {
      channel = "stable";
    };
  };

  defaultKeybindings = {
    "app.agents.hub" = "alt+a";
    "app.clear" = "ctrl+c";
    "app.clipboard.copyLine" = "alt+shift+l";
    "app.clipboard.copyPrompt" = "alt+shift+c";
    "app.clipboard.pasteImage" = [
      "ctrl+v"
    ];
    "app.clipboard.pasteTextRaw" = [
      "ctrl+shift+v"
      "alt+shift+v"
    ];
    "app.display.reset" = "alt+l";
    "app.editor.external" = "ctrl+g";
    "app.exit" = "ctrl+d";
    "app.history.search" = "ctrl+r";
    "app.interrupt" = "escape";
    "app.live.toggle" = "ctrl+l";
    "app.message.dequeue" = [
      "alt+up"
      "shift+up"
    ];
    "app.message.followUp" = [
      "ctrl+q"
      "ctrl+enter"
    ];
    "app.model.cycleBackward" = "shift+ctrl+p";
    "app.model.cycleForward" = "ctrl+p";
    "app.model.select" = "alt+m";
    "app.model.selectTemporary" = "alt+p";
    "app.plan.toggle" = "alt+shift+p";
    "app.retry" = "alt+r";
    "app.session.delete" = "ctrl+d";
    "app.session.deleteNoninvasive" = "ctrl+backspace";
    "app.session.fork" = [ ];
    "app.session.new" = [ ];
    "app.session.observe" = "ctrl+s";
    "app.session.rename" = "ctrl+r";
    "app.session.resume" = [ ];
    "app.session.togglePath" = "ctrl+p";
    "app.session.toggleSort" = "ctrl+s";
    "app.session.tree" = [ ];
    "app.stt.toggle" = [ ];
    "app.suspend" = "ctrl+z";
    "app.thinking.cycle" = "shift+tab";
    "app.thinking.toggle" = "ctrl+t";
    "app.tools.expand" = "ctrl+o";
    "app.tools.toggleVisibility" = "ctrl+shift+o";
    "app.tree.foldOrUp" = [
      "ctrl+left"
      "alt+left"
    ];
    "app.tree.unfoldOrDown" = [
      "ctrl+right"
      "alt+right"
    ];
    "tui.editor.cursorDown" = "down";
    "tui.editor.cursorLeft" = [
      "left"
      "ctrl+b"
    ];
    "tui.editor.cursorLineEnd" = [
      "end"
      "ctrl+e"
    ];
    "tui.editor.cursorLineStart" = [
      "home"
      "ctrl+a"
    ];
    "tui.editor.cursorRight" = [
      "right"
      "ctrl+f"
    ];
    "tui.editor.cursorUp" = "up";
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
    "tui.editor.deleteCharBackward" = "backspace";
    "tui.editor.deleteCharForward" = [
      "delete"
      "ctrl+d"
    ];
    "tui.editor.deleteToLineEnd" = "ctrl+k";
    "tui.editor.deleteToLineStart" = "ctrl+u";
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
    "tui.editor.jumpBackward" = "ctrl+alt+]";
    "tui.editor.jumpForward" = "ctrl+]";
    "tui.editor.pageDown" = "pageDown";
    "tui.editor.pageUp" = "pageUp";
    "tui.editor.undo" = [
      "ctrl+-"
      "ctrl+_"
    ];
    "tui.editor.yank" = "ctrl+y";
    "tui.editor.yankPop" = "alt+y";
    "tui.input.copy" = "ctrl+c";
    "tui.input.newLine" = [
      "shift+enter"
      "ctrl+j"
    ];
    "tui.input.submit" = "enter";
    "tui.input.tab" = "tab";
    "tui.select.cancel" = [
      "escape"
      "ctrl+c"
    ];
    "tui.select.confirm" = "enter";
    "tui.select.down" = "down";
    "tui.select.pageDown" = "pageDown";
    "tui.select.pageUp" = "pageUp";
    "tui.select.up" = "up";
  };
}
