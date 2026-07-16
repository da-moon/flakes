{
  description = "OpenNews MCP - crypto news MCP server";

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
        "aarch64-darwin"
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
        pname = "opennews-mcp";

        pythonEnv = pkgs.python3.withPackages (ps: [
          ps.httpx
          ps.mcp
          ps.websockets
        ]);

        # Builder: derive an opennews-mcp package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/rev/hash now
        # come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            rev = entry.rev;

            src = pkgs.fetchFromGitHub {
              owner = "6551Team";
              repo = "opennews-mcp";
              inherit rev;
              hash = entry.hash;
            };
          in
          pkgs.stdenv.mkDerivation {
            inherit pname version src;

            meta = with lib; {
              description = "MCP server for crypto news via 6551 REST and WebSocket APIs";
              homepage = "https://github.com/6551Team/opennews-mcp";
              license = licenses.mit;
              mainProgram = "opennews-mcp";
              platforms = systems;
              maintainers = [ ];
            };

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

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `opennews-mcp_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "${pname}_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          "opennews-mcp" = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/opennews-mcp";
          };
          "opennews-mcp" = {
            type = "app";
            program = "${latestPkg}/bin/opennews-mcp";
          };
        };
      }
    );
}
