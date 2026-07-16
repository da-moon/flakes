{
  description = "RTK - Rust Token Killer CLI";

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

        # Per-system build config (stable across versions; NOT version data).
        # Only the version/src-url/hash come from the releases.json entry.
        releaseConfigBySystem = {
          "aarch64-linux" = {
            target = "aarch64-unknown-linux-gnu";
            needsAutoPatchelf = true;
          };
          "x86_64-linux" = {
            target = "x86_64-unknown-linux-musl";
            needsAutoPatchelf = false;
          };
          "aarch64-darwin" = {
            target = "aarch64-apple-darwin";
            needsAutoPatchelf = false;
          };
          "x86_64-darwin" = {
            target = "x86_64-apple-darwin";
            needsAutoPatchelf = false;
          };
        };

        currentConfig =
          releaseConfigBySystem.${system} or (throw "Unsupported system for rtk flake: ${system}");

        # Builder: derive an rtk package from one releases.json entry.
        mk =
          key: entry:
          let
            version = entry.version;
            binarySha256 =
              entry.hashes.${system} or (throw "Missing hash for system ${system} in rtk release ${key}");
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "rtk";
            inherit version;

            meta = with lib; {
              description = "High-performance CLI proxy that reduces LLM token consumption";
              homepage = "https://github.com/rtk-ai/rtk";
              license = licenses.mit;
              mainProgram = "rtk";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/rtk-ai/rtk/releases/download/v${version}/rtk-${currentConfig.target}.tar.gz";
              hash = binarySha256;
            };

            sourceRoot = ".";
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;

            nativeBuildInputs = lib.optionals currentConfig.needsAutoPatchelf [
              pkgs.autoPatchelfHook
            ];

            buildInputs = lib.optionals currentConfig.needsAutoPatchelf [
              pkgs.stdenv.cc.cc.lib
            ];

            installPhase = ''
              runHook preInstall
              install -m755 -D rtk $out/bin/rtk
              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `rtk_<sanitized-key>` package per entry in the table.
        versionPackages = builtins.listToAttrs (
          builtins.map (key: {
            name = "rtk_${sanitizeKey key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
        );
      in
      {
        packages = {
          default = latestPkg;
          rtk = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/rtk";
          };
          rtk = {
            type = "app";
            program = "${latestPkg}/bin/rtk";
          };
        };
      }
    );
}
