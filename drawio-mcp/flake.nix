{
  description = "draw.io MCP server packaged from the @drawio/mcp npm artifact";

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
        nodejs = pkgs.nodejs_22;
        pname = "drawio-mcp";
        npmPackage = "@drawio/mcp";
        tarballName = "mcp";
        version = "1.2.7";

        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-poELdlf1B/ApaRoeZsIM/XFf7ixDLzBjZjy7m4Z86tw=";
        };

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/${npmPackage}/-/${tarballName}-${version}.tgz";
            hash = "sha256-FVdjC/xj+sSwRp9SF2qNVSGbSA580cKxA7MWvvm4QF0=";
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

        drawio-mcp = pkgs.stdenv.mkDerivation {
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

            makeWrapper ${nodejs}/bin/node $out/bin/drawio-mcp \
              --add-flags "$out/lib/${pname}/src/index.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules" \
              --set NODE_ENV "production"

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Official draw.io MCP server for opening and editing diagrams";
            homepage = "https://github.com/jgraph/drawio-mcp";
            license = licenses.asl20;
            mainProgram = "drawio-mcp";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = drawio-mcp;
          "drawio-mcp" = drawio-mcp;
        };

        apps = {
          default = {
            type = "app";
            program = "${drawio-mcp}/bin/drawio-mcp";
          };
          "drawio-mcp" = {
            type = "app";
            program = "${drawio-mcp}/bin/drawio-mcp";
          };
        };
      }
    );
}
