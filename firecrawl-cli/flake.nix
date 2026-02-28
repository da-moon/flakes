{
  description = "Firecrawl CLI - scrape, crawl, and extract data from websites from your terminal";

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
        pname = "firecrawl-cli";
        version = "1.9.1";

        # NOTE: npm optionalDependencies and native dependencies can be platform-specific,
        # so the fixed-output hash from "npm install" is not always portable.
        # Start from fakeHash and rehash per-system after build.
        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-isJub/UQspiQDxitAyXc+RP/U/HCSFeKcYC+pM8cvcA=";
        };

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
            hash = "sha256-hilRmdy3ofa30QTmHl/O6ceWd5rRBOyFCqNHuPVvp2A=";
          };

          nativeBuildInputs = [ nodejs pkgs.cacert ];

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

        firecrawl-cli = pkgs.stdenv.mkDerivation {
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

            makeWrapper ${nodejs}/bin/node $out/bin/firecrawl \
              --add-flags "$out/lib/${pname}/dist/index.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules"

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Firecrawl CLI - scrape, crawl, and extract data from any website.";
            homepage = "https://docs.firecrawl.dev/cli";
            platforms = platforms.unix;
            mainProgram = "firecrawl";
          };
        };
      in
      {
        packages = {
          default = firecrawl-cli;
          inherit firecrawl-cli;
        };

        apps.default = {
          type = "app";
          program = "${firecrawl-cli}/bin/firecrawl";
        };
      }
    );
}
