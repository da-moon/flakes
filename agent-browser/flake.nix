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
        version = "0.25.3";

        outputHashBySystem = {
          "aarch64-darwin" = pkgs.lib.fakeHash;
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-darwin" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-mp6eJxPjGSizUE0A9ScQ+9NqPjlDkjDaHk2Kn7rARds=";
        };

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
            hash = "sha256-nImOug/P/8Mj9WDvZrsaArPQewcq7YI41LbGxGpByNs=";
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
          ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            pkgs.autoPatchelfHook
          ];
          buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            pkgs.stdenv.cc.cc.lib
          ];
          dontBuild = true;
          dontConfigure = true;

          installPhase = ''
            runHook preInstall

            mkdir -p "$out/lib/${pname}" "$out/bin"
            cp -r "$src"/* "$out/lib/${pname}/"
            chmod -R u+w "$out/lib/${pname}"
            entrypoint=""
            if [ -f "$out/lib/${pname}/bin/agent-browser.js" ]; then
              entrypoint="$out/lib/${pname}/bin/agent-browser.js"
            elif [ -f "$out/lib/${pname}/dist/daemon.js" ]; then
              entrypoint="$out/lib/${pname}/dist/daemon.js"
            else
              echo "Could not find agent-browser entrypoint" >&2
              exit 1
            fi

            makeWrapper ${nodejs}/bin/node "$out/bin/agent-browser" \
              --add-flags "$entrypoint" \
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
