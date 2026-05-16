{
  description = "xurl - ngrok-enchanced curl replacement for Linux";

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
        version = "1.1.1";

        releaseBySystem = {
          "aarch64-linux" = {
            asset = "xurl_Linux_arm64.tar.gz";
            sha256 = "sha256-1NJ0JDqm4+MWdO+PvAMRP9AgYs1rKCc5dsuyHz5Cjn0=";
          };
          "x86_64-linux" = {
            asset = "xurl_Linux_x86_64.tar.gz";
            sha256 = "sha256-g3QL0nX0JDIJW0b9GAQOF/pmpOSSGha23b+o0exsvQ0=";
          };
        };

        currentRelease =
          releaseBySystem.${system}
            or (throw "Unsupported system for xurl flake: ${system}");

        xurl = pkgs.stdenv.mkDerivation rec {
          pname = "xurl";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/xdevplatform/xurl/releases/download/v${version}/${currentRelease.asset}";
            hash = currentRelease.sha256;
          };

          sourceRoot = ".";
          dontBuild = true;
          dontConfigure = true;
          dontStrip = true;
          dontPatchELF = true;

          installPhase = ''
            runHook preInstall
            install -m755 -D xurl $out/bin/xurl
            runHook postInstall
          '';

          meta = with lib; {
            description = "ngrok-enhanced curl replacement for API and webhook testing";
            homepage = "https://github.com/xdevplatform/xurl";
            license = licenses.mit;
            mainProgram = "xurl";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = xurl;
          inherit xurl;
        };

        apps = {
          default = {
            type = "app";
            program = "${xurl}/bin/xurl";
          };
          xurl = {
            type = "app";
            program = "${xurl}/bin/xurl";
          };
        };
      }
    );
}
