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
        version = "0.15.3";

        releaseBySystem = {
          "x86_64-linux" = {
            asset = "hunkdiff-linux-x64.tar.gz";
            sourceRoot = "hunkdiff-linux-x64";
            hash = "sha256-cIlbUiSgvrCaw/8bx/9ELDL6XgF2Sa9xtFIhv4KcC1s=";
          };
          "aarch64-linux" = {
            asset = "hunkdiff-linux-arm64.tar.gz";
            sourceRoot = "hunkdiff-linux-arm64";
            hash = "sha256-zegp14pIC6bOdsQbbe/I/B5vWLo85cCdTBNrMQw9FPI=";
          };
        };

        release =
          releaseBySystem.${system}
            or (throw "Unsupported system for hunk: ${system}");

        hunk = pkgs.stdenv.mkDerivation rec {
          pname = "hunk";
          inherit version;

          meta = with lib; {
            description = "AI-friendly diff review CLI";
            homepage = "https://github.com/modem-dev/hunk";
            mainProgram = "hunk";
            platforms = linuxSystems;
            maintainers = [ ];
          };

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
