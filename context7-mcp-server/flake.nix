{
  description = "Context7 MCP Server - brings up-to-date documentation into context";

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
        pname = "context7-mcp";
        version = "1.0.33";

        # NOTE: npm optionalDependencies can be platform-specific (for example, esbuild),
        # so the fixed-output hash from "npm install" is not portable across systems.
        outputHashBySystem = {
          "aarch64-linux" = "sha256-6RfpAZzaqavNUC/iTFmUYzZzz6y87feNVXDBSgqxVpY=";
          "x86_64-linux" = "sha256-4iRmTnqwOd5sqq7k+2SHgu3tv+DYrs/8PobiLOmDXXk=";
        };

        # Fixed-output derivation to fetch npm package with all dependencies
        # This has network access during build
        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/@upstash/context7-mcp/-/context7-mcp-${version}.tgz";
            hash = "sha256-gl8VOdBaxYEoJmYKhVozSssN7ofwE3fgTKvw7SbYs0E=";
          };

          nativeBuildInputs = [ nodejs pkgs.cacert ];

          # FOD settings - allows network access, output is content-addressed
          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          # Get this hash by first building with pkgs.lib.fakeHash
          outputHash = outputHashBySystem.${system}
            or (throw "Missing outputHashBySystem entry for system: ${system}");

          buildPhase = ''
            runHook preBuild

            export HOME=$TMPDIR
            export npm_config_cache=$TMPDIR/.npm

            tar -xzf $src
            cd package
            npm install --production --ignore-scripts

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r . $out/
            runHook postInstall
          '';
        };

        # Main package - just sets up the wrapper
        context7-mcp = pkgs.stdenv.mkDerivation {
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

            # Create wrapper - shebangs handled automatically by Nix
            makeWrapper ${nodejs}/bin/node $out/bin/context7-mcp \
              --add-flags "$out/lib/${pname}/dist/index.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules"

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Context7 MCP Server - up-to-date documentation for LLMs";
            homepage = "https://github.com/upstash/context7";
            platforms = platforms.unix;
          };
        };

      in
      {
        packages = {
          default = context7-mcp;
          inherit context7-mcp;
        };
      }
    );
}
