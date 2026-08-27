{
  description = "synth - The Declarative Data Generator";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
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
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        # Map a nix system to the upstream release-asset file name.
        releaseAssetBySystem = {
          "x86_64-linux" = "synth-ubuntu-18.04-x86_64.tar.gz";
          "aarch64-linux" = "synth-ubuntu-latest-arm64.tar.gz";
          "x86_64-darwin" = "synth-macos-latest-x86_64.tar.gz";
        };

        # Builder: derive the prebuilt synth package from one releases.json entry.
        mkPrebuilt =
          asset: entry:
          let
            version = entry.version;
            rev = entry.rev;
            binarySha256 = entry.hashes.${system} or (throw "Missing hashes entry for system: ${system}");
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "synth";
            inherit version;

            meta = with lib; {
              description = "The Declarative Data Generator (prebuilt release binary)";
              homepage = "https://www.getsynth.com/";
              license = licenses.asl20;
              platforms = [ system ];
              mainProgram = "synth";
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/shuttle-hq/synth/releases/download/${rev}/${asset}";
              sha256 = binarySha256;
            };

            sourceRoot = ".";

            # No build needed - precompiled binary
            dontBuild = true;
            dontConfigure = true;

            # Don't strip: keep the shipped binary byte-for-byte unchanged.
            dontStrip = true;
            # Don't rewrite the ELF interpreter on Darwin.
            dontPatchELF = pkgs.stdenv.hostPlatform.isDarwin;

            nativeBuildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.autoPatchelfHook
            ];
            buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.stdenv.cc.cc.lib
            ];

            installPhase = ''
              runHook preInstall
              install -m755 -D synth $out/bin/synth
              runHook postInstall
            '';
          };

        # Builder: derive a source-built synth package from one releases.json entry.
        # Upstream ships no aarch64-darwin prebuilt asset, so this is used as the
        # fallback on that system. The project requires a nightly Rust toolchain
        # from around its release date, so we add the nixpkgs-mozilla overlay and
        # build with naersk. We reuse the flake's nixpkgs input (rather than a
        # second, older pin) so Darwin consumers hit the binary cache instead of
        # building things like curl from source.
        mkSource =
          entry:
          let
            version = entry.version;
            rev = entry.rev;
            rustNightlyDate = entry.rustNightlyDate or "2022-11-20";
            rustManifestHash = entry.rustManifestHash or (throw "Missing rustManifestHash for source build");

            src = builtins.fetchTarball {
              url = "https://github.com/shuttle-hq/synth/archive/refs/tags/${rev}.tar.gz";
              sha256 = entry.srcHash;
            };

            # Fixed infrastructure for the source build. These are kept as
            # constants rather than flake inputs so that consumers of the
            # prebuilt packages do not pay the cost of fetching them.
            nixpkgs-mozilla = builtins.fetchTarball {
              url = "https://github.com/mozilla/nixpkgs-mozilla/archive/16ab32eeb8390de633eb336eb4910efbbe0091e6.tar.gz";
              sha256 = "sha256-WXGFkdoYqOX9mjJaSfN5+rAH7eFe/1F6LmYb/Rs360g=";
            };
            naersk-src = builtins.fetchTarball {
              url = "https://github.com/nix-community/naersk/archive/9aa07bb0256d300219b30622d2454e85f7f3667e.tar.gz";
              sha256 = "sha256-thLTFbp9D5Qknmh8q/v4FRpLGphUSijT3E86cbLYTXo=";
            };

            pkgs' = (pkgs.extend (self: super: {
              # nixpkgs-mozilla's rust overlay still expects pkgs.makeOverridable,
              # which was removed in nixpkgs 24.11. Re-expose it from lib so the
              # overlay evaluates without warnings on newer nixpkgs.
              makeOverridable = super.lib.makeOverridable;
            })).extend (import nixpkgs-mozilla);

            rust-bin = (pkgs'.rustChannelOf {
              channel = "nightly";
              date = rustNightlyDate;
              sha256 = rustManifestHash;
            }).rust;

            naersk = pkgs'.callPackage naersk-src { rustc = rust-bin; cargo = rust-bin; };
          in
          naersk.buildPackage {
            pname = "synth";
            inherit version src;

            meta = {
              description = "The Declarative Data Generator (source build)";
              homepage = "https://www.getsynth.com/";
              license = lib.licenses.asl20;
              platforms = systems;
              mainProgram = "synth";
              maintainers = [ ];
            };

            nativeBuildInputs = with pkgs'; [ pkg-config ];
            buildInputs =
              with pkgs';
              [
                sqlite.dev
                ncurses6.dev
                libiconv
              ]
              # In nixpkgs 26.05 the legacy per-framework stubs are gone; the
              # unified apple-sdk package provides IOKit/Security/AppKit.
              ++ lib.optionals pkgs'.stdenv.hostPlatform.isDarwin [
                apple-sdk
              ];

            doCheck = false;
          };

        # Builder: derive the synth parts (prebuilt binary + source build +
        # the resolved default) from one releases.json entry.
        mkParts =
          key: entry:
          let
            synth-bin =
              if releaseAssetBySystem ? ${system} then
                mkPrebuilt releaseAssetBySystem.${system} entry
              else
                null;
            synth-source = mkSource entry;
            # Default: prebuilt where available, build from source elsewhere.
            synth = if synth-bin != null then synth-bin else synth-source;
          in
          {
            inherit synth synth-bin synth-source;
          };

        # Builder: derive the default (resolved) synth package from one entry.
        mk = key: entry: (mkParts key entry).synth;

        latestParts = mkParts releases.latest releases.versions.${releases.latest};
        latestPkg = latestParts.synth;

        # One `synth_<sanitized-key>` package per entry in the table.
        versionedPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "synth_${sanitize key}" (mk key entry)
        ) releases.versions;

      in
      {
        packages = {
          default = latestPkg;
          synth = latestPkg;
        }
        // lib.optionalAttrs (latestParts.synth-bin != null) {
          synth-bin = latestParts.synth-bin;
        }
        // {
          synth-source = latestParts.synth-source;
        }
        // versionedPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/synth";
          };
          synth = {
            type = "app";
            program = "${latestPkg}/bin/synth";
          };
        };
      }
    );
}
