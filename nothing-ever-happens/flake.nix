{
  description = "Nothing Ever Happens - Polymarket bot";

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
        pname = "nothing-ever-happens";
        rev = "930e18050e7b40658ab503d17c15ddc75a09e897";
        version = "unstable-2026-04-13-930e180";
        srcHash = "sha256-lx+hNGv/XTkCbd1117jNsCJ5vocLdG/FtXipjvk/D7I=";

        src = pkgs.fetchFromGitHub {
          owner = "sterlingcrispin";
          repo = "nothing-ever-happens";
          inherit rev;
          hash = srcHash;
        };

        polyEip712Structs = py.buildPythonPackage rec {
          pname = "poly-eip712-structs";
          version = "0.0.1";
          format = "wheel";

          src = pkgs.fetchurl {
            url = "https://files.pythonhosted.org/packages/5a/d7/ff1cfba1c3a3d5d6851d7bef5e4ad19710ed6d03e149dc183111d103acab/poly_eip712_structs-0.0.1-py3-none-any.whl";
            hash = "sha256-EecU6MJcZNIty4pgbIfPBS5xVMr3AWUtKWh92vfe40I=";
          };

          propagatedBuildInputs = [
            py."eth-utils"
            py.pydantic
            py.pycryptodome
            py.pytest
          ];

          doCheck = false;
          pythonImportsCheck = [ "poly_eip712_structs" ];
        };

        pyOrderUtils = py.buildPythonPackage rec {
          pname = "py-order-utils";
          version = "0.3.2";
          format = "wheel";

          src = pkgs.fetchurl {
            url = "https://files.pythonhosted.org/packages/29/68/b0a971b064b3236fce7307bd5c180409cccd9b207ec459274bdb4e401ec0/py_order_utils-0.3.2-py3-none-any.whl";
            hash = "sha256-WreA5h7VMt3ahSpqEtRwvnu9quASE87T68bIh87bHT4=";
          };

          propagatedBuildInputs = [
            py."eth-account"
            py."eth-utils"
            py.pydantic
            polyEip712Structs
            py.pytest
          ];

          doCheck = false;
          pythonImportsCheck = [ "py_order_utils" ];
        };

        pyBuilderSigningSdk = py.buildPythonPackage rec {
          pname = "py-builder-signing-sdk";
          version = "0.0.2";
          format = "wheel";

          src = pkgs.fetchurl {
            url = "https://files.pythonhosted.org/packages/57/fb/23c68c8f6356a50f959e2df2ae80e8344c3ff8ccca92943848a57a495928/py_builder_signing_sdk-0.0.2-py3-none-any.whl";
            hash = "sha256-EUudV77CKBd9dZzhXEdVifR9siUu0f1nysPJsGQKvnY=";
          };

          propagatedBuildInputs = [
            py.python-dotenv
            py.requests
          ];

          doCheck = false;
          pythonImportsCheck = [ "py_builder_signing_sdk" ];
        };

        pyClobClient = py.buildPythonPackage rec {
          pname = "py-clob-client";
          version = "0.34.6";
          format = "wheel";

          src = pkgs.fetchurl {
            url = "https://files.pythonhosted.org/packages/8f/93/cd8aa728b3ff66162be5f91002dfd7eab9defd5d8200cddf14f119e32c04/py_clob_client-0.34.6-py3-none-any.whl";
            hash = "sha256-KcOQArdvORjyMSyWPbCzGUHNRVvWxqzcFRnY/81whC0=";
          };

          propagatedBuildInputs = [
            py."eth-account"
            py."eth-utils"
            py.h2
            py.httpx
            py.pydantic
            py.python-dotenv
            polyEip712Structs
            pyBuilderSigningSdk
            pyOrderUtils
          ];

          doCheck = false;
          pythonImportsCheck = [ "py_clob_client" ];
        };

        pythonEnv = pkgs.python3.withPackages (
          ps: [
            ps.aiohttp
            ps.psycopg2
            ps.python-dotenv
            ps."python-json-logger"
            ps.sqlalchemy
            ps.web3
            pyClobClient
          ]
        );

        nothingEverHappens = pkgs.stdenv.mkDerivation {
          inherit pname version src;

          nativeBuildInputs = [ pkgs.makeWrapper ];
          dontBuild = true;
          dontConfigure = true;

          installPhase = ''
            runHook preInstall

            mkdir -p $out/lib/${pname}
            mkdir -p $out/bin
            cp -r $src/* $out/lib/${pname}/

            cat > $out/bin/nothing-ever-happens <<'EOF'
            #!/usr/bin/env bash
            set -euo pipefail

            case "''${1:-}" in
              --version|-V)
                echo "nothing-ever-happens __VERSION__"
                exit 0
                ;;
              --help|-h)
                cat <<'USAGE'
            nothing-ever-happens

            Starts the Polymarket bot from the current working directory.

            Safe commands:
              nothing-ever-happens --version
              nothing-ever-happens --help

            Runtime files expected in your working directory:
              config.json
              .env
            USAGE
                exit 0
                ;;
            esac

            config_path="''${CONFIG_PATH:-config.json}"
            if [ ! -f "$config_path" ]; then
              echo "Config file not found: $config_path" >&2
              echo "Copy config.example.json to config.json and fill in your values." >&2
              exit 1
            fi

            export PYTHONPATH="__PKG_ROOT__''${PYTHONPATH:+:$PYTHONPATH}"
            exec "__PYTHON__" -m bot.main "$@"
            EOF
            substituteInPlace $out/bin/nothing-ever-happens \
              --replace-fail "__VERSION__" "${version}" \
              --replace-fail "__PKG_ROOT__" "$out/lib/${pname}" \
              --replace-fail "__PYTHON__" "${pythonEnv}/bin/python"
            chmod +x $out/bin/nothing-ever-happens

            runHook postInstall
          '';

          meta = with lib; {
            description = "Async Polymarket bot that buys NO on standalone yes/no markets";
            homepage = "https://github.com/sterlingcrispin/nothing-ever-happens";
            license = licenses.cc0;
            mainProgram = "nothing-ever-happens";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = nothingEverHappens;
          "nothing-ever-happens" = nothingEverHappens;
        };

        apps = {
          default = {
            type = "app";
            program = "${nothingEverHappens}/bin/nothing-ever-happens";
          };
          "nothing-ever-happens" = {
            type = "app";
            program = "${nothingEverHappens}/bin/nothing-ever-happens";
          };
        };
      }
    );
}
