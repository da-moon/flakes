{
  description = "Context Mode - cross-platform MCP plugin for context-efficient coding";

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
        lib = nixpkgs.lib;

        # Use Node 22 so runtime falls back to built-in node:sqlite
        # instead of needing the optional better-sqlite3 native addon.
        pname = "context-mode";
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ pname ];
        };
        nodejs = pkgs.nodejs_22;
        # Pin pnpm major to match the committed pnpm-lock.yaml (lockfileVersion 9.0).
        pnpm = pkgs.pnpm_10;

        # Builder: derive a context-mode package from one releases.json entry.
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
              url = "https://registry.npmjs.org/context-mode/-/context-mode-${version}.tgz";
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
              description = "MCP plugin for context-efficient AI coding workflows";
              homepage = "https://github.com/mksglu/context-mode";
              license = licenses.elastic20;
              mainProgram = "context-mode";
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
            # The published tarball already ships prebuilt bundles
            # (cli.bundle.mjs / server.bundle.mjs / build/), so no build step
            # (tsc/esbuild) is needed here — devDependencies are not installed.
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

              makeWrapper ${nodejs}/bin/node $out/bin/.context-mode-real \
                --add-flags "$out/lib/${pname}/cli.bundle.mjs" \
                --set NODE_PATH "$out/lib/${pname}/node_modules" \
                --set NODE_ENV "production" \
                --prefix PATH : ${
                  lib.makeBinPath [
                    pkgs.git
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.findutils
                    pkgs.ripgrep
                  ]
                }

              cat > $out/bin/context-mode <<'EOF'
              #!/usr/bin/env bash
              set -euo pipefail

              case "''${1:-}" in
                --version|-V)
                  echo "context-mode __VERSION__"
                  exit 0
                  ;;
                --help|-h)
                  cat <<'USAGE'
              context-mode <command>

              Common commands:
                context-mode setup
                context-mode doctor
                context-mode --version

              With no arguments, the upstream CLI starts the MCP server on stdio.
              USAGE
                  exit 0
                  ;;
              esac

              exec "__REAL_BIN__" "$@"
              EOF
              substituteInPlace $out/bin/context-mode \
                --replace-fail "__VERSION__" "${version}" \
                --replace-fail "__REAL_BIN__" "$out/bin/.context-mode-real"
              chmod +x $out/bin/context-mode

              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `context-mode_<sanitized-key>` package per entry that has a
        # committed pnpm-lock.yaml under deps/<key>/.
        versionPackages = builtins.listToAttrs (
          builtins.map
            (key: {
              name = "context-mode_${sanitize key}";
              value = mk key releases.versions.${key};
            })
            (
              builtins.filter (
                key: builtins.pathExists (./deps + "/${key}/pnpm-lock.yaml")
              ) (builtins.attrNames releases.versions)
            )
        );
      in
      {
        packages = versionPackages // {
          default = latestPkg;
          "context-mode" = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/context-mode";
          };
          "context-mode" = {
            type = "app";
            program = "${latestPkg}/bin/context-mode";
          };
        };
      }
    );
}
