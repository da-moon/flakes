{
  description = "Firecrawl MCP Server - web scraping and crawling for LLMs";

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
        pname = "firecrawl-mcp";

        # Builder: turns one releases.json entry into the firecrawl-mcp
        # derivation. Dependencies are pinned by a committed yarn.lock
        # (deps/<key>/) and fetched with fetchYarnDeps into an offline
        # mirror; yarnConfigHook then runs `yarn install --offline
        # --frozen-lockfile`. This is reproducible over time: the
        # offline-mirror hash changes only when the committed lockfile
        # changes, never because the npm registry drifted.
        mk =
          key: entry:
          let
            version = entry.version;
            yarnLock = ./deps + "/${key}/yarn.lock";

            tarball = pkgs.fetchurl {
              url = "https://registry.npmjs.org/firecrawl-mcp/-/firecrawl-mcp-${version}.tgz";
              hash = entry.hash;
            };

            src = pkgs.runCommand "${pname}-${version}-src" { } ''
              mkdir -p $out
              tar -xzf ${tarball} -C $out --strip-components=1
            '';

            offlineCache = pkgs.fetchYarnDeps {
              inherit yarnLock;
              hash = entry.yarnDepsHash;
            };
          in
          pkgs.stdenv.mkDerivation {
            inherit
              pname
              version
              src
              offlineCache
              ;

            meta = with pkgs.lib; {
              description = "Firecrawl MCP Server - web scraping and crawling";
              homepage = "https://github.com/mendableai/firecrawl-mcp-server";
              platforms = platforms.unix;
            };

            nativeBuildInputs = [
              nodejs
              pkgs.yarn
              pkgs.yarnConfigHook
              pkgs.makeWrapper
            ];

            # The published tarball has no yarn.lock; ensure the committed,
            # complete lock is present before the offline install
            # (yarnConfigHook diffs it against the fetchYarnDeps mirror).
            postPatch = ''
              cp ${yarnLock} yarn.lock
              chmod +w yarn.lock
            '';

            # The npm tarball ships a prebuilt dist/index.js — no build step needed.
            dontBuild = true;

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/${pname}
              mkdir -p $out/bin

              cp -r . $out/lib/${pname}/

              makeWrapper ${nodejs}/bin/node $out/bin/firecrawl-mcp \
                --add-flags "$out/lib/${pname}/dist/index.js" \
                --set NODE_PATH "$out/lib/${pname}/node_modules"

              runHook postInstall
            '';
          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `firecrawl-mcp-server_<sanitized-key>` package per table entry.
        versionedPackages = builtins.listToAttrs (
          builtins.map
            (key: {
              name = "firecrawl-mcp-server_${sanitize key}";
              value = mk key releases.versions.${key};
            })
            (
              builtins.filter (
                # Only expose versions that have a committed lockfile.
                key: builtins.pathExists (./deps + "/${key}/yarn.lock")
              ) (builtins.attrNames releases.versions)
            )
        );
      in
      {
        packages = versionedPackages // {
          default = latestPkg;
          firecrawl-mcp-server = latestPkg;
          firecrawl-mcp = latestPkg;
        };
      }
    );
}
