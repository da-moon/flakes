{
  description = "Claude Code - native Linux CLI packaged as a Nix flake";

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

        # Version table: consumers select the latest OR any past version.
        # New entries are appended by scripts/update-version.sh via jq — do
        # NOT hand-edit the version data in this file.
        releases = builtins.fromJSON (builtins.readFile ./releases.json);

        releasePlatformBySystem = {
          x86_64-linux = "linux-x64";
          aarch64-linux = "linux-arm64";
        };

        releasePlatform = releasePlatformBySystem.${system};

        # Builder: derive a claude-code package from one releases.json entry.
        mk =
          key: entry:
          let
            version = entry.version;
            binarySha256 = entry.hashes.${system};
          in
          pkgs.stdenv.mkDerivation rec {
          pname = "claude-code";
          inherit version;

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

        };

        # Sanitize a JSON key into a valid attribute-name suffix.
        sanitizeKey = key: builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] key;

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `claude-code_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "claude-code_${sanitizeKey key}" (mk key entry)
        ) releases.versions;

      in
      {
        packages = {
          default = latestPkg;
          claude-code = latestPkg;
        } // versionPackages;

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
            program = "${latestPkg}/bin/claude";
          };
          claude = {
            type = "app";
            program = "${latestPkg}/bin/claude";
          };
          claude-direct = {
            type = "app";
            program = "${latestPkg}/bin/claude-direct";
          };
        };
      }
    );
}
