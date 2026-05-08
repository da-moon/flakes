{
  description = "GSD 2 CLI packaged from the gsd-pi npm artifact";

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
        npmPackage = "gsd-pi";
        version = "2.80.0";
        nodejs = pkgs.nodejs_22;

        # npm optionalDependencies include native and platform-specific engine packages,
        # so the fixed-output hash is expected to differ by Linux architecture.
        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-/sGA7xgWH1Oo+CZWRbdNi8dZnQY8BKJ73/P67sqitwk=";
        };

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/${npmPackage}/-/${npmPackage}-${version}.tgz";
            hash = "sha256-H6886rw1/zfp5OfHOowA3uSxMw3zcIeeQZKMaJlefmQ=";
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

            const linuxEngines = new Set([
              "@gsd-build/engine-linux-x64-gnu",
              "@gsd-build/engine-linux-arm64-gnu",
            ]);
            if (pkg.optionalDependencies) {
              for (const name of Object.keys(pkg.optionalDependencies)) {
                if (name === "fsevents") {
                  delete pkg.optionalDependencies[name];
                  continue;
                }
                if (name.startsWith("@gsd-build/engine-")) {
                  if (linuxEngines.has(name)) {
                    pkg.optionalDependencies[name] = pkg.version;
                  } else {
                    delete pkg.optionalDependencies[name];
                  }
                }
              }
            }
            fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2));
NODE

            pnpm install --prod --ignore-scripts --shamefully-hoist
            test -d node_modules/@gsd-build/engine-linux-x64-gnu \
              || test -d node_modules/@gsd-build/engine-linux-arm64-gnu

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

            makeWrapper ${nodejs}/bin/node $out/bin/gsd \
              --add-flags "$out/lib/${pname}/dist/loader.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules" \
              --set NODE_ENV "production" \
              --set npm_config_ignore_scripts "true" \
              --set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD "1" \
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
            homepage = "https://github.com/gsd-build/gsd-2";
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
