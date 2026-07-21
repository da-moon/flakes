{
  description = "command-code packaged as a Nix flake (npm tarball, offline install) with Home Manager and project modules";

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
      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];

      latestRelease = releases.versions.${releases.latest};
      schemaTypes = import ./modules/schema.nix { lib = nixpkgs.lib; };
      render = import ./modules/render.nix { lib = nixpkgs.lib; };
      uncheckedConfigSchema = builtins.fromJSON (builtins.readFile ./schema/upstream.json);
      recordedSchemaHash = nixpkgs.lib.removeSuffix "\n" (builtins.readFile ./schema/upstream.sha256);
      configSchema =
        if uncheckedConfigSchema.package.version != latestRelease.version then
          throw "Command Code schema artifact version does not match releases.json"
        else if schemaTypes.schemaVersion != latestRelease.version then
          throw "Command Code Nix schema version does not match releases.json"
        else if recordedSchemaHash != latestRelease.schemaSha256 then
          throw "Command Code schema hash does not match releases.json"
        else
          uncheckedConfigSchema;

      evalTyped =
        name: type: value:
        (nixpkgs.lib.evalModules {
          modules = [
            {
              options.value = nixpkgs.lib.mkOption {
                inherit type;
                description = "Validated ${name}.";
              };
              config.value = value;
            }
          ];
        }).config.value;

      mkGlobalConfig =
        value:
        render.toGlobalConfig (evalTyped "Command Code global config" schemaTypes.globalConfigType value);
      mkProjectConfig =
        value:
        render.toProjectSettings (
          evalTyped "Command Code project config" schemaTypes.projectSettingsType value
        );

      commandCodePackage = pkgs: self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      projectFactory = import ./modules/project-integration.nix {
        lib = nixpkgs.lib;
        inherit commandCodePackage;
      };

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      homeManagerModule =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        {
          imports = [ ./modules/home-manager.nix ];
          config.programs.command-code.package =
            lib.mkDefault
              self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };

      flakePartsModule = import ./flake-modules/default.nix {
        inherit commandCodePackage;
        inherit (projectFactory) mkProjectIntegration;
        inherit (schemaTypes)
          projectSettingsType
          hookType
          mcpServerType
          ;
      };
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        nodejs = pkgs.nodejs_22;
        pname = "command-code";

        # Builder: turns one releases.json entry into the command-code derivation.
        # PRESERVES the original build logic exactly; only version/tarball-hash/
        # per-system FOD hash now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            lockDir = ./deps + "/${version}";

            tarball = pkgs.fetchurl {
              url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
              hash = entry.hash;
            };

            # The published npm tarball ships no lockfile. Inject our committed,
            # fully-pinned package.json (devDependencies + packageManager already
            # stripped) + package-lock.json + .npmrc. This is what makes the
            # dependency set reproducible: importNpmLock fetches every module as
            # its own content-addressed derivation keyed to the lockfile's
            # integrity hashes — there is no drift-prone recursive FOD hash.
            src = pkgs.runCommand "${pname}-${version}-src" { } ''
              mkdir -p $out
              tar -xzf ${tarball} -C $out --strip-components=1
              cp ${lockDir}/package.json $out/package.json
              cp ${lockDir}/package-lock.json $out/package-lock.json
              cp ${lockDir}/.npmrc $out/.npmrc
            '';

            npmDeps = pkgs.importNpmLock { npmRoot = src; };
          in
          pkgs.stdenv.mkDerivation {
            inherit pname version src npmDeps;

            meta = with pkgs.lib; {
              description = "Command Code - coding agent that continuously learns your taste";
              homepage = "https://github.com/CommandCodeAI/command-code";
              license = licenses.unfree;
              mainProgram = "command-code";
              platforms = platforms.unix;
            };

            # npmConfigHook runs `npm ci` offline against npmDeps during the
            # configure phase, populating node_modules.
            nativeBuildInputs = [
              nodejs
              nodejs.passthru.python
              pkgs.importNpmLock.npmConfigHook
              pkgs.makeWrapper
            ];

            dontBuild = true;

            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib/${pname}
              mkdir -p $out/bin
              cp -r . $out/lib/${pname}/

              for bin_name in cmd cmdc command-code commandcode; do
                makeWrapper ${nodejs}/bin/node $out/bin/$bin_name \
                  --add-flags "$out/lib/${pname}/dist/index.mjs" \
                  --set NODE_PATH "$out/lib/${pname}/node_modules" \
                  --set NODE_ENV "production"
              done

              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `command-code_<sanitized-key>` package per entry in the table.
        versionedPackages = builtins.listToAttrs (
          builtins.map
            (key: {
              name = "${pname}_${sanitize key}";
              value = mk key releases.versions.${key};
            })
            (
              builtins.filter (
                key:
                # Only expose versions that have a committed lockfile.
                builtins.pathExists (./deps + "/${key}/package-lock.json")
              ) (builtins.attrNames releases.versions)
            )
        );

        moduleCheck = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            homeManagerModule
            {
              home.username = "cc-test";
              home.homeDirectory =
                if pkgs.stdenv.hostPlatform.isDarwin then "/Users/cc-test" else "/home/cc-test";
              home.stateVersion = "24.11";
              programs.home-manager.enable = true;
              programs.command-code = {
                enable = true;
                config = {
                  provider = "command-code";
                  model = "zai-org/GLM-5.2";
                  reasoningEffort."zai-org/GLM-5.2" = "max";
                };
                settings.input.collapsePastedText = true;
                mcpServers.fixture = {
                  transport = "stdio";
                  command = "${pkgs.coreutils}/bin/true";
                };
              };
            }
          ];
        };

        configTests = import ./tests/config { inherit pkgs lib; };
        projectTests = import ./tests/project { inherit pkgs lib; };
        flakeModuleConsumer =
          flake-parts.lib.mkFlake
            {
              inputs = {
                inherit
                  self
                  nixpkgs
                  flake-utils
                  home-manager
                  flake-parts
                  ;
              };
            }
            {
              systems = [ system ];
              imports = [ flakePartsModule ];
              command-code.project = {
                enable = true;
                settings = {
                  tasteLearning = false;
                  permissions.autoApprove.update = true;
                };
              };
              perSystem =
                { pkgs, ... }:
                {
                  command-code.project.extraPackages = [ pkgs.jq ];
                };
            };
        flakeModuleCheck =
          assert builtins.hasAttr "command-code" flakeModuleConsumer.apps.${system};
          assert builtins.hasAttr "command-code" flakeModuleConsumer.devShells.${system};
          assert builtins.hasAttr "command-code-project-config" flakeModuleConsumer.packages.${system};
          flakeModuleConsumer.checks.${system}.command-code-project-config;
        latestTarball = pkgs.fetchurl {
          url = "https://registry.npmjs.org/${pname}/-/${pname}-${latestRelease.version}.tgz";
          hash = latestRelease.hash;
        };
        schemaArtifactCheck =
          pkgs.runCommand "command-code-schema-artifact-check"
            {
              nativeBuildInputs = [
                pkgs.gnutar
                pkgs.gzip
              ];
            }
            ''
              mkdir package-root
              tar -xzf ${latestTarball} -C package-root
              ${nodejs}/bin/node ${./scripts/verify-config-schema.mjs} \
                --schema ${./schema/upstream.json} \
                --hash ${./schema/upstream.sha256} \
                --expected-version ${lib.escapeShellArg latestRelease.version} \
                --expected-sha256 ${lib.escapeShellArg latestRelease.schemaSha256} \
                --package-dir package-root/package \
                > "$out"
              test -x ${latestPkg}/bin/cmdc
              test -f ${latestPkg}/lib/command-code/${configSchema.package.entrypoint}
              test -f ${latestPkg}/lib/command-code/node_modules/@sindresorhus/slugify/index.js
            '';
      in
      {
        packages = versionedPackages // {
          default = latestPkg;
          command-code = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/command-code";
          };
          command-code = {
            type = "app";
            program = "${latestPkg}/bin/command-code";
          };
        };

        checks = {
          module-eval = moduleCheck.activationPackage;
          config-schema = configTests.command-code-config-schema;
          flake-module = flakeModuleCheck;
          managed-sync = configTests.command-code-managed-sync;
          project-integration = projectTests.command-code-project-integration;
          schema-artifact = schemaArtifactCheck;
        };
      }
    )
    // {
      homeManagerModules = {
        default = homeManagerModule;
        command-code = homeManagerModule;
        "command-code_${sanitize releases.latest}" = homeManagerModule;
      };

      flakeModules = {
        default = flakePartsModule;
        command-code = flakePartsModule;
      };

      lib = {
        inherit
          configSchema
          mkGlobalConfig
          mkProjectConfig
          ;
        inherit (projectFactory) mkProjectIntegration;
      };
    };
}
