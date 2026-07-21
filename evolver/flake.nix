{
  description = "Evolver - self-evolution engine for AI agents";

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
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        nodejs = pkgs.nodejs_22;
        pname = "evolver";
        npmPackage = "@evomap/evolver";
        npmTarballName = "evolver";
        # Pin pnpm major to match the committed pnpm-lock.yaml (lockfileVersion 9.0).
        pnpm = pkgs.pnpm_10;

        # Version table: consumers select the latest OR any past version.
        # New entries are appended by scripts/update-version.sh via jq — do
        # NOT hand-edit the version data in this file.
        releases = builtins.fromJSON (builtins.readFile ./releases.json);

        # Sanitize a JSON key into a valid attribute-name suffix.
        sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];

        # Builder: derive an evolver package from one releases.json entry.
        #
        # Dependencies are pinned by a committed pnpm-lock.yaml (deps/<version>/)
        # and fetched with pnpm.fetchDeps — a content-addressed derivation keyed
        # to that lockfile. This is reproducible over time: the hash changes only
        # when the committed lockfile changes, never because the npm registry
        # drifted. PRESERVES the original wrapper/install logic exactly.
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
              description = "Self-evolution engine for AI agents";
              homepage = "https://github.com/EvoMap/evolver";
              license = licenses.gpl3Plus;
              mainProgram = "evolver";
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

              makeWrapper ${nodejs}/bin/node $out/bin/.evolver-real \
                --add-flags "$out/lib/${pname}/index.js" \
                --set NODE_PATH "$out/lib/${pname}/node_modules" \
                --set NODE_ENV "production" \
                --prefix PATH : ${
                  lib.makeBinPath [
                    pkgs.git
                    pkgs.bash
                    pkgs.coreutils
                  ]
                }

              cat > $out/bin/evolver <<'EOF'
              #!/usr/bin/env bash
              set -euo pipefail

              export MEMORY_DIR="''${MEMORY_DIR:-$PWD/memory}"

              case "''${1:-}" in
                --version|-V)
                  echo "evolver __VERSION__"
                  exit 0
                  ;;
              esac

              exec "__REAL_BIN__" "$@"
              EOF
              substituteInPlace $out/bin/evolver \
                --replace-fail "__VERSION__" "${version}" \
                --replace-fail "__REAL_BIN__" "$out/bin/.evolver-real"
              chmod +x $out/bin/evolver

              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `evolver_<sanitized-key>` package per entry that has a committed
        # lockfile.
        versionPackages =
          lib.mapAttrs' (key: entry: lib.nameValuePair "evolver_${sanitizeKey key}" (mk key entry))
            (lib.filterAttrs (key: _: builtins.pathExists (./deps + "/${key}/pnpm-lock.yaml")) releases.versions);
      in
      {
        packages = {
          default = latestPkg;
          evolver = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/evolver";
          };
          evolver = {
            type = "app";
            program = "${latestPkg}/bin/evolver";
          };
        };
      }
    );
}
