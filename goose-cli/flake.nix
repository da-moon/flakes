{
  description = "Goose - AI agent for software development";

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
      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Builder: derive the goose-cli parts (prebuilt binary + source build +
        # the resolved default) from one releases.json entry. PRESERVES the
        # original build logic exactly; only version/rev/hash(es) now come from
        # `entry` instead of let-bindings.
        mkParts =
          key: entry:
          let
            version = entry.version;
            rev = entry.rev;

            # On x86_64-linux we pull the prebuilt release binary from GitHub (fast, no
            # heavy Rust build). Every other system builds goose-cli from source below.
            prebuiltBySystem = {
              "x86_64-linux" = {
                url = "https://github.com/block/goose/releases/download/${rev}/goose-x86_64-unknown-linux-gnu.tar.gz";
                sha256 = entry.prebuiltHashes."x86_64-linux";
              };
            };

            mkPrebuilt =
              spec:
              pkgs.stdenv.mkDerivation {
                pname = "goose-cli";
                inherit version;

                src = pkgs.fetchurl { inherit (spec) url sha256; };
                sourceRoot = ".";

                nativeBuildInputs = [ pkgs.autoPatchelfHook ];
                buildInputs = [ pkgs.stdenv.cc.cc.lib ];

                installPhase = ''
                  runHook preInstall
                  install -m755 -D goose $out/bin/goose
                  runHook postInstall
                '';

                meta = with pkgs.lib; {
                  description = "Open-source AI agent for software development (prebuilt release binary)";
                  homepage = "https://github.com/block/goose";
                  license = licenses.asl20;
                  platforms = [ system ];
                  mainProgram = "goose";
                };
              };

            goose-cli-bin =
              if prebuiltBySystem ? ${system} then mkPrebuilt prebuiltBySystem.${system} else null;

            rustyV8ArchiveByTarget = {
              "x86_64-unknown-linux-gnu" = pkgs.fetchurl {
                url = "https://github.com/denoland/rusty_v8/releases/download/v145.0.0/librusty_v8_release_x86_64-unknown-linux-gnu.a.gz";
                sha256 = "sha256-chV1PAx40UH3Ute5k3lLrgfhih39Rm3KqE+mTna6ysE=";
              };
              "aarch64-unknown-linux-gnu" = pkgs.fetchurl {
                url = "https://github.com/denoland/rusty_v8/releases/download/v145.0.0/librusty_v8_release_aarch64-unknown-linux-gnu.a.gz";
                sha256 = "sha256-4IivYskhUSsMLZY97+g23UtUYh4p5jk7CzhMbMyqXyY=";
              };
            };
            rustyV8Archive =
              if builtins.hasAttr pkgs.stdenv.hostPlatform.config rustyV8ArchiveByTarget then
                rustyV8ArchiveByTarget.${pkgs.stdenv.hostPlatform.config}
              else
                throw "No pre-fetched rusty_v8 archive for target ${pkgs.stdenv.hostPlatform.config}";

            goose-cli-source = pkgs.rustPlatform.buildRustPackage {
              pname = "goose-cli";
              inherit version;

              meta = with pkgs.lib; {
                description = "Open-source AI agent for software development";
                homepage = "https://github.com/block/goose";
                license = licenses.asl20;
                platforms = platforms.unix;
                mainProgram = "goose";
              };

              src = pkgs.fetchFromGitHub {
                owner = "block";
                repo = "goose";
                inherit rev;
                sha256 = entry.srcHash;
              };

              cargoLock = {
                lockFile = ./Cargo.lock;
                outputHashes = entry.cargoOutputHashes;
              };

              # Build only the goose-cli crate
              buildAndTestSubdir = "crates/goose-cli";

              env = {
                RUSTY_V8_ARCHIVE = "${rustyV8Archive}";
                LIBCLANG_PATH = "${pkgs.lib.getLib pkgs.llvmPackages.libclang}/lib";
                SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
                NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              };

              nativeBuildInputs = with pkgs; [
                rustPlatform.bindgenHook
                cmake
                pkg-config
                python3
                curl
                cacert
              ];

              buildInputs = with pkgs; [
                openssl
              ]
              ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                dbus
                libxcb
              ]
              ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
                pkgs.darwin.apple_sdk.frameworks.Security
                pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
              ];

              preBuild = ''
                export RUSTY_V8_ARCHIVE="${rustyV8Archive}"
              '';

            };

            # Default: prebuilt binary on x86_64-linux, build-from-source everywhere else.
            goose-cli = if system == "x86_64-linux" && goose-cli-bin != null then goose-cli-bin else goose-cli-source;
          in
          {
            inherit goose-cli goose-cli-bin goose-cli-source;
          };

        # Builder: derive the default (resolved) goose-cli package from one entry.
        mk = key: entry: (mkParts key entry).goose-cli;

        latestParts = mkParts releases.latest releases.versions.${releases.latest};
        latestPkg = latestParts.goose-cli;

        # One `goose-cli_<sanitized-key>` package per entry in the table.
        versionPackages = pkgs.lib.mapAttrs' (
          key: entry: pkgs.lib.nameValuePair "goose-cli_${sanitizeKey key}" (mk key entry)
        ) releases.versions;

      in
      {
        packages = {
          default = latestPkg;
          goose-cli = latestPkg;
          goose-cli-source = latestParts.goose-cli-source;
        }
        // pkgs.lib.optionalAttrs (latestParts.goose-cli-bin != null) {
          goose-cli-bin = latestParts.goose-cli-bin;
        }
        // versionPackages;
      }
    );
}
