{
  description = "askii - TUI based ASCII diagram editor packaged from GitHub releases";

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
      systems = [
        "x86_64-linux"
        "x86_64-darwin"
      ];

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        assetBySystem = {
          "x86_64-linux" = "askii";
          "x86_64-darwin" = "askii-osx";
        };

        # Builder: derive an askii package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src-url/hash
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            asset = assetBySystem.${system};
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "askii";
            inherit version;

            meta = with lib; {
              description = "TUI based ASCII diagram editor";
              homepage = "https://github.com/nytopop/askii";
              license = licenses.mit;
              mainProgram = "askii";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/nytopop/askii/releases/download/v${version}/${asset}";
              hash = entry.hashes.${system};
            };

            dontUnpack = true;
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;

            nativeBuildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.autoPatchelfHook
            ];
            buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              (lib.getLib pkgs.stdenv.cc.cc)
              pkgs.libbsd
              pkgs.libmd
              pkgs.libxau
              pkgs.libxdmcp
              pkgs.libxcb
            ];

            installPhase = ''
              runHook preInstall
              install -m755 -D "$src" "$out/bin/askii"
              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `askii_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "askii_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          askii = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/askii";
          };
          askii = {
            type = "app";
            program = "${latestPkg}/bin/askii";
          };
        };
      }
    );
}
