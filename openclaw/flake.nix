{
  # ============================================================================
  # GENERIC OPENCLAW HOME-MANAGER FLAKE
  # ============================================================================
  # This flake sets up OpenClaw (AI assistant gateway) with:
  #   - Moonshot AI (Kimi K2.5) as the primary LLM
  #   - Telegram bot integration
  #   - Browser automation (headless Chromium)
  #   - Web search (Perplexity) and speech-to-text (Deepgram)
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
      primaryModel = "moonshot/kimi-k2.5";

      # Browser CDP ports (defaults from OpenClaw docs)
      browserPort = 18800;        # openclaw-managed browser
      chromeServicePort = 18792;  # systemd-managed Chromium
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
            programs.starship = {
              enable = true;
              enableBashIntegration = true;
            };
            programs.bash.enable = true;  # Required for shell aliases

            # ── Headless Chromium systemd service ────────────────────────────
            # Runs Chromium in headless mode on a fixed port so OpenClaw
            # can connect via CDP. Auto-starts on login.
            systemd.user.services.claw-chrome = {
              Unit = {
                Description = "OpenClaw headless Chromium (CDP)";
                After = [ "network.target" ];
              };
              Service = {
                ExecStart = "${pkgs.chromium}/bin/chromium --headless=new --no-sandbox --disable-gpu --remote-debugging-port=${toString chromeServicePort} --remote-allow-origins=* --user-data-dir=%h/.openclaw/browser/chrome/user-data about:blank";
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
              inputs.beads.packages.${system}.beads


              # Browser and fonts (required for GUI apps in WSL2)
              pkgs.chromium
              pkgs.liberation_ttf
              pkgs.dejavu_fonts
              pkgs.noto-fonts

              # Editor and CLI tools (from unstable)
              pkgsUnstable.helix
              pkgsUnstable.bat
              pkgsUnstable.ripgrep
              pkgsUnstable.eza
              pkgsUnstable.fd

              # some core useful packages and libs
              pkgs.nixfmt
              pkgs.vtsls
              pkgs.nodejs
              pkgs.nodePackages_latest.bash-language-server
              pkgs.nodePackages_latest.prettier
              pkgs.bun
              pkgs.uv
              pkgs.deno
              pkgsUnstable.dolt

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

                # ── Agent model ────────────────────────────────────────────
                # Primary: Moonshot Kimi K2.5 (reads MOONSHOT_API_KEY from env)
                # Fallback: Same model (no secondary provider needed)
                agents.defaults.model = {
                  primary = primaryModel;
                  fallbacks = [ "minimax/MiniMax-M2.5" "zai/glm-5" ];
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

                  # Speech-to-text via Deepgram Nova-3
                  # Key: DEEPGRAM_API_KEY in ~/.secrets/openclaw-env
                  media.audio = {
                    enabled = true;
                    models = [{
                      provider = "deepgram";
                      model = "nova-3";
                    }];
                  };
                };

                # ── Browser automation ─────────────────────────────────────
                # Two profiles:
                #   1. openclaw: Gateway-managed browser (Playwright-compatible)
                #   2. chrome:   Connects to systemd service (always-on)
                browser = {
                  enabled = true;
                  headless = true;
                  noSandbox = true;  # Required for WSL2
                  defaultProfile = "openclaw";

                  # Gateway-managed browser (downloads Playwright Chromium)
                  profiles.openclaw = {
                    cdpPort = browserPort;
                    color = "#FF6B35";
                  };

                  # Connects to systemd-managed Chromium service
                  profiles.chrome = {
                    cdpUrl = "http://127.0.0.1:${toString chromeServicePort}";
                    color = "#4285F4";
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
#      MOONSHOT_API_KEY=sk-...         (https://platform.moonshot.ai/)
#      MINIMAX_API_KEY=sk-api-...      (https://platform.minimax.io/)
#      ZAI_API_KEY=...                 (https://z.ai/)
#      PERPLEXITY_API_KEY=pplx-...     (https://perplexity.ai/settings/api)
#      DEEPGRAM_API_KEY=...            (https://console.deepgram.com/)
#      PLAYWRIGHT_BROWSERS_PATH=...    (set to ~/.openclaw/playwright-browsers)
#
# 5. Lock down permissions:
#    chmod 600 ~/.secrets/*
#
# 6. Activate:
#    nix run home-manager/release-24.11 -- switch --impure --flake ~/.config/home-manager#$USER
#
# 7. Start services:
#    systemctl --user enable --now claw-chrome.service
#    systemctl --user restart openclaw-gateway
# ============================================================================
