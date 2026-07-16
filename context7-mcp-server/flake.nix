{
  description = "Context7 MCP Server - brings up-to-date documentation into context";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
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
        pname = "context7-mcp";

        # Builder: turns one releases.json entry into the context7-mcp derivation.
        # PRESERVES the original build logic exactly; only version/src/hash(es)
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;

            # NOTE: npm optionalDependencies can be platform-specific (for example, esbuild),
            # so the fixed-output hash from "npm install" is not portable across systems.
            outputHashBySystem = entry.outputHashBySystem;

            # Fixed-output derivation to fetch npm package with all dependencies
            # This has network access during build
            npmDeps = pkgs.stdenv.mkDerivation {
              name = "${pname}-${version}-npm-deps";

              src = pkgs.fetchurl {
                url = "https://registry.npmjs.org/@upstash/context7-mcp/-/context7-mcp-${version}.tgz";
                hash = entry.hash;
              };

              nativeBuildInputs = [
                nodejs
                pkgs.cacert
              ];
              dontPatchShebangs = true;

              # FOD settings - allows network access, output is content-addressed
              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              # Get this hash by first building with pkgs.lib.fakeHash
              outputHash =
                outputHashBySystem.${system} or (throw "Missing outputHashBySystem entry for system: ${system}");

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
                npm install --production --ignore-scripts \
                  --os ${if pkgs.stdenv.hostPlatform.isDarwin then "darwin" else "linux"} \
                  --cpu ${if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x64"}

                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall
                mkdir -p $out
                cp -r . $out/
                runHook postInstall
              '';
            };
          in
          # Main package - just sets up the wrapper
          pkgs.stdenv.mkDerivation {
            inherit pname version;

            meta = with pkgs.lib; {
              description = "Context7 MCP Server - up-to-date documentation for LLMs";
              homepage = "https://github.com/upstash/context7";
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

              # Create wrapper - shebangs handled automatically by Nix
              makeWrapper ${nodejs}/bin/node $out/bin/context7-mcp \
                --add-flags "$out/lib/${pname}/dist/index.js" \
                --set NODE_PATH "$out/lib/${pname}/node_modules"

              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `context7-mcp-server_<sanitized-key>` package per entry in the table.
        versionedPackages = builtins.listToAttrs (
          builtins.map
            (key: {
              name = "context7-mcp-server_${sanitize key}";
              value = mk key releases.versions.${key};
            })
            (
              builtins.filter (
                key:
                let
                  hash = releases.versions.${key}.outputHashBySystem.${system} or null;
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
          context7-mcp = latestPkg;
          context7-mcp-server = latestPkg;
        };
      }
    );
}
