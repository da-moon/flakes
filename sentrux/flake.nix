{
  description = "Sentrux packaged as a Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
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

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];

      # Release asset filenames are arch-specific but version-agnostic.
      binaryAssetBySystem = {
        "x86_64-linux" = "sentrux-linux-x86_64";
        "aarch64-linux" = "sentrux-linux-aarch64";
      };
      grammarAssetBySystem = {
        "x86_64-linux" = "grammars-linux-x86_64.tar.gz";
        "aarch64-linux" = "grammars-linux-aarch64.tar.gz";
      };
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        # Builder: derive a sentrux package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src-url/
        # hash(es) now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;

            binaryAsset =
              binaryAssetBySystem.${system}
                or (throw "Unsupported system for sentrux: ${system}");
            grammarAsset =
              grammarAssetBySystem.${system}
                or (throw "Unsupported system for sentrux: ${system}");
            binaryHash =
              entry.binaryHashes.${system}
                or (throw "Missing binaryHashes entry for system: ${system}");
            grammarHash =
              entry.grammarHashes.${system}
                or (throw "Missing grammarHashes entry for system: ${system}");

            grammars = pkgs.fetchurl {
              url = "https://github.com/sentrux/sentrux/releases/download/v${version}/${grammarAsset}";
              hash = grammarHash;
            };
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "sentrux";
            inherit version;

            meta = with lib; {
              description = "Code intelligence and repository visualization tool";
              homepage = "https://github.com/sentrux/sentrux";
              mainProgram = "sentrux";
              platforms = linuxSystems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/sentrux/sentrux/releases/download/v${version}/${binaryAsset}";
              hash = binaryHash;
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

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `sentrux_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "sentrux_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          sentrux = latestPkg;
        } // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/sentrux";
          };
          sentrux = {
            type = "app";
            program = "${latestPkg}/bin/sentrux";
          };
        };
      }
    );
}
