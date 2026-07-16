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

            # NOTE: npm optionalDependencies can be platform-specific,
            # so the fixed-output hash from "npm install" is not portable across systems.
            # Untested architectures use lib.fakeHash in releases.json to get the correct
            # hash on first build.
            outputHash =
              entry.npmDepsHashes.${system} or (throw "Missing npmDepsHashes entry for system: ${system}");

            # Fixed-output derivation to fetch npm package with prod dependencies
            npmDeps = pkgs.stdenv.mkDerivation {
              name = "${pname}-${version}-npm-deps";

              src = pkgs.fetchurl {
                url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
                hash = entry.hash;
              };

              nativeBuildInputs = [
                nodejs
                pkgs.cacert
              ];

              dontPatchShebangs = true;
              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              inherit outputHash;

              buildPhase = ''
                                runHook preBuild
                                export HOME=$TMPDIR
                                export npm_config_cache=$TMPDIR/.npm
                                tar -xzf $src
                                cd package
                                ${nodejs}/bin/node <<'NODE'
                                const fs = require("fs");
                                const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));

                                // Dev dependencies include platform-specific @lydell/node-pty-* packages
                                // that fail to resolve in the Nix sandbox; they are not needed at runtime.
                                delete pkg.devDependencies;
                                delete pkg.packageManager;

                                function exactSpec(spec) {
                                  if (typeof spec !== "string") return spec;
                                  if (/^(file:|link:|workspace:|git\+|https?:)/.test(spec)) return spec;
                                  const bare = spec.match(/^[~^](\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)$/);
                                  return bare ? bare[1] : spec;
                                }

                                function isExactInstallSpec(spec) {
                                  return /^(file:|link:|workspace:|git\+|https?:)/.test(spec)
                                    || /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(spec);
                                }

                                const unresolved = [];
                                for (const field of ["dependencies", "devDependencies", "optionalDependencies"]) {
                                  for (const [name, spec] of Object.entries(pkg[field] || {})) {
                                    const next = exactSpec(spec);
                                    pkg[field][name] = next;
                                    if (typeof next === "string" && !isExactInstallSpec(next)) {
                                      unresolved.push(field + "." + name + "=" + next);
                                    }
                                  }
                                }

                                if (unresolved.length > 0) {
                                  throw new Error("Non-exact dependency specs remain: " + unresolved.join(", "));
                                }

                                fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n");
                NODE
                                npm install --production --ignore-scripts --legacy-peer-deps \
                                  --os ${if pkgs.stdenv.hostPlatform.isDarwin then "darwin" else "linux"} \
                                  --cpu ${if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x64"}
                                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall
                mkdir -p $out
                cp -r . $out/
                runHook postInstall
              '';
            };
          in
          pkgs.stdenv.mkDerivation {
            inherit pname version;

            meta = with pkgs.lib; {
              description = "Command Code - coding agent that continuously learns your taste";
              homepage = "https://github.com/CommandCodeAI/command-code";
              license = licenses.unfree;
              mainProgram = "command-code";
              platforms = platforms.unix;
            };

            src = npmDeps;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            dontBuild = true;
            dontConfigure = true;

            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib/${pname}
              mkdir -p $out/bin
              cp -r $src/* $out/lib/${pname}/

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
                let
                  hash = releases.versions.${key}.npmDepsHashes.${system} or null;
                in
                # fakeHash entries must stay exposed: update-version.sh builds the
                # attr to learn the real hash from nix's "got:" mismatch line.
                hash != null
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
