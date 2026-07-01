{
  description = "QMD (Query Markup Documents) - on-device search engine for markdown notes";

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
        version = "2.5.3";

        sqliteWithExtensions = pkgs.sqlite.overrideAttrs (old: {
          configureFlags = (old.configureFlags or [ ]) ++ [
            "--enable-load-extension"
          ];
        });

        sourceHashBySystem = {
          "aarch64-linux" = "sha256-v1s5PPB6GwJXCR1JkQBOpJ+1r97FCkQg1EXQ/fvvZXM=";
          "x86_64-linux" = "sha256-v1s5PPB6GwJXCR1JkQBOpJ+1r97FCkQg1EXQ/fvvZXM=";
        };

        # Optional dependencies and install artifacts may vary by architecture.
        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-HV999LRzcH5D6NyvocOS1Zasv+ZG6P39k+Hpw1KpOkM=";
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
            ${pkgs.nodejs_22}/bin/node <<'NODE'
            const fs = require("fs");
            const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));

            function exactSpec(spec) {
              if (typeof spec !== "string") return spec;
              if (/^(file:|link:|workspace:|git\+|https?:)/.test(spec)) return spec;
              const bare = spec.match(/^[~^](\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)$/);
              return bare ? bare[1] : spec;
            }

            function isExactInstallSpec(spec) {
              return /^(file:|link:|workspace:|git\+|https?:)/.test(spec)
                || /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(spec);
            }

            const unresolved = [];
            for (const field of ["dependencies", "devDependencies", "optionalDependencies"]) {
              for (const [name, spec] of Object.entries(pkg[field] || {})) {
                const next = exactSpec(spec);
                pkg[field][name] = next;
                if (typeof next === "string" && !isExactInstallSpec(next)) {
                  unresolved.push(field + "." + name + "=" + next);
                }
              }
            }

            if (unresolved.length > 0) {
              throw new Error("Non-exact dependency specs remain: " + unresolved.join(", "));
            }

            fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n");
NODE
            bun install --ignore-scripts --backend=copyfile
          '';

          installPhase = ''
            mkdir -p $out
            cp -r . $out/
          '';
        };

        qmd = pkgs.stdenv.mkDerivation {
          inherit pname version;

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
