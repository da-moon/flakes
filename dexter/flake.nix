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

        nodejs = pkgs.nodejs_22;

        # Builder: derive a dexter package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src/hash
        # now come from `entry` instead of let-bindings. Dependencies are
        # resolved from the committed lockfile under ./deps/<key>/ via
        # importNpmLock instead of a recursive-hash fixed-output derivation.
        mk =
          key: entry:
          let
            version = entry.version;
            rev = entry.rev;
            lockDir = ./deps + "/${key}";

            githubSrc = pkgs.fetchFromGitHub {
              owner = "virattt";
              repo = "dexter";
              inherit rev;
              hash = entry.hash;
            };

            # The upstream repo's own package.json/package-lock.json still
            # carry devDependencies. Inject our committed, deps-only
            # package.json + package-lock.json + .npmrc so importNpmLock
            # resolves every module as its own content-addressed derivation
            # keyed to the lockfile's integrity hashes — there is no
            # drift-prone recursive FOD hash.
            src = pkgs.runCommand "${pname}-${version}-src" { } ''
              mkdir -p $out
              cp -r ${githubSrc}/. $out/
              chmod -R u+w $out
              cp ${lockDir}/package.json $out/package.json
              cp ${lockDir}/package-lock.json $out/package-lock.json
              cp ${lockDir}/.npmrc $out/.npmrc
            '';

            # @whiskeysockets/baileys' `libsignal` dependency is a git commit,
            # normally recorded by npm as an unauthenticated-inaccessible
            # `git+ssh://git@github.com/...` URL. We fetch that exact commit
            # ourselves via fetchFromGitHub (a real content-addressed,
            # hash-verified derivation) and hand it to importNpmLock as a
            # source override for the top-level `libsignal` module.
            #
            # The committed lockfile also patches baileys' OWN recorded
            # dependency on `libsignal` from the raw git spec down to a plain
            # semver ("6.0.0", libsignal's version) — `npm install` (used by
            # npmConfigHook, not `npm ci`) treats any git-looking dependency
            # spec as needing live re-resolution against the network
            # (ls-remote / a codeload.github.com tarball fetch) to verify it,
            # *regardless* of what the tree already has resolved there. A
            # plain version spec instead lets it satisfy the edge by ordinary
            # semver matching against the already-installed node, with no
            # network access needed.
            libsignalSrc = pkgs.fetchFromGitHub {
              owner = "whiskeysockets";
              repo = "libsignal-node";
              rev = "bcea72df9ec34d9d9140ab30619cf479c7c144c7";
              hash = "sha256-xb6ep3shVNEu+P4O4EeyRVYVaYtxdPAuMCuhpRKaJ4U=";
            };

            npmDeps = pkgs.importNpmLock {
              npmRoot = src;
              packageSourceOverrides."node_modules/libsignal" = libsignalSrc;
            };
          in
          pkgs.stdenv.mkDerivation {
            inherit pname version src npmDeps;

            meta = with pkgs.lib; {
              description = "Autonomous financial research agent";
              homepage = "https://github.com/virattt/dexter";
              license = licenses.mit;
              mainProgram = "dexter";
              platforms = systems;
            };

            # npmConfigHook runs `npm install --ignore-scripts` offline
            # against npmDeps during the configure phase, populating
            # node_modules.
            nativeBuildInputs = with pkgs; [
              gcc
              git
              makeWrapper
              nodejs
              nodejs.passthru.python
              pkgs.importNpmLock.npmConfigHook
              pkg-config
              python3
            ];

            buildPhase = ''
              runHook preBuild

              export HOME=$TMPDIR
              export npm_config_build_from_source=true
              export npm_config_nodedir=${nodejs}
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
                # Only expose versions that have a committed lockfile.
                key: builtins.pathExists (./deps + "/${key}/package-lock.json")
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
