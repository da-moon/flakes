{
  description = "Firecrawl CLI - scrape, crawl, and extract data from websites from your terminal";

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
        nodejs = pkgs.nodejs_22;
        pname = "firecrawl-cli";
        version = "1.19.23";

        # NOTE: npm optionalDependencies and native dependencies can be platform-specific,
        # so the fixed-output hash from "npm install" is not always portable.
        # Start from fakeHash and rehash per-system after build.
        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-gKpHNKYYo7JF/V0OIb4aPbnGpatJi5ASDTqwboIJb4w=";
        };

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
            hash = "sha256-ZZL+puOl9CLM13Ncu0lrs6zsfCmcgK9YvZfH/UXqJqo=";
          };

          nativeBuildInputs = [ nodejs pkgs.pnpm pkgs.cacert ];

          # Don't patch shebangs in FOD - it would add store references
          # Shebangs will be patched in the main derivation
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

            # Upstream may pin a pnpm CLI version that cannot self-bootstrap in
            # the Nix sandbox. Keep using pnpm, but ignore the packageManager pin.
            ${nodejs}/bin/node -e '
              const fs = require("fs");
              const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
              delete pkg.packageManager;
              delete pkg.devDependencies;
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
              fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2));
            '

            # Use pnpm instead of npm because npm crashes with "double free or corruption"
            # on aarch64-linux (Android/nix-on-droid)
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

        firecrawl-cli = pkgs.stdenv.mkDerivation {
          inherit pname version;

          meta = with pkgs.lib; {
            description = "Firecrawl CLI - scrape, crawl, and extract data from any website.";
            homepage = "https://docs.firecrawl.dev/cli";
            platforms = platforms.unix;
            mainProgram = "firecrawl";
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

            makeWrapper ${nodejs}/bin/node $out/bin/firecrawl \
              --add-flags "$out/lib/${pname}/dist/index.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules"

            runHook postInstall
          '';

        };
      in
      {
        packages = {
          default = firecrawl-cli;
          inherit firecrawl-cli;
        };

        apps.default = {
          type = "app";
          program = "${firecrawl-cli}/bin/firecrawl";
        };
      }
    );
}
