{
  description = "Context7 MCP Server - brings up-to-date documentation into context";

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
        pname = "context7-mcp";
        version = "3.0.0";

        # NOTE: npm optionalDependencies can be platform-specific (for example, esbuild),
        # so the fixed-output hash from "npm install" is not portable across systems.
        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-ewfqwfA0Giiy2cTZg7dNo+/CqcLBR19BySdTIqIYKyQ=";
        };

        # Fixed-output derivation to fetch npm package with all dependencies
        # This has network access during build
        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/@upstash/context7-mcp/-/context7-mcp-${version}.tgz";
            hash = "sha256-lX2PeONNWTK5EA1WgHGMCs7N4Qpg9N7jUF8hgxir02k=";
          };

          nativeBuildInputs = [ nodejs pkgs.cacert ];
          dontPatchShebangs = true;

          # FOD settings - allows network access, output is content-addressed
          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          # Get this hash by first building with pkgs.lib.fakeHash
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
            const childProcess = require("child_process");
            const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));

            function exactFromNpm(name, spec) {
              if (!/^[~^]/.test(spec)) return null;
              const raw = childProcess.execFileSync(
                "npm",
                ["view", name + "@" + spec, "version", "--json"],
                { encoding: "utf8" }
              ).trim();
              const parsed = JSON.parse(raw);
              if (Array.isArray(parsed)) return parsed[parsed.length - 1];
              return parsed;
            }

            function exactSpec(name, spec) {
              if (typeof spec !== "string") return spec;
              if (/^(file:|link:|workspace:|git\+|https?:)/.test(spec)) return spec;
              const resolved = exactFromNpm(name, spec);
              if (resolved) return resolved;
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
                const next = exactSpec(name, spec);
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

        # Main package - just sets up the wrapper
        context7-mcp = pkgs.stdenv.mkDerivation {
          inherit pname version;

          src = npmDeps;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          dontBuild = true;
          dontConfigure = true;

          installPhase = ''
            runHook preInstall

            mkdir -p $out/lib/${pname}
            mkdir -p $out/bin

            cp -r $src/* $out/lib/${pname}/

            # Create wrapper - shebangs handled automatically by Nix
            makeWrapper ${nodejs}/bin/node $out/bin/context7-mcp \
              --add-flags "$out/lib/${pname}/dist/index.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules"

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Context7 MCP Server - up-to-date documentation for LLMs";
            homepage = "https://github.com/upstash/context7";
            platforms = platforms.unix;
          };
        };

      in
      {
        packages = {
          default = context7-mcp;
          inherit context7-mcp;
        };
      }
    );
}
