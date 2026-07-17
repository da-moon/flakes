{
  description = "Cloudcraft MCP server for managing cloud architecture blueprints";

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
        pname = "cloudcraft-mcp";

        # Builder: derive a cloudcraft-mcp package from one releases.json entry.
        # Only version/rev/hash come from the version table; the package logic
        # remains shared across all retained releases.
        mk =
          _key: entry:
          py.buildPythonApplication {
            inherit pname;
            version = entry.version;
            pyproject = true;

            meta = with lib; {
              description = "MCP server for managing Cloudcraft architecture blueprints";
              homepage = "https://github.com/hypark5540/cloudcraft-mcp";
              license = licenses.mit;
              mainProgram = "cloudcraft-mcp";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchFromGitHub {
              owner = "hypark5540";
              repo = "cloudcraft-mcp";
              rev = entry.rev;
              hash = entry.hash;
            };

            nativeBuildInputs = [ py.hatchling ];

            propagatedBuildInputs = [
              py.httpx
              py.mcp
              py."typing-extensions"
            ];

            doCheck = false;
            pythonImportsCheck = [ "cloudcraft_mcp" ];
          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `cloudcraft-mcp_<sanitized-key>` package per table entry.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "${pname}_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          "cloudcraft-mcp" = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/cloudcraft-mcp";
          };
          "cloudcraft-mcp" = {
            type = "app";
            program = "${latestPkg}/bin/cloudcraft-mcp";
          };
        };
      }
    );
}
