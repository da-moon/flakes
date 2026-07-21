{
  description = "draw.io MCP server packaged from the @drawio/mcp npm artifact";

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
        pname = "drawio-mcp";
        npmPackage = "@drawio/mcp";
        tarballName = "mcp";
        nodejs = pkgs.nodejs_22;
        # Pin pnpm major to match the committed pnpm-lock.yaml (lockfileVersion 9.0).
        pnpm = pkgs.pnpm_10;

        # Builder: derive a drawio-mcp package from one releases.json entry.
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
              url = "https://registry.npmjs.org/${npmPackage}/-/${tarballName}-${version}.tgz";
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
              description = "Official draw.io MCP server for opening and editing diagrams";
              homepage = "https://github.com/jgraph/drawio-mcp";
              license = licenses.asl20;
              mainProgram = "drawio-mcp";
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
            # Platform-specific optional deps auto-select under --prod.
            pnpmInstallFlags = [
              "--prod"
              "--shamefully-hoist"
              "--ignore-scripts"
            ];

            dontBuild = true;

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/${pname}
              mkdir -p $out/bin
              cp -r . $out/lib/${pname}/

              makeWrapper ${nodejs}/bin/node $out/bin/drawio-mcp \
                --add-flags "$out/lib/${pname}/src/index.js" \
                --set NODE_PATH "$out/lib/${pname}/node_modules" \
                --set NODE_ENV "production"

              runHook postInstall
            '';
          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `drawio-mcp_<sanitized-key>` package per entry that has a committed
        # lockfile.
        versionPackages =
          lib.mapAttrs' (key: entry: lib.nameValuePair "${pname}_${sanitizeKey key}" (mk key entry))
            (
              lib.filterAttrs (
                key: _: builtins.pathExists (./deps + "/${key}/pnpm-lock.yaml")
              ) releases.versions
            );
      in
      {
        packages = versionPackages // {
          default = latestPkg;
          "drawio-mcp" = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/drawio-mcp";
          };
          "drawio-mcp" = {
            type = "app";
            program = "${latestPkg}/bin/drawio-mcp";
          };
        };
      }
    );
}
