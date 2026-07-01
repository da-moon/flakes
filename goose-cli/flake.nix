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
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        version = "1.39.0";

        # On x86_64-linux we pull the prebuilt release binary from GitHub (fast, no
        # heavy Rust build). Every other system builds goose-cli from source below.
        prebuiltBySystem = {
          "x86_64-linux" = {
            url = "https://github.com/block/goose/releases/download/v${version}/goose-x86_64-unknown-linux-gnu.tar.gz";
            sha256 = "sha256-9K0IZ0MNNCDqYLw7s2po9vVmnAYM5t6VL+mifYp+B2c=";
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

        goose-cli-bin = if prebuiltBySystem ? ${system} then mkPrebuilt prebuiltBySystem.${system} else null;

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
            rev = "v${version}";
            sha256 = "sha256-7CXLvfY2jYUB9IG/Z1lPiqwZ7UwIypq32ZLq1SsnHQI=";
          };

          cargoLock = {
            lockFile = ./Cargo.lock;
            outputHashes = {
              "mlx-lm-0.0.1" = "sha256-iBBF6MN3caKbyaP8yniUxOt2uEgsm4C/DMtdyj7aUfg=";
              "cudaforge-0.1.6" = "sha256-w0e/mfx08BkphDEFEWxuyxyZu/gHiG0m6RHx+3BLzDY=";
            };
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
        packages = {
          default = goose-cli;
          goose-cli = goose-cli;
          goose-cli-source = goose-cli-source;
        }
        // pkgs.lib.optionalAttrs (goose-cli-bin != null) {
          goose-cli-bin = goose-cli-bin;
        };
      }
    );
}
