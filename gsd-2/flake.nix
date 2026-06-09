{
  description = "GSD Pi CLI packaged from the @opengsd/gsd-pi npm artifact";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        pname = "gsd-2";
        npmPackage = "@opengsd/gsd-pi";
        npmTarballName = "gsd-pi";
        version = "1.2.0";
        nodejs = pkgs.nodejs_22;

        # npm optionalDependencies include native and platform-specific engine packages,
        # so the fixed-output hash is expected to differ by Linux architecture.
        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-JtcCbewBjnaSC061Li2WUwXbbFS7tiNNh20lFwJAwYM=";
        };

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/${npmPackage}/-/${npmTarballName}-${version}.tgz";
            hash = "sha256-vIURB5RZbslnG8ULGb9AlcryILMejrgWYqQjEdIlSpk=";
          };

          nativeBuildInputs = [
            nodejs
            pkgs.pnpm
            pkgs.cacert
          ];

          dontPatchShebangs = true;

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = outputHashBySystem.${system}
            or (throw "Missing outputHashBySystem entry for system: ${system}");

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

            const linuxEngines = new Set([
              "@opengsd/engine-linux-x64-gnu",
              "@opengsd/engine-linux-arm64-gnu",
            ]);
            if (pkg.optionalDependencies) {
              for (const name of Object.keys(pkg.optionalDependencies)) {
                if (name === "fsevents") {
                  delete pkg.optionalDependencies[name];
                  continue;
                }
                if (name.startsWith("@opengsd/engine-")) {
                  if (linuxEngines.has(name)) {
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

            pnpm install --prod --ignore-scripts --shamefully-hoist
            test -d node_modules/@opengsd/engine-linux-x64-gnu \
              || test -d node_modules/@opengsd/engine-linux-arm64-gnu

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r . $out/
            runHook postInstall
          '';
        };

        gsd-2 = pkgs.stdenv.mkDerivation {
          inherit pname version;
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
              --set-default GSD_HOME "$HOME/.gsd" \
              --prefix PATH : ${lib.makeBinPath [
                pkgs.bash
                pkgs.coreutils
                pkgs.findutils
                pkgs.gawk
                pkgs.git
                pkgs.gnugrep
                pkgs.gnused
                pkgs.ripgrep
              ]}

            ln -s $out/bin/gsd $out/bin/gsd-cli

            runHook postInstall
          '';

          meta = with lib; {
            description = "GSD coding agent CLI";
            homepage = "https://github.com/open-gsd/gsd-pi";
            license = licenses.mit;
            mainProgram = "gsd";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = gsd-2;
          "gsd-2" = gsd-2;
        };

        apps = {
          default = {
            type = "app";
            program = "${gsd-2}/bin/gsd";
          };
          gsd = {
            type = "app";
            program = "${gsd-2}/bin/gsd";
          };
          "gsd-cli" = {
            type = "app";
            program = "${gsd-2}/bin/gsd-cli";
          };
        };
      }
    );
}
