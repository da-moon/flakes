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
        "aarch64-linux"
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

        # Builder: derive the askii parts (prebuilt binary + source build +
        # the resolved default) from one releases.json entry. Upstream ships
        # release binaries for x86_64 only; aarch64-linux has no prebuilt
        # asset and falls back to a buildRustPackage from the v${rev} tag.
        mkParts =
          key: entry:
          let
            version = entry.version;

            assetBySystem = {
              "x86_64-linux" = "askii";
              "x86_64-darwin" = "askii-osx";
            };

            # Prebuilt release binary. PRESERVES the original packaging logic;
            # only version/asset/hash now come from `entry`.
            mkPrebuilt =
              asset:
              pkgs.stdenv.mkDerivation {
                pname = "askii";
                inherit version;

                meta = with lib; {
                  description = "TUI based ASCII diagram editor (prebuilt release binary)";
                  homepage = "https://github.com/nytopop/askii";
                  license = licenses.mit;
                  mainProgram = "askii";
                  platforms = [ system ];
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

            askii-bin = if assetBySystem ? ${system} then mkPrebuilt assetBySystem.${system} else null;

            # Source build from the v${rev} tag. Used as the default where no
            # prebuilt asset exists (aarch64-linux) and exposed separately on
            # Linux so the updater can resolve srcHash/cargoHash on x86_64.
            # The `xcb` crate (pulled in via clipboard -> x11-clipboard) runs a
            # python3 build script to generate its Rust bindings and links
            # natively against libxcb.
            askii-source = pkgs.rustPlatform.buildRustPackage {
              pname = "askii";
              inherit version;

              meta = with lib; {
                description = "TUI based ASCII diagram editor";
                homepage = "https://github.com/nytopop/askii";
                license = licenses.mit;
                mainProgram = "askii";
                platforms = lib.platforms.unix;
                maintainers = [ ];
              };

              src = pkgs.fetchFromGitHub {
                owner = "nytopop";
                repo = "askii";
                # entry.rev is the unprefixed version; the git tag is v-prefixed.
                rev = "v${entry.rev}";
                hash = entry.srcHash;
              };

              cargoHash = entry.cargoHash;
              # fetchCargoVendor (the sole cargo vendor backend in nixpkgs
              # 25.05+) reads Cargo.lock from the unpacked source via a
              # Python util that requires inline package checksums (v3
              # lockfile format).  Upstream askii v0.6.0 ships a legacy v1
              # lockfile (checksums in [metadata] only, no version key),
              # which makes the util throw KeyError: 'checksum'.  The
              # committed ./Cargo.lock has been converted to v3; inject it
              # over the source copy so both the vendor FOD and the main
              # build parse the compatible lockfile.
              postUnpack = ''
                cp ${./Cargo.lock} "$sourceRoot/Cargo.lock"
              '';

              nativeBuildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                pkgs.python3
              ];
              buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                pkgs.libxau
                pkgs.libxdmcp
                pkgs.libxcb
              ];
            };

            # Default: prebuilt where available, build from source elsewhere.
            askii = if askii-bin != null then askii-bin else askii-source;
          in
          {
            inherit askii askii-bin askii-source;
          };

        # Builder: derive the default (resolved) askii package from one entry.
        mk = key: entry: (mkParts key entry).askii;

        latestParts = mkParts releases.latest releases.versions.${releases.latest};
        latestPkg = latestParts.askii;

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
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          askii-source = latestParts.askii-source;
        }
        // lib.optionalAttrs (latestParts.askii-bin != null) {
          askii-bin = latestParts.askii-bin;
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
