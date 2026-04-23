{
  description = "OpenNews MCP - crypto news MCP server";

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
        py = pkgs.python3Packages;
        pname = "opennews-mcp";
        baseVersion = "0.1.0";
        rev = "e4f40e1eddd0438939850f69a7435314d8fbeb7f";
        version = "0.1.0-unstable-2026-04-10-e4f40e1";
        srcHash = "sha256-4LUpy2n9cVSlXi/AHdc/AKx4Ttji1CXoyZ1c0Rq8Zfo=";

        src = pkgs.fetchFromGitHub {
          owner = "6551Team";
          repo = "opennews-mcp";
          inherit rev;
          hash = srcHash;
        };

        pythonEnv = pkgs.python3.withPackages (
          ps: [
            ps.httpx
            ps.mcp
            ps.websockets
          ]
        );

        opennewsMcp = pkgs.stdenv.mkDerivation {
          inherit pname version src;

          nativeBuildInputs = [ pkgs.makeWrapper ];
          dontBuild = true;
          dontConfigure = true;

          installPhase = ''
            runHook preInstall

            mkdir -p $out/lib/${pname}
            mkdir -p $out/bin
            cp -r $src/* $out/lib/${pname}/

            cat > $out/bin/opennews-mcp <<'EOF'
            #!/usr/bin/env bash
            set -euo pipefail

            case "''${1:-}" in
              --version|-V)
                echo "opennews-mcp __VERSION__"
                exit 0
                ;;
              --help|-h)
                cat <<'USAGE'
            opennews-mcp

            Starts the OpenNews MCP server on stdio.

            Safe commands:
              opennews-mcp --version
              opennews-mcp --help

            Runtime configuration:
              OPENNEWS_TOKEN
              OPENNEWS_API_BASE
              OPENNEWS_WSS_URL
            USAGE
                exit 0
                ;;
            esac

            export PYTHONPATH="__PKG_ROOT__/src''${PYTHONPATH:+:$PYTHONPATH}"
            exec "__PYTHON__" -m opennews_mcp.server "$@"
            EOF
            substituteInPlace $out/bin/opennews-mcp \
              --replace-fail "__VERSION__" "${version}" \
              --replace-fail "__PKG_ROOT__" "$out/lib/${pname}" \
              --replace-fail "__PYTHON__" "${pythonEnv}/bin/python"
            chmod +x $out/bin/opennews-mcp

            runHook postInstall
          '';

          meta = with lib; {
            description = "MCP server for crypto news via 6551 REST and WebSocket APIs";
            homepage = "https://github.com/6551Team/opennews-mcp";
            license = licenses.mit;
            mainProgram = "opennews-mcp";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = opennewsMcp;
          "opennews-mcp" = opennewsMcp;
        };

        apps = {
          default = {
            type = "app";
            program = "${opennewsMcp}/bin/opennews-mcp";
          };
          "opennews-mcp" = {
            type = "app";
            program = "${opennewsMcp}/bin/opennews-mcp";
          };
        };
      }
    );
}
