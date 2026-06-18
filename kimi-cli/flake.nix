{
  description = "Kimi Code - native Linux CLI packaged as a Nix flake";

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
        version = "0.18.0";

        releasePlatformBySystem = {
          x86_64-linux = "linux-x64";
          aarch64-linux = "linux-arm64";
        };

        binarySha256BySystem = {
          # update-version.sh managed hashes.
          x86_64-linux = "sha256-5dnOiC1JCkptfP7zOjPuUNvcEW2iXWD6u1YeinOYVG0=";
          aarch64-linux = "sha256-ILOQwY4NC1AA6YGTq7CA4iFM5IlljTbLeio/EvTx6nU=";
        };

        releasePlatform = releasePlatformBySystem.${system};
        binarySha256 = binarySha256BySystem.${system};

        kimi-cli = pkgs.stdenv.mkDerivation rec {
          pname = "kimi-cli";
          inherit version;

          meta = with lib; {
            description = "Kimi Code - AI coding assistant CLI for terminal";
            homepage = "https://code.kimi.com";
            license = licenses.asl20;
            mainProgram = "kimi";
            platforms = linuxSystems;
            maintainers = [ ];
          };

          src = pkgs.fetchurl {
            url = "https://code.kimi.com/kimi-code/binaries/${version}/kimi-code-${releasePlatform}";
            sha256 = binarySha256;
          };

          dontUnpack = true;
          dontBuild = true;
          dontConfigure = true;
          dontStrip = true;

          nativeBuildInputs = with pkgs; [
            autoPatchelfHook
          ];

          buildInputs = [
            pkgs.stdenv.cc.cc.lib
          ];

          installPhase = ''
            runHook preInstall

            mkdir -p $out/bin
            install -m755 $src $out/bin/kimi

            runHook postInstall
          '';
        };

      in
      {
        packages = {
          default = kimi-cli;
          kimi-cli = kimi-cli;
        };

        apps = {
          default = {
            type = "app";
            program = "${kimi-cli}/bin/kimi";
          };
          kimi = {
            type = "app";
            program = "${kimi-cli}/bin/kimi";
          };
        };
      }
    );
}
