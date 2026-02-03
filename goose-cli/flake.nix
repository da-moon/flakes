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

        goose-cli = pkgs.rustPlatform.buildRustPackage rec {
          pname = "goose-cli";
          version = "1.22.2";

          src = pkgs.fetchFromGitHub {
            owner = "block";
            repo = "goose";
            rev = "v${version}";
            sha256 = "sha256-eRQW/8GeFs1GRpqcuPiiSaC0GLSnZh4JvkVRMqMlu8o=";
          };

          cargoHash = "sha256-MLgb2gaYMeHH/7sju31lk1NTsswFf26QGCm+kA+ifoA=";

          # Build only the goose-cli crate
          buildAndTestSubdir = "crates/goose-cli";

          nativeBuildInputs = with pkgs; [
            pkg-config
          ];

          buildInputs = with pkgs; [
            openssl
            xorg.libxcb
          ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.Security
            pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
          ];

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
