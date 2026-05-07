{
  description = "RTK - Rust Token Killer CLI";

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
        version = "0.39.0";

        releaseBySystem = {
          "aarch64-linux" = {
            target = "aarch64-unknown-linux-gnu";
            sha256 = "sha256-aP00y/9GhWgmoJLCYdZ7G4C1ee9sigQAwAieFDJecJ0=";
            needsAutoPatchelf = true;
          };
          "x86_64-linux" = {
            target = "x86_64-unknown-linux-musl";
            sha256 = "sha256-BuWCuhmW7wPnakQbmJarp53Rt0bOU50igpbGgbHFQBw=";
            needsAutoPatchelf = false;
          };
        };

        currentRelease =
          releaseBySystem.${system}
            or (throw "Unsupported system for rtk flake: ${system}");

        rtk = pkgs.stdenv.mkDerivation rec {
          pname = "rtk";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/rtk-ai/rtk/releases/download/v${version}/rtk-${currentRelease.target}.tar.gz";
            hash = currentRelease.sha256;
          };

          sourceRoot = ".";
          dontBuild = true;
          dontConfigure = true;
          dontStrip = true;

          nativeBuildInputs = lib.optionals currentRelease.needsAutoPatchelf [
            pkgs.autoPatchelfHook
          ];

          buildInputs = lib.optionals currentRelease.needsAutoPatchelf [
            pkgs.stdenv.cc.cc.lib
          ];

          installPhase = ''
            runHook preInstall
            install -m755 -D rtk $out/bin/rtk
            runHook postInstall
          '';

          meta = with lib; {
            description = "High-performance CLI proxy that reduces LLM token consumption";
            homepage = "https://github.com/rtk-ai/rtk";
            license = licenses.mit;
            mainProgram = "rtk";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = rtk;
          inherit rtk;
        };

        apps = {
          default = {
            type = "app";
            program = "${rtk}/bin/rtk";
          };
          rtk = {
            type = "app";
            program = "${rtk}/bin/rtk";
          };
        };
      }
    );
}
