{
  description = "Leaf CLI packaged as a Nix flake";

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

        # Per-system upstream release asset name (build logic, keyed by system).
        assetBySystem = {
          "x86_64-linux" = "leaf-linux-x86_64";
          "aarch64-linux" = "leaf-linux-arm64";
          "x86_64-darwin" = "leaf-macos-x86_64";
          "aarch64-darwin" = "leaf-macos-arm64";
        };

        # Builder: derive a leaf package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src-url/hash
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            asset = assetBySystem.${system} or (throw "Unsupported system for leaf: ${system}");
            hash = entry.hashes.${system} or (throw "Missing hash for system: ${system}");
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "leaf";
            inherit version;

            meta = with lib; {
              description = "Terminal Markdown previewer with a GUI-like experience";
              homepage = "https://github.com/RivoLink/leaf";
              mainProgram = "leaf";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/RivoLink/leaf/releases/download/${version}/${asset}";
              inherit hash;
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
            ];

            installPhase = ''
              runHook preInstall
              install -m755 -D $src $out/bin/leaf
              runHook postInstall
            '';

          };

        # Sanitize a JSON key into a valid attribute-name suffix.
        sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `leaf_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "leaf_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          leaf = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/leaf";
          };
          leaf = {
            type = "app";
            program = "${latestPkg}/bin/leaf";
          };
        };
      }
    );
}
