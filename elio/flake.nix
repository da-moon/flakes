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
            asset = "elio-${version}-x86_64-unknown-linux-gnu.tar.gz";
            sourceRoot = "elio-${version}-x86_64-unknown-linux-gnu";
            hash = "sha256-VkCkYo9NeCH++mv+fWql5IotQn3SJ0c3PUsahmg+h94=";
          };
          # aarch64-linux has no upstream release; use the x86_64 binary via qemu or leave unpopulated
          "aarch64-linux" = {
            asset = "elio-${version}-x86_64-unknown-linux-gnu.tar.gz";
            sourceRoot = "elio-${version}-x86_64-unknown-linux-gnu";
            hash = "sha256-1mbn2nm0a0q88bnlvf9q9gy28a3p5h6493vc93p5il5hjr5qygll";
          };
        };

        release =
          releaseBySystem.${system}
            or (throw "Unsupported system for elio: ${system}");

        elio = pkgs.stdenv.mkDerivation rec {
          pname = "elio";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/elio-fm/elio/releases/download/v${version}/${release.asset}";
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
            install -m755 -D elio $out/bin/elio

            # Install desktop entry and icons
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
            mainProgram = "elio";
            platforms = linuxSystems;
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
