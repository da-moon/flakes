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

        sourceHashBySystem = {
          "aarch64-linux" = "sha256-a+lF9917f1kl2wTrrQ38Jz55kUOlIkqg1jy5uuLwIao=";
          "x86_64-linux" = "sha256-a+lF9917f1kl2wTrrQ38Jz55kUOlIkqg1jy5uuLwIao=";
        };

        # SQLite with loadable extension support for sqlite-vec
        sqliteWithExtensions = pkgs.sqlite.overrideAttrs (old: {
          configureFlags = (old.configureFlags or [ ]) ++ [
            "--enable-load-extension"
          ];
        });

        source = let
          source_archive = pkgs.fetchurl {
            url = "https://github.com/tobi/qmd/archive/refs/tags/v${version}.tar.gz";
            hash = sourceHashBySystem.${system} or (throw "Missing source hash for system ${system}");
          };
        in
          pkgs.runCommand "${pname}-source-${version}" { } ''
            tar -xzf ${source_archive}
            cp -r "${pname}-${version}/." "$out/"
          '';

        qmd = pkgs.stdenv.mkDerivation {
          inherit pname version;

          src = source;

          nativeBuildInputs = [
            pkgs.bun
            pkgs.makeWrapper
            pkgs.python3
          ];

          buildInputs = [ pkgs.sqlite sqliteWithExtensions ];

          buildPhase = ''
            export HOME=$(mktemp -d)
            bun install --frozen-lockfile
          '';

          installPhase = ''
            mkdir -p $out/lib/qmd
            mkdir -p $out/bin

            cp -r node_modules $out/lib/qmd/
            cp -r src $out/lib/qmd/
            cp package.json $out/lib/qmd/

            makeWrapper ${pkgs.bun}/bin/bun $out/bin/qmd \
              --add-flags "$out/lib/qmd/src/qmd.ts" \
              --set DYLD_LIBRARY_PATH "${sqliteWithExtensions.out}/lib" \
              --set LD_LIBRARY_PATH "${sqliteWithExtensions.out}/lib"
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
