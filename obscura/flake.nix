{
  description = "Obscura - lightweight headless browser for Linux";

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
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        # Version table: consumers select the latest OR any past version.
        # New entries are appended by scripts/update-version.sh via jq — do
        # NOT hand-edit the version data in this file.
        releases = builtins.fromJSON (builtins.readFile ./releases.json);

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
              platforms = linuxSystems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/h4ckf0r0day/obscura/releases/download/v${rev}/obscura-${system}.tar.gz";
              hash = binaryHash;
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
        } // versionPackages;

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
