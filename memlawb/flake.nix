{
  description = "memlawb - zero-knowledge, end-to-end-encrypted agent memory: server, CLI, and MCP server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      home-manager,
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

      homeManagerModule =
        { lib, pkgs, ... }:
        {
          imports = [ ./modules/home-manager.nix ];
          programs.memlawb.package = lib.mkDefault (self.packages.${pkgs.stdenv.hostPlatform.system}.memlawb);
        };

      flakePartsModule = import ./flake-modules/default.nix {
        memlawbPackage = consumerPkgs: self.packages.${consumerPkgs.stdenv.hostPlatform.system}.memlawb;
      };
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pname = "memlawb";

        nodejs = pkgs.nodejs_22;

        # Builder: derive a memlawb package from one releases.json entry.
        # Dependencies are resolved from the committed lockfile under
        # ./deps/<key>/ via importNpmLock — there is no drift-prone
        # recursive FOD hash. The runtime is bun, which executes the
        # TypeScript entrypoint directly.
        mk =
          key: entry:
          let
            version = entry.version;
            lockDir = ./deps + "/${key}";

            githubSrc = pkgs.fetchFromGitHub {
              owner = "Gitlawb";
              repo = "memlawb";
              rev = entry.rev;
              hash = entry.hash;
            };

            # The upstream repo's package.json carries devDependencies (and
            # does not declare zod, which src/mcp/server.ts imports). Inject
            # our committed, deps-only package.json + package-lock.json +
            # .npmrc so importNpmLock resolves every module as its own
            # content-addressed derivation keyed to the lockfile's integrity
            # hashes.
            src = pkgs.runCommand "${pname}-${version}-src" { } ''
              mkdir -p $out
              cp -r ${githubSrc}/. $out/
              chmod -R u+w $out
              cp ${lockDir}/package.json $out/package.json
              cp ${lockDir}/package-lock.json $out/package-lock.json
              cp ${lockDir}/.npmrc $out/.npmrc
            '';

            # Read the lockfile straight from the committed deps/<key>/
            # directory (a plain flake path, not a derivation) so evaluation
            # needs no import-from-derivation — consumers can reference the
            # package from their own modules without breaking
            # `nix flake show`. The identical files are overlaid onto src
            # above, so npmConfigHook stays consistent with npmDeps.
            npmDeps = pkgs.importNpmLock {
              npmRoot = lockDir;
            };
          in
          pkgs.stdenv.mkDerivation {
            inherit
              pname
              version
              src
              npmDeps
              ;

            meta = with pkgs.lib; {
              description = "Zero-knowledge, end-to-end-encrypted agent memory — server, CLI, and MCP server";
              homepage = "https://github.com/Gitlawb/memlawb";
              license = licenses.mit;
              mainProgram = "memlawb";
              platforms = systems;
            };

            # npmConfigHook runs `npm install --ignore-scripts` offline
            # against npmDeps during the configure phase, populating
            # node_modules. All dependencies are pure JS; nothing is compiled.
            nativeBuildInputs = [
              pkgs.makeWrapper
              nodejs
              pkgs.importNpmLock.npmConfigHook
            ];

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/${pname} $out/bin
              shopt -s dotglob
              cp -r ./* $out/lib/${pname}/
              shopt -u dotglob

              makeWrapper ${pkgs.bun}/bin/bun $out/bin/memlawb \
                --add-flags "$out/lib/${pname}/bin/memlawb.ts"

              runHook postInstall
            '';
          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `memlawb_<sanitized-key>` package per entry in the table.
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

        mcpApp = pkgs.writeShellScriptBin "memlawb-mcp" ''
          exec ${latestPkg}/bin/memlawb mcp "$@"
        '';

        serveApp = pkgs.writeShellScriptBin "memlawb-serve" ''
          exec ${latestPkg}/bin/memlawb serve "$@"
        '';

        moduleEvaluation = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            homeManagerModule
            {
              home = {
                username = "memlawb-test";
                homeDirectory = "/home/memlawb-test";
                stateVersion = "26.05";
              };
              programs.memlawb = {
                enable = true;
                client = {
                  url = "https://memory.example.com";
                  namespace = "user:test";
                  scan = "warn";
                };
              }
              // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
                server = {
                  enable = true;
                  port = 18080;
                  allowUnauthenticated = true;
                };
              };
            }
          ];
        };

        cliSmoke = pkgs.runCommand "memlawb-cli-smoke" { } ''
          export HOME="$TMPDIR"
          usage_text="$(${latestPkg}/bin/memlawb 2>&1 || true)"
          case "$usage_text" in
            *"memlawb push"*"memlawb mcp"*"memlawb serve"*) ;;
            *)
              echo "memlawb CLI did not print its usage text:" >&2
              echo "$usage_text" >&2
              exit 1
              ;;
          esac
          touch $out
        '';

        serverSmoke = pkgs.runCommand "memlawb-server-smoke" { } ''
          export HOME="$TMPDIR"
          export PORT=18080
          export DATA_DIR="$TMPDIR/data"
          export ALLOW_UNAUTHENTICATED=true
          ${latestPkg}/bin/memlawb serve >server.log 2>&1 &
          pid=$!
          ok=false
          for _ in $(seq 1 50); do
            if grep -q "listening on :18080" server.log; then
              ok=true
              break
            fi
            sleep 0.2
          done
          kill "$pid" 2>/dev/null || true
          if [ "$ok" != true ]; then
            echo "memlawb server did not start:" >&2
            cat server.log >&2
            exit 1
          fi
          touch $out
        '';

        mcpSmoke = pkgs.runCommand "memlawb-mcp-stdio-smoke" { } ''
          export HOME="$TMPDIR"
          export MEMLAWB_PASSPHRASE=nix-check-passphrase
          printf '%s\n' \
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"nix-check","version":"0"}}}' \
            | timeout 30 ${latestPkg}/bin/memlawb mcp >mcp.log 2>mcp.err || true
          grep -q '"protocolVersion"' mcp.log
          grep -q '\[memlawb mcp\] ready' mcp.err
          touch $out
        '';
      in
      {
        formatter = pkgs.nixfmt-rfc-style;

        packages = versionedPackages // {
          default = latestPkg;
          memlawb = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/memlawb";
          };
          memlawb = {
            type = "app";
            program = "${latestPkg}/bin/memlawb";
          };
          memlawb-mcp = {
            type = "app";
            program = "${mcpApp}/bin/memlawb-mcp";
          };
          memlawb-serve = {
            type = "app";
            program = "${serveApp}/bin/memlawb-serve";
          };
        };

        checks = {
          package = latestPkg;
          cli = cliSmoke;
          server = serverSmoke;
          mcp-stdio = mcpSmoke;
          module-eval = moduleEvaluation.activationPackage;
        };
      }
    )
    // {
      homeManagerModules = {
        default = homeManagerModule;
        memlawb = homeManagerModule;
      };

      flakeModules = {
        default = flakePartsModule;
        memlawb = flakePartsModule;
      };
    };
}
