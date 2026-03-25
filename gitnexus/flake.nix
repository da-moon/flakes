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
        version = "1.4.8";

        # Native parser/database dependencies make the fixed-output install
        # arch-specific. Rehash each supported Linux system separately.
        outputHashBySystem = {
          "aarch64-linux" = "sha256-OBUN9VGISDH07EaVVhjQ5PoMN9837N5KvifLOtr7O7I=";
          "x86_64-linux" = "sha256-wJUBKLYAknjoWsnqKbIWAn4iha7TCOF06rqdzgaVbJ0=";
        };

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
            hash = "sha256-ReLWZ7IUnxbxK1murf95Q05BISlOxB5IH3xZKc1tp28=";
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

              if (pkg.optionalDependencies) {
                delete pkg.optionalDependencies["tree-sitter-swift"];
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

            pnpm install --prod --ignore-scripts --shamefully-hoist

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
