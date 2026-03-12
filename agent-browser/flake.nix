{
  description = "agent-browser packaged as a Nix flake (npm tarball, offline install)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nodejs = pkgs.nodejs_20;
        pname = "agent-browser";
        version = "0.17.1";

        outputHashBySystem = {
          "aarch64-darwin" = "sha256-ZOSFNEAINB61izAz+4UvuCSZko8AI8ElFqJwttw5VKw=";
          "aarch64-linux" = "sha256-uOvzRDcktyUW+6dcpOy8Y8tZepWgUtLztj4epu0prfQ=";
          "x86_64-darwin" = "sha256-ZOSFNEAINB61izAz+4UvuCSZko8AI8ElFqJwttw5VKw=";
          "x86_64-linux" = "sha256-9apxlE067j7RkpPTSdUKxXa9nCvjB6ZCUkP+6Q+KxRs=";
        };

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
            hash = "sha256-V7Y9iPO7diEWMhiKYLRQLBunZPfTyMzuCFmcj1K67nI=";
          };

          nativeBuildInputs = [ nodejs pkgs.cacert ];

          dontPatchShebangs = true;
          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = outputHashBySystem.${system}
            or (throw "Missing outputHashBySystem entry for system: ${system}");

          buildPhase = ''
            runHook preBuild

            export HOME="$TMPDIR"
            export npm_config_cache="$TMPDIR/.npm"

            tar -xzf "$src"
            cd package

            ${nodejs}/bin/node -e '
              const fs = require("fs");
              const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
              delete pkg.devDependencies;
              fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n");
            '

            npm install --omit=dev --ignore-scripts

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out"
            cp -r . "$out/"
            runHook postInstall
          '';
        };

        agent-browser = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = npmDeps;

          nativeBuildInputs = [
            pkgs.makeWrapper
            pkgs.coreutils
          ];
          dontBuild = true;
          dontConfigure = true;

          installPhase = ''
            runHook preInstall

            mkdir -p "$out/lib/${pname}" "$out/bin"
            cp -r "$src"/* "$out/lib/${pname}/"
            chmod -R u+w "$out/lib/${pname}"

            if [ -d "$out/lib/${pname}/bin" ]; then
              find "$out/lib/${pname}/bin" -type f ! -name 'agent-browser.js' -delete
            fi

            makeWrapper ${nodejs}/bin/node "$out/bin/agent-browser" \
              --add-flags "$out/lib/${pname}/dist/daemon.js" \
              --set NODE_ENV "production" \
              --set AGENT_BROWSER_NATIVE "0" \
              --set NODE_PATH "$out/lib/${pname}/node_modules"

            runHook postInstall
          '';

          doInstallCheck = true;
          installCheckPhase = ''
            runHook preInstallCheck
            export HOME="$TMPDIR"
            timeout 5 "$out/bin/agent-browser" --help >/dev/null || [ "$?" -eq 124 ]
            runHook postInstallCheck
          '';

          meta = with pkgs.lib; {
            description = "Headless browser automation CLI for AI agents";
            homepage = "https://github.com/vercel-labs/agent-browser";
            license = licenses.asl20;
            mainProgram = "agent-browser";
            platforms = platforms.unix;
          };
        };
      in
      {
        packages = {
          default = agent-browser;
          inherit agent-browser;
        };

        apps.default = {
          type = "app";
          program = "${agent-browser}/bin/agent-browser";
        };
      }
    );
}
