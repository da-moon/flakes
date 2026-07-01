{
  description = "Code Review Graph - token-efficient code review knowledge graph";

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
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        py = pkgs.python3Packages;
        pname = "code-review-graph";

        pyKeyValueAio = py.buildPythonPackage rec {
          pname = "py-key-value-aio";
          version = "2.3.6";
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
          version = "2.3.6";
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

        # Builder: derive a code-review-graph package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/wheel-url/hash
        # now come from `entry` instead of top-level let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            codeReviewGraphWheelUrl = entry.url;
            codeReviewGraphWheelHash = entry.hash;
          in
          py.buildPythonApplication rec {
          inherit pname version;

          meta = with lib; {
            description = "Persistent incremental knowledge graph for token-efficient code reviews";
            homepage = "https://github.com/tirth8205/code-review-graph";
            license = licenses.mit;
            mainProgram = "code-review-graph";
            platforms = linuxSystems;
            maintainers = [ ];
          };

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

        };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `code-review-graph_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "code-review-graph_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          "code-review-graph" = latestPkg;
        } // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/code-review-graph";
          };
          "code-review-graph" = {
            type = "app";
            program = "${latestPkg}/bin/code-review-graph";
          };
          "crg-daemon" = {
            type = "app";
            program = "${latestPkg}/bin/crg-daemon";
          };
        };
      }
    );
}
