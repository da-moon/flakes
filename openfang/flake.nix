{
  description = "OpenFang CLI packaged as a Nix flake";

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

        targetBySystem = {
          "x86_64-linux" = "x86_64-unknown-linux-gnu";
          "aarch64-linux" = "aarch64-unknown-linux-gnu";
        };

        target =
          targetBySystem.${system}
            or (throw "Unsupported system for openfang: ${system}");

        # Sanitize a JSON key into a valid attribute-name suffix.
        sanitizeKey = key: builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] key;

        # Builder: derive an openfang package from one releases.json entry.
        mk =
          key: entry:
          let
            version = entry.version;
            hash =
              entry.hashes.${system}
                or (throw "Missing hashes entry for system: ${system}");
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "openfang";
            inherit version;

            meta = with lib; {
              description = "OpenFang CLI";
              homepage = "https://github.com/RightNow-AI/openfang";
              mainProgram = "openfang";
              platforms = linuxSystems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/RightNow-AI/openfang/releases/download/v${version}/openfang-${target}.tar.gz";
              inherit hash;
            };

            sourceRoot = ".";
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;

            nativeBuildInputs = [ pkgs.autoPatchelfHook ];
            buildInputs = [ (lib.getLib pkgs.stdenv.cc.cc) ];

            installPhase = ''
              runHook preInstall
              install -m755 -D openfang $out/bin/openfang
              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `openfang_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "openfang_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          openfang = latestPkg;
        } // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/openfang";
          };
          openfang = {
            type = "app";
            program = "${latestPkg}/bin/openfang";
          };
        };
      }
    );
}
