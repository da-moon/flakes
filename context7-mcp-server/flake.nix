{
  description = "Context7 MCP Server - brings up-to-date documentation into context";

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
        pname = "context7-mcp";

        # Builder: turns one releases.json entry into the context7-mcp derivation.
        # PRESERVES the original build logic exactly; only version/tarball-hash
        # now comes from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            lockDir = ./deps + "/${version}";

            tarball = pkgs.fetchurl {
              url = "https://registry.npmjs.org/@upstash/context7-mcp/-/context7-mcp-${version}.tgz";
              hash = entry.hash;
            };

            # The published npm tarball ships no lockfile. Inject our committed,
            # fully-pinned package.json (devDependencies stripped, since dist/ is
            # prebuilt and shipped in the tarball) + package-lock.json + .npmrc.
            # This is what makes the dependency set reproducible: importNpmLock
            # fetches every module as its own content-addressed derivation keyed
            # to the lockfile's integrity hashes — there is no drift-prone
            # recursive FOD hash.
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
              description = "Context7 MCP Server - up-to-date documentation for LLMs";
              homepage = "https://github.com/upstash/context7";
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

              # Create wrapper - shebangs handled automatically by Nix
              makeWrapper ${nodejs}/bin/node $out/bin/context7-mcp \
                --add-flags "$out/lib/${pname}/dist/index.js" \
                --set NODE_PATH "$out/lib/${pname}/node_modules"

              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `context7-mcp-server_<sanitized-key>` package per entry in the table.
        versionedPackages = builtins.listToAttrs (
          builtins.map
            (key: {
              name = "context7-mcp-server_${sanitize key}";
              value = mk key releases.versions.${key};
            })
            (
              builtins.filter (
                key:
                # Only expose versions that have a committed lockfile.
                builtins.pathExists (./deps + "/${key}/package-lock.json")
              ) (builtins.attrNames releases.versions)
            )
        );
      in
      {
        packages = versionedPackages // {
          default = latestPkg;
          context7-mcp = latestPkg;
          context7-mcp-server = latestPkg;
        };
      }
    );
}
