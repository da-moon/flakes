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
          let
            # cloudcraft-mcp 0.1.6 hard-pins the hatchling build backend
            # (`hatchling==1.31.0`, vs 1.29.0 in nixpkgs 26.05) and declares
            # runtime deps newer than ANY current nixpkgs channel packages:
            # mcp>=1.28.1, pydantic-settings>=2.14.2, python-multipart>=0.0.31,
            # starlette>=1.3.1 (nixos-unstable tops out at mcp 1.27.1 etc.), plus
            # a new cryptography>=48.0.1 dependency (nixpkgs has 48.0.0). We add
            # cryptography and relax those lower bounds to the packaged versions
            # so the tool builds today; this trades strict upstream pinning for
            # buildability and should be revisited once nixpkgs ships the pinned
            # versions. 0.1.5 keeps its pristine build (its looser bounds are
            # satisfied by nixpkgs).
            needsRelaxedDeps = lib.versionAtLeast entry.version "0.1.6";
          in
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

            postPatch = lib.optionalString needsRelaxedDeps ''
              substituteInPlace pyproject.toml \
                --replace-warn 'hatchling==1.31.0' 'hatchling'
            '';

            pythonRelaxDeps = lib.optionals needsRelaxedDeps [
              "mcp"
              "pydantic-settings"
              "python-multipart"
              "starlette"
              "cryptography"
            ];

            nativeBuildInputs = [ py.hatchling ];

            propagatedBuildInputs = [
              py.httpx
              py.mcp
              py."typing-extensions"
            ]
            ++ lib.optionals needsRelaxedDeps [
              py.cryptography
              py.pydantic-settings
              py.python-multipart
              py.starlette
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
