{
  description = "purgecss CLI packaged as a Nix flake (npm tarball, offline install)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nodejs = pkgs.nodejs_20;
        pname = "purgecss";
        version = "7.0.2";

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
            hash = "sha256-x+fTfIqh+Bv3BpZXW8mu3MaIzEDNMpzawdBLdU1PPXs=";
          };

          nativeBuildInputs = [ nodejs pkgs.cacert ];
          dontPatchShebangs = true;

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = "sha256-zw03lD054YbKJ2lmo+166stm1LqwKMJQUPOTxBJI9CQ=";

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

        purgecss = pkgs.stdenv.mkDerivation {
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
            makeWrapper ${nodejs}/bin/node $out/bin/purgecss \
              --add-flags "$out/lib/${pname}/bin/purgecss.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules"
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Remove unused CSS via PurgeCSS CLI";
            homepage = "https://purgecss.com/";
            license = licenses.mit;
            platforms = platforms.unix;
          };
        };
      in
      {
        packages = {
          default = purgecss;
          inherit purgecss;
        };
        apps.default = {
          type = "app";
          program = "${purgecss}/bin/purgecss";
        };
      });
}
