{
  description = "MCPDoc - MCP server for llms.txt documentation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pname = "mcpdoc";
        version = "0.0.10";

        mcpdoc = pkgs.python3Packages.buildPythonApplication {
          inherit pname version;

          pyproject = true;

          nativeBuildInputs = with pkgs.python3Packages; [ hatchling ];

          src = pkgs.fetchPypi {
            inherit pname version;
            hash = "sha256-f+jj7R28CIY3imxwBNbLHmt5Vz7RvhU3Tx4aH8BfMKk=";
          };

          propagatedBuildInputs = with pkgs.python3Packages; [
            httpx
            markdownify
            mcp
            pyyaml
          ];

          doCheck = false;

          meta = with pkgs.lib; {
            description = "Server llms-txt documentation over MCP";
            homepage = "https://github.com/langchain-ai/mcpdoc";
            license = licenses.mit;
            platforms = [ "aarch64-linux" "x86_64-linux" ];
            mainProgram = pname;
          };
        };
      in
      {
        packages = {
          default = mcpdoc;
          inherit mcpdoc;
        };

        apps.default = {
          type = "app";
          program = "${mcpdoc}/bin/mcpdoc";
        };
        apps.mcpdoc = {
          type = "app";
          program = "${mcpdoc}/bin/mcpdoc";
        };
      }
    );
}
