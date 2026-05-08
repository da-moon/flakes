{
  description = "Trunks CLI packaged from the PyPI wheel";

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
        py = pkgs.python3Packages;
        pname = "trunks";
        version = "1.2.14";
        trunksWheelUrl = "https://files.pythonhosted.org/packages/38/07/cbf08831906c5cbd1d4fe1aefb2883f99d3a887df4e73e5ccc62fe3a8c37/trunks-1.2.14-py3-none-any.whl";
        trunksWheelHash = "sha256-4RMVsCZzR/Iy33kMDT6QttS2F5xrH+BUKSv1Z0Zo9eY=";

        trunks = py.buildPythonApplication {
          inherit pname version;
          format = "wheel";

          src = pkgs.fetchurl {
            url = trunksWheelUrl;
            hash = trunksWheelHash;
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

          meta = with lib; {
            description = "Git repositories backed by user-owned storage";
            homepage = "https://layerbrain.com/trunks";
            license = licenses.mit;
            mainProgram = "trunks";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = trunks;
          inherit trunks;
        };

        apps = {
          default = {
            type = "app";
            program = "${trunks}/bin/trunks";
          };
          trunks = {
            type = "app";
            program = "${trunks}/bin/trunks";
          };
          "git-remote-trunks" = {
            type = "app";
            program = "${trunks}/bin/git-remote-trunks";
          };
        };
      }
    );
}
