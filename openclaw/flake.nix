{
  # ============================================================================
  # GENERIC OPENCLAW HOME-MANAGER FLAKE
  # ============================================================================
  # This flake sets up OpenClaw (AI assistant gateway) with:
  #   - OpenAI GPT-5.2 as the primary LLM
  #   - Fallback providers: MiniMax M2.5, Moonshot Kimi K2.5, Z.AI GLM-5
  #   - Telegram bot integration
  #   - Browser automation (headless Chromium + extension relay)
  #   - Web search (Perplexity Sonar Reasoning Pro)
  #   - Speech-to-text (OpenAI Whisper)
  #   - QMD memory backend for local semantic search (BM25 + vector + rerank)
  #
  # SECURITY: All API keys live in ~/.secrets/ files (never in this flake)
  # ============================================================================

  description = "Generic OpenClaw Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    home-manager.url = "github:nix-community/home-manager/release-24.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-openclaw.url = "github:openclaw/nix-openclaw";
    claude-code.url = "git+https://github.com/da-moon/flakes.git?dir=claude-code";
    codex.url = "git+https://github.com/da-moon/flakes.git?dir=codex";
    beads.url = "git+https://github.com/da-moon/flakes.git?dir=beads";
    qmd.url = "git+https://github.com/da-moon/flakes.git?dir=qmd";
  };

  outputs = { self, ... }@inputs:
    let
      inherit (inputs) nixpkgs nixpkgs-unstable home-manager;

      system = builtins.currentSystem;
      user = builtins.getEnv "USER";

      pkgs = import nixpkgs { inherit system; };
      pkgsUnstable = import nixpkgs-unstable { inherit system; };

      # ── SECRETS (read from ~/.secrets/ — never hardcode in this flake) ────────
      #
      # Gateway token: a random hex string used for local IPC between the
      # gateway and its clients. Generate your own with: openssl rand -hex 32
      # Then write it to ~/.secrets/gateway-token
      gatewayToken = builtins.readFile "/home/${user}/.secrets/gateway-token";

      # Telegram user ID: your numeric Telegram account ID.
      # Find it by messaging @userinfobot on Telegram.
      # Write the number (digits only) to ~/.secrets/telegram-user-id
      telegramUserId =
        builtins.fromJSON (builtins.readFile "/home/${user}/.secrets/telegram-user-id");

      # ── CONFIGURATION ─────────────────────────────────────────────────────────
      # Primary model for the agent (provider/model-id)
      primaryModel = "openai/gpt-5.2";

      # Browser CDP port for the headless claw-chrome systemd service
      # 18792 is reserved for the extension relay (gateway port + 3)
      chromeServicePort = 18793;
      # ───────────────────────────────────────────────────────────────────────────

      mkHome = username: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [

          # ── OpenClaw Home-Manager module ────────────────────────────────────
          inputs.nix-openclaw.homeManagerModules.openclaw

          
          # ── Systemd service configuration ───────────────────────────────────
          # Loads all API keys from ~/.secrets/openclaw-env
          # Create this file with: MOONSHOT_API_KEY=sk-...
          ({ lib, ... }: {
            systemd.user.services.openclaw-gateway = {
              Install.WantedBy = [ "default.target" ];
              Service = {
                # Load API keys from env file (keeps secrets out of flake)
                EnvironmentFile = "/home/${username}/.secrets/openclaw-env";
                # Expose tools the gateway spawns
                Environment = [
                  "PATH=${pkgs.lib.makeBinPath [
                    inputs.qmd.packages.${system}.qmd
                    pkgs.sqlite
                    pkgs.coreutils
                    pkgs.bash
                  ]}:/usr/bin:/bin"
                ];
                # Log output to file for debugging
                StandardOutput = lib.mkForce "append:/home/${username}/.openclaw/logs/openclaw-gateway.log";
                StandardError = lib.mkForce "append:/home/${username}/.openclaw/logs/openclaw-gateway.log";
              };
            };
          })

          # ── Main user environment ───────────────────────────────────────────
          {
            home.username = username;
            home.homeDirectory = "/home/${username}";
            home.stateVersion = "24.11";
            programs.home-manager.enable = true;

            # ── Chromium browser ──────────────────────────────────────────────
            # Pre-installs the OpenClaw Browser Relay extension for
            # controlling your local Chrome via CDP.
            programs.chromium = {
              enable = true;
              extensions = [
                { id = "nglingapjinhecnfejdcpihlpneeadjp"; }  # OpenClaw Browser Relay
              ];
            };

            # ── Shell setup ───────────────────────────────────────────────────
            programs.bash.enable = true;  # Required for shell aliases

            # ── Zoxide (smarter cd) ─────────────────────────────────────────
            programs.zoxide = {
              enable = true;
              enableBashIntegration = true;
            };

            # ── Atuin (shell history) ───────────────────────────────────────
            programs.atuin = {
              enable = true;
              enableBashIntegration = true;
              settings = {
                search_mode = "fuzzy";
                filter_mode = "global";
                style = "compact";
                show_preview = true;
                max_preview_height = 4;
                show_help = true;
                inline_height = 20;
                auto_sync = false;
              };
            };

            # ── fzf (fuzzy finder) ──────────────────────────────────────────
            programs.fzf = {
              enable = true;
              enableBashIntegration = true;
            };

            # ── Starship (prompt) ───────────────────────────────────────────
            programs.starship = {
              enable = true;
              enableBashIntegration = true;
            };

            # ── Headless Chromium systemd service ────────────────────────────
            # Runs Playwright's own Chromium (revision 1208) for full
            # Playwright connectOverCDP compatibility (snapshot, actions).
            # The Playwright binary needs FHS libs, provided via LD_LIBRARY_PATH
            # from Nix packages. If Playwright Chromium is missing, install:
            #   PLAYWRIGHT_BROWSERS_PATH=~/.openclaw/playwright-browsers \
            #     npx playwright install chromium
            systemd.user.services.claw-chrome = let
              playwrightChromiumLibs = pkgs.lib.makeLibraryPath [
                pkgs.nspr pkgs.nss pkgs.atk pkgs.at-spi2-atk
                pkgs.cups.lib pkgs.libxkbcommon pkgs.libdrm pkgs.mesa
                pkgs.alsa-lib pkgs.pango pkgs.cairo pkgs.fontconfig.lib
                pkgs.freetype pkgs.harfbuzz
                pkgs.xorg.libX11 pkgs.xorg.libXcomposite pkgs.xorg.libXdamage
                pkgs.xorg.libXext pkgs.xorg.libXfixes pkgs.xorg.libXrandr
                pkgs.xorg.libxcb pkgs.dbus.lib pkgs.glib pkgs.expat
              ];
              fontsConf = pkgs.makeFontsConf {
                fontDirectories = [
                  pkgs.liberation_ttf pkgs.dejavu_fonts pkgs.noto-fonts
                ];
              };
              playwrightChromium = pkgs.writeShellScript "playwright-chromium" ''
                export LD_LIBRARY_PATH="${playwrightChromiumLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                export FONTCONFIG_FILE="${fontsConf}"
                exec /home/${username}/.openclaw/playwright-browsers/chromium-1208/chrome-linux64/chrome "$@"
              '';
            in {
              Unit = {
                Description = "OpenClaw headless Chromium (CDP)";
                After = [ "network.target" ];
              };
              Service = {
                ExecStart = "${playwrightChromium} --headless=new --no-sandbox --disable-gpu --remote-debugging-port=${toString chromeServicePort} --remote-allow-origins=* --user-data-dir=%h/.openclaw/browser/chrome/user-data about:blank";
                Restart = "on-failure";
                RestartSec = "5s";
              };
              Install = {
                WantedBy = [ "default.target" ];
              };
            };

            # ── User packages ────────────────────────────────────────────────
            home.packages = [
              # custom flakes
              inputs.claude-code.packages.${system}.claude-code
              inputs.codex.packages.${system}.codex

              # Core Packages
              pkgs.which
              pkgs.unzip
              
              
              # Editor and CLI tools (from unstable)
              pkgsUnstable.helix
              pkgsUnstable.bat
              pkgsUnstable.ripgrep
              pkgsUnstable.eza
              pkgsUnstable.fd

              # some core useful packages and libs
              pkgsUnstable.nixfmt
              pkgsUnstable.vtsls
              pkgsUnstable.nodejs
              pkgsUnstable.nodePackages_latest.bash-language-server
              pkgsUnstable.nodePackages_latest.prettier
              pkgsUnstable.bun
              pkgsUnstable.uv
              pkgsUnstable.deno

              # Beads memory system
              inputs.beads.packages.${system}.beads
              pkgsUnstable.dolt

              # Browser and fonts (required for GUI apps in WSL2)
              pkgs.chromium
              pkgs.liberation_ttf
              pkgs.dejavu_fonts
              pkgs.noto-fonts

              # QMD — local semantic search for the memory backend
              # Wraps Bun + node-llama-cpp with Nix-compatible LD_LIBRARY_PATH
              inputs.qmd.packages.${system}.qmd
              pkgs.sqlite  # Required by QMD for index storage
              
            ];

            # ── OPENCLAW CONFIGURATION ───────────────────────────────────────
            programs.openclaw = {
              enable = true;
              package = pkgs.lib.lowPrio inputs.nix-openclaw.packages.${system}.openclaw;
              
              config = {
                # ── Gateway ─────────────────────────────────────────────────
                # Local mode = gateway runs on localhost, no external exposure
                gateway = {
                  mode = "local";
                  auth.token = gatewayToken;
                };

                # ── Telegram bot ────────────────────────────────────────────
                # 1. Create bot via @BotFather, get token
                # 2. Put token in ~/.secrets/telegram-bot-token
                # 3. Find your user ID via @userinfobot
                channels.telegram = {
                  accounts.default.tokenFile = "/home/${username}/.secrets/telegram-bot-token";
                  allowFrom = [ telegramUserId ];
                  groups."*".requireMention = true;  # Require @botname in groups
                };

                # ── Agent model ──────────────────────────────────────────────
                # Primary: OpenAI GPT-5.2 (API key from OPENAI_API_KEY)
                # Fallback: MiniMax M2.5, Kimi K2.5, GLM-5
                agents.defaults.model = {
                  primary = primaryModel;
                  fallbacks = [ "minimax/MiniMax-M2.5" "moonshot/kimi-k2.5" "zai/glm-5" ];
                };

                # ── Session compaction ─────────────────────────────────────
                # Prevents context window timeouts by summarizing older history
                agents.defaults.compaction = {
                  reserveTokens = 8000;        # Reserve for model output
                  reserveTokensFloor = 16000;  # Lower floor = more aggressive compaction
                  keepRecentTokens = 4000;     # Preserve recent context
                  mode = "safeguard";          # Chunked summarization for reliability
                  memoryFlush = {
                    enabled = true;
                    softThresholdTokens = 6000;
                  };
                };

                # ── Memory (QMD backend) ──────────────────────────────────
                # QMD is a local-first search sidecar combining BM25 full-text
                # search, vector embeddings, and reranking. It keeps Markdown
                # files as the source of truth and auto-downloads GGUF models
                # from HuggingFace on first use (~2.2GB total):
                #   - embeddinggemma-300M  (~329MB) — embeddings
                #   - qmd-query-expansion  (~1.3GB) — query expansion
                #   - qwen3-reranker-0.6B  (~639MB) — reranking
                #
                # The gateway manages QMD automatically:
                #   - Indexes MEMORY.md + memory/**/*.md from the workspace
                #   - Runs `qmd update` + `qmd embed` on boot and every 5 min
                #   - Falls back to builtin SQLite if QMD fails
                #
                # To warm the index manually (pre-download models):
                #   STATE_DIR="${"$"}{OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
                #   export XDG_CONFIG_HOME="$STATE_DIR/agents/main/qmd/xdg-config"
                #   export XDG_CACHE_HOME="$STATE_DIR/agents/main/qmd/xdg-cache"
                #   qmd update && qmd embed
                #   qmd query "test" -c memory-root-main --json
                memory = {
                  backend = "qmd";
                  citations = "auto";
                  qmd = {
                    includeDefaultMemory = true;
                    searchMode = "query";  # Uses reranker + query expansion
                    update = {
                      interval = "5m";
                      debounceMs = 15000;
                      onBoot = true;
                      waitForBootSync = false;  # Non-blocking boot sync
                    };
                    limits = {
                      maxResults = 6;
                      maxSnippetChars = 2000;
                      timeoutMs = 30000;  # First query loads ~2.2GB of GGUF models
                    };
                    scope = {
                      default = "deny";  # Only enable for DMs (not group chats)
                      rules = [
                        { action = "allow"; match = { chatType = "direct"; }; }
                      ];
                    };
                  };
                };

                # ── LLM Providers ─────────────────────────────────────────
                # API keys are loaded from env vars via ~/.secrets/openclaw-env
                # (injected by the systemd EnvironmentFile directive above).
                # Pattern: <PROVIDER_UPPER>_API_KEY (e.g. MOONSHOT_API_KEY)
                models = {
                  mode = "merge";
                  providers = {
                    # Moonshot AI (Kimi K2.5) — OpenAI-compatible API
                    # Key: MOONSHOT_API_KEY in ~/.secrets/openclaw-env
                    moonshot = {
                      baseUrl = "https://api.moonshot.ai/v1";
                      api = "openai-completions";
                      auth = "api-key";
                      models = [{
                        id = "kimi-k2.5";
                        name = "Kimi K2.5";
                        contextWindow = 262144;
                        maxTokens = 8192;
                      }];
                    };

                    # MiniMax M2.5 — Anthropic-compatible API
                    # Key: MINIMAX_API_KEY in ~/.secrets/openclaw-env
                    minimax = {
                      baseUrl = "https://api.minimax.io/anthropic";
                      api = "anthropic-messages";
                      auth = "api-key";
                      models = [{
                        id = "MiniMax-M2.5";
                        name = "MiniMax M2.5";
                        contextWindow = 200000;
                        maxTokens = 8192;
                      }];
                    };

                    # Z.AI GLM-5 — OpenAI-compatible API
                    # Key: ZAI_API_KEY in ~/.secrets/openclaw-env
                    zai = {
                      baseUrl = "https://api.z.ai/api/paas/v4";
                      api = "openai-completions";
                      auth = "api-key";
                      models = [{
                        id = "glm-5";
                        name = "GLM-5";
                        contextWindow = 200000;
                        maxTokens = 128000;
                      }];
                    };

                    # OpenAI GPT-5 — OpenAI Responses API
                    # Key: OPENAI_API_KEY in ~/.secrets/openclaw-env
                    openai = {
                      baseUrl = "https://api.openai.com/v1";
                      api = "openai-responses";
                      auth = "api-key";
                      models = [{
                        id = "gpt-5.2";
                        name = "gpt-5.2";
                        contextWindow = 200000;
                        maxTokens = 128000;
                      }];
                    };
                  };
                };

                # ── Tools ──────────────────────────────────────────────────
                tools = {
                  # Full tool access for the agent
                  profile = "full";
                  
                  # Only allow elevated commands from your Telegram account
                  elevated = {
                    enabled = true;
                    allowFrom.telegram = [ telegramUserId ];
                  };
                  
                  # Shell execution with full access (trusted single-user setup)
                  exec.security = "full";

                  # Web search via Perplexity — Sonar Reasoning Pro
                  # Key: PERPLEXITY_API_KEY in ~/.secrets/openclaw-env
                  web.search = {
                    enabled = true;
                    provider = "perplexity";
                    perplexity = {
                      baseUrl = "https://api.perplexity.ai";
                      model = "perplexity/sonar-reasoning-pro";
                    };
                  };

                  # Speech-to-text via OpenAI Whisper
                  # Uses OPENAI_API_KEY (same as the LLM provider)
                  media.audio = {
                    enabled = true;
                    models = [{
                      provider = "openai";
                      model = "whisper-1";
                    }];
                  };
                };

                # ── Browser automation ─────────────────────────────────────
                # Two profiles:
                #   1. chrome:   Connects to claw-chrome systemd service (headless)
                #   2. openclaw: Extension relay — attach visible Chromium tabs
                #                via the OpenClaw Browser Relay extension (WSLg)
                browser = {
                  enabled = true;
                  headless = true;
                  noSandbox = true;  # Required for WSL2
                  defaultProfile = "chrome";  # Uses systemd-managed claw-chrome service
                  # Use Nix-managed Chromium (Playwright's own binary can't run
                  # in Nix due to missing FHS libs — exit 127)
                  executablePath = "${pkgs.chromium}/bin/chromium";

                  # Connects to systemd-managed Chromium service (headless)
                  profiles.chrome = {
                    cdpUrl = "http://127.0.0.1:${toString chromeServicePort}";
                    color = "#4285F4";
                  };

                  # Extension relay on 18792 (gateway + 3)
                  # Attach visible Chromium tabs via Browser Relay extension
                  profiles.openclaw = {
                    driver = "extension";
                    cdpUrl = "http://127.0.0.1:18792";
                    color = "#FF6B35";
                  };
                };
              };
            };
          }
        ];
      };
    in {
      homeConfigurations."${user}" = mkHome user;
    };
}
# ============================================================================
# ONBOARDING — create these files before first activation
# ============================================================================
#
# All files must be chmod 600 and live under ~/.secrets/.
#
# 1. ~/.secrets/gateway-token
#    A random hex string for local gateway IPC auth.
#    Generate: openssl rand -hex 32 > ~/.secrets/gateway-token
#
# 2. ~/.secrets/telegram-bot-token
#    Your Telegram bot token (plain text, no newline).
#    Get one: message @BotFather on Telegram → /newbot → copy token
#    Write:   echo -n 'YOUR_TOKEN' > ~/.secrets/telegram-bot-token
#
# 3. ~/.secrets/telegram-user-id
#    Your numeric Telegram user ID (digits only, no newline).
#    Find it: message @userinfobot on Telegram → copy the "Id" number
#    Write:   echo -n '12345678' > ~/.secrets/telegram-user-id
#
# 4. ~/.secrets/openclaw-env
#    All API keys as KEY=VALUE lines (see the file for onboarding links):
#      ANTHROPIC_API_KEY=sk-ant-...    (https://console.anthropic.com/)
#      OPENAI_API_KEY=sk-...           (https://platform.openai.com/api-keys)
#      MOONSHOT_API_KEY=sk-...         (https://platform.moonshot.ai/)
#      MINIMAX_API_KEY=sk-api-...      (https://platform.minimax.io/)
#      ZAI_API_KEY=...                 (https://z.ai/)
#      PERPLEXITY_API_KEY=pplx-...     (https://perplexity.ai/settings/api)
#      PLAYWRIGHT_BROWSERS_PATH=...    (set to ~/.openclaw/playwright-browsers)
#
# 5. Lock down permissions:
#    chmod 600 ~/.secrets/*
#
# 6. Activate:
#    nix run home-manager/release-24.11 -- switch --impure --flake ~/.config/home-manager#$USER
#
# 7. Install Playwright Chromium (required for browser automation):
#    PLAYWRIGHT_BROWSERS_PATH=~/.openclaw/playwright-browsers \
#      npx playwright install chromium
#
# 8. Start services:
#    systemctl --user enable --now claw-chrome.service
#    systemctl --user restart openclaw-gateway
#
# 9. Warm QMD index (optional — downloads ~2.2GB of GGUF models):
#    The gateway warms models automatically on first memory_search,
#    but you can pre-download to avoid delays:
#      STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
#      export XDG_CONFIG_HOME="$STATE_DIR/agents/main/qmd/xdg-config"
#      export XDG_CACHE_HOME="$STATE_DIR/agents/main/qmd/xdg-cache"
#      qmd update && qmd embed
#      qmd query "test" -c memory-root-main --json
#
# PORT LAYOUT
#   18789  Gateway WebSocket
#   18791  Browser control (CDP proxy)
#   18792  Extension relay (gateway + 3, HMAC auth)
#   18793  Headless Chromium CDP (claw-chrome systemd service)
# ============================================================================
