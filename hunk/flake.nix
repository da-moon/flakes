{
  description = "Hunk - AI-friendly diff review CLI packaged as a Nix flake";

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

        # Per-system release-asset metadata (version-independent).
        assetBySystem = {
          "x86_64-linux" = {
            asset = "hunkdiff-linux-x64.tar.gz";
            sourceRoot = "hunkdiff-linux-x64";
          };
          "aarch64-linux" = {
            asset = "hunkdiff-linux-arm64.tar.gz";
            sourceRoot = "hunkdiff-linux-arm64";
          };
          "x86_64-darwin" = {
            asset = "hunkdiff-darwin-x64.tar.gz";
            sourceRoot = "hunkdiff-darwin-x64";
          };
          "aarch64-darwin" = {
            asset = "hunkdiff-darwin-arm64.tar.gz";
            sourceRoot = "hunkdiff-darwin-arm64";
          };
        };

        systemAsset = assetBySystem.${system} or (throw "Unsupported system for hunk: ${system}");

        # Builder: derive a hunk package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/hash(es)
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            binarySha256 = entry.hashes.${system} or (throw "Missing hash for system ${system} in hunk ${key}");
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "hunk";
            inherit version;

            meta = with lib; {
              description = "AI-friendly diff review CLI";
              homepage = "https://github.com/modem-dev/hunk";
              mainProgram = "hunk";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/modem-dev/hunk/releases/download/v${version}/${systemAsset.asset}";
              hash = binarySha256;
            };

            sourceRoot = systemAsset.sourceRoot;
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
              install -m755 -D hunk $out/bin/hunk
              runHook postInstall
            '';

          };

        # Sanitize a JSON key into a valid attribute-name suffix.
        sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `hunk_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "hunk_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          hunk = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/hunk";
          };
          hunk = {
            type = "app";
            program = "${latestPkg}/bin/hunk";
          };
        };
      }
    );
}
