{
  description = "Hoangsa CLI packaged as a Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
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
        version = "0.2.5";

        releaseBySystem = {
          "x86_64-linux" = {
            asset = "hoangsa-linux-x64.tar.gz";
            sourceRoot = "hoangsa-linux-x64";
            hash = "sha256-ejh0qfE900uaUlL2KuhbkCdFL5ZlYXEokpl48hJmkb8=";
          };
          "aarch64-linux" = {
            asset = "hoangsa-linux-arm64.tar.gz";
            sourceRoot = "hoangsa-linux-arm64";
            hash = "sha256-84NahoIkdFL1es2HLnmsQfr7ZyZG5YKRqNrY1tVEtgw=";
          };
        };

        release =
          releaseBySystem.${system}
            or (throw "Unsupported system for hoangsa: ${system}");

        hoangsa = pkgs.stdenv.mkDerivation rec {
          pname = "hoangsa";
          inherit version;

          meta = with lib; {
            description = "Hoangsa workflow and memory CLI";
            homepage = "https://github.com/unknown-studio-dev/hoangsa";
            mainProgram = "hoangsa-cli";
            platforms = linuxSystems;
            maintainers = [ ];
          };

          src = pkgs.fetchurl {
            url = "https://github.com/unknown-studio-dev/hoangsa/releases/download/v${version}/${release.asset}";
            inherit (release) hash;
          };

          sourceRoot = release.sourceRoot;
          dontBuild = true;
          dontConfigure = true;
          dontStrip = true;

          nativeBuildInputs = [
            pkgs.autoPatchelfHook
            pkgs.makeWrapper
          ];
          buildInputs = [ (lib.getLib pkgs.stdenv.cc.cc) ];

          installPhase = ''
            runHook preInstall

            mkdir -p $out/lib/hoangsa $out/bin $out/share/hoangsa
            cp -R . $out/lib/hoangsa/
            cp -R templates $out/share/hoangsa/

            for bin in hoangsa-cli hsp hoangsa-memory hoangsa-memory-mcp; do
              makeWrapper "$out/lib/hoangsa/bin/$bin" "$out/bin/$bin"
            done

            runHook postInstall
          '';

        };
      in
      {
        packages = {
          default = hoangsa;
          inherit hoangsa;
        };

        apps = {
          default = {
            type = "app";
            program = "${hoangsa}/bin/hoangsa-cli";
          };
          hoangsa-cli = {
            type = "app";
            program = "${hoangsa}/bin/hoangsa-cli";
          };
          hoangsa-memory-mcp = {
            type = "app";
            program = "${hoangsa}/bin/hoangsa-memory-mcp";
          };
        };
      }
    );
}
