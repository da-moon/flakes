{
  description = "MCPDoc - MCP server for llms.txt documentation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pname = "mcpdoc";

        # Builder: derive an mcpdoc package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version and the
        # source hash now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
          in
          pkgs.python3Packages.buildPythonApplication {
            inherit pname version;

            meta = with pkgs.lib; {
              description = "Server llms-txt documentation over MCP";
              homepage = "https://github.com/langchain-ai/mcpdoc";
              license = licenses.mit;
              platforms = platforms.unix;
              mainProgram = pname;
            };

            pyproject = true;

            nativeBuildInputs = with pkgs.python3Packages; [ hatchling ];

            src = pkgs.fetchPypi {
              inherit pname version;
              hash = entry.hash;
            };

            propagatedBuildInputs = with pkgs.python3Packages; [
              httpx
              markdownify
              mcp
              pyyaml
            ];

            doCheck = false;

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `mcpdoc-mcp-server_<sanitized-key>` package per entry in the table.
        versionedPackages = builtins.listToAttrs (
          builtins.map (key: {
            name = "mcpdoc-mcp-server_${sanitize key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
        );
      in
      {
        packages = versionedPackages // {
          default = latestPkg;
          mcpdoc = latestPkg;
          mcpdoc-mcp-server = latestPkg;
        };

        apps.default = {
          type = "app";
          program = "${latestPkg}/bin/mcpdoc";
        };
        apps.mcpdoc = {
          type = "app";
          program = "${latestPkg}/bin/mcpdoc";
        };
      }
    );
}
