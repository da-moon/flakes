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
        version = "2.0.0";

        sqliteWithExtensions = pkgs.sqlite.overrideAttrs (old: {
          configureFlags = (old.configureFlags or [ ]) ++ [
            "--enable-load-extension"
          ];
        });

        sourceHashBySystem = {
          "aarch64-linux" = "sha256-VpcOP0F8E+IDoc1M/XG+CIvLwRsKJxdYpY/k3SiC1Zo=";
          "x86_64-linux" = "sha256-VpcOP0F8E+IDoc1M/XG+CIvLwRsKJxdYpY/k3SiC1Zo=";
        };

        # Optional dependencies and install artifacts may vary by architecture.
        outputHashBySystem = {
          "aarch64-linux" = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          "x86_64-linux" = "sha256-VOm6EY6Mx9a4HQQSjh0EIdZTZZ57Ujj6rOIZ/r6ZXOc=";
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
            bun install --ignore-scripts
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

            # Symlink localBuilds to a writable location so node-llama-cpp
            # doesn't try to mkdir inside the read-only /nix/store
            chmod u+w $out/lib/${pname}/node_modules/node-llama-cpp/llama
            ln -sf /tmp/node-llama-cpp/localBuilds \
              $out/lib/${pname}/node_modules/node-llama-cpp/llama/localBuilds

            makeWrapper ${pkgs.bun}/bin/bun $out/bin/qmd \
              --add-flags "$out/lib/${pname}/src/qmd.ts" \
              --set-default NODE_LLAMA_CPP_BUILD_DIR "/tmp/node-llama-cpp" \
              --set NODE_LLAMA_CPP_SKIP_DOWNLOAD "true" \
              --run "mkdir -p /tmp/node-llama-cpp/localBuilds" \
              --set DYLD_LIBRARY_PATH "${sqliteWithExtensions.out}/lib" \
              --set LD_LIBRARY_PATH "${pkgs.lib.makeLibraryPath [
                sqliteWithExtensions
                pkgs.stdenv.cc.cc.lib
              ]}"
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
