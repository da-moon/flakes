{
  description = "ml-intern CLI packaged from the PyPI wheel";

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
        python = pkgs.python3.override {
          packageOverrides = self: super: {
            "huggingface-hub" = super.buildPythonPackage {
              pname = "huggingface-hub";
              version = "1.14.0";
              format = "wheel";

              src = pkgs.fetchurl {
                url = "https://files.pythonhosted.org/packages/89/a5/33b49ba7bea7c41bb37f74ec0f8beea0831e052330196633fe2c77516ea6/huggingface_hub-1.14.0-py3-none-any.whl";
                hash = "sha256-7+B1U1xi4TCzDoNrE44TeF9vBD0fBTngo5qkEamekLg=";
              };

              propagatedBuildInputs = [
                self.filelock
                self.fsspec
                self."hf-xet"
                self.httpx
                self.packaging
                self.pyyaml
                self.tqdm
                self.typer
                self."typing-extensions"
              ];

              doCheck = false;
              pythonImportsCheck = [ "huggingface_hub" ];
            };
          };
        };
        py = python.pkgs;
        pname = "ml-intern";

        # Builder: derive an ml-intern package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/url/hash
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            mlInternWheelUrl = entry.url;
            mlInternWheelHash = entry.hash;
          in
          py.buildPythonApplication {
            inherit pname version;

            meta = with lib; {
              description = "ml-intern command-line agent";
              homepage = "https://pypi.org/project/ml-intern/";
              mainProgram = "ml-intern";
              platforms = systems;
              maintainers = [ ];
            };

            format = "wheel";
            dontCheckRuntimeDeps = true;

            src = pkgs.fetchurl {
              url = mlInternWheelUrl;
              hash = mlInternWheelHash;
            };

            propagatedBuildInputs = [
              py.datasets
              py.pydantic
              py."python-dotenv"
              py.requests
              py.litellm
              py.boto3
              py."huggingface-hub"
              py.fastmcp
              py."prompt-toolkit"
              py.thefuzz
              py.rich
              py.nbconvert
              py.nbformat
              py.whoosh
              py.fastapi
              py.uvicorn
              py.httpx
              py.websockets
              py.apscheduler
            ];

            doCheck = false;
            pythonImportsCheck = [ "agent" ];

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `ml-intern_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "ml-intern_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          "ml-intern" = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/ml-intern";
          };
          "ml-intern" = {
            type = "app";
            program = "${latestPkg}/bin/ml-intern";
          };
        };
      }
    );
}
