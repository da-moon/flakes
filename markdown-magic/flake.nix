{
  description = "markdown-magic CLI packaged from the markdown-magic npm artifact";

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
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nodejs = pkgs.nodejs_22;
        pname = "markdown-magic";
        version = "4.8.0";

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
            hash = "sha256-k9KdIWjHmWqDwfTJM+Zg+LFA5MBDlwrUB1XlMgtceWY=";
          };

          nativeBuildInputs = [
            nodejs
            pkgs.cacert
          ];

          dontPatchShebangs = true;
          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = "sha256-ToaGW1Y3Wge+P7YNjVfhsWcrEY9UM05dYPOJ9/LOHww=";

          buildPhase = ''
            runHook preBuild

            export HOME=$TMPDIR
            export npm_config_cache=$TMPDIR/npm-cache

            tar -xzf $src
            cd package
            npm install --omit=dev --ignore-scripts

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r . $out/
            runHook postInstall
          '';
        };

        markdownMagic = pkgs.stdenv.mkDerivation {
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

            makeWrapper ${nodejs}/bin/node $out/bin/md-magic \
              --add-flags "$out/lib/${pname}/cli.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules" \
              --set NODE_ENV "production"

            ln -s md-magic $out/bin/markdown
            ln -s md-magic $out/bin/mdm

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Automatically update markdown files with content from external sources";
            homepage = "https://github.com/DavidWells/markdown-magic";
            license = licenses.mit;
            mainProgram = "md-magic";
            platforms = platforms.unix;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = markdownMagic;
          "markdown-magic" = markdownMagic;
        };

        apps = {
          default = {
            type = "app";
            program = "${markdownMagic}/bin/md-magic";
          };
          "md-magic" = {
            type = "app";
            program = "${markdownMagic}/bin/md-magic";
          };
          markdown = {
            type = "app";
            program = "${markdownMagic}/bin/markdown";
          };
          mdm = {
            type = "app";
            program = "${markdownMagic}/bin/mdm";
          };
        };
      }
    );
}
