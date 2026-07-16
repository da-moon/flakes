{
  description = "Hoangsa CLI packaged as a Nix flake";

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

        # Per-arch asset naming is a property of the system, not the version.
        releaseBySystem = {
          "x86_64-linux" = {
            asset = "hoangsa-linux-x64.tar.gz";
            sourceRoot = "hoangsa-linux-x64";
          };
          "aarch64-linux" = {
            asset = "hoangsa-linux-arm64.tar.gz";
            sourceRoot = "hoangsa-linux-arm64";
          };
          "aarch64-darwin" = {
            asset = "hoangsa-darwin-arm64.tar.gz";
            sourceRoot = "hoangsa-darwin-arm64";
          };
        };

        release = releaseBySystem.${system} or (throw "Unsupported system for hoangsa: ${system}");

        # Builder: derive a hoangsa package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src-url/hash
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            hash = entry.hashes.${system};
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "hoangsa";
            inherit version;

            meta = with lib; {
              description = "Hoangsa workflow and memory CLI";
              homepage = "https://github.com/unknown-studio-dev/hoangsa";
              mainProgram = "hoangsa-cli";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/unknown-studio-dev/hoangsa/releases/download/v${version}/${release.asset}";
              inherit hash;
            };

            sourceRoot = release.sourceRoot;
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;

            nativeBuildInputs = [
              pkgs.makeWrapper
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.autoPatchelfHook
            ];
            buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              (lib.getLib pkgs.stdenv.cc.cc)
            ];

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/hoangsa $out/bin $out/share/hoangsa
              cp -R . $out/lib/hoangsa/
              cp -R templates $out/share/hoangsa/

              for bin in hoangsa-cli hsp hoangsa-memory hoangsa-memory-mcp; do
                makeWrapper "$out/lib/hoangsa/bin/$bin" "$out/bin/$bin"
              done

              runHook postInstall
            '';

          };

        # Sanitize a JSON key into a valid attribute-name suffix.
        sanitizeKey = key: builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] key;

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `hoangsa_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "hoangsa_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          hoangsa = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/hoangsa-cli";
          };
          hoangsa-cli = {
            type = "app";
            program = "${latestPkg}/bin/hoangsa-cli";
          };
          hoangsa-memory-mcp = {
            type = "app";
            program = "${latestPkg}/bin/hoangsa-memory-mcp";
          };
        };
      }
    );
}
