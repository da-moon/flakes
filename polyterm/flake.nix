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

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        python = pkgs.python312;

        # Builder: derive a polyterm package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/rev/hash
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          python.pkgs.buildPythonApplication rec {
            pname = "polyterm";
            version = entry.version;

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
              rev = entry.rev;
              hash = entry.hash;
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

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `polyterm_<sanitized-key>` package per entry in the table.
        versionPackages = builtins.listToAttrs (
          builtins.map (key: {
            name = "polyterm_${sanitize key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
        );
      in
      {
        packages = versionPackages // {
          default = latestPkg;
          polyterm = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/polyterm";
          };
          polyterm = {
            type = "app";
            program = "${latestPkg}/bin/polyterm";
          };
        };
      }
    );
}
