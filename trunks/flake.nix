{
  description = "Trunks CLI packaged from the PyPI wheel";

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
        py = pkgs.python3Packages;
        pname = "trunks";

        # Builder: derive a trunks package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/url/hash
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
          in
          py.buildPythonApplication {
            inherit pname version;

            meta = with lib; {
              description = "Git repositories backed by user-owned storage";
              homepage = "https://layerbrain.com/trunks";
              license = licenses.mit;
              mainProgram = "trunks";
              platforms = systems;
              maintainers = [ ];
            };

            format = "wheel";

            src = pkgs.fetchurl {
              url = entry.url;
              hash = entry.hash;
            };

            propagatedBuildInputs = [
              py.aiohttp
              py.asyncpg
              py.asyncssh
              py."azure-storage-blob"
              py."google-cloud-storage"
              py.httpx
              py.orjson
              py.pyyaml
              py.uvloop
            ];

            doCheck = false;
            pythonImportsCheck = [ "trunks" ];

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `trunks_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "trunks_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          trunks = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/trunks";
          };
          trunks = {
            type = "app";
            program = "${latestPkg}/bin/trunks";
          };
          "git-remote-trunks" = {
            type = "app";
            program = "${latestPkg}/bin/git-remote-trunks";
          };
        };
      }
    );
}
