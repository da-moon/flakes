{
  description = "draw.io MCP server packaged from the @drawio/mcp npm artifact";

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
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nodejs = pkgs.nodejs_22;
        pname = "drawio-mcp";
        npmPackage = "@drawio/mcp";
        tarballName = "mcp";

        # Builder: derive a drawio-mcp package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/tarball
        # hash/per-system outputHash now come from `entry`.
        mk =
          key: entry:
          let
            version = entry.version;
            tarballHash = entry.hash;

            npmDeps = pkgs.stdenv.mkDerivation {
              name = "${pname}-${version}-npm-deps";

              src = pkgs.fetchurl {
                url = "https://registry.npmjs.org/${npmPackage}/-/${tarballName}-${version}.tgz";
                hash = tarballHash;
              };

              nativeBuildInputs = [
                nodejs
                pkgs.pnpm
                pkgs.cacert
              ];

              dontPatchShebangs = true;

              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              outputHash =
                entry.outputHashes.${system} or (throw "Missing outputHashes entry for system: ${system}");

              buildPhase = ''
                runHook preBuild

                export HOME=$TMPDIR
                export npm_config_cache=$TMPDIR/npm-cache

                tar -xzf $src
                cd package

                ${nodejs}/bin/node -e '
                  const fs = require("fs");
                  const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
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
                  fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2));
                '

                pnpm install --prod --ignore-scripts --shamefully-hoist \
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
          pkgs.stdenv.mkDerivation {
            inherit pname version;

            meta = with pkgs.lib; {
              description = "Official draw.io MCP server for opening and editing diagrams";
              homepage = "https://github.com/jgraph/drawio-mcp";
              license = licenses.asl20;
              mainProgram = "drawio-mcp";
              platforms = systems;
              maintainers = [ ];
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

              makeWrapper ${nodejs}/bin/node $out/bin/drawio-mcp \
                --add-flags "$out/lib/${pname}/src/index.js" \
                --set NODE_PATH "$out/lib/${pname}/node_modules" \
                --set NODE_ENV "production"

              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `drawio-mcp_<sanitized-key>` package per entry in the table.
        versionPackages = builtins.listToAttrs (
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
        packages = versionPackages // {
          default = latestPkg;
          "drawio-mcp" = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/drawio-mcp";
          };
          "drawio-mcp" = {
            type = "app";
            program = "${latestPkg}/bin/drawio-mcp";
          };
        };
      }
    );
}
