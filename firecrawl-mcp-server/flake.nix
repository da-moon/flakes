{
  description = "Firecrawl MCP Server - web scraping and crawling for LLMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nodejs = pkgs.nodejs_20;
        pname = "firecrawl-mcp";
        version = "3.14.1";

        # NOTE: npm optionalDependencies can be platform-specific,
        # so the fixed-output hash from "yarn install" is not portable across systems.
        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-9pG06aljvpyoBxKgj4pRf6z1ueP1e1T77tC32+GKxFY=";
        };

        # Fixed-output derivation to fetch npm package with all dependencies
        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/firecrawl-mcp/-/firecrawl-mcp-${version}.tgz";
            hash = "sha256-Yl/SVfAVWjJW3yJzgjqc7OZSNwRoms4IIycddPFkV8U=";
          };

          nativeBuildInputs = [ nodejs pkgs.cacert pkgs.yarn ];

          # Don't patch shebangs in FOD - it would add store references
          # Shebangs will be patched in the main derivation
          dontPatchShebangs = true;

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = outputHashBySystem.${system}
            or (throw "Missing outputHashBySystem entry for system: ${system}");

          buildPhase = ''
            runHook preBuild

            export HOME=$TMPDIR

            tar -xzf $src
            cd package
            yarn install --production --ignore-scripts --non-interactive

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r . $out/
            runHook postInstall
          '';
        };

        # Main package
        firecrawl-mcp = pkgs.stdenv.mkDerivation {
          inherit pname version;

          src = npmDeps;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          dontBuild = true;
          dontConfigure = true;

          installPhase = ''
            runHook preInstall

            mkdir -p $out/lib/${pname}
            mkdir -p $out/bin

            cp -r $src/* $out/lib/${pname}/

            makeWrapper ${nodejs}/bin/node $out/bin/firecrawl-mcp \
              --add-flags "$out/lib/${pname}/dist/index.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules"

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Firecrawl MCP Server - web scraping and crawling";
            homepage = "https://github.com/mendableai/firecrawl-mcp-server";
            platforms = platforms.unix;
          };
        };

      in
      {
        packages = {
          default = firecrawl-mcp;
          inherit firecrawl-mcp;
        };
      }
    );
}
