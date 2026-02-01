{
  description = "csso-cli packaged as a Nix flake (npm tarball, offline install)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nodejs = pkgs.nodejs_20;
        pname = "csso-cli";
        version = "4.0.2";

        # NOTE: npm optionalDependencies can be platform-specific,
        # so the fixed-output hash from "npm install" is not portable across systems.
        # Use pkgs.lib.fakeHash for untested architectures to get the correct hash on first build.
        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-/hpU7FKz/td9NqlEINs1eeFTR9Mb6FHklhzauK8RLmo=";
        };

        # Fixed-output derivation to fetch npm package with prod dependencies
        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
            hash = "sha256-25rzgJXTKZKvWKJwFdO1PMLj4nug/A7T2NdftSesnz0=";
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

        csso-cli = pkgs.stdenv.mkDerivation {
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
            makeWrapper ${nodejs}/bin/node $out/bin/csso \
              --add-flags "$out/lib/${pname}/bin/csso" \
              --set NODE_PATH "$out/lib/${pname}/node_modules"
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Command-line CSS optimizer (CSSO) wrapper from npm";
            homepage = "https://github.com/css/csso-cli";
            license = licenses.mit;
            platforms = platforms.unix;
          };
        };
      in
      {
        packages = {
          default = csso-cli;
          inherit csso-cli;
        };
        apps.default = {
          type = "app";
          program = "${csso-cli}/bin/csso";
        };
      });
}
