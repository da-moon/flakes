{
  description = "markdown-magic CLI packaged from the markdown-magic npm artifact";

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
        pname = "markdown-magic";

        # Builder: turns one releases.json entry into the markdown-magic
        # derivation. PRESERVES the original build logic exactly; only
        # version/src-url/hash(es) now come from `entry`.
        mk =
          key: entry:
          let
            version = entry.version;

            npmDeps = pkgs.stdenv.mkDerivation {
              name = "${pname}-${version}-npm-deps";

              src = pkgs.fetchurl {
                url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
                hash = entry.hash;
              };

              nativeBuildInputs = [
                nodejs
                pkgs.cacert
              ];

              dontPatchShebangs = true;
              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              outputHash = entry.npmDepsHash;

              buildPhase = ''
                runHook preBuild

                export HOME=$TMPDIR
                export npm_config_cache=$TMPDIR/npm-cache

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
                npm install --omit=dev --ignore-scripts

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
              description = "Automatically update markdown files with content from external sources";
              homepage = "https://github.com/DavidWells/markdown-magic";
              license = licenses.mit;
              mainProgram = "md-magic";
              platforms = platforms.unix;
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

              makeWrapper ${nodejs}/bin/node $out/bin/md-magic \
                --add-flags "$out/lib/${pname}/cli.js" \
                --set NODE_PATH "$out/lib/${pname}/node_modules" \
                --set NODE_ENV "production"

              ln -s md-magic $out/bin/markdown
              ln -s md-magic $out/bin/mdm

              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `markdown-magic_<sanitized-key>` package per entry in the table.
        versionedPackages = builtins.listToAttrs (
          builtins.map (key: {
            name = "${pname}_${sanitize key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
        );
      in
      {
        packages = versionedPackages // {
          default = latestPkg;
          "markdown-magic" = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/md-magic";
          };
          "md-magic" = {
            type = "app";
            program = "${latestPkg}/bin/md-magic";
          };
          markdown = {
            type = "app";
            program = "${latestPkg}/bin/markdown";
          };
          mdm = {
            type = "app";
            program = "${latestPkg}/bin/mdm";
          };
        };
      }
    );
}
