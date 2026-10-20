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
        securePy =
          let
            fetchPypi =
              pname: version: hash:
              pkgs.fetchPypi {
                inherit pname version hash;
              };
          in
          py
          // {
            hatchling = py.hatchling.overridePythonAttrs (_: {
              version = "1.32.4";
              src = fetchPypi "hatchling" "1.32.4" "sha256-xEaPcxRMBU0qq07w8DeMQ7mHi/B/j/1reWkOlw03Xwc=";
              dependencies = [
                py.editables
                py.packaging
                py.pathspec
                py.pluggy
                py.tomlkit
                py.trove-classifiers
              ];
            });

            cryptography-vectors = py.cryptography.vectors.overridePythonAttrs (_: rec {
              version = "50.0.2";
              src =
                fetchPypi "cryptography_vectors" version
                  "sha256-2ZER/l3VqNQGUOMAqtNLbmkQyhmMZ0uACEUMpp+PBcQ=";
              sourceRoot = "cryptography_vectors-${version}";
            });

            cryptography = py.cryptography.overridePythonAttrs (old: rec {
              version = "50.0.2";
              src = fetchPypi "cryptography" version "sha256-e0YWW7VutHBOLqr4bzyUDRkVRTXZsMp9bVkLBAYOANU=";
              # These CVE fixes are included in 50.0.2.
              patches = [ ];
              nativeCheckInputs = map (
                dep: if (dep.pname or "") == "cryptography-vectors" then securePy.cryptography-vectors else dep
              ) old.nativeCheckInputs;
              cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
                pname = "cryptography";
                inherit version src;
                hash = "sha256-OUfcs3MIoEwUx1BQV1ZYnAx9IDEbQUWEaeddwK0LLmQ=";
              };
            });

            "pydantic-settings" = py."pydantic-settings".overridePythonAttrs (_: {
              version = "2.14.2";
              src = fetchPypi "pydantic_settings" "2.14.2" "sha256-wZ3WSxkJfx3oAYTwzHsCcqE65uFwy/JAo+J+OB7RSl8=";
              dependencies = [
                securePy.pydantic
                securePy.python-dotenv
                securePy."typing-inspection"
              ];
            });

            "python-multipart" = py."python-multipart".overridePythonAttrs (_: {
              version = "0.0.32";
              src = fetchPypi "python_multipart" "0.0.32" "sha256-vlS38/oWe7g+T82Ta4h7cI9OV/51kRwCrr9T76+Nk44=";
            });

            starlette = py.starlette.overridePythonAttrs (old: {
              nativeCheckInputs = old.nativeCheckInputs ++ [ py.httpx2 ];
              version = "1.3.1";
              src = fetchPypi "starlette" "1.3.1" "sha256-BdAhMZPy+6rmDi7LWTtK3UJirU5GU2tUq+NvEacXJOA=";
              dependencies = [ securePy.anyio ];
            });

            pyjwt = py.pyjwt.overridePythonAttrs (_: {
              version = "2.15.1";
              src = fetchPypi "pyjwt" "2.15.1" "sha256-TyWegM37az/Bin3lH9HvnseWUvJQGbrmiXXKJGijTfg=";
              optional-dependencies.crypto = [ securePy.cryptography ];
            });

            mcp = py.mcp.overridePythonAttrs (_: {
              pythonRelaxDeps = [ ];
              version = "1.30.0";
              src = fetchPypi "mcp" "1.30.0" "sha256-RFQUYl/OXClfqlBbsRus7OZhq29AKNV8k121eCC3o+Q=";
              build-system = [
                securePy.hatchling
                py.uv-dynamic-versioning
              ];
              dependencies = [
                securePy.anyio
                securePy.httpx
                securePy.httpx-sse
                securePy.jsonschema
                securePy.pydantic
                securePy."pydantic-settings"
                securePy.pyjwt
                securePy."python-multipart"
                securePy.sse-starlette
                securePy.starlette
                securePy."typing-extensions"
                securePy."typing-inspection"
                securePy.uvicorn
              ];
            });
          };
        pname = "cloudcraft-mcp";

        # Builder: derive a cloudcraft-mcp package from one releases.json entry.
        # Only version/rev/hash come from the version table; the package logic
        # remains shared across all retained releases.
        mk =
          _key: entry:
          let
            needsRelaxedDeps =
              lib.versionAtLeast entry.version "0.1.6" && lib.versionOlder entry.version "0.1.7";
            needsSecureDeps = lib.versionAtLeast entry.version "0.1.7";
            buildPy = if needsSecureDeps then securePy else py;
          in
          buildPy.buildPythonApplication {
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

            nativeBuildInputs = [ buildPy.hatchling ];

            propagatedBuildInputs = [
              buildPy.httpx
              buildPy.mcp
              buildPy."typing-extensions"
            ]
            ++ lib.optionals needsRelaxedDeps [
              buildPy.cryptography
              buildPy.pydantic-settings
              buildPy.python-multipart
              buildPy.starlette
            ]
            ++ lib.optionals needsSecureDeps [
              buildPy.cryptography
              buildPy."pydantic-settings"
              buildPy."python-multipart"
              buildPy.starlette
              buildPy.pyjwt
              buildPy.pydantic
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
