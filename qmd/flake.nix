{
  description = "QMD (Query Markup Documents) - on-device search engine for markdown notes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pname = "qmd";

        sqliteWithExtensions = pkgs.sqlite.overrideAttrs (old: {
          configureFlags = (old.configureFlags or [ ]) ++ [
            "--enable-load-extension"
          ];
        });

        # Builder: derive a qmd package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src/hash(es)
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;

            source = pkgs.fetchurl {
              url = "https://github.com/tobi/qmd/archive/refs/tags/v${version}.tar.gz";
              hash = entry.hash;
            };

            npmDeps = pkgs.stdenv.mkDerivation {
              name = "${pname}-${version}-npm-deps";

              src = source;
              nativeBuildInputs = [
                pkgs.bun
                pkgs.python3
                pkgs.cacert
              ];
              dontPatchShebangs = true;

              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              outputHash =
                entry.outputHashes.${system} or (throw "Missing outputHashes entry for system ${system}");

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
                                bun install --ignore-scripts --backend=copyfile \
                                  --os ${if pkgs.stdenv.hostPlatform.isDarwin then "darwin" else "linux"} \
                                  --cpu ${if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x64"}
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
                  "aarch64-darwin"
                  "x86_64-darwin"
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
                  --set LD_LIBRARY_PATH "${
                    pkgs.lib.makeLibraryPath [
                      sqliteWithExtensions
                      pkgs.stdenv.cc.cc.lib
                    ]
                  }"
              '';

            };
          in
          qmd;

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `qmd_<sanitized-key>` package per entry in the table.
        versionedPackages = builtins.listToAttrs (
          builtins.map
            (key: {
              name = "${pname}_${sanitizeKey key}";
              value = mk key releases.versions.${key};
            })
            (
              builtins.filter (
                key:
                let
                  hash = releases.versions.${key}.outputHashes.${system} or null;
                in
                # fakeHash entries must stay exposed: update-version.sh builds the
                # attr to learn the real hash from nix's "got:" mismatch line.
                hash != null
              ) (builtins.attrNames releases.versions)
            )
        );

      in
      {
        packages = versionedPackages // {
          default = latestPkg;
          qmd = latestPkg;
        };

        apps.default = {
          type = "app";
          program = "${latestPkg}/bin/qmd";
        };

        apps.qmd = {
          type = "app";
          program = "${latestPkg}/bin/qmd";
        };
      }
    );
}
