{
  description = "Obscura - lightweight cross-platform headless browser";

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
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        # Version table: consumers select the latest OR any past version.
        # New entries are appended by scripts/update-version.sh via jq — do
        # NOT hand-edit the version data in this file.
        releases = builtins.fromJSON (builtins.readFile ./releases.json);

        assetBySystem = {
          "x86_64-linux" = "obscura-x86_64-linux.tar.gz";
          "aarch64-linux" = "obscura-aarch64-linux.tar.gz";
          "x86_64-darwin" = "obscura-x86_64-macos.tar.gz";
          "aarch64-darwin" = "obscura-aarch64-macos.tar.gz";
        };

        # Builder: derive an obscura package from one releases.json entry.
        mk =
          key: entry:
          let
            version = entry.version;
            rev = entry.rev;
            binaryHash = entry.hashes.${system};
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "obscura";
            inherit version;

            meta = with lib; {
              description = "Lightweight headless browser for web scraping and automation";
              homepage = "https://github.com/h4ckf0r0day/obscura";
              license = licenses.asl20;
              mainProgram = "obscura";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/h4ckf0r0day/obscura/releases/download/v${rev}/${assetBySystem.${system}}";
              hash = binaryHash;
            };

            sourceRoot = ".";
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;

            nativeBuildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.autoPatchelfHook
            ];
            buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              (lib.getLib pkgs.stdenv.cc.cc)
            ];

            installPhase = ''
              runHook preInstall
              install -m755 -D obscura $out/bin/obscura
              runHook postInstall
            '';

          };

        # Sanitize a JSON key into a valid attribute-name suffix.
        sanitizeKey = key: builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] key;

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `obscura_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "obscura_${sanitizeKey key}" (mk key entry)
        ) releases.versions;

      in
      {
        packages = {
          default = latestPkg;
          obscura = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/obscura";
          };
          obscura = {
            type = "app";
            program = "${latestPkg}/bin/obscura";
          };
        };
      }
    );
}
