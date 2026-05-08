{
  description = "Code Review Graph - token-efficient code review knowledge graph";

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
        pname = "code-review-graph";
        version = "2.3.3";
        codeReviewGraphWheelUrl = "https://files.pythonhosted.org/packages/03/d7/0d634119035f45b17bc2635470939cde580b6952dcdf6ef44112c05b10f5/code_review_graph-2.3.3-py3-none-any.whl";
        codeReviewGraphWheelHash = "sha256-FM0kcGCQyemIg7xw1FzyMju9xh9jMiXE4gZiHeEEJN8=";

        pyKeyValueAio = py.buildPythonPackage rec {
          pname = "py-key-value-aio";
          version = "2.3.3";
          format = "wheel";

          src = pkgs.fetchurl {
            url = "https://files.pythonhosted.org/packages/32/69/f1b537ee70b7def42d63124a539ed3026a11a3ffc3086947a1ca6e861868/py_key_value_aio-0.4.4-py3-none-any.whl";
            hash = "sha256-GOF1ZOyuYbmH+Qn8LNQe4gEshLSx3LjAVc+LS8G/P10=";
          };

          propagatedBuildInputs = [
            py.aiofile
            py.anyio
            py.beartype
            py.cachetools
            py.keyring
            py."typing-extensions"
          ];

          doCheck = false;
          pythonImportsCheck = [ "key_value" ];
        };

        fastmcp = py.buildPythonPackage rec {
          pname = "fastmcp";
          version = "2.3.3";
          format = "wheel";

          src = pkgs.fetchurl {
            url = "https://files.pythonhosted.org/packages/cf/76/b310d52fa0e30d39bd937eb58ec2c1f1ea1b5f519f0575e9dd9612f01deb/fastmcp-3.2.4-py3-none-any.whl";
            hash = "sha256-5snEKRcQQUVeR6uUuz+DxGV2IqDsKJIvaUAFOVm9WKk=";
          };

          propagatedBuildInputs = [
            py.authlib
            py.cyclopts
            py."email-validator"
            py.exceptiongroup
            py.griffelib
            py.httpx
            py.jsonref
            py."jsonschema-path"
            py.mcp
            py."openapi-pydantic"
            py."opentelemetry-api"
            py.packaging
            py.platformdirs
            py.pydantic
            py.pyperclip
            py.python-dotenv
            py.pyyaml
            py.rich
            py."uncalled-for"
            py.uvicorn
            py.watchfiles
            py.websockets
            pyKeyValueAio
          ];

          doCheck = false;
          pythonImportsCheck = [ "fastmcp" ];
        };

        codeReviewGraph = py.buildPythonApplication rec {
          inherit pname version;
          format = "wheel";
          # The published wheel metadata lags behind the current upstream
          # pyproject constraints, so rely on the explicit dependency set below.
          dontCheckRuntimeDeps = true;

          src = pkgs.fetchurl {
            url = codeReviewGraphWheelUrl;
            hash = codeReviewGraphWheelHash;
          };

          propagatedBuildInputs = [
            fastmcp
            py.mcp
            py.networkx
            py.tree-sitter
            py."tree-sitter-language-pack"
            py.watchdog
          ];

          doCheck = false;
          pythonImportsCheck = [ "code_review_graph" ];

          meta = with lib; {
            description = "Persistent incremental knowledge graph for token-efficient code reviews";
            homepage = "https://github.com/tirth8205/code-review-graph";
            license = licenses.mit;
            mainProgram = "code-review-graph";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = codeReviewGraph;
          "code-review-graph" = codeReviewGraph;
        };

        apps = {
          default = {
            type = "app";
            program = "${codeReviewGraph}/bin/code-review-graph";
          };
          "code-review-graph" = {
            type = "app";
            program = "${codeReviewGraph}/bin/code-review-graph";
          };
          "crg-daemon" = {
            type = "app";
            program = "${codeReviewGraph}/bin/crg-daemon";
          };
        };
      }
    );
}
