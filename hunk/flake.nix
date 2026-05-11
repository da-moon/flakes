{
  description = "Hunk - AI-friendly diff review CLI packaged as a Nix flake";

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
        version = "0.11.1";

        releaseBySystem = {
          "x86_64-linux" = {
            asset = "hunkdiff-linux-x64.tar.gz";
            sourceRoot = "hunkdiff-linux-x64";
            hash = "sha256-XQkhUXxA9Vsd1ILgyo3cRqrOTfYNgVSUyiY9ZnQYchQ=";
          };
          "aarch64-linux" = {
            asset = "hunkdiff-linux-arm64.tar.gz";
            sourceRoot = "hunkdiff-linux-arm64";
            hash = "sha256-vFzAW+6fXj6kNWm7V7Oj46F8xfjLMssrWti158uQ8ec=";
          };
        };

        release =
          releaseBySystem.${system}
            or (throw "Unsupported system for hunk: ${system}");

        hunk = pkgs.stdenv.mkDerivation rec {
          pname = "hunk";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/modem-dev/hunk/releases/download/v${version}/${release.asset}";
            inherit (release) hash;
          };

          sourceRoot = release.sourceRoot;
          dontBuild = true;
          dontConfigure = true;
          dontStrip = true;

          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = [ (lib.getLib pkgs.stdenv.cc.cc) ];

          installPhase = ''
            runHook preInstall
            install -m755 -D hunk $out/bin/hunk
            runHook postInstall
          '';

          meta = with lib; {
            description = "AI-friendly diff review CLI";
            homepage = "https://github.com/modem-dev/hunk";
            mainProgram = "hunk";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = hunk;
          inherit hunk;
        };

        apps = {
          default = {
            type = "app";
            program = "${hunk}/bin/hunk";
          };
          hunk = {
            type = "app";
            program = "${hunk}/bin/hunk";
          };
        };
      }
    );
}
