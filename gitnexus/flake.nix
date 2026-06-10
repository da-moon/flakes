{
  description = "GitNexus - graph-powered code intelligence for AI agents";

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
        pname = "gitnexus";
        version = "1.6.7";

        # Native parser/database dependencies make the fixed-output install
        # arch-specific. Rehash each supported Linux system separately.
        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-Q0shA9ZDMfJh2x1/ynL58zksmMvP2mYijESziwlN9Wc=";
        };

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
            hash = "sha256-mEC8LAb5b/p46ByKa/XQsivSr0B4uCydJArgj/RTfiE=";
          };

          nativeBuildInputs = [
            nodejs
            pkgs.pnpm
            pkgs.cacert
          ];

          # Don't patch shebangs in FOD - it would add store references.
          # Shebangs will be patched in the main derivation.
          dontPatchShebangs = true;

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = outputHashBySystem.${system}
            or (throw "Missing outputHashBySystem entry for system: ${system}");

          buildPhase = ''
            runHook preBuild

            export HOME=$TMPDIR
            tar -xzf $src
            cd package

            # The published tarball already contains dist/, so skip root build
            # hooks. Native rebuilds happen in the main derivation, which keeps
            # the fixed-output dependency tree free of local compiler references.
            ${nodejs}/bin/node -e '
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

            NODE_OPTIONS=--max-old-space-size=4096 pnpm install --prod --ignore-scripts --shamefully-hoist

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r . $out/
            runHook postInstall
          '';
        };

        gitnexus = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = npmDeps;

          nativeBuildInputs = [
            nodejs
            pkgs.pnpm
            pkgs.makeWrapper
            pkgs.cacert
            pkgs.python3
            pkgs.gcc
            pkgs.pkg-config
          ];
          dontConfigure = true;

          buildPhase = ''
            runHook preBuild

            export HOME=$TMPDIR/home
            mkdir -p $HOME
            export npm_config_nodedir=${nodejs}
            export npm_config_python=${pkgs.python3}/bin/python3

            cp -r $src/. .
            chmod -R u+w .

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
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.ripgrep ]}

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Graph-powered code intelligence for AI agents";
            homepage = "https://github.com/abhigyanpatwari/GitNexus";
            platforms = platforms.unix;
            mainProgram = "gitnexus";
          };
        };
      in
      {
        packages = {
          default = gitnexus;
          inherit gitnexus;
        };

        apps.default = {
          type = "app";
          program = "${gitnexus}/bin/gitnexus";
        };
      }
    );
}
