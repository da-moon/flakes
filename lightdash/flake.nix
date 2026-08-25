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
        isDarwin = lib.hasSuffix "-darwin" system;

        # darwin: upstream publishes a genuine self-contained native binary
        # per GitHub release (lightdash-cli-X.Y.Z-macos-{arm64,x64}.tar.gz,
        # a single Mach-O executable, no node/npm/lockfile involved at all).
        # Prefer that over the npm/importNpmLock path used for linux: it's
        # simpler, has no scoped-tarball-URL footgun, and needs no vendored
        # lockfile. Only macOS assets exist upstream (no linux binaries), so
        # linux keeps the npm-based build below.
        darwinArchBySystem = {
          aarch64-darwin = "arm64";
          x86_64-darwin = "x64";
        };

        mkDarwin =
          key: entry:
          let
            version = entry.version;
            arch = darwinArchBySystem.${system};
            hash = entry.darwinHashes.${system};

            tarball = pkgs.fetchurl {
              url = "https://github.com/lightdash/lightdash/releases/download/${version}/lightdash-cli-${version}-macos-${arch}.tar.gz";
              inherit hash;
            };
          in
          pkgs.stdenv.mkDerivation {
            inherit pname version;
            src = tarball;

            meta = with lib; {
              description = "Lightdash CLI - BI tool CLI for dbt projects";
              homepage = "https://github.com/lightdash/lightdash";
              license = licenses.mit;
              mainProgram = "lightdash";
              platforms = [ system ];
              maintainers = [ ];
            };

            sourceRoot = ".";
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;

            installPhase = ''
              runHook preInstall
              install -D -m755 lightdash-macos-${arch} $out/bin/lightdash
              runHook postInstall
            '';
          };

        # linux: PRESERVES the offline npm install logic; only
        # version/tarball-hash now come from `entry`.
        mkLinux =
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

        mk = if isDarwin then mkDarwin else mkLinux;

        hasBuildData =
          key: entry:
          if isDarwin then
            (entry ? darwinHashes) && (entry.darwinHashes ? ${system})
          else
            # Only expose linux versions that have a committed lockfile.
            builtins.pathExists (./deps + "/${key}/package-lock.json");

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `lightdash_<sanitized-key>` package per entry in the table.
        versionedPackages = builtins.listToAttrs (
          builtins.map
            (key: {
              name = "${pname}_${sanitizeKey key}";
              value = mk key releases.versions.${key};
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
