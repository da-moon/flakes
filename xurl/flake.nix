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
        version = "1.2.2";

        releaseBySystem = {
          "aarch64-linux" = {
            asset = "xurl_Linux_arm64.tar.gz";
            sha256 = "sha256-I+Mh+44GzesUPkMTzu7UHukVEd8aX/xtYDwo+9fcFXc=";
          };
          "x86_64-linux" = {
            asset = "xurl_Linux_x86_64.tar.gz";
            sha256 = "sha256-AADgrJ1GJb/N8UQei/EXnV+IG9lbMqz2w0is9wQHqpE=";
          };
        };

        currentRelease =
          releaseBySystem.${system}
            or (throw "Unsupported system for xurl flake: ${system}");

        xurl = pkgs.stdenv.mkDerivation rec {
          pname = "xurl";
          inherit version;

          meta = with lib; {
            description = "ngrok-enhanced curl replacement for API and webhook testing";
            homepage = "https://github.com/xdevplatform/xurl";
            license = licenses.mit;
            mainProgram = "xurl";
            platforms = linuxSystems;
            maintainers = [ ];
          };

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
