{
  description = "GitNexus - graph-powered code intelligence for AI agents";

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
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nodejs = pkgs.nodejs_22;
        # Pin pnpm major to match the committed pnpm-lock.yaml (lockfileVersion 9.0).
        pnpm = pkgs.pnpm_10;
        pname = "gitnexus";

        # Builder: turns one releases.json entry into the gitnexus derivation.
        #
        # Dependencies are pinned by a committed pnpm-lock.yaml (deps/<version>/)
        # and fetched with pnpm.fetchDeps — a content-addressed derivation keyed
        # to that lockfile. This is reproducible over time: the hash changes only
        # when the committed lockfile changes, never because the npm registry or
        # native addon builds drifted.
        mk =
          key: entry:
          let
            version = entry.version;
            lockfile = ./deps + "/${key}/pnpm-lock.yaml";

            tarball = pkgs.fetchurl {
              url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
              hash = entry.hash;
            };

            # The published npm tarball ships no lockfile. Inject our committed,
            # fully-pinned pnpm-lock.yaml, but first apply the exact same
            # package.json mutation the lockfile was generated against: strip
            # lifecycle scripts and unbuildable dev/optional deps, pin semver
            # ranges down to the exact version already listed (so the resolved
            # tree can never drift), bump onnxruntime-node to the version
            # actually used at runtime, and declare pnpm's build-script
            # allowlist for native addons (tree-sitter, @ladybugdb/core).
            src = pkgs.runCommand "${pname}-${version}-src" { nativeBuildInputs = [ nodejs ]; } ''
              mkdir -p $out
              tar -xzf ${tarball} -C $out --strip-components=1
              cd $out

              node -e '
                const fs = require("fs");
                const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));

                if (pkg.scripts) {
                  delete pkg.scripts.prepare;
                  delete pkg.scripts.postinstall;
                }

                if (pkg.devDependencies) {
                  delete pkg.devDependencies["gitnexus-shared"];
                }

                if (pkg.optionalDependencies) {
                  delete pkg.optionalDependencies["tree-sitter-swift"];
                }

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

                if (pkg.dependencies && pkg.dependencies["onnxruntime-node"] === "1.24.0") {
                  pkg.dependencies["onnxruntime-node"] = "1.26.0";
                }

                pkg.pnpm = {
                  onlyBuiltDependencies: [
                    "@ladybugdb/core",
                    "tree-sitter",
                    "tree-sitter-c",
                    "tree-sitter-c-sharp",
                    "tree-sitter-cpp",
                    "tree-sitter-go",
                    "tree-sitter-java",
                    "tree-sitter-javascript",
                    "tree-sitter-kotlin",
                    "tree-sitter-php",
                    "tree-sitter-python",
                    "tree-sitter-ruby",
                    "tree-sitter-rust",
                    "tree-sitter-typescript"
                  ],
                  ignoredBuiltDependencies: [
                    "onnxruntime-node",
                    "protobufjs",
                    "sharp"
                  ]
                };

                fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2));
              '

              cp ${lockfile} $out/pnpm-lock.yaml
            '';

            pnpmDeps = pnpm.fetchDeps {
              inherit pname version src;
              fetcherVersion = 2;
              hash = entry.pnpmDepsHash;
            };
          in
          pkgs.stdenv.mkDerivation {
            inherit
              pname
              version
              src
              pnpmDeps
              ;

            meta = with pkgs.lib; {
              description = "Graph-powered code intelligence for AI agents";
              homepage = "https://github.com/abhigyanpatwari/GitNexus";
              platforms = platforms.unix;
              mainProgram = "gitnexus";
            };

            nativeBuildInputs = [
              nodejs
              pnpm.configHook
              pkgs.makeWrapper
              pkgs.cacert
              pkgs.python3
              pkgs.gcc
              pkgs.pkg-config
            ];

            # structuredAttrs is required so pnpmInstallFlags reaches the
            # config hook as a bash array rather than one space-joined string.
            __structuredAttrs = true;

            # pnpmConfigHook runs `pnpm install --offline --frozen-lockfile` with
            # these flags: production-only tree, flattened so NODE_PATH resolves,
            # lifecycle scripts skipped here (native addons are rebuilt
            # explicitly below via the pnpm.onlyBuiltDependencies allowlist).
            pnpmInstallFlags = [
              "--prod"
              "--ignore-scripts"
              "--shamefully-hoist"
            ];

            buildPhase = ''
              runHook preBuild

              export HOME=$TMPDIR/home
              mkdir -p $HOME
              export npm_config_nodedir=${nodejs}
              export npm_config_python=${pkgs.python3}/bin/python3

              pnpm rebuild --pending

              ${nodejs}/bin/node -e '
                const fs = require("fs");
                const path = require("path");

                const coreEntry = require.resolve("@ladybugdb/core", { paths: [process.cwd()] });
                const coreDir = fs.realpathSync(path.dirname(coreEntry));
                const platformEntry = require.resolve(`@ladybugdb/core-''${process.platform}-''${process.arch}`, {
                  paths: [process.cwd()]
                });
                const src = path.join(fs.realpathSync(path.dirname(platformEntry)), "lbugjs.node");
                const dest = path.join(coreDir, "lbugjs.node");

                if (!fs.existsSync(src)) {
                  throw new Error(`Missing LadybugDB platform binary: ''${src}`);
                }

                fs.copyFileSync(src, dest);
              '

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/${pname}
              mkdir -p $out/bin
              shopt -s dotglob
              cp -r ./* $out/lib/${pname}/
              shopt -u dotglob

              makeWrapper ${nodejs}/bin/node $out/bin/gitnexus \
                --add-flags "$out/lib/${pname}/dist/cli/index.js" \
                --set NODE_PATH "$out/lib/${pname}/node_modules" \
                --set NODE_ENV "production" \
                --prefix PATH : ${
                  pkgs.lib.makeBinPath [
                    pkgs.git
                    pkgs.ripgrep
                  ]
                }

              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        versionedPackages = builtins.listToAttrs (
          builtins.map
            (key: {
              name = "${pname}_${sanitize key}";
              value = mk key releases.versions.${key};
            })
            (
              builtins.filter (
                key: builtins.pathExists (./deps + "/${key}/pnpm-lock.yaml")
              ) (builtins.attrNames releases.versions)
            )
        );
      in
      {
        packages = versionedPackages // {
          default = latestPkg;
          gitnexus = latestPkg;
        };

        apps.default = {
          type = "app";
          program = "${latestPkg}/bin/gitnexus";
        };
      }
    );
}
