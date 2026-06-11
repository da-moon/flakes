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
        version = "8.0.0";

        # NOTE: npm optionalDependencies can be platform-specific,
        # so the fixed-output hash from "npm install" is not portable across systems.
        # Use pkgs.lib.fakeHash for untested architectures to get the correct hash on first build.
        outputHashBySystem = {
          "aarch64-linux" = "sha256-+OfpurXKdhc6ejCcmmwpbEsYkwnzZAcOOcnpga0T9NU=";
          "x86_64-linux" = "sha256-mb7DufeI310vhCT/cgj+wdG7cuxctcBhv1BJygrhiNA=";
        };

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
            hash = "sha256-YU1mDinFNKLTr5qtnjQz61xz49XOFo7aqHv0MNBYtVg=";
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

          meta = with pkgs.lib; {
            description = "Remove unused CSS via PurgeCSS CLI";
            homepage = "https://purgecss.com/";
            license = licenses.mit;
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
            makeWrapper ${nodejs}/bin/node $out/bin/purgecss \
              --add-flags "$out/lib/${pname}/bin/purgecss.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules"
            runHook postInstall
          '';

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
