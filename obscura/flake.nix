{
  description = "Obscura - lightweight headless browser for Linux";

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
        version = "0.1.2";

        obscura = pkgs.stdenv.mkDerivation rec {
          pname = "obscura";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/h4ckf0r0day/obscura/releases/download/v${version}/obscura-x86_64-linux.tar.gz";
            hash = "sha256-MHzliv/qP/OSI79XPPORyIg+CBHTbpzXGF+MfFSUKAI=";
          };

          sourceRoot = ".";
          dontBuild = true;
          dontConfigure = true;
          dontStrip = true;

          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = [ (lib.getLib pkgs.stdenv.cc.cc) ];

          installPhase = ''
            runHook preInstall
            install -m755 -D obscura $out/bin/obscura
            runHook postInstall
          '';

          meta = with lib; {
            description = "Lightweight headless browser for web scraping and automation";
            homepage = "https://github.com/h4ckf0r0day/obscura";
            license = licenses.asl20;
            mainProgram = "obscura";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = obscura;
          inherit obscura;
        };

        apps = {
          default = {
            type = "app";
            program = "${obscura}/bin/obscura";
          };
          obscura = {
            type = "app";
            program = "${obscura}/bin/obscura";
          };
        };
      }
    );
}
