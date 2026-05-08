{
  description = "Feynman - Companion AI CLI packaged as a Nix flake";

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
      linuxSystems = [ "x86_64-linux" ];
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        version = "0.2.49";

        feynman = pkgs.stdenv.mkDerivation rec {
          pname = "feynman";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/getcompanion-ai/feynman/releases/download/v${version}/feynman-${version}-linux-x64.tar.gz";
            hash = "sha256-PagUoxctANy+0IiIZkFc1bYu+4bE8i1scnNBCwXW8MY=";
          };

          sourceRoot = "feynman-${version}-linux-x64";
          dontBuild = true;
          dontConfigure = true;
          dontStrip = true;

          nativeBuildInputs = [
            pkgs.autoPatchelfHook
            pkgs.makeWrapper
          ];
          buildInputs = [ (lib.getLib pkgs.stdenv.cc.cc) ];
          autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ];

          installPhase = ''
            runHook preInstall

            mkdir -p $out/libexec/feynman $out/bin
            cp -R . $out/libexec/feynman/

            makeWrapper $out/libexec/feynman/node/bin/node $out/bin/feynman \
              --add-flags "$out/libexec/feynman/app/bin/feynman.js"

            runHook postInstall
          '';

          meta = with lib; {
            description = "Companion AI CLI";
            homepage = "https://github.com/getcompanion-ai/feynman";
            mainProgram = "feynman";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = feynman;
          inherit feynman;
        };

        apps = {
          default = {
            type = "app";
            program = "${feynman}/bin/feynman";
          };
          feynman = {
            type = "app";
            program = "${feynman}/bin/feynman";
          };
        };
      }
    );
}
