{
  description = "Evolver - self-evolution engine for AI agents";

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
        nodejs = pkgs.nodejs_22;
        pname = "evolver";
        version = "1.83.0";

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/@evomap/evolver/-/evolver-${version}.tgz";
            hash = "sha256-619H7BflHeHqk+9bjwX16ZrL/FGlHkLPINkjIbIhdEw=";
          };

          nativeBuildInputs = [
            nodejs
            pkgs.pnpm
            pkgs.cacert
          ];

          dontPatchShebangs = true;

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = "sha256-2q2ukxXs5RWH+rcEKK0Xcz2suWj9USS7Zvfg66uVnyI=";

          buildPhase = ''
            runHook preBuild

            export HOME=$TMPDIR
            tar -xzf $src
            cd package

            ${nodejs}/bin/node -e '
              const fs = require("fs");
              const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
              delete pkg.devDependencies;
              delete pkg.packageManager;
              fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2));
            '

            pnpm install --prod --ignore-scripts --shamefully-hoist

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r . $out/
            runHook postInstall
          '';
        };

        evolver = pkgs.stdenv.mkDerivation {
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

            makeWrapper ${nodejs}/bin/node $out/bin/.evolver-real \
              --add-flags "$out/lib/${pname}/index.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules" \
              --set NODE_ENV "production" \
              --prefix PATH : ${lib.makeBinPath [
                pkgs.git
                pkgs.bash
                pkgs.coreutils
              ]}

            cat > $out/bin/evolver <<'EOF'
            #!/usr/bin/env bash
            set -euo pipefail

            export MEMORY_DIR="''${MEMORY_DIR:-$PWD/memory}"

            case "''${1:-}" in
              --version|-V)
                echo "evolver __VERSION__"
                exit 0
                ;;
            esac

            exec "__REAL_BIN__" "$@"
            EOF
            substituteInPlace $out/bin/evolver \
              --replace-fail "__VERSION__" "${version}" \
              --replace-fail "__REAL_BIN__" "$out/bin/.evolver-real"
            chmod +x $out/bin/evolver

            runHook postInstall
          '';

          meta = with lib; {
            description = "Self-evolution engine for AI agents";
            homepage = "https://github.com/EvoMap/evolver";
            license = licenses.gpl3Plus;
            mainProgram = "evolver";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = evolver;
          inherit evolver;
        };

        apps = {
          default = {
            type = "app";
            program = "${evolver}/bin/evolver";
          };
          evolver = {
            type = "app";
            program = "${evolver}/bin/evolver";
          };
        };
      }
    );
}
