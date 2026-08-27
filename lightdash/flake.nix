{
  description = "Lightdash CLI packaged from npm release archives";

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
        nodejs = pkgs.nodejs_24;
        pname = "lightdash";

        mkPkg =
          key: entry:
          let
            version = entry.version;
            lockDir = ./deps + "/${version}";

            tarball = pkgs.fetchurl {
              # npm strips the scope from the tarball filename for scoped
              # packages: @lightdash/cli/-/cli-X.Y.Z.tgz, not
              # @lightdash/cli-X.Y.Z.tgz. Verified against the registry's own
              # dist.tarball field for this version.
              url = "https://registry.npmjs.org/@lightdash/cli/-/cli-${version}.tgz";
              hash = entry.tarballHash;
            };

            # The published npm tarball ships no lockfile. Inject our committed,
            # fully-pinned package.json (devDependencies stripped) +
            # package-lock.json + .npmrc so importNpmLock can install every
            # dependency offline and reproducibly.
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

            meta = with lib; {
              description = "Lightdash CLI - BI tool CLI for dbt projects";
              homepage = "https://github.com/lightdash/lightdash";
              license = licenses.mit;
              mainProgram = "lightdash";
              platforms = [ system ];
              maintainers = [ ];
            };

            nativeBuildInputs = [
              nodejs
              pkgs.importNpmLock.npmConfigHook
              pkgs.makeWrapper
            ];

            # The published tarball already contains the compiled dist/ output.
            dontBuild = true;

            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib/${pname}
              mkdir -p $out/bin
              cp -r . $out/lib/${pname}/

              makeWrapper ${nodejs}/bin/node $out/bin/lightdash \
                --add-flags "$out/lib/${pname}/dist/index.js" \
                --set NODE_PATH "$out/lib/${pname}/node_modules" \
                --set NODE_ENV "production"

              runHook postInstall
            '';
          };

        # Only expose versions that have a committed lockfile.
        hasBuildData =
          key: entry:
          builtins.pathExists (./deps + "/${key}/package-lock.json");

        latestPkg = mkPkg releases.latest releases.versions.${releases.latest};

        # One `lightdash_<sanitized-key>` package per entry in the table.
        versionedPackages = builtins.listToAttrs (
          builtins.map
            (key: {
              name = "${pname}_${sanitizeKey key}";
              value = mkPkg key releases.versions.${key};
            })
            (builtins.filter (key: hasBuildData key releases.versions.${key}) (builtins.attrNames releases.versions))
        );
      in
      {
        packages = versionedPackages // {
          default = latestPkg;
          lightdash = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/lightdash";
          };
          lightdash = {
            type = "app";
            program = "${latestPkg}/bin/lightdash";
          };
        };
      }
    );
}
