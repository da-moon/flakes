{
  description = "Feynman - open source AI research agent CLI, packaged as a Nix flake";

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

        releaseBySystem = {
          "x86_64-linux" = "linux-x64";
          "x86_64-darwin" = "darwin-x64";
          "aarch64-darwin" = "darwin-arm64";
        };

        # Builder: derive a feynman package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src-url/hash
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            release = releaseBySystem.${system};
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "feynman";
            inherit version;

            meta = with lib; {
              description = "Open source AI research agent CLI";
              homepage = "https://github.com/getcompanion-ai/feynman";
              mainProgram = "feynman";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/getcompanion-ai/feynman/releases/download/v${version}/feynman-${version}-${release}.tar.gz";
              hash = entry.hashes.${system};
            };

            sourceRoot = "feynman-${version}-${release}";
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
            autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ];

            installPhase = ''
              runHook preInstall

              mkdir -p $out/libexec/feynman $out/bin
              cp -R . $out/libexec/feynman/

              makeWrapper $out/libexec/feynman/node/bin/node $out/bin/feynman \
                --add-flags "$out/libexec/feynman/app/bin/feynman.js"

              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `feynman_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "feynman_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          feynman = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/feynman";
          };
          feynman = {
            type = "app";
            program = "${latestPkg}/bin/feynman";
          };
        };
      }
    );
}
