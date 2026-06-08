{
  description = "Elio - Terminal music player packaged as a Nix flake";

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
        version = "1.8.0";

        releaseBySystem = {
          "x86_64-linux" = {
            target = "x86_64-unknown-linux-gnu";
            sha256 = "sha256-VkCkYo9NeCH++mv+fWql5IotQn3SJ0c3PUsahmg+h94=";
            needsAutoPatchelf = true;
          };
          # No upstream aarch64-linux release; macOS ARM exists but is not Linux.
          "aarch64-linux" = {
            target = "aarch64-unknown-linux-gnu";
            sha256 = "";
            needsAutoPatchelf = true;
          };
        };

        currentRelease =
          releaseBySystem.${system}
            or (throw "Unsupported system for elio flake: ${system}");

        elio = pkgs.stdenv.mkDerivation rec {
          pname = "elio";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/elio-fm/elio/releases/download/v${version}/elio-${version}-${currentRelease.target}.tar.gz";
            hash = currentRelease.sha256;
          };

          sourceRoot = "elio-${version}-${currentRelease.target}";
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
            install -m755 -D elio $out/bin/elio

            mkdir -p $out/share/applications
            install -m644 packaging/linux/elio.desktop $out/share/applications/elio.desktop

            for size in 48 128 256 512; do
              mkdir -p $out/share/icons/hicolor/''${size}x''${size}/apps
              install -m644 packaging/linux/icons/hicolor/''${size}x''${size}/apps/elio.png \
                $out/share/icons/hicolor/''${size}x''${size}/apps/elio.png
            done

            runHook postInstall
          '';

          meta = with lib; {
            description = "Elio - Terminal music player";
            homepage = "https://github.com/elio-fm/elio";
            license = licenses.mit;
            mainProgram = "elio";
            platforms = [ "x86_64-linux" ];
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = elio;
          inherit elio;
        };

        apps = {
          default = {
            type = "app";
            program = "${elio}/bin/elio";
          };
          elio = {
            type = "app";
            program = "${elio}/bin/elio";
          };
        };
      }
    );
}
