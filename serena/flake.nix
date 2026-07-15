{
  description = "Serena stable package and complete Nix-managed YAML configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # BEGIN GENERATED SERENA UPSTREAM INPUT
    serena-upstream.url = "github:oraios/serena/2449313c0d7427275c4c66aedff7d4881782f713";
    # END GENERATED SERENA UPSTREAM INPUT
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-utils,
      home-manager,
      serena-upstream,
      ...
    }:
    let
      releases = builtins.fromJSON (builtins.readFile ./releases.json);
      releaseKey = releases.latest;
      release = releases.versions.${releaseKey};
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
      versionedAttr = "serena_${sanitize releaseKey}";

      schema = import ./lib/config-schema.nix { lib = nixpkgs.lib; };
      renderFor = lib: import ./lib/render.nix { inherit lib; };
      packageFor = system: serena-upstream.packages.${system}.serena;

      homeManagerModule =
        { lib, pkgs, ... }:
        {
          imports = [ ./modules/home-manager.nix ];
          programs.serena.package = lib.mkDefault (packageFor pkgs.stdenv.hostPlatform.system);
        };

      projectIntegrationFor =
        pkgs:
        import ./lib/project-integration.nix {
          inherit (pkgs) lib;
          renderProjectConfig = (renderFor pkgs.lib).mkProjectYaml;
          serenaPackage = consumerPkgs: packageFor consumerPkgs.stdenv.hostPlatform.system;
        };

      validateProjectSettings =
        pkgs: settings:
        let
          consumerSchema = import ./lib/config-schema.nix { inherit (pkgs) lib; };
          evaluated = pkgs.lib.evalModules {
            modules = [
              {
                options.value = pkgs.lib.mkOption {
                  type = consumerSchema.projectSettingsType;
                };
                config.value = settings;
              }
            ];
          };
          value = evaluated.config.value;
          assertions = consumerSchema.assertionsFor {
            scope = "project";
            config = value;
            languages = value.languages;
          };
          failures = builtins.filter (entry: !entry.assertion) assertions;
          warnings = consumerSchema.warningsFor {
            scope = "project";
            config = value;
            languages = value.languages;
          };
          checked =
            if failures == [ ] then
              value
            else
              throw (
                "Invalid Serena project configuration:\n"
                + pkgs.lib.concatMapStringsSep "\n" (entry: "- ${entry.message}") failures
              );
        in
        builtins.foldl' (result: warning: pkgs.lib.warn warning result) checked warnings;

      mkProjectIntegration =
        args:
        (projectIntegrationFor args.pkgs).mkProjectIntegration (
          args
          // {
            settings = validateProjectSettings args.pkgs args.settings;
          }
        );

      mkBashLanguageServerWrapper =
        {
          pkgs,
          bashLanguageServer ? pkgs.bash-language-server,
          shellcheck ? pkgs.shellcheck,
        }:
        pkgs.writeShellScriptBin "serena-bash-language-server" ''
          export SHELLCHECK_PATH=${nixpkgs.lib.escapeShellArg (nixpkgs.lib.getExe shellcheck)}
          exec ${nixpkgs.lib.escapeShellArg (nixpkgs.lib.getExe bashLanguageServer)} "$@"
        '';

      flakePartsModule = import ./flake-modules/default.nix {
        inherit mkProjectIntegration;
        projectSettingsType = schema.projectSettingsType;
        serenaPackage = consumerPkgs: packageFor consumerPkgs.stdenv.hostPlatform.system;
      };

      schemaHash = builtins.hashFile "sha256" ./schema/upstream.json;
      releaseAssertions =
        assert release.rev == serena-upstream.rev;
        assert release.narHash == serena-upstream.narHash;
        assert release.schemaSha256 == schemaHash;
        true;
    in
    assert releaseAssertions;
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        package = packageFor system;
        render = renderFor pkgs.lib;

        smokeGlobalFile = render.mkGlobalYaml {
          inherit pkgs;
          name = "serena-smoke-global.yml";
          settings = {
            webDashboard = false;
            webDashboardOpenOnLaunch = false;
            lsSpecificSettings.python.lsPath = "/nix/store/serena-smoke-pyright";
          };
        };
        smokeContextFile = render.mkContextYaml {
          inherit pkgs;
          name = "serena-smoke-context.yml";
          settings.prompt = "Operate in Serena's configuration smoke test.";
        };
        smokeModeFile = render.mkModeYaml {
          inherit pkgs;
          name = "serena-smoke-mode.yml";
          settings.prompt = "Use the smoke-test mode.";
        };
        smokePromptFile = render.mkPromptYaml {
          inherit pkgs;
          name = "serena-smoke-prompts.yml";
          settings.onboardingPrompt = "Serena prompt-template smoke test.";
        };

        moduleEvaluation = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            homeManagerModule
            {
              home = {
                username = "serena-test";
                homeDirectory = "/home/serena-test";
                stateVersion = "26.05";
              };
              programs.serena = {
                enable = true;
                runtimePackages = [ pkgs.hello ];
                global = {
                  webDashboard = false;
                  webDashboardOpenOnLaunch = false;
                  webDashboardInterface = "browser";
                  webDashboardListenAddress = "127.0.0.1";
                  lsSpecificSettings.python.lsPath = "/nix/store/serena-test-pyright";
                };
                contexts.smoke.prompt = "Evaluate a custom Serena context.";
                modes.smoke.prompt = "Evaluate a custom Serena mode.";
                promptTemplates.smoke.onboardingPrompt = "Evaluate a custom Serena prompt.";
              };
            }
          ];
        };

        schemaCheck = pkgs.runCommand "serena-schema-pin-check" { } ''
          actual="$(${pkgs.coreutils}/bin/sha256sum ${./schema/upstream.json} | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
          expected=${nixpkgs.lib.escapeShellArg release.schemaSha256}
          test "$actual" = "$expected"
          touch "$out"
        '';

        mcpSmoke =
          pkgs.runCommand "serena-mcp-stdio-smoke"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.gnugrep
              ];
            }
            ''
              export HOME="$TMPDIR/home"
              export SERENA_HOME="$HOME/.serena"
              export SERENA_USAGE_REPORTING=false
              mkdir -p \
                "$SERENA_HOME/contexts" \
                "$SERENA_HOME/modes" \
                "$SERENA_HOME/prompt_templates"
              install -m 0600 ${smokeGlobalFile} "$SERENA_HOME/serena_config.yml"
              install -m 0600 ${smokeContextFile} "$SERENA_HOME/contexts/smoke.yml"
              install -m 0600 ${smokeModeFile} "$SERENA_HOME/modes/smoke.yml"
              install -m 0600 ${smokePromptFile} "$SERENA_HOME/prompt_templates/smoke.yml"

              timeout 30 ${package}/bin/serena start-mcp-server \
                --transport stdio \
                --context smoke \
                --mode smoke \
                --enable-web-dashboard false \
                --enable-gui-log-window false \
                </dev/null >stdout.log 2>stderr.log

              grep -q "Starting MCP server" stderr.log
              cmp ${smokeGlobalFile} "$SERENA_HOME/serena_config.yml"
              touch "$out"
            '';

        projectChecks = import ./tests/project {
          inherit pkgs;
          inherit (pkgs) lib;
        };
        configChecks = import ./tests/config {
          inherit pkgs;
          inherit (pkgs) lib;
        };
      in
      {
        formatter = pkgs.nixfmt-rfc-style;

        packages = {
          default = package;
          serena = package;
        }
        // {
          ${versionedAttr} = package;
        };

        apps = {
          default = {
            type = "app";
            program = "${package}/bin/serena";
          };
          serena = {
            type = "app";
            program = "${package}/bin/serena";
          };
        };

        checks = {
          package = package;
          schema = schemaCheck;
          module-eval = moduleEvaluation.activationPackage;
          mcp-stdio = mcpSmoke;
        }
        // configChecks
        // projectChecks;
      }
    )
    // {
      homeManagerModules = {
        default = homeManagerModule;
        serena = homeManagerModule;
      }
      // {
        ${versionedAttr} = homeManagerModule;
      };

      flakeModules = {
        default = flakePartsModule;
        serena = flakePartsModule;
      };

      lib = {
        inherit
          release
          mkBashLanguageServerWrapper
          mkProjectIntegration
          ;
        configSchema = schema.manifest;
        projectModule = flakePartsModule;
        mkGlobalConfig = args: (renderFor args.pkgs.lib).mkGlobalYaml args;
        mkProjectConfig = args: (renderFor args.pkgs.lib).mkProjectYaml args;
      };
    };
}
