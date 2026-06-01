{
  description = "QuantConnect Lean CLI with pinned Docker engine defaults";

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
        python = pkgs.python312;

        engineImageTag = "17758";
        engineImageDigest = "sha256:f85c643572f9c50301591f9ab405d90dec957945ff1f25b6d09de384e3e703c7";
        researchImageDigest = "sha256:9e7b4fb9b7284802ca78b6eeaf0bcb73511609e5abfd4eaab38d30e61426ee21";

        quantconnect-stubs = python.pkgs.buildPythonPackage {
          pname = "quantconnect-stubs";
          version = "17758";
          format = "wheel";

          src = pkgs.fetchPypi {
            pname = "quantconnect_stubs";
            version = "17758";
            format = "wheel";
            dist = "py3";
            python = "py3";
            hash = "sha256-t0ySi6mCKJEIBWxn/f0EVf28zy+ngeZV/P1Ny68pyD8=";
          };

          propagatedBuildInputs = with python.pkgs; [
            matplotlib
            pandas
          ];

          doCheck = false;

          meta = with pkgs.lib; {
            description = "Python type stubs for the QuantConnect LEAN API";
            homepage = "https://github.com/QuantConnect/Lean";
            license = licenses.asl20;
            platforms = linuxSystems;
          };
        };

        lean = python.pkgs.buildPythonApplication rec {
          pname = "lean";
          version = "1.0.225";
          format = "setuptools";

          src = pkgs.fetchPypi {
            inherit pname version;
            hash = "sha256-lokFOYWmyQvSdsnZKVE/9sjGHAyYVsFPebMrv0eSN2c=";
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
            platforms = linuxSystems;
          };
        };
      in
      {
        packages = {
          default = lean;
          inherit lean quantconnect-stubs;
        };

        apps.default = {
          type = "app";
          program = "${lean}/bin/lean";
        };
      }
    );
}
