{
  description = "Sentrux packaged as a Nix flake";

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
        version = "0.5.7";

        releaseBySystem = {
          "x86_64-linux" = {
            binaryAsset = "sentrux-linux-x86_64";
            binaryHash = "sha256-Mjf4D+INVKrU3u+ooUPw1gVDu10tatiR60JDLxVXJaY=";
            grammarAsset = "grammars-linux-x86_64.tar.gz";
            grammarHash = "sha256-iEnx6wffP21Ooe1CLY3uS5t5olBoL6VkZnXa5GZVRFQ=";
          };
          "aarch64-linux" = {
            binaryAsset = "sentrux-linux-aarch64";
            binaryHash = "sha256-J+G0o+RxazQd126XNqVVPGc3wk4WXMJ+Dbw5nMW014Y=";
            grammarAsset = "grammars-linux-aarch64.tar.gz";
            grammarHash = "sha256-8fuLTRD5YvPNynHq9oZi36lx5Q4i07iUfRvCKcQX8lM=";
          };
        };

        release =
          releaseBySystem.${system}
            or (throw "Unsupported system for sentrux: ${system}");

        grammars = pkgs.fetchurl {
          url = "https://github.com/sentrux/sentrux/releases/download/v${version}/${release.grammarAsset}";
          hash = release.grammarHash;
        };

        sentrux = pkgs.stdenv.mkDerivation rec {
          pname = "sentrux";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/sentrux/sentrux/releases/download/v${version}/${release.binaryAsset}";
            hash = release.binaryHash;
          };

          dontUnpack = true;
          dontBuild = true;
          dontConfigure = true;
          dontStrip = true;

          nativeBuildInputs = [
            pkgs.autoPatchelfHook
            pkgs.makeWrapper
          ];

          buildInputs = with pkgs; [
            gtk3
            glib
            openssl
            zlib
            libxkbcommon
            wayland
            libglvnd
            cairo
            pango
            harfbuzz
            gdk-pixbuf
            atk
            at-spi2-atk
            libepoxy
            dbus
            fontconfig
            freetype
            (lib.getLib stdenv.cc.cc)
            libx11
            libxext
            libxi
            libxcursor
            libxrandr
            libxinerama
            libxdamage
            libxcomposite
            libxfixes
          ];

          installPhase = ''
            runHook preInstall

            install -m755 -D $src $out/libexec/sentrux/sentrux
            mkdir -p $out/share/sentrux/grammars
            tar -xzf ${grammars} -C $out/share/sentrux/grammars

            makeWrapper $out/libexec/sentrux/sentrux $out/bin/sentrux \
              --set SENTRUX_GRAMMARS_DIR "$out/share/sentrux/grammars"

            runHook postInstall
          '';

          meta = with lib; {
            description = "Code intelligence and repository visualization tool";
            homepage = "https://github.com/sentrux/sentrux";
            mainProgram = "sentrux";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = sentrux;
          inherit sentrux;
        };

        apps = {
          default = {
            type = "app";
            program = "${sentrux}/bin/sentrux";
          };
          sentrux = {
            type = "app";
            program = "${sentrux}/bin/sentrux";
          };
        };
      }
    );
}
