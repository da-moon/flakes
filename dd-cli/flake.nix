{
  description = "dd-cli - Datadog CLI helpers from NimbusHQ";

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
      releases = builtins.fromJSON (builtins.readFile ./releases.json);
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nodejs = pkgs.nodejs_22;
        pname = "dd-cli";
        patchPackageJsonExactVersions = node: ''
                      ${node}/bin/node <<'NODE'
                      const fs = require("fs");

                      const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));

                      function escapeRegExp(value) {
                        return value
                          .split("")
                          .map((char) => ("\\^$*+?.()|{}[]".includes(char) ? "\\" + char : char))
                          .join("");
                      }

                      function exactFromPackageLock(name) {
                        if (!fs.existsSync("package-lock.json")) return null;
                        const lock = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));
                        const lockedPackage = lock.packages && lock.packages["node_modules/" + name];
                        if (lockedPackage && lockedPackage.version) return lockedPackage.version;
                        const lockedDependency = lock.dependencies && lock.dependencies[name];
                        return lockedDependency && lockedDependency.version ? lockedDependency.version : null;
                      }

                      function exactFromYarnLock(name, spec) {
                        if (!fs.existsSync("yarn.lock")) return null;
                        const selector = name + "@" + spec;
                        const stanzas = fs.readFileSync("yarn.lock", "utf8").split(/\n(?=\S)/);
                        for (const stanza of stanzas) {
                          const header = (stanza.split("\n")[0] || "").replace(/:$/, "");
                          const selectors = header
                            .split(/,\s*/)
                            .map((entry) => entry.trim().replace(/^"|"$/g, ""));
                          if (selectors.includes(selector)) {
                            const match = stanza.match(/\n\s+version "([^"]+)"/);
                            if (match) return match[1];
                          }
                        }
                        return null;
                      }

                      function exactFromPnpmLock(name) {
                        if (!fs.existsSync("pnpm-lock.yaml")) return null;
                        const escapedName = escapeRegExp(name);
                        const match = fs
                          .readFileSync("pnpm-lock.yaml", "utf8")
                          .match(new RegExp("\\n\\s{4}" + escapedName + ":\\n(?:\\s{6}[^\\n]+\\n)*?\\s{6}version:\\s*([^\\s()]+)"));
                        return match ? match[1].replace(/^['"]|['"]$/g, "") : null;
                      }

                      function exactSpec(name, spec) {
                        if (typeof spec !== "string") return spec;
                        if (/^(file:|link:|workspace:|git\+|https?:)/.test(spec)) return spec;
                        const locked = exactFromPackageLock(name) || exactFromYarnLock(name, spec) || exactFromPnpmLock(name);
                        if (locked) return locked;
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
        '';

        # Builder: turns one releases.json entry into the dd-cli derivation.
        # PRESERVES the original build logic exactly; only version/src/hash(es)
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            rev = entry.rev;

            src = pkgs.fetchFromGitHub {
              owner = "nimbushq";
              repo = "dd-cli";
              inherit rev;
              hash = entry.hash;
            };

            npmDeps = pkgs.stdenv.mkDerivation {
              name = "${pname}-${version}-npm-deps";
              inherit src;

              nativeBuildInputs = [
                nodejs
                pkgs.cacert
                pkgs.yarn
              ];

              dontPatchShebangs = true;
              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              outputHash =
                entry.npmDepsHashes.${system} or (throw "Missing npmDepsHashes entry for system: ${system}");

              buildPhase = ''
                runHook preBuild

                export HOME=$TMPDIR
                export XDG_CACHE_HOME=$TMPDIR/.cache
                export YARN_CACHE_FOLDER=$TMPDIR/.yarn-cache

                cp -r $src/. .
                chmod -R u+w .

                # Upstream's yarn.lock omits the direct typescript devDependency.
                ${patchPackageJsonExactVersions nodejs}
                # Yarn Classic cannot target a foreign platform. Installing all
                # optional platform packages makes this FOD byte-identical on
                # Linux and Darwin; runtime packages select their native binary.
                yarn install --ignore-scripts --ignore-platform --non-interactive

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
              description = "CLI tool for working with Datadog logs";
              homepage = "https://github.com/nimbushq/dd-cli";
              license = licenses.asl20;
              mainProgram = "dd-cli";
              platforms = platforms.unix;
            };

            src = npmDeps;

            nativeBuildInputs = [
              nodejs
              pkgs.makeWrapper
            ];

            dontConfigure = true;

            buildPhase = ''
              runHook preBuild

              chmod -R u+w .
              ${nodejs}/bin/node ./node_modules/typescript/bin/tsc

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/${pname} $out/bin
              cp -r package.json lib node_modules $out/lib/${pname}/

              makeWrapper ${nodejs}/bin/node $out/bin/dd-cli \
                --add-flags "$out/lib/${pname}/lib/bin/dd-cli.js" \
                --set NODE_PATH "$out/lib/${pname}/node_modules" \
                --set NODE_ENV "production"

              runHook postInstall
            '';
          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

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
          dd-cli = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/dd-cli";
          };
          dd-cli = {
            type = "app";
            program = "${latestPkg}/bin/dd-cli";
          };
        };
      }
    );
}
