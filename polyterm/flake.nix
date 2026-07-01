{
  description = "PolyTerm - terminal monitoring for Polymarket prediction markets";

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
        python = pkgs.python312;

        polyterm = python.pkgs.buildPythonApplication rec {
          pname = "polyterm";
          version = "0.10.0";

          meta = with pkgs.lib; {
            description = "Terminal-based monitoring app for Polymarket shifts";
            homepage = "https://github.com/NYTEMODEONLY/polyterm";
            license = licenses.mit;
            mainProgram = "polyterm";
            platforms = linuxSystems;
          };

          format = "setuptools";

          src = pkgs.fetchFromGitHub {
            owner = "NYTEMODEONLY";
            repo = "polyterm";
            rev = "v${version}";
            hash = "sha256-43R126PynqesJzzTfrqy15RAgu/T82Pjn6UqiCwq0e4=";
          };

          propagatedBuildInputs = with python.pkgs; [
            aiohttp
            click
            gql
            packaging
            pandas
            plyer
            pytest
            pytest-asyncio
            pytest-mock
            python-dateutil
            requests
            responses
            rich
            toml
            typer
            websockets
          ];

          pythonImportsCheck = [ "polyterm" ];
          doCheck = false;

        };
      in
      {
        packages = {
          default = polyterm;
          inherit polyterm;
        };

        apps = {
          default = {
            type = "app";
            program = "${polyterm}/bin/polyterm";
          };
          polyterm = {
            type = "app";
            program = "${polyterm}/bin/polyterm";
          };
        };
      }
    );
}
