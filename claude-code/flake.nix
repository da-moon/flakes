{
  description = "Claude Code - native Linux CLI packaged as a Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        version = "2.1.133";

        releasePlatformBySystem = {
          x86_64-linux = "linux-x64";
          aarch64-linux = "linux-arm64";
        };

        binarySha256BySystem = {
          # update-version.sh managed hashes.
          x86_64-linux = "sha256-0N3wrubkQmpwVxnl1HFuPOPLOPml/gbrbV/872yYgyo=";
          aarch64-linux = "sha256-3McnX5GYMX4HPDKavhdIJ2BKgB6b+1d6ANhu/PT4Fnw=";
        };

        releasePlatform = releasePlatformBySystem.${system};
        binarySha256 = binarySha256BySystem.${system};

        claude-code = pkgs.stdenv.mkDerivation rec {
          pname = "claude-code";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://downloads.claude.ai/claude-code-releases/${version}/${releasePlatform}/claude";
            sha256 = binarySha256;
          };

          dontUnpack = true;
          dontBuild = true;
          dontConfigure = true;

          nativeBuildInputs = with pkgs; [
            autoPatchelfHook
            makeWrapper
          ];

          buildInputs = [
            pkgs.stdenv.cc.cc.lib
          ];

          installPhase = ''
            runHook preInstall

            mkdir -p $out/bin $out/libexec

            install -m755 $src $out/libexec/claude

            # This package is Nix-managed, so bypass native-installer checks and updates.
            makeWrapper $out/libexec/claude $out/bin/claude \
              --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]} \
              --set DISABLE_INSTALLATION_CHECKS 1 \
              --set DISABLE_UPDATES 1 \
              --set DISABLE_UPGRADE_COMMAND 1 \
              --set DISABLE_AUTOUPDATER 1

            makeWrapper $out/libexec/claude $out/bin/claude-direct \
              --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]} \
              --set DISABLE_INSTALLATION_CHECKS 1 \
              --set DISABLE_UPDATES 1 \
              --set DISABLE_UPGRADE_COMMAND 1 \
              --set DISABLE_AUTOUPDATER 1

            runHook postInstall
          '';

          dontStrip = true;

          meta = with lib; {
            description = "Claude Code - AI coding assistant CLI for terminal";
            longDescription = ''
              Claude Code is an agentic coding tool that lives in your terminal,
              understands your codebase, and helps you code faster by executing
              routine tasks, explaining complex code, and handling git workflows
              through natural language commands.

              This package uses Anthropic's native Linux release binary and keeps
              updates pinned through the flake rather than using the built-in
              updater automatically.
            '';
            homepage = "https://code.claude.com/docs";
            mainProgram = "claude";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };

      in
      {
        packages = {
          default = claude-code;
          claude-code = claude-code;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            curl
            wget
            jq
            git
          ];

          shellHook = ''
            echo "-----------------------------------------------"
            echo "  Claude Code Development Shell"
            echo "-----------------------------------------------"
            echo ""
            echo "Environment:"
            echo "  system:   ${system}"
            echo "  curl:     $(curl --version | head -n1)"
            echo "  wget:     $(wget --version | head -n1)"
            echo "  jq:       $(jq --version)"
            echo "  git:      $(git --version)"
            echo ""
            echo "Commands:"
            echo "  nix build .#claude-code"
            echo "  ./result/bin/claude --version"
            echo "  ./scripts/update-version.sh --check"
            echo ""
            echo "Set up API key before using:"
            echo "  export ANTHROPIC_API_KEY='your-key-here'"
            echo "-----------------------------------------------"
          '';
        };

        apps = {
          default = {
            type = "app";
            program = "${claude-code}/bin/claude";
          };
          claude = {
            type = "app";
            program = "${claude-code}/bin/claude";
          };
          claude-direct = {
            type = "app";
            program = "${claude-code}/bin/claude-direct";
          };
        };
      }
    );
}
