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

        sqliteWithExtensions = pkgs.sqlite.overrideAttrs (old: {
          configureFlags = (old.configureFlags or [ ]) ++ [
            "--enable-load-extension"
          ];
        });

        sourceHashBySystem = {
          "aarch64-linux" = "sha256-a+lF9917f1kl2wTrrQ38Jz55kUOlIkqg1jy5uuLwIao=";
          "x86_64-linux" = "sha256-a+lF9917f1kl2wTrrQ38Jz55kUOlIkqg1jy5uuLwIao=";
        };

        # Optional dependencies and install artifacts may vary by architecture.
        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-5el0o8mkrf2L8uce9v96CprrAb/JC8WG3NBPoNyJjlI=";
        };

        source = pkgs.fetchurl {
          url = "https://github.com/tobi/qmd/archive/refs/tags/v${version}.tar.gz";
          hash = sourceHashBySystem.${system} or (throw "Missing source hash for system ${system}");
        };

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = source;
          nativeBuildInputs = [ pkgs.bun pkgs.python3 pkgs.cacert ];
          dontPatchShebangs = true;

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = outputHashBySystem.${system}
            or (throw "Missing outputHashBySystem entry for system ${system}");

          buildPhase = ''
            export HOME=$TMPDIR
            export BUN_INSTALL=$TMPDIR/.bun
            export BUN_INSTALL_GLOBAL_DIR=$TMPDIR/.bun-global
            export BUN_INSTALL_CACHE_DIR=$TMPDIR/.bun-cache

            tar -xzf $src
            cd qmd-${version}
            bun install --frozen-lockfile --ignore-scripts
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

            makeWrapper ${pkgs.bun}/bin/bun $out/bin/qmd \
              --add-flags "$out/lib/${pname}/src/qmd.ts" \
              --set-default NODE_LLAMA_CPP_BUILD_DIR "/tmp/node-llama-cpp" \
              --run "mkdir -p /tmp/node-llama-cpp" \
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
