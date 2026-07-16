{
  description = "QuantConnect Lean CLI with pinned Docker engine defaults";

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
        python = pkgs.python312;

        # Builder for the quantconnect-stubs dependency from one entry.
        mkStubs =
          entry:
          python.pkgs.buildPythonPackage {
            pname = "quantconnect-stubs";
            version = entry.stubsVersion;

            meta = with pkgs.lib; {
              description = "Python type stubs for the QuantConnect LEAN API";
              homepage = "https://github.com/QuantConnect/Lean";
              license = licenses.asl20;
              platforms = systems;
            };

            format = "wheel";

            src = pkgs.fetchPypi {
              pname = "quantconnect_stubs";
              version = entry.stubsVersion;
              format = "wheel";
              dist = "py3";
              python = "py3";
              hash = entry.stubsHash;
            };

            propagatedBuildInputs = with python.pkgs; [
              matplotlib
              pandas
            ];

            doCheck = false;

          };

        # Builder: derive a lean package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src/hash(es)
        # and the pinned Docker image data now come from `entry`.
        mk =
          key: entry:
          let
            engineImageTag = entry.engineImageTag;
            engineImageDigest = entry.engineImageDigest;
            researchImageDigest = entry.researchImageDigest;

            quantconnect-stubs = mkStubs entry;
          in
          python.pkgs.buildPythonApplication rec {
            pname = "lean";
            version = entry.version;

            meta = with pkgs.lib; {
              description = "CLI for running the QuantConnect LEAN engine locally and in the cloud";
              longDescription = ''
                This packages the Python Lean CLI from source and patches its
                default engine and research Docker image references to pinned
                QuantConnect image digests. Native .NET packaging is not used
                here because the current LEAN engine source targets net10.0 and
                is substantially less practical to build reproducibly in this
                repository than the official Docker-based workflow.
              '';
              homepage = "https://github.com/QuantConnect/lean-cli";
              license = licenses.asl20;
              mainProgram = "lean";
              platforms = systems;
            };

            format = "setuptools";

            src = pkgs.fetchPypi {
              inherit pname version;
              hash = entry.hash;
            };

            postPatch = ''
              substituteInPlace lean/constants.py \
                --replace 'DEFAULT_ENGINE_IMAGE = "quantconnect/lean:latest"' \
                          'DEFAULT_ENGINE_IMAGE = "quantconnect/lean:${engineImageTag}@${engineImageDigest}"' \
                --replace 'DEFAULT_RESEARCH_IMAGE = "quantconnect/research:latest"' \
                          'DEFAULT_RESEARCH_IMAGE = "quantconnect/research:${engineImageTag}@${researchImageDigest}"'
            '';

            propagatedBuildInputs = with python.pkgs; [
              click
              cryptography
              docker
              joblib
              json5
              lxml
              pydantic
              python-dateutil
              quantconnect-stubs
              requests
              rich
              setuptools
            ];

            pythonImportsCheck = [ "lean" ];
            doCheck = false;

          };

        latestEntry = releases.versions.${releases.latest};
        latestPkg = mk releases.latest latestEntry;

        # One `lean_<sanitized-key>` package per entry in the table.
        versionPackages = pkgs.lib.mapAttrs' (
          key: entry: pkgs.lib.nameValuePair "lean_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          lean = latestPkg;
          quantconnect-stubs = mkStubs latestEntry;
        }
        // versionPackages;

        apps.default = {
          type = "app";
          program = "${latestPkg}/bin/lean";
        };
      }
    );
}
