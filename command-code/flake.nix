{
  description = "command-code packaged as a Nix flake (npm tarball, offline install)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nodejs = pkgs.nodejs_22;
        pname = "command-code";
        version = "0.38.6";

        # NOTE: npm optionalDependencies can be platform-specific,
        # so the fixed-output hash from "npm install" is not portable across systems.
        # Use pkgs.lib.fakeHash for untested architectures to get the correct hash on first build.
        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-zw8X+q2kooRAzDMK8attYsoeX9hj5Kys+5iy68TcapE=";
        };

        # Fixed-output derivation to fetch npm package with prod dependencies
        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
            hash = "sha256-b1w6JBPRLIai0NAV0RPdSQWvEovaNlloKqmLVKVyms0=";
          };

          nativeBuildInputs = [ nodejs pkgs.cacert ];

          dontPatchShebangs = true;
          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = outputHashBySystem.${system}
            or (throw "Missing outputHashBySystem entry for system: ${system}");

          buildPhase = ''
            runHook preBuild
            export HOME=$TMPDIR
            export npm_config_cache=$TMPDIR/.npm
            tar -xzf $src
            cd package
            ${nodejs}/bin/node <<'NODE'
            const fs = require("fs");
            const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));

            // Dev dependencies include platform-specific @lydell/node-pty-* packages
            // that fail to resolve in the Nix sandbox; they are not needed at runtime.
            delete pkg.devDependencies;
            delete pkg.packageManager;

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
            npm install --production --ignore-scripts --legacy-peer-deps
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r . $out/
            runHook postInstall
          '';
        };

        command-code = pkgs.stdenv.mkDerivation {
          inherit pname version;

          meta = with pkgs.lib; {
            description = "Command Code - coding agent that continuously learns your taste";
            homepage = "https://github.com/CommandCodeAI/command-code";
            license = licenses.unfree;
            mainProgram = "command-code";
            platforms = platforms.unix;
          };

          src = npmDeps;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          dontBuild = true;
          dontConfigure = true;

          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib/${pname}
            mkdir -p $out/bin
            cp -r $src/* $out/lib/${pname}/

            for bin_name in cmd cmdc command-code commandcode; do
              makeWrapper ${nodejs}/bin/node $out/bin/$bin_name \
                --add-flags "$out/lib/${pname}/dist/index.mjs" \
                --set NODE_PATH "$out/lib/${pname}/node_modules" \
                --set NODE_ENV "production"
            done

            runHook postInstall
          '';

        };
      in
      {
        packages = {
          default = command-code;
          inherit command-code;
        };
        apps.default = {
          type = "app";
          program = "${command-code}/bin/command-code";
        };
      });
}
