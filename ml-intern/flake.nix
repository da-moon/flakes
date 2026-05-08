{
  description = "ml-intern CLI packaged from the PyPI wheel";

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
        version = "0.1.0";
        mlInternWheelUrl = "https://files.pythonhosted.org/packages/c3/40/817a5dcaf2b92f4b02e74b2ae12023080411f25d5f98811ebb10bff27804/ml_intern-0.1.0-py3-none-any.whl";
        mlInternWheelHash = "sha256-nnDcbkQ77DxpSKleHXms0sf+F+nfdC2tWptDZk7rwUw=";

        ml-intern = py.buildPythonApplication {
          inherit pname version;
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

          meta = with lib; {
            description = "ml-intern command-line agent";
            homepage = "https://pypi.org/project/ml-intern/";
            mainProgram = "ml-intern";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = ml-intern;
          "ml-intern" = ml-intern;
        };

        apps = {
          default = {
            type = "app";
            program = "${ml-intern}/bin/ml-intern";
          };
          "ml-intern" = {
            type = "app";
            program = "${ml-intern}/bin/ml-intern";
          };
        };
      }
    );
}
