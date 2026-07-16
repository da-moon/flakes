{
  description = "Dexter - AI agent for deep financial research";

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
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pname = "dexter";

        # Builder: derive a dexter package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src/hash(es)
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            rev = entry.rev;

            src = pkgs.fetchFromGitHub {
              owner = "virattt";
              repo = "dexter";
              inherit rev;
              hash = entry.hash;
            };

            outputHashBySystem = entry.npmDepsHashes;

            npmDeps = pkgs.stdenv.mkDerivation {
              name = "${pname}-${version}-npm-deps";
              inherit src;

              nativeBuildInputs = with pkgs; [
                nodejs_22
                cacert
              ];

              dontPatchShebangs = true;
              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              outputHash =
                outputHashBySystem.${system} or (throw "Missing outputHashBySystem entry for system: ${system}");

              buildPhase = ''
                runHook preBuild

                export HOME=$TMPDIR
                export XDG_CACHE_HOME=$TMPDIR/.cache
                export npm_config_cache=$TMPDIR/.npm
                export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
                export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true

                cp -r $src/. .
                chmod -R u+w .

                ${pkgs.nodejs_22}/bin/node <<'NODE'
                const fs = require("fs");
                const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));

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

                fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n");
                NODE
                npm install --omit=dev --ignore-scripts \
                  --os ${if pkgs.stdenv.hostPlatform.isDarwin then "darwin" else "linux"} \
                  --cpu ${if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x64"}

                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall
                mkdir -p $out
                shopt -s dotglob
                cp -r ./* $out/
                shopt -u dotglob
                runHook postInstall
              '';
            };
          in
          pkgs.stdenv.mkDerivation {
            inherit pname version;

            meta = with pkgs.lib; {
              description = "Autonomous financial research agent";
              homepage = "https://github.com/virattt/dexter";
              license = licenses.mit;
              mainProgram = "dexter";
              platforms = systems;
            };

            src = npmDeps;

            nativeBuildInputs = with pkgs; [
              gcc
              makeWrapper
              nodejs_22
              pkg-config
              python3
            ];

            dontConfigure = true;

            buildPhase = ''
              runHook preBuild

              export HOME=$TMPDIR
              export npm_config_build_from_source=true
              export npm_config_nodedir=${pkgs.nodejs_22}
              export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
              export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true

              chmod -R u+w .
              patchShebangs node_modules
              npm rebuild better-sqlite3 --build-from-source

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/${pname} $out/bin
              shopt -s dotglob
              cp -r ./* $out/lib/${pname}/
              shopt -u dotglob

              makeWrapper ${pkgs.bun}/bin/bun $out/bin/dexter \
                --add-flags "$out/lib/${pname}/src/index.tsx" \
                --set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD "1" \
                --set PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS "true"

              makeWrapper ${pkgs.bun}/bin/bun $out/bin/dexter-gateway \
                --add-flags "$out/lib/${pname}/src/gateway/index.ts run" \
                --set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD "1" \
                --set PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS "true"

              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `dexter_<sanitized-key>` package per entry in the table.
        versionedPackages = builtins.listToAttrs (
          builtins.map
            (key: {
              name = "${pname}_${sanitize key}";
              value = mk key releases.versions.${key};
            })
            (
              builtins.filter (
                key:
                let
                  hash = releases.versions.${key}.npmDepsHashes.${system} or null;
                in
                hash != null && hash != pkgs.lib.fakeHash
              ) (builtins.attrNames releases.versions)
            )
        );
      in
      {
        packages = versionedPackages // {
          default = latestPkg;
          dexter = latestPkg;
        };

        apps.default = {
          type = "app";
          program = "${latestPkg}/bin/dexter";
        };
      }
    );
}
