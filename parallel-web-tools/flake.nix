{
  description = "Parallel Web Tools - CLI for web search, content extraction, and deep research via the Parallel API";

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
        version = "0.2.0";

        # Architecture-specific configuration
        archConfig = {
          "aarch64-linux" = {
            arch = "linux-arm64";
            sha256 = "sha256-foJFKiqiaSm3jc3b7C/LXXai429B/fBvii17RTNxs4k=";
          };
          "x86_64-linux" = {
            arch = "linux-x64";
            sha256 = "sha256-5MNPX6WnkecHY6pqXoUi+wOYTDiwNxqFf6DiNU8kYSo=";
          };
        };

        # Get config for current system, fallback to x86_64 if unknown
        currentArch = archConfig.${system} or archConfig."x86_64-linux";

        parallel-cli = pkgs.stdenv.mkDerivation rec {
          pname = "parallel-cli";
          inherit version;

          src = pkgs.fetchzip {
            url = "https://github.com/parallel-web/parallel-web-tools/releases/download/v${version}/parallel-cli-${currentArch.arch}.zip";
            sha256 = currentArch.sha256;
            stripRoot = true;
          };

          # autoPatchelfHook fixes ELF interpreter/rpath for NixOS
          nativeBuildInputs = [ pkgs.autoPatchelfHook ];

          # Runtime libraries needed by PyInstaller bundle
          buildInputs = [
            pkgs.stdenv.cc.cc.lib # libstdc++
            pkgs.zlib
          ];

          # No build needed - precompiled binary
          dontBuild = true;
          dontConfigure = true;

          # Don't strip PyInstaller binaries
          dontStrip = true;

          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib/parallel-cli $out/bin
            cp -r . $out/lib/parallel-cli/
            chmod +x $out/lib/parallel-cli/parallel-cli
            ln -s $out/lib/parallel-cli/parallel-cli $out/bin/parallel-cli
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "CLI for web search, content extraction, and deep research via the Parallel API";
            homepage = "https://github.com/parallel-web/parallel-web-tools";
            platforms = [ "aarch64-linux" "x86_64-linux" ];
            maintainers = [ ];
          };
        };

      in
      {
        packages = {
          default = parallel-cli;
          parallel-cli = parallel-cli;
        };

        apps = {
          default = {
            type = "app";
            program = "${parallel-cli}/bin/parallel-cli";
          };
          parallel-cli = {
            type = "app";
            program = "${parallel-cli}/bin/parallel-cli";
          };
        };
      }
    );
}
