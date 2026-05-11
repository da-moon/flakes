{
  description = "Context Mode - MCP plugin for context-efficient coding on Linux";

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
        lib = nixpkgs.lib;

        # Use Node 22 on Linux so runtime falls back to built-in node:sqlite
        # instead of needing the optional better-sqlite3 native addon.
        pname = "context-mode";
        version = "1.0.121";
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ pname ];
        };
        nodejs = pkgs.nodejs_22;

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/context-mode/-/context-mode-${version}.tgz";
            hash = "sha256-BQu3xhQ9V5/td8Lg5m/X3NSaqS161yfoCRkbK/NDlSQ=";
          };

          nativeBuildInputs = [
            nodejs
            pkgs.pnpm
            pkgs.cacert
          ];

          dontPatchShebangs = true;

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = "sha256-q1fYHIN2sQ5BovquH/ZrcnraX0NZ2bsUKcF+yzRT2bQ=";

          buildPhase = ''
            runHook preBuild

            export HOME=$TMPDIR
            tar -xzf $src
            cd package

            ${nodejs}/bin/node -e '
              const fs = require("fs");
              const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
              delete pkg.devDependencies;
              delete pkg.optionalDependencies;
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

        contextMode = pkgs.stdenv.mkDerivation {
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

            makeWrapper ${nodejs}/bin/node $out/bin/.context-mode-real \
              --add-flags "$out/lib/${pname}/cli.bundle.mjs" \
              --set NODE_PATH "$out/lib/${pname}/node_modules" \
              --set NODE_ENV "production" \
              --prefix PATH : ${lib.makeBinPath [
                pkgs.git
                pkgs.bash
                pkgs.coreutils
                pkgs.findutils
                pkgs.ripgrep
              ]}

            cat > $out/bin/context-mode <<'EOF'
            #!/usr/bin/env bash
            set -euo pipefail

            case "''${1:-}" in
              --version|-V)
                echo "context-mode __VERSION__"
                exit 0
                ;;
              --help|-h)
                cat <<'USAGE'
            context-mode <command>

            Common commands:
              context-mode setup
              context-mode doctor
              context-mode --version

            With no arguments, the upstream CLI starts the MCP server on stdio.
            USAGE
                exit 0
                ;;
            esac

            exec "__REAL_BIN__" "$@"
            EOF
            substituteInPlace $out/bin/context-mode \
              --replace-fail "__VERSION__" "${version}" \
              --replace-fail "__REAL_BIN__" "$out/bin/.context-mode-real"
            chmod +x $out/bin/context-mode

            runHook postInstall
          '';

          meta = with lib; {
            description = "MCP plugin for context-efficient AI coding workflows";
            homepage = "https://github.com/mksglu/context-mode";
            license = licenses.elastic20;
            mainProgram = "context-mode";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = contextMode;
          "context-mode" = contextMode;
        };

        apps = {
          default = {
            type = "app";
            program = "${contextMode}/bin/context-mode";
          };
          "context-mode" = {
            type = "app";
            program = "${contextMode}/bin/context-mode";
          };
        };
      }
    );
}
