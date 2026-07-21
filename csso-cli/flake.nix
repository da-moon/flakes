{
  description = "csso-cli packaged as a Nix flake (npm tarball, offline install)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
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
        pname = "csso-cli";

        # Builder: turns one releases.json entry into the csso-cli derivation.
        # PRESERVES the original install/wrapper logic exactly; dependencies are
        # now resolved from a committed package-lock.json via importNpmLock
        # instead of a recursive-hash fixed-output derivation that ran "npm
        # install" (and drifted across systems/time).
        mk =
          key: entry:
          let
            version = entry.version;
            lockDir = ./deps + "/${version}";

            tarball = pkgs.fetchurl {
              url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
              hash = entry.hash;
            };

            # The published npm tarball ships no lockfile. Inject our committed,
            # fully-pinned package.json (devDependencies stripped, since csso-cli
            # just repackages its prebuilt bin/lib and needs no build step) +
            # package-lock.json + .npmrc. This is what makes the dependency set
            # reproducible: importNpmLock fetches every module as its own
            # content-addressed derivation keyed to the lockfile's integrity
            # hashes — there is no drift-prone recursive FOD hash.
            src = pkgs.runCommand "${pname}-${version}-src" { } ''
              mkdir -p $out
              tar -xzf ${tarball} -C $out --strip-components=1
              cp ${lockDir}/package.json $out/package.json
              cp ${lockDir}/package-lock.json $out/package-lock.json
              cp ${lockDir}/.npmrc $out/.npmrc
            '';

            npmDeps = pkgs.importNpmLock { npmRoot = src; };
          in
          pkgs.stdenv.mkDerivation {
            inherit pname version src npmDeps;

            meta = with pkgs.lib; {
              description = "Command-line CSS optimizer (CSSO) wrapper from npm";
              homepage = "https://github.com/css/csso-cli";
              license = licenses.mit;
              platforms = platforms.unix;
            };

            # npmConfigHook runs `npm ci` offline against npmDeps during the
            # configure phase, populating node_modules.
            nativeBuildInputs = [
              nodejs
              nodejs.passthru.python
              pkgs.importNpmLock.npmConfigHook
              pkgs.makeWrapper
            ];

            dontBuild = true;

            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib/${pname}
              mkdir -p $out/bin
              cp -r . $out/lib/${pname}/
              makeWrapper ${nodejs}/bin/node $out/bin/csso \
                --add-flags "$out/lib/${pname}/bin/csso" \
                --set NODE_PATH "$out/lib/${pname}/node_modules"
              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `csso-cli_<sanitized-key>` package per entry in the table.
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
          csso-cli = latestPkg;
        };
        apps.default = {
          type = "app";
          program = "${latestPkg}/bin/csso";
        };
      }
    );
}
