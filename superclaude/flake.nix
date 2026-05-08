{
  description = "SuperClaude CLI packaged from the PyPI wheel";

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
        pname = "superclaude";
        version = "4.3.0";
        superclaudeWheelUrl = "https://files.pythonhosted.org/packages/b2/55/41fd89182d46f3489b6e0f53c7c9403b745091fce893e90cc31ddaa57e61/superclaude-4.3.0-py3-none-any.whl";
        superclaudeWheelHash = "sha256-uWp1RpMHzSPUDMQ8MFg2U9FCwgE87L4XWVQ7uwAq0eU=";

        superclaude = py.buildPythonApplication {
          inherit pname version;
          format = "wheel";

          src = pkgs.fetchurl {
            url = superclaudeWheelUrl;
            hash = superclaudeWheelHash;
          };

          propagatedBuildInputs = [
            py.click
            py.pytest
            py.rich
          ];

          doCheck = false;
          pythonImportsCheck = [ "superclaude" ];

          meta = with lib; {
            description = "AI-enhanced development framework for Claude Code";
            homepage = "https://github.com/SuperClaude-Org/SuperClaude_Framework";
            license = licenses.mit;
            mainProgram = "superclaude";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = superclaude;
          inherit superclaude;
        };

        apps = {
          default = {
            type = "app";
            program = "${superclaude}/bin/superclaude";
          };
          superclaude = {
            type = "app";
            program = "${superclaude}/bin/superclaude";
          };
        };
      }
    );
}
