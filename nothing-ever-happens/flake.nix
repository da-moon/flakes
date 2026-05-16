{
  description = "Nothing Ever Happens - Polymarket bot";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      homeManagerModule =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          inherit (lib)
            concatStringsSep
            escapeShellArg
            filter
            hasPrefix
            literalExpression
            mapAttrsToList
            mkEnableOption
            mkIf
            mkOption
            optionalAttrs
            types
            ;

          cfg = config.services.nothing-ever-happens;
          jsonFormat = pkgs.formats.json { };

          boolToEnv = value: if value then "true" else "false";
          toEnvValue = value: if builtins.isBool value then boolToEnv value else toString value;

          mkIntOption =
            default: description:
            mkOption {
              type = types.int;
              inherit default description;
            };

          mkNumberOption =
            default: description:
            mkOption {
              type = types.number;
              inherit default description;
            };

          generatedConfig = jsonFormat.generate "nothing-ever-happens-config.json" {
            connection = {
              host = cfg.connection.host;
              chain_id = cfg.connection.chainId;
              signature_type = cfg.connection.signatureType;
            };
            strategies.nothing_happens = {
              market_refresh_interval_sec = cfg.strategy.marketRefreshIntervalSec;
              price_poll_interval_sec = cfg.strategy.pricePollIntervalSec;
              position_sync_interval_sec = cfg.strategy.positionSyncIntervalSec;
              order_dispatch_interval_sec = cfg.strategy.orderDispatchIntervalSec;
              cash_pct_per_trade = cfg.strategy.cashPctPerTrade;
              min_trade_amount = cfg.strategy.minTradeAmount;
              fixed_trade_amount = cfg.strategy.fixedTradeAmount;
              max_entry_price = cfg.strategy.maxEntryPrice;
              allowed_slippage = cfg.strategy.allowedSlippage;
              request_concurrency = cfg.strategy.requestConcurrency;
              buy_retry_count = cfg.strategy.buyRetryCount;
              buy_retry_base_delay_sec = cfg.strategy.buyRetryBaseDelaySec;
              max_backoff_sec = cfg.strategy.maxBackoffSec;
              max_new_positions = cfg.strategy.maxNewPositions;
              shutdown_on_max_new_positions = cfg.strategy.shutdownOnMaxNewPositions;
              redeemer_interval_sec = cfg.strategy.redeemerIntervalSec;
            };
          };

          moduleEnvironment = {
            CONFIG_PATH = generatedConfig;
            BOT_MODE = cfg.mode;
            LIVE_TRADING_ENABLED = cfg.mode == "live";
            DRY_RUN = cfg.mode != "live";
            LOG_LEVEL = cfg.logLevel;
            TRADE_LEDGER_PATH = cfg.tradeLedgerPath;
            PM_RISK_MAX_TOTAL_OPEN_EXPOSURE_USD = cfg.risk.maxTotalOpenExposureUsd;
            PM_RISK_MAX_MARKET_OPEN_EXPOSURE_USD = cfg.risk.maxMarketOpenExposureUsd;
            PM_RISK_MAX_DAILY_DRAWDOWN_USD = cfg.risk.maxDailyDrawdownUsd;
            PM_RISK_KILL_COOLDOWN_SEC = cfg.risk.killSwitchCooldownSec;
            PM_RISK_DRAWDOWN_ARM_AFTER_SEC = cfg.risk.drawdownArmAfterSec;
            PM_RISK_DRAWDOWN_MIN_FRESH_OBS = cfg.risk.drawdownMinFreshObservations;
            PM_RECOVERY_BATCH_LIMIT = cfg.recovery.batchLimit;
            PM_RECOVERY_CALL_CONCURRENCY = cfg.recovery.callConcurrency;
            PM_RECOVERY_INTER_ROW_DELAY_SEC = cfg.recovery.interRowDelaySec;
            PM_PAPER_INITIAL_COLLATERAL_BALANCE = cfg.paper.initialCollateralBalance;
            PM_NH_MAX_END_DATE_DAYS = cfg.strategy.maxEndDateDays;
            PM_REDEEMER_MAX_GAS_GWEI = cfg.redeemer.maxGasGwei;
            PM_BACKGROUND_EXECUTOR_WORKERS = cfg.performance.backgroundExecutorWorkers;
            PM_TRADE_LEDGER_QUEUE_MAXSIZE = cfg.performance.tradeLedgerQueueMaxsize;
          }
          // optionalAttrs (cfg.dashboard.port != null) {
            DASHBOARD_PORT = cfg.dashboard.port;
          }
          // optionalAttrs (cfg.botVariant != null && cfg.botVariant != "") {
            BOT_VARIANT = cfg.botVariant;
          }
          // cfg.extraEnvironment;

          startScript = pkgs.writeShellScript "nothing-ever-happens-start" ''
            ${concatStringsSep "\n" (
              mapAttrsToList (
                name: value: "export ${name}=${escapeShellArg (toEnvValue value)}"
              ) moduleEnvironment
            )}
            exec ${escapeShellArg "${cfg.package}/bin/nothing-ever-happens"} "$@"
          '';

          extraEnvNames = builtins.attrNames cfg.extraEnvironment;
          reservedEnvNames = [
            "BOT_MODE"
            "BOT_VARIANT"
            "CONFIG_PATH"
            "DASHBOARD_PORT"
            "DRY_RUN"
            "LIVE_TRADING_ENABLED"
            "LOG_LEVEL"
            "PORT"
            "TRADE_LEDGER_PATH"
          ];
          reservedEnvPrefixes = [
            "PM_BACKGROUND_"
            "PM_NH_"
            "PM_PAPER_"
            "PM_RECOVERY_"
            "PM_REDEEM_"
            "PM_REDEEMER_"
            "PM_RISK_"
            "PM_TRADE_LEDGER_"
          ];
          secretEnvNames = [
            "DATABASE_URL"
            "FUNDER_ADDRESS"
            "POLYGON_RPC_URL"
            "POLYGONSCAN_API_KEY"
            "PRIVATE_KEY"
          ];
          envConflicts = filter (
            name:
            builtins.elem name (reservedEnvNames ++ secretEnvNames)
            || lib.any (prefix: hasPrefix prefix name) reservedEnvPrefixes
          ) extraEnvNames;
          invalidEnvNames = filter (name: builtins.match "[A-Za-z_][A-Za-z0-9_]*" name == null) extraEnvNames;
        in
        {
          options.services.nothing-ever-happens = {
            enable = mkEnableOption "the Nothing Ever Happens Polymarket bot";

            package = mkOption {
              type = types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
              defaultText = literalExpression "inputs.nothing-ever-happens.packages.\${pkgs.stdenv.hostPlatform.system}.default";
              description = "Package providing the nothing-ever-happens executable.";
            };

            stateDir = mkOption {
              type = types.str;
              default = "${config.xdg.stateHome}/nothing-ever-happens";
              defaultText = literalExpression ''"${config.xdg.stateHome}/nothing-ever-happens"'';
              description = "Writable state directory used as the service working directory.";
            };

            envFile = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "%h/.secrets/nothing-ever-happens.env";
              description = "Optional systemd EnvironmentFile for secrets and host-local values.";
            };

            mode = mkOption {
              type = types.enum [
                "paper"
                "live"
              ];
              default = "paper";
              description = "Trading mode. Live mode sets BOT_MODE=live, LIVE_TRADING_ENABLED=true, and DRY_RUN=false.";
            };

            logLevel = mkOption {
              type = types.str;
              default = "INFO";
              description = "Python log level passed as LOG_LEVEL.";
            };

            botVariant = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Optional BOT_VARIANT value for partitioning bot state in shared storage.";
            };

            tradeLedgerPath = mkOption {
              type = types.str;
              default = "${cfg.stateDir}/trades.jsonl";
              defaultText = literalExpression ''"${config.services.nothing-ever-happens.stateDir}/trades.jsonl"'';
              description = "Path to the local JSONL trade ledger.";
            };

            extraEnvironment = mkOption {
              type = types.attrsOf (
                types.oneOf [
                  types.str
                  types.int
                  types.float
                  types.bool
                ]
              );
              default = { };
              description = "Additional non-secret environment variables. Use envFile for secrets.";
            };

            dashboard.port = mkOption {
              type = types.nullOr types.port;
              default = null;
              example = 8080;
              description = "Dashboard port. Null disables the dashboard.";
            };

            paper.initialCollateralBalance = mkNumberOption 100.0 "Initial paper-mode collateral balance in USD.";

            connection = {
              host = mkOption {
                type = types.str;
                default = "https://clob.polymarket.com";
                description = "Polymarket CLOB host.";
              };
              chainId = mkIntOption 137 "Polygon chain id used by the exchange client.";
              signatureType = mkOption {
                type = types.enum [
                  0
                  1
                  2
                ];
                default = 2;
                description = "Polymarket signature type: 0 EOA, 1 proxy, or 2 delegated wallet.";
              };
            };

            strategy = {
              marketRefreshIntervalSec = mkIntOption 600 "Seconds between full market refreshes.";
              pricePollIntervalSec = mkIntOption 60 "Seconds between price polling cycles.";
              positionSyncIntervalSec = mkIntOption 60 "Seconds between position sync cycles.";
              orderDispatchIntervalSec = mkIntOption 60 "Seconds between order dispatch cycles.";
              cashPctPerTrade = mkNumberOption 0.02 "Fraction of available cash to allocate per trade.";
              minTradeAmount = mkNumberOption 5.0 "Minimum trade amount in USD.";
              fixedTradeAmount = mkNumberOption 0.0 "Fixed trade amount in USD. Zero uses cashPctPerTrade.";
              maxEntryPrice = mkNumberOption 0.65 "Maximum NO entry price.";
              allowedSlippage = mkNumberOption 0.30 "Allowed slippage as a fraction.";
              requestConcurrency = mkIntOption 4 "Concurrent market data requests.";
              buyRetryCount = mkIntOption 3 "Number of buy retry attempts.";
              buyRetryBaseDelaySec = mkNumberOption 1.0 "Base delay between buy retries.";
              maxBackoffSec = mkNumberOption 900.0 "Maximum retry backoff.";
              maxEndDateDays = mkIntOption 90 "Maximum days until candidate market end date.";
              maxNewPositions = mkIntOption (-1) "Maximum new positions per run. -1 means unlimited.";
              shutdownOnMaxNewPositions = mkOption {
                type = types.bool;
                default = false;
                description = "Stop the service after reaching maxNewPositions.";
              };
              redeemerIntervalSec = mkIntOption 1800 "Seconds between redeemer checks.";
            };

            risk = {
              maxTotalOpenExposureUsd = mkNumberOption 1500.0 "Maximum total open exposure in USD.";
              maxMarketOpenExposureUsd = mkNumberOption 1000.0 "Maximum open exposure per market in USD.";
              maxDailyDrawdownUsd = mkNumberOption 0.0 "Daily drawdown kill-switch threshold in USD. Zero disables it.";
              killSwitchCooldownSec = mkNumberOption 900.0 "Risk kill-switch cooldown in seconds.";
              drawdownArmAfterSec = mkNumberOption 1800.0 "Seconds before drawdown checks become armed.";
              drawdownMinFreshObservations = mkIntOption 3 "Fresh balance observations required before drawdown checks arm.";
            };

            recovery = {
              batchLimit = mkIntOption 10 "Maximum ambiguous recovery rows processed per batch.";
              callConcurrency = mkIntOption 4 "Concurrent venue calls for live recovery.";
              interRowDelaySec = mkNumberOption 0.02 "Delay between recovery rows.";
            };

            redeemer.maxGasGwei = mkNumberOption 150.0 "Maximum gas price for redemption transactions.";

            performance = {
              backgroundExecutorWorkers = mkIntOption 8 "Background ThreadPoolExecutor worker count.";
              tradeLedgerQueueMaxsize = mkIntOption 4096 "Maximum queued trade ledger records.";
            };
          };

          config = mkIf cfg.enable {
            assertions = [
              {
                assertion = pkgs.stdenv.hostPlatform.isLinux;
                message = "services.nothing-ever-happens is only supported on Linux user systemd.";
              }
              {
                assertion = cfg.mode != "live" || cfg.envFile != null;
                message = "services.nothing-ever-happens.envFile is required when mode = \"live\".";
              }
              {
                assertion = envConflicts == [ ];
                message = "services.nothing-ever-happens.extraEnvironment conflicts with module-owned or secret env vars: ${concatStringsSep ", " envConflicts}";
              }
              {
                assertion = invalidEnvNames == [ ];
                message = "services.nothing-ever-happens.extraEnvironment contains invalid environment variable names: ${concatStringsSep ", " invalidEnvNames}";
              }
            ];

            home.activation.nothing-ever-happens-stateDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
              run mkdir -m 700 -p ${escapeShellArg cfg.stateDir}
            '';

            systemd.user.services.nothing-ever-happens = {
              Unit = {
                Description = "Nothing Ever Happens Polymarket bot";
                After = [ "network.target" ];
              };
              Service = {
                ExecStart = startScript;
                WorkingDirectory = cfg.stateDir;
                Restart = "on-failure";
                RestartSec = "15s";
              }
              // optionalAttrs (cfg.envFile != null) {
                EnvironmentFile = cfg.envFile;
              };
              Install.WantedBy = [ "default.target" ];
            };
          };
        };

      perSystem = flake-utils.lib.eachSystem linuxSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;
          py = pkgs.python3Packages;
          pname = "nothing-ever-happens";
          rev = "930e18050e7b40658ab503d17c15ddc75a09e897";
          version = "unstable-2026-04-13-930e180";
          srcHash = "sha256-lx+hNGv/XTkCbd1117jNsCJ5vocLdG/FtXipjvk/D7I=";

          src = pkgs.fetchFromGitHub {
            owner = "sterlingcrispin";
            repo = "nothing-ever-happens";
            inherit rev;
            hash = srcHash;
          };

          polyEip712Structs = py.buildPythonPackage rec {
            pname = "poly-eip712-structs";
            version = "0.0.1";
            format = "wheel";

            src = pkgs.fetchurl {
              url = "https://files.pythonhosted.org/packages/5a/d7/ff1cfba1c3a3d5d6851d7bef5e4ad19710ed6d03e149dc183111d103acab/poly_eip712_structs-0.0.1-py3-none-any.whl";
              hash = "sha256-EecU6MJcZNIty4pgbIfPBS5xVMr3AWUtKWh92vfe40I=";
            };

            propagatedBuildInputs = [
              py."eth-utils"
              py.pydantic
              py.pycryptodome
              py.pytest
            ];

            doCheck = false;
            pythonImportsCheck = [ "poly_eip712_structs" ];
          };

          pyOrderUtils = py.buildPythonPackage rec {
            pname = "py-order-utils";
            version = "0.3.2";
            format = "wheel";

            src = pkgs.fetchurl {
              url = "https://files.pythonhosted.org/packages/29/68/b0a971b064b3236fce7307bd5c180409cccd9b207ec459274bdb4e401ec0/py_order_utils-0.3.2-py3-none-any.whl";
              hash = "sha256-WreA5h7VMt3ahSpqEtRwvnu9quASE87T68bIh87bHT4=";
            };

            propagatedBuildInputs = [
              py."eth-account"
              py."eth-utils"
              py.pydantic
              polyEip712Structs
              py.pytest
            ];

            doCheck = false;
            pythonImportsCheck = [ "py_order_utils" ];
          };

          pyBuilderSigningSdk = py.buildPythonPackage rec {
            pname = "py-builder-signing-sdk";
            version = "0.0.2";
            format = "wheel";

            src = pkgs.fetchurl {
              url = "https://files.pythonhosted.org/packages/57/fb/23c68c8f6356a50f959e2df2ae80e8344c3ff8ccca92943848a57a495928/py_builder_signing_sdk-0.0.2-py3-none-any.whl";
              hash = "sha256-EUudV77CKBd9dZzhXEdVifR9siUu0f1nysPJsGQKvnY=";
            };

            propagatedBuildInputs = [
              py.python-dotenv
              py.requests
            ];

            doCheck = false;
            pythonImportsCheck = [ "py_builder_signing_sdk" ];
          };

          pyClobClient = py.buildPythonPackage rec {
            pname = "py-clob-client";
            version = "0.34.6";
            format = "wheel";

            src = pkgs.fetchurl {
              url = "https://files.pythonhosted.org/packages/8f/93/cd8aa728b3ff66162be5f91002dfd7eab9defd5d8200cddf14f119e32c04/py_clob_client-0.34.6-py3-none-any.whl";
              hash = "sha256-KcOQArdvORjyMSyWPbCzGUHNRVvWxqzcFRnY/81whC0=";
            };

            propagatedBuildInputs = [
              py."eth-account"
              py."eth-utils"
              py.h2
              py.httpx
              py.pydantic
              py.python-dotenv
              polyEip712Structs
              pyBuilderSigningSdk
              pyOrderUtils
            ];

            doCheck = false;
            pythonImportsCheck = [ "py_clob_client" ];
          };

          pythonEnv = pkgs.python3.withPackages (ps: [
            ps.aiohttp
            ps.psycopg2
            ps.python-dotenv
            ps."python-json-logger"
            ps.requests
            ps.sqlalchemy
            ps.web3
            pyClobClient
          ]);

          nothingEverHappens = pkgs.stdenv.mkDerivation {
            inherit pname version src;

            nativeBuildInputs = [ pkgs.makeWrapper ];
            dontBuild = true;
            dontConfigure = true;

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/${pname}
              mkdir -p $out/bin
              cp -r $src/. $out/lib/${pname}/

              substituteInPlace $out/lib/${pname}/bot/exchange/paper.py \
                --replace-fail $'import time' $'import os\nimport time' \
                --replace-fail "        initial_collateral_balance: float = 100.0," "        initial_collateral_balance: float | None = None," \
                --replace-fail $'        self._collateral_balance = float(initial_collateral_balance)' $'        if initial_collateral_balance is None:\n            initial_collateral_balance = float(os.getenv("PM_PAPER_INITIAL_COLLATERAL_BALANCE", "100.0"))\n        self._collateral_balance = float(initial_collateral_balance)'

              substituteInPlace $out/lib/${pname}/bot/standalone_markets.py \
                --replace-fail $'import json' $'import json\nimport os' \
                --replace-fail "    cutoff = now + timedelta(days=max_end_date_months * 30)" $'    max_end_date_days = int(os.getenv("PM_NH_MAX_END_DATE_DAYS", str(max_end_date_months * 30)))\n    cutoff = now + timedelta(days=max(1, max_end_date_days))' \
                --replace-fail $'        except aiohttp.ClientResponseError as exc:\n            if exc.status == 429 and retries < PAGE_MAX_RETRIES:' $'        except aiohttp.ClientResponseError as exc:\n            if exc.status == 422 and offset > 0:\n                logger.info(\n                    "gamma_markets_pagination_exhausted offset=%d status=%s",\n                    offset,\n                    exc.status,\n                )\n                return\n            if exc.status == 429 and retries < PAGE_MAX_RETRIES:'

              cat > $out/bin/nothing-ever-happens <<'EOF'
              #!/usr/bin/env bash
              set -euo pipefail

              case "''${1:-}" in
                --version|-V)
                  echo "nothing-ever-happens __VERSION__"
                  exit 0
                  ;;
                --help|-h)
                  cat <<'USAGE'
              nothing-ever-happens

              Starts the Polymarket bot from the current working directory.

              Safe commands:
                nothing-ever-happens --version
                nothing-ever-happens --help

              Runtime files expected in your working directory:
                config.json
                .env
              USAGE
                  exit 0
                  ;;
              esac

              config_path="''${CONFIG_PATH:-config.json}"
              if [ ! -f "$config_path" ]; then
                echo "Config file not found: $config_path" >&2
                echo "Copy config.example.json to config.json and fill in your values." >&2
                exit 1
              fi

              export PYTHONPATH="__PKG_ROOT__''${PYTHONPATH:+:$PYTHONPATH}"
              exec "__PYTHON__" -m bot.main "$@"
              EOF
              substituteInPlace $out/bin/nothing-ever-happens \
                --replace-fail "__VERSION__" "${version}" \
                --replace-fail "__PKG_ROOT__" "$out/lib/${pname}" \
                --replace-fail "__PYTHON__" "${pythonEnv}/bin/python"
              chmod +x $out/bin/nothing-ever-happens

              makeWrapper "${pythonEnv}/bin/python" "$out/bin/nothing-ever-happens-db-stats" \
                --add-flags "$out/lib/${pname}/scripts/db_stats.py" \
                --prefix PYTHONPATH : "$out/lib/${pname}"
              makeWrapper "${pythonEnv}/bin/python" "$out/bin/nothing-ever-happens-export-db" \
                --add-flags "$out/lib/${pname}/scripts/export_db.py" \
                --prefix PYTHONPATH : "$out/lib/${pname}"
              makeWrapper "${pythonEnv}/bin/python" "$out/bin/nothing-ever-happens-wallet-history" \
                --add-flags "$out/lib/${pname}/scripts/wallet_history.py" \
                --prefix PYTHONPATH : "$out/lib/${pname}"
              makeWrapper "${pythonEnv}/bin/python" "$out/bin/nothing-ever-happens-parse-logs" \
                --add-flags "$out/lib/${pname}/scripts/parse_logs.py" \
                --prefix PYTHONPATH : "$out/lib/${pname}"

              runHook postInstall
            '';

            meta = with lib; {
              description = "Async Polymarket bot that buys NO on standalone yes/no markets";
              homepage = "https://github.com/sterlingcrispin/nothing-ever-happens";
              license = licenses.cc0;
              mainProgram = "nothing-ever-happens";
              platforms = linuxSystems;
              maintainers = [ ];
            };
          };
        in
        {
          packages = {
            default = nothingEverHappens;
            "nothing-ever-happens" = nothingEverHappens;
          };

          apps = {
            default = {
              type = "app";
              program = "${nothingEverHappens}/bin/nothing-ever-happens";
            };
            "nothing-ever-happens" = {
              type = "app";
              program = "${nothingEverHappens}/bin/nothing-ever-happens";
            };
          };
        }
      );
    in
    perSystem
    // {
      homeManagerModules = {
        default = homeManagerModule;
        nothing-ever-happens = homeManagerModule;
      };
    };
}
