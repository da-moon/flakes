{
  description = "Gemini CLI - AI agent that brings the power of Gemini directly into your terminal";

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
        pname = "gemini-cli";
        version = "0.27.2";

        # Platform-specific output hashes for npm install
        # Use pkgs.lib.fakeHash for untested architectures to get the correct hash on first build
        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-frtRH9OlJeDdFNst7JDmg7T7O18tJND0pr+Z+761xTM=";
        };

        # Fixed-output derivation that runs npm install with network access
        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/@google/gemini-cli/-/gemini-cli-${version}.tgz";
            sha256 = "sha256-kjtNQIZWiozasRrEAq2WJMgiQ25aFUcmzpbUpu5EzHI=";
          };

          nativeBuildInputs = [ nodejs pkgs.cacert ];
          dontPatchShebangs = true;

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = outputHashBySystem.${system}
            or (throw "Missing outputHashBySystem entry for system: ${system}");

          buildPhase = ''
            runHook preBuild
            export HOME=$TMPDIR
            export npm_config_cache=$TMPDIR/.npm
            tar -xzf $src
            cd package
            npm install --production --ignore-scripts
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r . $out/
            runHook postInstall
          '';
        };

        gemini-cli = pkgs.stdenv.mkDerivation {
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

            makeWrapper ${nodejs}/bin/node $out/bin/gemini \
              --add-flags "$out/lib/${pname}/dist/index.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules" \
              --set NODE_ENV "production" \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.ripgrep ]} \
              --set DISABLE_AUTO_UPDATE "1"

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Gemini CLI - AI agent that brings the power of Gemini directly into your terminal";
            homepage = "https://github.com/google-gemini/gemini-cli";
            platforms = platforms.unix;
            maintainers = [ ];
          };
        };

      in
      {
        packages = {
          default = gemini-cli;
          gemini-cli = gemini-cli;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            nodejs_20
            ripgrep
            git
          ];

          shellHook = ''
            echo "Gemini CLI Development Shell"
            echo "Node.js: $(node --version)"
          '';
        };

        apps = {
          default = {
            type = "app";
            program = "${gemini-cli}/bin/gemini";
          };
          gemini = {
            type = "app";
            program = "${gemini-cli}/bin/gemini";
          };
        };
      }
    );
}
