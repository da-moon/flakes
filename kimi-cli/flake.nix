{
  description = "Kimi Code - native cross-platform CLI packaged as a Nix flake with Home Manager and project-level configuration modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      home-manager,
      flake-parts,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitizeKey = key: builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] key;

      schemaFor = lib: import ./modules/config-schema.nix { inherit lib; };
      renderFor = lib: import ./modules/render.nix { inherit lib; };

      homeManagerModule =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        {
          imports = [ ./modules/home-manager.nix ];
          config.programs.kimi-cli.package =
            lib.mkDefault
              self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };

      # One versioned alias per releases.json key (serena convention): lets a
      # pinned consumer pair the module with its package version explicitly.
      versionedHomeManagerModules = nixpkgs.lib.mapAttrs' (
        key: _: nixpkgs.lib.nameValuePair "kimi-cli_${sanitizeKey key}" homeManagerModule
      ) releases.versions;

      mkProjectIntegration =
        { pkgs, ... }@args:
        let
          schema = schemaFor pkgs.lib;
          # Raw values from plain-flake consumers need schema defaults filled
          # (the HM/flake-parts modules get this from the module system).
          normalize =
            type: value:
            if value == null then
              null
            else
              (pkgs.lib.evalModules {
                modules = [
                  {
                    options.value = pkgs.lib.mkOption { inherit type; };
                    config.value = value;
                  }
                ];
              }).config.value;
        in
        import ./modules/project-integration.nix (
          args
          // {
            kimiPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
            settings = normalize schema.settingsType (args.settings or null);
            tui = normalize schema.tuiType (args.tui or null);
            mcpServers = normalize (pkgs.lib.types.attrsOf schema.mcpServerType) (args.mcpServers or null);
            hooks = map (
              h:
              {
                event = "PreToolUse";
                matcher = null;
                timeout = 30;
                runtimeInputs = [ ];
              }
              // h
            ) (args.hooks or [ ]);
          }
        );

      flakePartsModule = import ./flake-modules/default.nix {
        inherit mkProjectIntegration;
        kimiPackage = consumerPkgs: self.packages.${consumerPkgs.stdenv.hostPlatform.system}.default;
      };
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        releasePlatformBySystem = {
          x86_64-linux = "linux-x64";
          aarch64-linux = "linux-arm64";
          x86_64-darwin = "darwin-x64";
          aarch64-darwin = "darwin-arm64";
        };

        releasePlatform = releasePlatformBySystem.${system};

        # Builder: derive a kimi-cli package from one releases.json entry.
        mk =
          key: entry:
          let
            version = entry.version;
            binarySha256 = entry.hashes.${system};
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "kimi-cli";
            inherit version;

            meta = with lib; {
              description = "Kimi Code - AI coding assistant CLI for terminal";
              homepage = "https://code.kimi.com";
              license = licenses.asl20;
              mainProgram = "kimi";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://code.kimi.com/kimi-code/binaries/${version}/kimi-code-${releasePlatform}";
              sha256 = binarySha256;
            };

            dontUnpack = true;
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;

            nativeBuildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.autoPatchelfHook
            ];

            buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.stdenv.cc.cc.lib
            ];

            installPhase = ''
              runHook preInstall

              mkdir -p $out/bin
              install -m755 $src $out/bin/kimi

              runHook postInstall
            '';
          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `kimi-cli_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "kimi-cli_${sanitizeKey key}" (mk key entry)
        ) releases.versions;

        # HM module evaluation exercising every typed surface.
        moduleCheck = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            homeManagerModule
            {
              home.username = "kimi-test";
              home.homeDirectory =
                if pkgs.stdenv.hostPlatform.isDarwin then "/Users/kimi-test" else "/home/kimi-test";
              home.stateVersion = "24.11";
              programs.home-manager.enable = true;
              programs.kimi-cli = {
                enable = true;
                settings = {
                  defaultModel = "kimi-code/k3";
                  defaultPlanMode = false;
                  mergeAllAvailableSkills = true;
                  extraSkillDirs = [ ];
                  telemetry = true;
                  thinking = {
                    enabled = true;
                    effort = "max";
                  };
                  loopControl = {
                    maxStepsPerTurn = 0;
                    maxRetriesPerStep = 3;
                    reservedContextSize = 50000;
                    extraSettings = {
                      max_ralph_iterations = 0;
                      compaction_trigger_ratio = 0.85;
                    };
                  };
                  background = {
                    maxRunningTasks = 4;
                    keepAliveOnExit = false;
                  };
                  providers."managed:kimi-code" = {
                    type = "kimi";
                    baseUrl = "https://api.kimi.com/coding/v1";
                    apiKey = "";
                  };
                  models."kimi-code/k3" = {
                    provider = "managed:kimi-code";
                    model = "k3";
                    maxContextSize = 1048576;
                    capabilities = [
                      "thinking"
                      "always_thinking"
                      "image_in"
                      "video_in"
                      "tool_use"
                    ];
                    displayName = "K3";
                    supportEfforts = [ "max" ];
                    defaultEffort = "max";
                  };
                  services.moonshot_search = {
                    baseUrl = "https://api.kimi.com/coding/v1/search";
                    apiKey = "";
                  };
                  permission.rules = [
                    {
                      decision = "allow";
                      pattern = "Read";
                    }
                    {
                      decision = "deny";
                      pattern = "Bash(rm -rf*)";
                      reason = "no recursive force deletes";
                    }
                  ];
                };
                tui = {
                  theme = "dark";
                  notifications = {
                    enabled = true;
                    notificationCondition = "unfocused";
                  };
                };
                mcpServers = {
                  "parallel-search" = {
                    url = "https://search-mcp.parallel.ai/mcp";
                    bearerTokenEnvVar = "PARALLEL_API_KEY";
                  };
                  local-stdio = {
                    command = "/usr/local/bin/example-mcp";
                    args = [ "--serve" ];
                  };
                };
                hooks = [
                  {
                    name = "redirect-web-tools";
                    event = "PreToolUse";
                    timeout = 5;
                    runtimeInputs = [
                      pkgs.gnugrep
                      pkgs.gnused
                      pkgs.coreutils
                    ];
                    script = ''
                      payload="$(cat)"
                      tool_name="$(printf '%s' "$payload" | grep -o '"tool_name"[^,]*' | head -n1)"
                      case "$tool_name" in
                        *WebSearch*|*FetchURL*) echo "use the parallel-search MCP instead" >&2; exit 2 ;;
                        *) exit 0 ;;
                      esac
                    '';
                  }
                ];
              };
            }
          ];
        };

        mergeChecks = import ./tests/merge {
          inherit pkgs;
          inherit (pkgs) lib;
        };
        projectChecks = import ./tests/project {
          inherit pkgs;
          inherit (pkgs) lib;
        };
      in
      {
        packages = {
          default = latestPkg;
          kimi-cli = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/kimi";
          };
          kimi = {
            type = "app";
            program = "${latestPkg}/bin/kimi";
          };
        };

        checks = {
          module-eval = moduleCheck.activationPackage;
        }
        // mergeChecks
        // projectChecks;
      }
    )
    // {
      homeManagerModules = {
        default = homeManagerModule;
        kimi-cli = homeManagerModule;
      }
      // versionedHomeManagerModules;

      flakeModules = {
        default = flakePartsModule;
        kimi-cli = flakePartsModule;
      };

      lib = {
        inherit mkProjectIntegration;
        projectModule = flakePartsModule;
        configSchema = (schemaFor nixpkgs.lib).manifest;
        tuiConfigSchema = (schemaFor nixpkgs.lib).tuiManifest;
        mkGlobalConfig =
          { pkgs, settings }:
          (renderFor pkgs.lib).mkConfigJson {
            inherit pkgs;
            settings =
              (pkgs.lib.evalModules {
                modules = [
                  {
                    options.value = pkgs.lib.mkOption {
                      type = (schemaFor pkgs.lib).settingsType;
                    };
                    config.value = settings;
                  }
                ];
              }).config.value;
          };
        mkProjectConfig =
          { pkgs, mcpServers }:
          (renderFor pkgs.lib).mkMcpJson {
            inherit pkgs;
            servers =
              (pkgs.lib.evalModules {
                modules = [
                  {
                    options.value = pkgs.lib.mkOption {
                      type = pkgs.lib.types.attrsOf (schemaFor pkgs.lib).mcpServerType;
                    };
                    config.value = mcpServers;
                  }
                ];
              }).config.value;
          };
      };
    };
}
