{
  description = "QMD - Quick Markdown Search";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pname = "qmd";
        version = "1.0.7";
        nodejs = pkgs.nodejs_22;

        sourceHashBySystem = {
          "aarch64-linux" = "sha256-wA9razNIb66uzAt+tAzhSPK2bXcCNSekVB/e/fxVJek=";
          "x86_64-linux" = "sha256-wA9razNIb66uzAt+tAzhSPK2bXcCNSekVB/e/fxVJek=";
        };

        # Optional dependencies in qmd may vary by platform.
        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-Hh0O8lncr3iatxBgwZ9dCkhQzTUtsXX6whcA92u7+kA=";
        };

        source = pkgs.fetchurl {
          url = "https://registry.npmjs.org/%40tobilu%2fqmd/-/qmd-${version}.tgz";
          hash = sourceHashBySystem.${system} or (throw "Missing source hash for system ${system}");
        };

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = source;
          nativeBuildInputs = [ nodejs pkgs.pnpm pkgs.cacert ];
          dontPatchShebangs = true;

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = outputHashBySystem.${system}
            or (throw "Missing outputHashBySystem entry for system ${system}");

          buildPhase = ''
            export HOME=$TMPDIR
            export npm_config_cache=$TMPDIR/.npm

            tar -xzf $src
            cd package
            pnpm install --prod --ignore-scripts --shamefully-hoist
          '';

          installPhase = ''
            mkdir -p $out
            cp -r . $out/
          '';
        };

        qmd = pkgs.stdenv.mkDerivation {
          inherit pname version;

          src = npmDeps;

          nativeBuildInputs = [ pkgs.makeWrapper ];
          dontBuild = true;
          dontConfigure = true;

          installPhase = ''
            mkdir -p $out/lib/${pname}
            mkdir -p $out/bin

            cp -r $src/* $out/lib/${pname}/

            makeWrapper ${nodejs}/bin/node $out/bin/qmd \
              --add-flags "$out/lib/${pname}/dist/qmd.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules" \
              --set NODE_ENV "production"
          '';

          meta = with pkgs.lib; {
            description = "On-device search engine for markdown notes with markdown knowledge extraction";
            homepage = "https://github.com/tobi/qmd";
            license = licenses.mit;
            platforms = [
              "aarch64-linux"
              "x86_64-linux"
            ];
            mainProgram = "qmd";
          };
        };

      in
      {
        packages = {
          default = qmd;
          inherit qmd;
        };

        apps.default = {
          type = "app";
          program = "${qmd}/bin/qmd";
        };

        apps.qmd = {
          type = "app";
          program = "${qmd}/bin/qmd";
        };
      }
    );
}
