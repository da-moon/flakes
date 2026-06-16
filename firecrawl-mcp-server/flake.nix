{
  description = "Firecrawl MCP Server - web scraping and crawling for LLMs";

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
        pname = "firecrawl-mcp";
        version = "3.20.6";

        # NOTE: npm optionalDependencies can be platform-specific,
        # so the fixed-output hash from "yarn install" is not portable across systems.
        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-t+IoA+qjvCus/42+TlzmFLgJ6Ra/smNHXWgqA8md21s=";
        };

        # Fixed-output derivation to fetch npm package with all dependencies
        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/firecrawl-mcp/-/firecrawl-mcp-${version}.tgz";
            hash = "sha256-e3jBORTO2J2bWKoTxPT1LQ8YkgNsrbEUCD29FCUp030=";
          };

          nativeBuildInputs = [ nodejs pkgs.cacert pkgs.yarn ];

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
            yarn install --production --ignore-scripts --non-interactive

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r . $out/
            runHook postInstall
          '';
        };

        # Main package
        firecrawl-mcp = pkgs.stdenv.mkDerivation {
          inherit pname version;

          meta = with pkgs.lib; {
            description = "Firecrawl MCP Server - web scraping and crawling";
            homepage = "https://github.com/mendableai/firecrawl-mcp-server";
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

            makeWrapper ${nodejs}/bin/node $out/bin/firecrawl-mcp \
              --add-flags "$out/lib/${pname}/dist/index.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules"

            runHook postInstall
          '';

        };

      in
      {
        packages = {
          default = firecrawl-mcp;
          inherit firecrawl-mcp;
        };
      }
    );
}
