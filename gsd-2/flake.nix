{
  description = "GSD Pi CLI packaged from the @opengsd/gsd-pi npm artifact";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
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
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        pname = "gsd-2";
        npmPackage = "@opengsd/gsd-pi";
        npmTarballName = "gsd-pi";
        nodejs = pkgs.nodejs_22;
        dependencyOS = if pkgs.stdenv.hostPlatform.isDarwin then "darwin" else "linux";
        dependencyCPU = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x64";
        enginePackage =
          if pkgs.stdenv.hostPlatform.isDarwin then
            "@opengsd/engine-darwin-${dependencyCPU}"
          else
            "@opengsd/engine-linux-${dependencyCPU}-gnu";

        # Builder: derive a gsd-2 package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/tarball
        # hash/per-arch npm-deps hash now come from `entry`.
        mk =
          key: entry:
          let
            version = entry.version;

            # npm optionalDependencies include native and platform-specific engine packages,
            # so the fixed-output hash is expected to differ by Linux architecture.
            outputHashBySystem = entry.npmDepsHashes;

            npmDeps = pkgs.stdenv.mkDerivation {
              name = "${pname}-${version}-npm-deps";

              src = pkgs.fetchurl {
                url = "https://registry.npmjs.org/${npmPackage}/-/${npmTarballName}-${version}.tgz";
                hash = entry.hash;
              };

              nativeBuildInputs = [
                nodejs
                pkgs.pnpm
                pkgs.cacert
              ];

              dontPatchShebangs = true;

              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              outputHash =
                outputHashBySystem.${system} or (throw "Missing outputHashBySystem entry for system: ${system}");

              buildPhase = ''
                                runHook preBuild

                                export HOME=$TMPDIR
                                export npm_config_cache=$TMPDIR/npm-cache
                                export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

                                tar -xzf $src
                                cd package

                                ${nodejs}/bin/node <<'NODE'
                                const fs = require("fs");
                                const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
                                delete pkg.devDependencies;
                                delete pkg.packageManager;
                                delete pkg.workspaces;
                                if (pkg.scripts) {
                                  delete pkg.scripts.postinstall;
                                }

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

                                const targetOS = "${dependencyOS}";
                                const targetEngine = "${enginePackage}";
                                if (pkg.optionalDependencies) {
                                  for (const name of Object.keys(pkg.optionalDependencies)) {
                                    if (name === "fsevents" && targetOS !== "darwin") {
                                      delete pkg.optionalDependencies[name];
                                      continue;
                                    }
                                    if (name.startsWith("@opengsd/engine-")) {
                                      if (name === targetEngine) {
                                        pkg.optionalDependencies[name] = pkg.version;
                                      } else {
                                        delete pkg.optionalDependencies[name];
                                      }
                                    }
                                  }
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
                                fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2));
                NODE

                                pnpm install --prod --ignore-scripts --shamefully-hoist \
                                  --os ${dependencyOS} \
                                  --cpu ${dependencyCPU}
                                test -d "node_modules/${enginePackage}"

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

            meta = with lib; {
              description = "GSD coding agent CLI";
              homepage = "https://github.com/open-gsd/gsd-pi";
              license = licenses.mit;
              mainProgram = "gsd";
              platforms = systems;
              maintainers = [ ];
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
                            chmod -R u+w $out/lib/${pname}/node_modules

                            export GSD_INSTALL_ROOT="$out/lib/${pname}"
                            ${nodejs}/bin/node <<'NODE'
                            const fs = require("fs");
                            const path = require("path");

                            const root = process.env.GSD_INSTALL_ROOT;
                            const packagesDir = path.join(root, "packages");
                            const nodeModulesDir = path.join(root, "node_modules");

                            if (fs.existsSync(packagesDir)) {
                              for (const entry of fs.readdirSync(packagesDir, { withFileTypes: true })) {
                                if (!entry.isDirectory()) continue;

                                const packageDir = path.join(packagesDir, entry.name);
                                const packageJsonPath = path.join(packageDir, "package.json");
                                if (!fs.existsSync(packageJsonPath)) continue;

                                const pkg = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));
                                if (typeof pkg.name !== "string" || !pkg.name.startsWith("@")) continue;

                                const [scope, name] = pkg.name.split("/");
                                if (!scope || !name) continue;

                                const scopeDir = path.join(nodeModulesDir, scope);
                                const linkPath = path.join(scopeDir, name);
                                fs.mkdirSync(scopeDir, { recursive: true });
                                if (!fs.existsSync(linkPath)) {
                                  fs.symlinkSync(packageDir, linkPath, "dir");
                                }
                              }
                            }
              NODE

                            makeWrapper ${nodejs}/bin/node $out/bin/gsd \
                              --add-flags "$out/lib/${pname}/dist/loader.js" \
                              --set NODE_PATH "$out/lib/${pname}/node_modules" \
                              --set NODE_ENV "production" \
                              --set npm_config_ignore_scripts "true" \
                              --set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD "1" \
                              --set-default GSD_HOME "\$HOME/.gsd" \
                              --prefix PATH : ${
                                lib.makeBinPath [
                                  pkgs.bash
                                  pkgs.coreutils
                                  pkgs.findutils
                                  pkgs.gawk
                                  pkgs.git
                                  pkgs.gnugrep
                                  pkgs.gnused
                                  pkgs.ripgrep
                                ]
                              }

                            ln -s $out/bin/gsd $out/bin/gsd-cli

                            runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `gsd-2_<sanitized-key>` package per entry in the table.
        versionPackages =
          lib.mapAttrs' (key: entry: lib.nameValuePair "gsd-2_${sanitizeKey key}" (mk key entry))
            (
              lib.filterAttrs (
                _: entry:
                let
                  hash = entry.npmDepsHashes.${system} or null;
                in
                # fakeHash entries must stay exposed: update-version.sh builds the
                # attr to learn the real hash from nix's "got:" mismatch line.
                hash != null
              ) releases.versions
            );
      in
      {
        packages = {
          default = latestPkg;
          "gsd-2" = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/gsd";
          };
          gsd = {
            type = "app";
            program = "${latestPkg}/bin/gsd";
          };
          "gsd-cli" = {
            type = "app";
            program = "${latestPkg}/bin/gsd-cli";
          };
        };
      }
    );
}
