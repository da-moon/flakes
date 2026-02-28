{
  description = "Goose - AI agent for software development";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
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

        goose-cli = pkgs.rustPlatform.buildRustPackage rec {
          pname = "goose-cli";
          version = "1.26.1";

          src = pkgs.fetchFromGitHub {
            owner = "block";
            repo = "goose";
            rev = "v${version}";
            sha256 = "sha256-2qsRLeBXAJzaOEVarU5LGQp9iooPsYq/+vrMx5Mr2Gw=";
          };

          cargoHash = "sha256-XHjOne43aCu6CkLaAF12TOcmP4TxSACu8Juxio3Td4k=";

          # Build only the goose-cli crate
          buildAndTestSubdir = "crates/goose-cli";

          env = {
            RUSTY_V8_ARCHIVE = "${rustyV8Archive}";
          };

          nativeBuildInputs = with pkgs; [
            pkg-config
            python3
            curl
          ];

          buildInputs = with pkgs; [
            openssl
            xorg.libxcb
          ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.Security
            pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
          ];

          preBuild = ''
            export RUSTY_V8_ARCHIVE="${rustyV8Archive}"
          '';

          meta = with pkgs.lib; {
            description = "Open-source AI agent for software development";
            homepage = "https://github.com/block/goose";
            license = licenses.asl20;
            platforms = platforms.unix;
            mainProgram = "goose";
          };
        };

      in
      {
        packages = {
          default = goose-cli;
          goose-cli = goose-cli;
        };
      }
    );
}
