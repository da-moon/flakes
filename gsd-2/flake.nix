{
  description = "GSD Pi CLI packaged from the @opengsd/gsd-pi npm artifact";

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
        lib = pkgs.lib;
        pname = "gsd-2";
        npmPackage = "@opengsd/gsd-pi";
        npmTarballName = "gsd-pi";
        nodejs = pkgs.nodejs_22;
        # Pin pnpm major to match the committed pnpm-lock.yaml (lockfileVersion 9.0).
        pnpm = pkgs.pnpm_10;

        # Builder: derive a gsd-2 package from one releases.json entry.
        #
        # Dependencies are pinned by a committed pnpm-lock.yaml (deps/<version>/)
        # and fetched with pnpm.fetchDeps — a content-addressed derivation keyed
        # to that lockfile. This is reproducible over time: the hash changes only
        # when the committed lockfile changes, never because the npm registry
        # drifted. fetchDeps downloads every platform's tarballs (--force), so
        # `pnpmDepsHash` is identical on all systems.
        mk =
          key: entry:
          let
            version = entry.version;
            lockfile = ./deps + "/${version}/pnpm-lock.yaml";

            tarball = pkgs.fetchurl {
              url = "https://registry.npmjs.org/${npmPackage}/-/${npmTarballName}-${version}.tgz";
              hash = entry.hash;
            };

            # The published npm tarball ships no lockfile, so inject our
            # committed, fully-pinned pnpm-lock.yaml into the source tree.
            src = pkgs.runCommand "${pname}-${version}-src" { } ''
              mkdir -p $out
              tar -xzf ${tarball} -C $out --strip-components=1
              cp ${lockfile} $out/pnpm-lock.yaml
            '';

            pnpmDeps = pnpm.fetchDeps {
              inherit pname version src;
              fetcherVersion = 2;
              hash = entry.pnpmDepsHash;
            };
          in
          pkgs.stdenv.mkDerivation {
            inherit
              pname
              version
              src
              pnpmDeps
              ;

            meta = with lib; {
              description = "GSD coding agent CLI";
              homepage = "https://github.com/open-gsd/gsd-pi";
              license = licenses.mit;
              mainProgram = "gsd";
              platforms = systems;
              maintainers = [ ];
            };

            nativeBuildInputs = [
              nodejs
              pnpm.configHook
              pkgs.makeWrapper
            ];

            # structuredAttrs is required so pnpmInstallFlags reaches the
            # config hook as a bash array rather than one space-joined string.
            __structuredAttrs = true;

            # pnpmConfigHook runs `pnpm install --offline --frozen-lockfile` with
            # these flags: production-only tree, flattened so NODE_PATH resolves.
            pnpmInstallFlags = [
              "--prod"
              "--shamefully-hoist"
            ];

            dontBuild = true;

            installPhase = ''
                            runHook preInstall

                            mkdir -p $out/lib/${pname}
                            mkdir -p $out/bin
                            cp -r . $out/lib/${pname}/
                            chmod -R u+w $out/lib/${pname}/node_modules

                            export GSD_INSTALL_ROOT="$out/lib/${pname}"
                            ${nodejs}/bin/node <<'NODE'
                            const fs = require("fs");
                            const path = require("path");

                            const root = process.env.GSD_INSTALL_ROOT;
                            const packagesDir = path.join(root, "packages");
                            const nodeModulesDir = path.join(root, "node_modules");

                            if (fs.existsSync(packagesDir)) {
                              for (const entry of fs.readdirSync(packagesDir, { withFileTypes: true })) {
                                if (!entry.isDirectory()) continue;

                                const packageDir = path.join(packagesDir, entry.name);
                                const packageJsonPath = path.join(packageDir, "package.json");
                                if (!fs.existsSync(packageJsonPath)) continue;

                                const pkg = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));
                                if (typeof pkg.name !== "string" || !pkg.name.startsWith("@")) continue;

                                const [scope, name] = pkg.name.split("/");
                                if (!scope || !name) continue;

                                const scopeDir = path.join(nodeModulesDir, scope);
                                const linkPath = path.join(scopeDir, name);
                                fs.mkdirSync(scopeDir, { recursive: true });
                                if (!fs.existsSync(linkPath)) {
                                  fs.symlinkSync(packageDir, linkPath, "dir");
                                }
                              }
                            }
              NODE

                            makeWrapper ${nodejs}/bin/node $out/bin/gsd \
                              --add-flags "$out/lib/${pname}/dist/loader.js" \
                              --set NODE_PATH "$out/lib/${pname}/node_modules" \
                              --set NODE_ENV "production" \
                              --set npm_config_ignore_scripts "true" \
                              --set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD "1" \
                              --set-default GSD_HOME "\$HOME/.gsd" \
                              --prefix PATH : ${
                                lib.makeBinPath [
                                  pkgs.bash
                                  pkgs.coreutils
                                  pkgs.findutils
                                  pkgs.gawk
                                  pkgs.git
                                  pkgs.gnugrep
                                  pkgs.gnused
                                  pkgs.ripgrep
                                ]
                              }

                            ln -s $out/bin/gsd $out/bin/gsd-cli

                            runHook postInstall
            '';
          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `gsd-2_<sanitized-key>` package per entry that has a committed
        # lockfile + resolved pnpmDepsHash.
        versionPackages =
          lib.mapAttrs' (key: entry: lib.nameValuePair "gsd-2_${sanitizeKey key}" (mk key entry))
            (lib.filterAttrs (_: entry: entry ? pnpmDepsHash) releases.versions);
      in
      {
        packages = {
          default = latestPkg;
          "gsd-2" = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/gsd";
          };
          gsd = {
            type = "app";
            program = "${latestPkg}/bin/gsd";
          };
          "gsd-cli" = {
            type = "app";
            program = "${latestPkg}/bin/gsd-cli";
          };
        };
      }
    );
}
