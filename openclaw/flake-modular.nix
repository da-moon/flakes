{
  # ============================================================================
  # HOME-MANAGER FLAKE
  # ============================================================================
  # Base dev environment + optional OpenClaw integration.
  # To disable OpenClaw, comment out the openclaw module entry in the
  # modules list below (search for "OPENCLAW MODULE").
  #
  # SECURITY: All API keys live in ~/.secrets/ files (never in this flake)
  # ============================================================================

  description = "Home Manager configuration";

  inputs = {
    # ── Base ──────────────────────────────────────────────────────────────
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    home-manager.url = "github:nix-community/home-manager/release-24.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    claude-code.url = "git+https://github.com/da-moon/flakes.git?dir=claude-code";
    codex.url = "git+https://github.com/da-moon/flakes.git?dir=codex";

    # ── OpenClaw ──────────────────────────────────────────────────────────
    beads.url = "git+https://github.com/da-moon/flakes.git?dir=beads";
    qmd.url = "git+https://github.com/da-moon/flakes.git?dir=qmd";
    nix-openclaw.url = "github:openclaw/nix-openclaw";
  };

  outputs = { self, ... }@inputs:
    let
      inherit (inputs) nixpkgs nixpkgs-unstable home-manager;

      system = builtins.currentSystem;
      user = builtins.getEnv "USER";

      pkgs = import nixpkgs { inherit system; };
      pkgsUnstable = import nixpkgs-unstable { inherit system; };

      # ── Secret file helpers ─────────────────────────────────────────────
      # readSecretOpt: reads file content (trimmed), or null if missing
      readSecretOpt = path:
        if builtins.pathExists path
        then builtins.replaceStrings ["\n" "\r"] ["" ""]
          (builtins.readFile path)
        else null;

      # assertSecret: throws a helpful error if a required secret file is missing
      assertSecret = name: path:
        if builtins.pathExists path then true
        else builtins.throw ''

          ══════════════════════════════════════════════════════════════
           Missing required secret: ${path}

           Secret "${name}" is required for OpenClaw to function.
           See the ONBOARDING section at the bottom of flake.nix
           for instructions on creating this file.
          ══════════════════════════════════════════════════════════════
        '';

      # ── Home configuration builder ─────────────────────────────────────
      mkHome = username: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [

          # ══════════════════════════════════════════════════════════════
          # BASE MODULE
          # Generic dev environment — works standalone without OpenClaw
          # ══════════════════════════════════════════════════════════════
          {
            home.username = username;
            home.homeDirectory = "/home/${username}";
            home.stateVersion = "24.11";
            programs.home-manager.enable = true;

            # ── Base packages ──────────────────────────────────────────
            home.packages = [
              # Custom flakes
              inputs.claude-code.packages.${system}.claude-code
              inputs.codex.packages.${system}.codex

              # Core
              pkgs.git
              pkgs.which
              pkgs.unzip

              # Editor and CLI tools (from unstable)
              pkgsUnstable.helix
              pkgsUnstable.bat
              pkgsUnstable.ripgrep
              pkgsUnstable.eza
              pkgsUnstable.fd
              pkgsUnstable.diffutils
              pkgsUnstable.difftastic
              pkgsUnstable.delta

              # Dev tools
              pkgsUnstable.nixfmt
              pkgsUnstable.vtsls
              pkgsUnstable.nodejs
              pkgsUnstable.nodePackages_latest.bash-language-server
              pkgsUnstable.nodePackages_latest.prettier
              pkgsUnstable.bun
              pkgsUnstable.uv
              pkgsUnstable.deno

              # Browser and fonts (required for GUI apps in WSL2)
              pkgs.chromium
              pkgs.liberation_ttf
              pkgs.dejavu_fonts
              pkgs.noto-fonts
            ];

            # ── Chromium browser ───────────────────────────────────────
            programs.chromium.enable = true;

            # ── Environment variables ──────────────────────────────────
            home.sessionVariables = {
              EDITOR = "hx";
            };

            # ── Shell setup ────────────────────────────────────────────
            programs.bash.enable = true;

            # ── Zoxide (smarter cd) ────────────────────────────────────
            programs.zoxide = {
              enable = true;
              enableBashIntegration = true;
            };

            # ── Atuin (shell history) ──────────────────────────────────
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

            # ── fzf (fuzzy finder) ─────────────────────────────────────
            programs.fzf = {
              enable = true;
              enableBashIntegration = true;
            };

            # ── Starship (prompt) ──────────────────────────────────────
            programs.starship = {
              enable = true;
              enableBashIntegration = true;
            };

            # ── Syncthing (file sync) ──────────────────────────────────
            # Shares files with other devices.
            # Web UI: http://127.0.0.1:8384
            services.syncthing.enable = true;
          }

          # ══════════════════════════════════════════════════════════════
          # OPENCLAW MODULE
          # ══════════════════════════════════════════════════════════════
          # OpenClaw AI assistant gateway integration with:
          #   - Moonshot Kimi K2.5 as the primary LLM
          #   - Fallback providers: OpenAI GPT-5.2, MiniMax M2.5, Z.AI GLM-5, Anthropic Claude Sonnet 4.6
          #   - Telegram bot integration
          #   - Browser automation (headless Chromium + extension relay)
          #   - Web search (Perplexity Sonar Reasoning Pro)
          #   - Speech-to-text (OpenAI Whisper)
          #   - Configurable memory backend (voyage, qmd, openai, ollama, local, builtin)
          #   - Tailscale integration (serve/funnel/off) for remote access
          #   - Workspace directory scaffolding via systemd-tmpfiles (memory/cron/)
          #   - Syncthing introducer configuration for workspace sharing across devices
          #
          # Comment out this entire block (from the opening parenthesis
          # below to its matching closing parenthesis) to run a
          # base-only environment.
          # ══════════════════════════════════════════════════════════════

          inputs.nix-openclaw.homeManagerModules.openclaw

          ({ lib, ... }:
            let
              # ── Required secrets validation ──────────────────────────
              # Gateway token + password are in ~/.secrets/openclaw-env as env vars:
              #   OPENCLAW_GATEWAY_TOKEN=...   (loaded at runtime by systemd EnvironmentFile)
              #   OPENCLAW_GATEWAY_PASSWORD=... (used for funnel mode)

              # ── OpenClaw configuration ───────────────────────────────
              # Primary model for the agent (provider/model-id)
              primaryModel = "moonshot/kimi-k2.5";
              fallbackModels = [ "openai/gpt-5.2" "minimax/MiniMax-M2.5" "zai/glm-5" "anthropic/claude-sonnet-4-6" ];

              # Memory backend for semantic search.
              # Options: "qmd" (local BM25+vector), "voyage", "openai", "ollama", "local", "builtin"
              memoryBackend = "voyage";
              isQmd = memoryBackend == "qmd";

              # Browser CDP port for the headless claw-chrome systemd service
              chromeServicePort = 18793;
              # Extension relay port for the OpenClaw Browser Relay extension
              extensionRelayPort = 18792;

              # Tailscale integration mode for the OpenClaw gateway.
              # "serve"  = tailnet-only HTTPS (tailscale serve), allows Tailscale identity auth
              # "funnel" = public HTTPS (tailscale funnel), requires OPENCLAW_GATEWAY_PASSWORD
              # "off"    = no tailscale, local-only
              tailscaleMode = "off";  # "serve" | "funnel" | "off"
              isTailscale = tailscaleMode != "off";

              # Telegram user ID: your numeric Telegram account ID.
              # Find it by messaging @userinfobot on Telegram.
              # Write the number (digits only) to ~/.secrets/telegram-user-id
              telegramUserId =
                builtins.fromJSON (builtins.readFile "/home/${user}/.secrets/telegram-user-id");

              # Syncthing introducer device ID (cloud VPS).
              # Write: echo -n 'SL7MZ7U-...' > ~/.secrets/syncthing-introducer-id
              # Optional: if the file is missing, Syncthing starts without an introducer.
              syncthingIntroducerId = readSecretOpt "/home/${username}/.secrets/syncthing-introducer-id";

              # ── Tailscale helpers (userspace networking on WSL2) ─────
              tailscaleSocket = "/home/${username}/.local/share/tailscale/tailscaled.sock";
              tailscaleWrapped = pkgs.writeShellScriptBin "tailscale" ''
                exec ${pkgs.tailscale}/bin/tailscale --socket="${tailscaleSocket}" "$@"
              '';

              # ── Playwright Chromium helpers for claw-chrome service ──
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
            in
            # Fail fast with a helpful message if the secrets file is missing
            assert assertSecret "openclaw-env" "/home/${username}/.secrets/openclaw-env";
            {
              # ── OpenClaw packages ────────────────────────────────────
              home.packages = [
                # Beads memory system
                inputs.beads.packages.${system}.beads
                pkgsUnstable.dolt
              ] ++ (pkgs.lib.optionals isTailscale [
                # Tailscale — VPN mesh for serve/funnel + general tailnet access
                pkgs.tailscale
              ]) ++ (pkgs.lib.optionals isQmd [
                # QMD — local semantic search for the memory backend
                # Wraps Bun + node-llama-cpp with Nix-compatible LD_LIBRARY_PATH
                inputs.qmd.packages.${system}.qmd
                pkgs.sqlite  # Required by QMD for index storage
              ]);

              # ── OpenClaw Browser Relay extension ─────────────────────
              # Pre-installs the OpenClaw Browser Relay extension for
              # controlling your local Chrome via CDP.
              programs.chromium.extensions = [
                { id = "nglingapjinhecnfejdcpihlpneeadjp"; }  # OpenClaw Browser Relay
              ];

              # ── Workspace directory scaffolding ──────────────────────
              # The openclaw agent's edit tool cannot create parent directories.
              # Use systemd-tmpfiles to ensure workspace subdirectories exist
              # before the agent needs them.
              #
              # Safety: the "d" type with "-" (no Age) only creates directories
              # if missing — it NEVER deletes or cleans existing content.
              # See tmpfiles.d(5), Type "d".
              home.file.".config/user-tmpfiles.d/openclaw-workspace.conf".text = ''
                # OpenClaw workspace subdirectories (created if missing, never cleaned)
                # Format: Type Path Mode User Group Age Argument
                d /home/${username}/.openclaw/workspace/memory       0755 - - - -
                d /home/${username}/.openclaw/workspace/memory/cron   0755 - - - -
              '';

              # ── OpenClaw systemd services ────────────────────────────
              systemd.user.services = {
                # Workspace directory scaffolding via systemd-tmpfiles
                openclaw-tmpfiles-setup = {
                  Unit.Description = "Create OpenClaw workspace directories";
                  Service = {
                    Type = "oneshot";
                    ExecStart = "${pkgs.systemd}/bin/systemd-tmpfiles --user --create";
                    RemainAfterExit = true;
                  };
                  Install.WantedBy = [ "default.target" ];
                };

                # Headless Chromium for CDP (uses Playwright's own binary)
                # Requires: PLAYWRIGHT_BROWSERS_PATH=~/.openclaw/playwright-browsers npx playwright install chromium
                claw-chrome = {
                  Unit = {
                    Description = "OpenClaw headless Chromium (CDP)";
                    After = [ "network.target" ];
                  };
                  Service = {
                    ExecStart = "${playwrightChromium} --headless=new --no-sandbox --disable-gpu --remote-debugging-port=${toString chromeServicePort} --remote-allow-origins=* --user-data-dir=%h/.openclaw/browser/chrome/user-data about:blank";
                    Restart = "on-failure";
                    RestartSec = "5s";
                  };
                  Install.WantedBy = [ "default.target" ];
                };

                # ── OpenClaw Gateway ───────────────────────────────────
                # Loads all API keys from ~/.secrets/openclaw-env
                # Create this file with: MOONSHOT_API_KEY=sk-...
                openclaw-gateway = {
                  Unit = lib.mkIf isTailscale {
                    After = lib.mkForce [ "tailscale-auth.service" ];
                    Wants = [ "tailscale-auth.service" ];
                  };
                  Install.WantedBy = [ "default.target" ];
                  Service = {
                    # Load API keys from env file (keeps secrets out of flake)
                    EnvironmentFile = "/home/${username}/.secrets/openclaw-env";
                    # Expose tools the gateway spawns
                    Environment = [
                      "PATH=${pkgs.lib.makeBinPath (
                        (pkgs.lib.optionals isQmd [
                          inputs.qmd.packages.${system}.qmd
                          pkgs.sqlite
                        ]) ++
                        (pkgs.lib.optionals isTailscale [
                          tailscaleWrapped
                        ]) ++ [
                          pkgs.coreutils
                          pkgs.bash
                        ]
                      )}:/usr/bin:/bin"
                    ];
                    # Log output to file for debugging
                    StandardOutput = lib.mkForce "append:/home/${username}/.openclaw/logs/openclaw-gateway.log";
                    StandardError = lib.mkForce "append:/home/${username}/.openclaw/logs/openclaw-gateway.log";
                  };
                };
              } // (pkgs.lib.optionalAttrs isQmd {
                # ── QMD index preseed ──────────────────────────────────
                # Warms QMD search index on boot (downloads GGUF models if needed).
                # Re-trigger: systemctl --user restart openclaw-qmd-preseed
                # Logs:       tail -f ~/.openclaw/logs/qmd-preseed.log
                openclaw-qmd-preseed = {
                  Unit = {
                    Description = "Pre-seed QMD search index (download models + build embeddings)";
                    After = [ "openclaw-gateway.service" ];
                  };
                  Service = {
                    Type = "oneshot";
                    RemainAfterExit = true;
                    Environment = [
                      "PATH=${pkgs.lib.makeBinPath [
                        inputs.qmd.packages.${system}.qmd
                        pkgs.sqlite
                        pkgs.coreutils
                        pkgs.bash
                      ]}:/usr/bin:/bin"
                      "XDG_CONFIG_HOME=/home/${username}/.openclaw/agents/main/qmd/xdg-config"
                      "XDG_CACHE_HOME=/home/${username}/.openclaw/agents/main/qmd/xdg-cache"
                    ];
                    ExecStart = let
                      script = pkgs.writeShellScript "qmd-preseed" ''
                        set -euo pipefail
                        if ! command -v qmd >/dev/null 2>&1; then
                          echo "qmd not found on PATH, skipping preseed"
                          exit 0
                        fi
                        echo "Starting QMD preseed at $(date -Iseconds)"
                        qmd update
                        echo "qmd update completed at $(date -Iseconds)"
                        qmd embed
                        echo "qmd embed completed at $(date -Iseconds)"
                        echo "QMD preseed finished successfully"
                      '';
                    in "${script}";
                    StandardOutput = "append:/home/${username}/.openclaw/logs/qmd-preseed.log";
                    StandardError = "append:/home/${username}/.openclaw/logs/qmd-preseed.log";
                  };
                  Install.WantedBy = [ "default.target" ];
                };
              }) // (pkgs.lib.optionalAttrs isTailscale {
                # ── Tailscale daemon (userspace networking) ────────────
                # Runs tailscaled without TUN device (suitable for WSL2 user services).
                # Trade-off: no subnet routing or exit node, but serve/funnel work fine.
                # Status: tailscale --socket=~/.local/share/tailscale/tailscaled.sock status
                tailscaled = {
                  Unit = {
                    Description = "Tailscale daemon (userspace networking)";
                    After = [ "network.target" ];
                  };
                  Service = {
                    ExecStart = "${pkgs.tailscale}/bin/tailscaled --tun=userspace-networking --statedir=/home/${username}/.local/share/tailscale --socket=${tailscaleSocket}";
                    Restart = "on-failure";
                    RestartSec = "5s";
                  };
                  Install.WantedBy = [ "default.target" ];
                };

                # ── Tailscale authentication ───────────────────────────
                # Authenticates with auth key on first boot (idempotent).
                # Auth key file: ~/.secrets/tailscale-authkey (can delete after first login)
                # Logs: tail -f ~/.openclaw/logs/tailscale-auth.log
                tailscale-auth = {
                  Unit = {
                    Description = "Authenticate Tailscale device";
                    After = [ "tailscaled.service" ];
                    Requires = [ "tailscaled.service" ];
                  };
                  Service = {
                    Type = "oneshot";
                    RemainAfterExit = true;
                    ExecStart = let
                      script = pkgs.writeShellScript "tailscale-auth" ''
                        set -euo pipefail
                        TS="${tailscaleWrapped}/bin/tailscale"

                        # Wait for tailscaled ready (up to 30s)
                        for i in $(seq 1 30); do
                          if "$TS" status >/dev/null 2>&1; then break; fi
                          sleep 1
                        done

                        # Skip if already authenticated
                        if "$TS" status 2>&1 | head -1 | grep -qv "Logged out"; then
                          echo "Already authenticated with Tailscale"
                          exit 0
                        fi

                        # Authenticate with auth key if available
                        AUTHKEY_FILE="/home/${username}/.secrets/tailscale-authkey"
                        if [ -f "$AUTHKEY_FILE" ]; then
                          "$TS" up --authkey="$(cat "$AUTHKEY_FILE")"
                          echo "Authenticated with Tailscale via auth key"
                        else
                          echo "No auth key at $AUTHKEY_FILE — run: tailscale --socket=${tailscaleSocket} up"
                        fi
                      '';
                    in "${script}";
                    StandardOutput = "append:/home/${username}/.openclaw/logs/tailscale-auth.log";
                    StandardError = "append:/home/${username}/.openclaw/logs/tailscale-auth.log";
                  };
                  Install.WantedBy = [ "default.target" ];
                };
              }) // (pkgs.lib.optionalAttrs (syncthingIntroducerId != null) {
                # ── Syncthing post-start configuration ─────────────────
                # Adds cloud VPS as introducer + shares workspace folder.
                # Logs: tail -f ~/.openclaw/logs/syncthing-configure.log
                syncthing-configure = {
                  Unit = {
                    Description = "Configure Syncthing introducer device and shared folders";
                    After = [ "syncthing.service" ];
                    Requires = [ "syncthing.service" ];
                  };
                  Service = {
                    Type = "oneshot";
                    RemainAfterExit = true;
                    ExecStart = let
                      script = pkgs.writeShellScript "syncthing-configure" ''
                        set -euo pipefail
                        SYNCTHING="${pkgs.syncthing}/bin/syncthing"

                        # Wait for Syncthing API to become ready (up to 30s)
                        for i in $(seq 1 30); do
                          if "$SYNCTHING" cli show system 2>/dev/null | grep -q '"myID"'; then
                            break
                          fi
                          sleep 1
                        done

                        # Add introducer device (idempotent)
                        if ! "$SYNCTHING" cli config devices list 2>/dev/null | grep -q "${syncthingIntroducerId}"; then
                          "$SYNCTHING" cli config devices add \
                            --device-id "${syncthingIntroducerId}" \
                            --name "cloud-introducer" \
                            --introducer
                          echo "Added introducer device: ${syncthingIntroducerId}"
                        else
                          echo "Introducer device already configured"
                        fi

                        # Add shared folder for workspace (idempotent)
                        FOLDER_ID="openclaw-workspace"
                        FOLDER_PATH="/home/${username}/.openclaw/workspace"
                        if ! "$SYNCTHING" cli config folders list 2>/dev/null | grep -q "$FOLDER_ID"; then
                          "$SYNCTHING" cli config folders add \
                            --id "$FOLDER_ID" \
                            --label "OpenClaw Workspace" \
                            --path "$FOLDER_PATH"
                          # Share folder with introducer
                          "$SYNCTHING" cli config folders "$FOLDER_ID" devices add \
                            --device-id "${syncthingIntroducerId}"
                          echo "Added shared folder: $FOLDER_ID -> $FOLDER_PATH"
                        else
                          echo "Shared folder $FOLDER_ID already configured"
                        fi
                      '';
                    in "${script}";
                    StandardOutput = "append:/home/${username}/.openclaw/logs/syncthing-configure.log";
                    StandardError = "append:/home/${username}/.openclaw/logs/syncthing-configure.log";
                  };
                  Install.WantedBy = [ "default.target" ];
                };
              });

              # ── OPENCLAW CONFIGURATION ───────────────────────────────
              programs.openclaw = {
                enable = true;
                package = pkgs.lib.lowPrio inputs.nix-openclaw.packages.${system}.openclaw;

                config = {
                  # ── Gateway ─────────────────────────────────────────────────
                  # Auth token/password read from env vars (OPENCLAW_GATEWAY_TOKEN,
                  # OPENCLAW_GATEWAY_PASSWORD) — never baked into config JSON.
                  gateway = {
                    mode = "local";
                    auth = { mode = "token"; }
                      // (pkgs.lib.optionalAttrs (tailscaleMode == "serve") {
                        allowTailscale = true;
                      })
                      // (pkgs.lib.optionalAttrs (tailscaleMode == "funnel") {
                        mode = "password";
                      });
                  } // (pkgs.lib.optionalAttrs isTailscale {
                    tailscale = {
                      mode = tailscaleMode;
                      resetOnExit = true;
                    };
                  });

                  # ── Telegram bot ────────────────────────────────────────────
                  # 1. Create bot via @BotFather, get token
                  # 2. Put token in ~/.secrets/telegram-bot-token
                  # 3. Find your user ID via @userinfobot
                  channels.telegram = {
                    accounts.default.tokenFile = "/home/${username}/.secrets/telegram-bot-token";
                    allowFrom = [ telegramUserId ];
                    groups."*".requireMention = true;  # Require @botname in groups
                  };

                  # ── Agent defaults ────────────────────────────────────────────
                  agents.defaults = {
                    # Primary: Moonshot Kimi K2.5 (API key from MOONSHOT_API_KEY)
                    # Fallback: GPT-5.2, MiniMax M2.5, GLM-5, Claude Sonnet 4.6
                    model = {
                      primary = primaryModel;
                      fallbacks = fallbackModels;
                    };

                    # Session compaction — prevents context window timeouts
                    compaction = {
                      reserveTokens = 8000;        # Reserve for model output
                      reserveTokensFloor = 16000;  # Lower floor = more aggressive compaction
                      keepRecentTokens = 4000;     # Preserve recent context
                      mode = "safeguard";          # Chunked summarization for reliability
                      memoryFlush = {
                        enabled = true;
                        softThresholdTokens = 6000;
                      };
                    };
                  } // (
                    # Memory search provider (non-QMD backends)
                    if memoryBackend == "voyage" then {
                      memorySearch = { provider = "voyage"; model = "voyage-3-large"; };
                    } else if memoryBackend == "openai" then {
                      memorySearch = { provider = "openai"; model = "text-embedding-3-large"; };
                    } else if memoryBackend == "ollama" then {
                      memorySearch = { provider = "ollama"; model = "nomic-embed-text"; };
                    } else if memoryBackend == "local" then {
                      memorySearch = { provider = "local"; };
                    } else {}
                  );

                  # ── Memory ────────────────────────────────────────────────
                  # Controlled by the `memoryBackend` variable at the top.
                  # "qmd"     = local BM25 + vector + rerank (downloads ~2.2GB GGUF models)
                  # "voyage"  = Voyage AI embeddings (needs VOYAGE_API_KEY)
                  # "openai"  = OpenAI embeddings (needs OPENAI_API_KEY)
                  # "ollama"  = Ollama local embeddings
                  # "local"   = node-llama-cpp local embeddings
                  # "builtin" = plain SQLite FTS, no vector search
                  memory = if isQmd then {
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
                  } else {
                    backend = "builtin";
                    citations = "auto";
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

                      # Anthropic (Claude) — native Messages API
                      # Key: ANTHROPIC_API_KEY in ~/.secrets/openclaw-env
                      anthropic = {
                        baseUrl = "https://api.anthropic.com";
                        api = "anthropic-messages";
                        auth = "api-key";
                        models = [{
                          id = "claude-sonnet-4-6";
                          name = "Claude Sonnet 4.6";
                          contextWindow = 200000;
                          maxTokens = 64000;
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

                    # Extension relay (gateway + 3)
                    # Attach visible Chromium tabs via Browser Relay extension
                    profiles.openclaw = {
                      driver = "extension";
                      cdpUrl = "http://127.0.0.1:${toString extensionRelayPort}";
                      color = "#FF6B35";
                    };
                  };
                };
              };
            }
          )
          # ── End of OPENCLAW MODULE ───────────────────────────────────

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
# 1. ~/.secrets/telegram-bot-token
#    Your Telegram bot token (plain text, no newline).
#    Get one: message @BotFather on Telegram → /newbot → copy token
#    Write:   echo -n 'YOUR_TOKEN' > ~/.secrets/telegram-bot-token
#
# 2. ~/.secrets/telegram-user-id
#    Your numeric Telegram user ID (digits only, no newline).
#    Find it: message @userinfobot on Telegram → copy the "Id" number
#    Write:   echo -n '12345678' > ~/.secrets/telegram-user-id
#
# 3. ~/.secrets/openclaw-env
#    All API keys + gateway auth as KEY=VALUE lines:
#      OPENCLAW_GATEWAY_TOKEN=...      (openssl rand -hex 32 — local IPC + serve mode)
#      OPENCLAW_GATEWAY_PASSWORD=...   (openssl rand -base64 24 — funnel mode only)
#      ANTHROPIC_API_KEY=sk-ant-...    (https://console.anthropic.com/)
#      OPENAI_API_KEY=sk-...           (https://platform.openai.com/api-keys)
#      MOONSHOT_API_KEY=sk-...         (https://platform.moonshot.ai/)
#      MINIMAX_API_KEY=sk-api-...      (https://platform.minimax.io/)
#      ZAI_API_KEY=...                 (https://z.ai/)
#      PERPLEXITY_API_KEY=pplx-...     (https://perplexity.ai/settings/api)
#      VOYAGE_API_KEY=pa-...           (https://dash.voyageai.com/ — for memoryBackend="voyage")
#      PLAYWRIGHT_BROWSERS_PATH=...    (set to ~/.openclaw/playwright-browsers)
#
# 4. (Optional) ~/.secrets/tailscale-authkey
#    Tailscale auth key for automatic device login (one-time use).
#    Generate: https://login.tailscale.com/admin/settings/keys → "Generate auth key"
#    Write:    echo -n 'tskey-auth-...' > ~/.secrets/tailscale-authkey
#    Can be deleted after the first successful tailscale login.
#
# 5. (Optional) ~/.secrets/syncthing-introducer-id
#    The device ID of your Syncthing introducer (e.g., cloud VPS).
#    If this file is missing, Syncthing starts without an introducer.
#    Write:   echo -n 'SL7MZ7U-...' > ~/.secrets/syncthing-introducer-id
#
# 6. Lock down permissions:
#    chmod 600 ~/.secrets/*
#
# 7. Activate:
#    nix run home-manager/release-24.11 -- switch --impure --flake ~/.config/home-manager#$USER
#
#    If home-manager reports conflicts with existing files, use -b backup:
#    nix run home-manager/release-24.11 -- switch --impure --flake ~/.config/home-manager#$USER -b backup
#
#    Clean stale .backup files after confirming everything works:
#      find ~ -maxdepth 3 -name '*.backup' -ls          # review
#      find ~ -maxdepth 3 -name '*.backup' -delete       # remove
#
#    To revert a failed activation:
#      home-manager generations      # list available generations
#      home-manager activate <gen>   # restore a previous generation
#
# 8. Install Playwright Chromium (required by the claw-chrome systemd service):
#    The claw-chrome headless browser service uses Playwright's own Chromium
#    binary at ~/.openclaw/playwright-browsers/chromium-1208/chrome-linux64/chrome
#    (NOT the Nix-managed Chromium). Install it:
#      PLAYWRIGHT_BROWSERS_PATH=~/.openclaw/playwright-browsers \
#        npx playwright install chromium
#
# 9. Start services:
#    systemctl --user start openclaw-tmpfiles-setup.service   # create workspace dirs
#    systemctl --user enable --now claw-chrome.service
#    systemctl --user restart openclaw-gateway
#
# 10. (Only if memoryBackend = "qmd") Warm QMD index:
#     The openclaw-qmd-preseed service does this automatically on boot.
#     To trigger manually: systemctl --user restart openclaw-qmd-preseed
#     To check logs:       tail -f ~/.openclaw/logs/qmd-preseed.log
#
# 11. Syncthing (auto-starts if enabled):
#     Check status: systemctl --user status syncthing syncthing-configure
#     Web UI:       http://127.0.0.1:8384
#     Config logs:  tail -f ~/.openclaw/logs/syncthing-configure.log
#
# 12. Tailscale (auto-starts when tailscaleMode != "off"):
#     Check status: systemctl --user status tailscaled tailscale-auth
#     Tailscale:    tailscale --socket=~/.local/share/tailscale/tailscaled.sock status
#     Auth logs:    tail -f ~/.openclaw/logs/tailscale-auth.log
#     Note: Uses userspace networking (no TUN/root). No subnet routing or exit node.
#     For funnel: tailnet needs MagicDNS + HTTPS enabled + funnel ACL attribute.
#
# PORT LAYOUT
#   18789  Gateway WebSocket
#   18791  Browser control (CDP proxy)
#   18792  Extension relay (gateway + 3, HMAC auth)
#   18793  Headless Chromium CDP (claw-chrome systemd service)
#   8384   Syncthing Web UI
#   443    Tailscale serve/funnel (external, managed by tailscale)
# ============================================================================
