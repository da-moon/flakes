{
  description = "dd-cli - Datadog CLI helpers from NimbusHQ";

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
      releases = builtins.fromJSON (builtins.readFile ./releases.json);
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nodejs = pkgs.nodejs_22;
        pname = "dd-cli";

        # Builder: turns one releases.json entry into the dd-cli derivation.
        #
        # Dependencies are pinned by a committed yarn.lock (deps/<key>/) and
        # fetched with fetchYarnDeps into an offline mirror; yarnConfigHook then
        # runs `yarn install --offline --frozen-lockfile`. This is reproducible
        # over time: the offline-mirror hash changes only when the committed
        # lockfile changes, never because the npm registry drifted.
        mk =
          key: entry:
          let
            version = entry.version;
            rev = entry.rev;
            yarnLock = ./deps + "/${key}/yarn.lock";

            src = pkgs.fetchFromGitHub {
              owner = "nimbushq";
              repo = "dd-cli";
              inherit rev;
              hash = entry.hash;
            };

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
              description = "CLI tool for working with Datadog logs";
              homepage = "https://github.com/nimbushq/dd-cli";
              license = licenses.asl20;
              mainProgram = "dd-cli";
              platforms = platforms.unix;
            };

            nativeBuildInputs = [
              nodejs
              pkgs.yarn
              pkgs.yarnConfigHook
              pkgs.makeWrapper
            ];

            # Upstream's committed yarn.lock omits the typescript devDependency;
            # replace it with our committed, complete lock before the offline
            # install (yarnConfigHook diffs it against the fetchYarnDeps mirror).
            postPatch = ''
              cp ${yarnLock} yarn.lock
            '';

            buildPhase = ''
              runHook preBuild
              ${nodejs}/bin/node ./node_modules/typescript/bin/tsc
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/${pname} $out/bin
              cp -r package.json lib node_modules $out/lib/${pname}/

              makeWrapper ${nodejs}/bin/node $out/bin/dd-cli \
                --add-flags "$out/lib/${pname}/lib/bin/dd-cli.js" \
                --set NODE_PATH "$out/lib/${pname}/node_modules" \
                --set NODE_ENV "production"

              runHook postInstall
            '';
          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        versionedPackages = builtins.listToAttrs (
          builtins.map
            (key: {
              name = "${pname}_${sanitize key}";
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
          dd-cli = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/dd-cli";
          };
          dd-cli = {
            type = "app";
            program = "${latestPkg}/bin/dd-cli";
          };
        };
      }
    );
}
