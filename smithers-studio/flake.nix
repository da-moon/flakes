{
  description = "Smithers Studio - the 4-process Vite dev UI for Smithers workspaces";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      homeManagerModule =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          inherit (lib)
            escapeShellArg
            getExe
            literalExpression
            mkEnableOption
            mkIf
            mkOption
            types
            ;

          cfg = config.programs.smithers-studio;

          mkPortOption =
            default: description:
            mkOption {
              type = types.port;
              inherit default description;
            };

          # Multi-workspace switch (launcher-only, NO app patch). The single
          # service boots on `defaultPath`; `smithers-studio-use <name>` writes a
          # pointer file and restarts the service so the gateway re-binds to it.
          # One stack / one port block (RAM-efficient); one workspace viewed at a
          # time. Parallel runs are unaffected - Studio is only a viewer.
          hasMap = cfg.workspaces != { };
          defaultPath =
            if cfg.defaultWorkspace != "" && builtins.hasAttr cfg.defaultWorkspace cfg.workspaces then
              cfg.workspaces.${cfg.defaultWorkspace}
            else
              cfg.service.workspace;
          stateDir = "${config.home.homeDirectory}/.local/state/smithers-studio";
          pointer = "${stateDir}/active-workspace";
          serviceLauncher = pkgs.writeShellScript "smithers-studio-service" ''
            set -euo pipefail
            ws=""
            if [ -f ${escapeShellArg pointer} ]; then ws="$(cat ${escapeShellArg pointer} 2>/dev/null || true)"; fi
            if [ -z "$ws" ] || [ ! -d "$ws" ]; then ws=${escapeShellArg defaultPath}; fi
            exec ${getExe cfg.package} "$ws"
          '';
          switchTool = pkgs.writeShellScriptBin "smithers-studio-use" ''
            set -euo pipefail
            declare -A WS=( ${lib.concatStringsSep " " (lib.mapAttrsToList (n: p: "[${escapeShellArg n}]=${escapeShellArg p}") cfg.workspaces)} )
            keys="''${!WS[*]}"
            name="''${1:-}"
            if [ -z "$name" ]; then
              echo "usage: smithers-studio-use <name>"
              echo "configured: ''${keys:-<none>}"
              exit 1
            fi
            path="''${WS[$name]:-}"
            if [ -z "$path" ]; then
              echo "unknown workspace: $name"
              echo "configured: ''${keys:-<none>}"
              exit 1
            fi
            mkdir -p ${escapeShellArg stateDir}
            printf '%s' "$path" > ${escapeShellArg pointer}
            systemctl --user restart smithers-studio.service
            echo "studio -> $name ($path)"
          '';
        in
        {
          options.programs.smithers-studio = {
            enable = mkEnableOption "the Smithers Studio dev UI launcher";

            package = mkOption {
              type = types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.smithers-studio;
              defaultText = literalExpression "inputs.smithers-studio.packages.\${pkgs.stdenv.hostPlatform.system}.smithers-studio";
              description = "Package providing the smithers-studio launcher.";
            };

            workspace = mkOption {
              type = types.str;
              default = "$PWD";
              defaultText = literalExpression ''"$PWD"'';
              example = "%h/projects/my-smithers-workspace";
              description = ''
                Workspace directory the backends operate on (must contain a
                real .smithers + smithers.db). Passed as SMITHERS_STUDIO_WORKSPACE.
                The default "$PWD" is resolved at launch by the wrapper, matching
                Smithers' cwd-keyed workspace model. An empty string also resolves
                to the launch cwd.
              '';
            };

            gatewayPort = mkPortOption 7331 "Smithers Gateway port (SMITHERS_GATEWAY_PORT).";
            workspaceApiPort = mkPortOption 7410 "Workspace API port (SMITHERS_WORKSPACE_API_PORT).";
            ptyPort = mkPortOption 7342 "PTY terminal server port (SMITHERS_PTY_PORT).";
            uiPort = mkPortOption 5190 "Vite UI dev server port (SMITHERS_STUDIO_2_PORT).";

            hideDemoData = mkEnableOption ''
              hiding Studio's demo/mock seed data (the mock projects, chat feed,
              toasts, and prototype dashboards) so the UI opens on the real
              studio shell and shows only the connected workspace. Sets
              VITE_SMITHERS_STUDIO_NO_DEMO=1'';

            workspaces = mkOption {
              type = types.attrsOf types.str;
              default = { };
              example = literalExpression ''{ neh = "/home/me/code/neh"; api = "/home/me/code/api"; }'';
              description = ''
                Named smithers workspaces (name -> absolute repo path) the single
                background service can switch between via `smithers-studio-use
                <name>` (repoints the gateway + restarts, ~2s). One stack, one
                port block (RAM-efficient); Studio binds one workspace at a time,
                so this trades simultaneous viewing for RAM. Parallel runs are
                unaffected (Studio is only a viewer). Leave empty for the classic
                single `service.workspace` mode.
              '';
            };

            defaultWorkspace = mkOption {
              type = types.str;
              default = "";
              example = "neh";
              description = ''
                Which `workspaces` entry the service boots on. Empty falls back to
                `service.workspace`.
              '';
            };

            # Optional always-on background service. This is a USER-GLOBAL opt-in:
            # a systemd user service is per-user, not per-repo, and two instances
            # would collide on the four ports. Enable it ONLY in a user/machine
            # home-manager config, NEVER in a repo-specific consumer flake. A
            # repo-specific consumer should use `programs.smithers-studio.enable`
            # (the package + command on PATH) and launch the wrapper by hand. The
            # service reuses the port + package options above; it does not
            # duplicate them.
            service = {
              enable = mkEnableOption "a background systemd user service that runs Smithers Studio on login";

              workspace = mkOption {
                type = types.str;
                default = config.home.homeDirectory;
                defaultText = literalExpression "config.home.homeDirectory";
                example = "%h/projects/my-smithers-workspace";
                description = ''
                  Opening workspace the service launches against (passed as the
                  wrapper's WORKSPACE argument). Studio resolves one active
                  workspace by ascending to the nearest .smithers and the
                  workspace is switchable in the UI, so this is only the starting
                  point. Unlike the launch-time `workspace` option this must be a
                  real path (no "$PWD"): a service has no interactive cwd.
                '';
              };
            };
          };

          config = mkIf cfg.enable {
            assertions = [
              {
                assertion = pkgs.stdenv.hostPlatform.isLinux;
                message = "programs.smithers-studio is only supported on Linux.";
              }
            ]
            ++ lib.optional hasMap {
              assertion = cfg.defaultWorkspace != "" && builtins.hasAttr cfg.defaultWorkspace cfg.workspaces;
              message = "programs.smithers-studio.defaultWorkspace must name an entry in programs.smithers-studio.workspaces.";
            };

            home.sessionVariables = {
              SMITHERS_STUDIO_DEFAULT_WORKSPACE = cfg.workspace;
              SMITHERS_GATEWAY_PORT = toString cfg.gatewayPort;
              SMITHERS_WORKSPACE_API_PORT = toString cfg.workspaceApiPort;
              SMITHERS_PTY_PORT = toString cfg.ptyPort;
              SMITHERS_STUDIO_2_PORT = toString cfg.uiPort;
            } // lib.optionalAttrs cfg.hideDemoData {
              VITE_SMITHERS_STUDIO_NO_DEMO = "1";
            };

            home.packages = [ cfg.package ] ++ lib.optional (cfg.service.enable && hasMap) switchTool;

            # Optional background user service (opt-in, see service.enable above).
            # Runs the same wrapper the package ships, against service.workspace,
            # with the four ports exported from the existing port options.
            systemd.user.services.smithers-studio = mkIf cfg.service.enable {
              Unit = {
                Description = "Smithers Studio dev UI (Gateway, Workspace API, PTY, Vite UI)";
                After = [ "default.target" ];
              };
              Service = {
                Environment = [
                  "SMITHERS_GATEWAY_PORT=${toString cfg.gatewayPort}"
                  "SMITHERS_WORKSPACE_API_PORT=${toString cfg.workspaceApiPort}"
                  "SMITHERS_PTY_PORT=${toString cfg.ptyPort}"
                  "SMITHERS_STUDIO_2_PORT=${toString cfg.uiPort}"
                ] ++ lib.optional cfg.hideDemoData "VITE_SMITHERS_STUDIO_NO_DEMO=1";
                ExecStart = "${serviceLauncher}";
                Restart = "on-failure";
                RestartSec = 5;
              };
              Install = {
                WantedBy = [ "default.target" ];
              };
            };
          };
        };

      perSystem = flake-utils.lib.eachSystem linuxSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;
          pname = "smithers-studio";
          # Pinned to the monorepo tag v0.24.2 (commit
          # bf77d29a8e239c5d64bd4412b63c16e75644ddf7). At this rev
          # packages/smithers publishes smithers-orchestrator@0.24.2 and every
          # @smithers-orchestrator/* runtime dep is published at 0.24.2 on npm,
          # so the Studio app builds standalone once its workspace:* specs are
          # rewritten to "0.24.2". Pinning the tag keeps Studio and the
          # gateway/CLI it loads version-consistent.
          version = "0.24.2";
          rev = "bf77d29a8e239c5d64bd4412b63c16e75644ddf7";
          srcHash = "sha256-doVd5k4Q3NQ/iLQ9FXQpCGQL/FTPw8Fc7etmiIDOhEU=";

          # Fixed-output hash of the pinned, network-installed node_modules tree
          # (Bun install of the standalone Studio app, including the natively
          # compiled node-pty). Refresh with scripts/update-version.sh --rehash
          # after changing rev/version.
          depsHash = "sha256-z//MLp4taracuPlgOHVH8BXMe8it7WQ8KRwH5XHTm1E=";

          appSubdir = "apps/smithers-studio-2";

          src = pkgs.fetchFromGitHub {
            owner = "smithersai";
            repo = "smithers";
            inherit rev;
            hash = srcHash;
          };

          # Patch the standalone app's package.json so it resolves entirely from
          # npm with no monorepo workspace:
          #   - drop "private": true (lets it install on its own)
          #   - devtools + gateway-client: workspace:* -> "0.24.2"
          #   - add smithers-orchestrator "0.24.2": server/startGatewayServer.ts
          #     imports it bare; in the monorepo it resolved via the workspace
          #     hoist, which is absent standalone.
          patchPackageJson = pkgs.writeShellScript "patch-studio-package-json" ''
            set -euo pipefail
            ${pkgs.jq}/bin/jq '
              del(.private)
              | .dependencies["@smithers-orchestrator/devtools"] = "0.24.2"
              | .dependencies["@smithers-orchestrator/gateway-client"] = "0.24.2"
              | .dependencies["smithers-orchestrator"] = "0.24.2"
            ' package.json > package.json.patched
            mv package.json.patched package.json
          '';

          # Fixed-output derivation: the only place network access is allowed.
          # Produces the resolved node_modules (with node-pty compiled native).
          studioDeps = pkgs.stdenv.mkDerivation {
            pname = "${pname}-deps";
            inherit version src;

            nativeBuildInputs = [
              pkgs.bun
              pkgs.nodejs
              pkgs.node-gyp
              pkgs.python3
              pkgs.jq
              pkgs.gcc
              pkgs.gnumake
              pkgs.patchelf
            ];

            dontConfigure = true;

            buildPhase = ''
              runHook preBuild

              # Install the app in ISOLATION, outside the monorepo tree. If Bun
              # sees the repo root it treats the app as a workspace member and
              # links smithers-orchestrator -> packages/smithers (the local source
              # package), which then needs the full workspace's deps it does not
              # have standalone. Copying only the app out to a fresh root forces
              # Bun to resolve smithers-orchestrator (and its closure) from the
              # self-contained published npm tarballs instead.
              appBuild=$TMPDIR/app
              mkdir -p "$appBuild"
              cp -R ${appSubdir}/. "$appBuild"/
              cd "$appBuild"
              ${patchPackageJson}

              export HOME=$TMPDIR
              # node-pty's install script runs `node-gyp rebuild` to compile its
              # native addon (no linux prebuild ships). node-gyp needs node
              # headers; point it at the nixpkgs nodejs dev tree.
              export npm_config_nodedir=${pkgs.nodejs}
              # Stop the nixpkgs gcc wrapper from baking a build-time RPATH
              # (gcc-lib / glibc / this FOD's own $out) into node-pty's compiled
              # pty.node. That RPATH string lands in .dynstr / .rodata and a
              # fixed-output derivation rejects it as an illegal store reference;
              # patchelf cannot garbage-collect the orphaned .dynstr copy after
              # the fact. The wrapper supplies the runtime library path via
              # LD_LIBRARY_PATH instead.
              export NIX_DONT_SET_RPATH=1
              export NIX_NO_SELF_RPATH=1
              bun install --no-save

              # Scrub node-gyp build scaffolding. node-gyp bakes the build-time
              # nodejs / node-gyp store paths into Makefile / *.mk / config.gypi,
              # which a fixed-output derivation rejects as illegal path references.
              # Only the compiled build/Release/*.node is needed at runtime.
              find node_modules -type d -name build 2>/dev/null | while read -r b; do
                [ -d "$b/Release" ] || continue
                find "$b" -maxdepth 1 -type f \
                  \( -name 'Makefile' -o -name 'binding.Makefile' \
                     -o -name 'config.gypi' -o -name '*.mk' \) -delete
              done
              find node_modules -type f -name '*.target.mk' -delete

              # Remove the RPATH from every compiled .node addon. node-gyp links
              # node-pty against this FOD's own $out/lib via the cc-wrapper even
              # with NIX_DONT_SET_RPATH, which a fixed-output derivation rejects
              # as an illegal store reference. patchelf drops the DT_RUNPATH tag
              # but leaves the now-orphaned path string in .dynstr, so a second
              # pass nulls any residual /nix/store/<hash>-... byte run in place
              # (dead data: no tag references it, size preserved). The addon is
              # RPATH-free at runtime; the wrapper supplies libstdc++ via
              # LD_LIBRARY_PATH and node's own loader finds glibc.
              find node_modules -type f -name '*.node' 2>/dev/null \
                | while read -r addon; do
                    patchelf --remove-rpath "$addon" 2>/dev/null || true
                  done
              ${pkgs.python3}/bin/python3 ${./scripts/scrub-store-strings.py} node_modules

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out
              # Self-contained node_modules (real files, no repo-root .bun store).
              cp -R "$TMPDIR/app/node_modules" $out/node_modules
              cp "$TMPDIR/app/package.json" $out/package.json
              runHook postInstall
            '';

            dontFixup = true;

            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = depsHash;
          };

          # gcc runtime libs: node-pty's native pty.node needs libstdc++.so.6 on
          # the loader path. node finds it via its own RPATH, but the dev stack
          # also imports node-pty under Bun (server/workspaceBackend.ts), and Bun
          # does not set that path up, so the wrapper exports it explicitly.
          runtimeLib = pkgs.stdenv.cc.cc.lib;

          smithersStudio = pkgs.stdenv.mkDerivation {
            inherit pname version src;

            meta = with lib; {
              description = "Smithers Studio - 4-process Vite dev UI for Smithers workspaces";
              homepage = "https://github.com/smithersai/smithers/tree/main/apps/smithers-studio-2";
              license = licenses.mit; # monorepo ships a top-level MIT LICENSE
              mainProgram = "smithers-studio";
              platforms = linuxSystems;
              maintainers = [ ];
            };

            nativeBuildInputs = [
              pkgs.makeWrapper
              pkgs.jq
            ];

            dontConfigure = true;
            dontBuild = true;

            # Bun's package store carries a few dangling symlinks for native
            # optionalDependencies it chose not to materialize (e.g.
            # msgpackr-extract, which msgpackr falls back away from to its pure-JS
            # path). They are inert and present in the upstream install too, so
            # skip the broken-symlink fixup check rather than prune real files.
            dontCheckForBrokenSymlinks = true;

            installPhase = ''
              runHook preInstall

              # Lay out a minimal root the dev stack runs from. dev.ts hardcodes
              # APP_DIR="apps/smithers-studio-2" relative to its cwd, so the app
              # lives at $storeApp/${appSubdir} and the launcher cd's to $storeApp.
              # Only the app subtree is staged (NOT the rest of the monorepo): the
              # app resolves smithers-orchestrator and its closure from the self-
              # contained published node_modules, not from packages/ source.
              storeApp=$out/lib/${pname}
              appDir="$storeApp/${appSubdir}"
              mkdir -p "$appDir" $out/bin

              cp -R $src/${appSubdir}/. "$appDir"/
              chmod -R u+w "$appDir"

              # Match the package.json the FOD resolved against.
              ( cd "$appDir" && ${patchPackageJson} )

              # Gate all demo/mock seed data behind VITE_SMITHERS_STUDIO_NO_DEMO
              # (off by default; the home-manager `hideDemoData` option flips it).
              ${pkgs.python3}/bin/python3 ${./scripts/no-demo-patch.py} "$appDir"

              # Wire in the pinned, pre-resolved, self-contained node_modules.
              rm -rf "$appDir/node_modules"
              cp -R ${studioDeps}/node_modules "$appDir/node_modules"
              chmod -R u+w "$appDir/node_modules"

              # Launcher: boots the real 4-process dev stack against a workspace.
              # Workspace precedence: $1 > SMITHERS_STUDIO_WORKSPACE >
              # SMITHERS_STUDIO_DEFAULT_WORKSPACE (set by the HM module) > $PWD.
              cat > $out/bin/smithers-studio <<'EOF'
              #!/usr/bin/env bash
              set -euo pipefail

              case "''${1:-}" in
                --version|-V)
                  echo "smithers-studio __VERSION__"
                  exit 0
                  ;;
                --help|-h)
                  cat <<'USAGE'
              smithers-studio [WORKSPACE]

              Boots the Smithers Studio dev stack (Gateway, Workspace API, PTY,
              and Vite UI) against a workspace, then prints the UI URL.

              WORKSPACE   directory holding a real .smithers + smithers.db.
                          Defaults to SMITHERS_STUDIO_WORKSPACE, then
                          SMITHERS_STUDIO_DEFAULT_WORKSPACE, then the current dir.

              Ports (env, each falls back to the upstream default):
                SMITHERS_GATEWAY_PORT        gateway        (default 7331)
                SMITHERS_WORKSPACE_API_PORT  workspace API  (default 7410)
                SMITHERS_PTY_PORT            PTY terminal   (default 7342)
                SMITHERS_STUDIO_2_PORT       Vite UI        (default 5190)

              The workspace must already contain a smithers.db. Create one by
              running a workflow there first (e.g. `smithers up <workflow>`).
              USAGE
                  exit 0
                  ;;
              esac

              ws="''${1:-}"
              if [ -z "$ws" ]; then ws="''${SMITHERS_STUDIO_WORKSPACE:-}"; fi
              if [ -z "$ws" ]; then ws="''${SMITHERS_STUDIO_DEFAULT_WORKSPACE:-}"; fi
              if [ -z "$ws" ] || [ "$ws" = "\$PWD" ]; then ws="$PWD"; fi
              ws="$(cd "$ws" 2>/dev/null && pwd || echo "$ws")"

              export SMITHERS_STUDIO_WORKSPACE="$ws"
              export PATH="__BIN__:$PATH"
              export LD_LIBRARY_PATH="__LIBDIR__''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

              # Vite transpiles vite.config.ts at startup and writes the result
              # NEXT TO the config (vite.config.ts.timestamp-*.mjs), which fails
              # EACCES inside the read-only Nix store. Stage a writable working
              # copy of the app: the small source files are copied, the heavy
              # node_modules is symlinked back to the immutable store tree (no
              # write needed there). The stack runs from this writable root.
              cacheBase="''${XDG_CACHE_HOME:-$HOME/.cache}/smithers-studio"
              runRoot="$cacheBase/__VERSION__"
              appRun="$runRoot/__APP_SUBDIR__"
              # Re-stage when the app is missing OR the store path changed (a
              # package rebuild or version bump): keying the marker on the store
              # path makes a launcher fix like this one self-apply on next start,
              # with no manual cache wipe.
              stageMarker="$appRun/.smithers-studio-store-rev"
              if [ ! -e "$appRun/scripts/dev.ts" ] || [ "$(cat "$stageMarker" 2>/dev/null || true)" != "__APP_ROOT__" ]; then
                rm -rf "$runRoot"
                mkdir -p "$appRun"
                cp -R "__APP_ROOT__/__APP_SUBDIR__/." "$appRun"/
                chmod -R u+w "$appRun"
                # node_modules as a SYMLINK FARM, not a single symlink-to-store.
                # Vite's cacheDir defaults to <root>/node_modules/.vite; a lone
                # node_modules -> /nix/store symlink makes that path read-only, so
                # optimizeDeps fails EACCES, the browser 404s on every dep, and the
                # UI never mounts. Symlinking each entry keeps the heavy deps
                # immutable in the store while leaving the node_modules ROOT
                # writable, so Vite creates .vite there at runtime.
                rm -rf "$appRun/node_modules"
                mkdir -p "$appRun/node_modules"
                ( shopt -s dotglob nullglob
                  for entry in "__APP_ROOT__/__APP_SUBDIR__/node_modules"/*; do
                    ln -s "$entry" "$appRun/node_modules/$(basename "$entry")"
                  done )
                printf '%s' "__APP_ROOT__" > "$stageMarker"
              fi

              cd "$runRoot"
              exec "__BUN__" "$appRun/scripts/dev.ts"
              EOF

              substituteInPlace $out/bin/smithers-studio \
                --replace-fail "__VERSION__" "${version}" \
                --replace-fail "__APP_ROOT__" "$storeApp" \
                --replace-fail "__APP_SUBDIR__" "${appSubdir}" \
                --replace-fail "__BUN__" "${pkgs.bun}/bin/bun" \
                --replace-fail "__BIN__" "${lib.makeBinPath [ pkgs.bun pkgs.nodejs ]}" \
                --replace-fail "__LIBDIR__" "${runtimeLib}/lib"
              chmod +x $out/bin/smithers-studio

              runHook postInstall
            '';
          };
        in
        {
          packages = {
            default = smithersStudio;
            "smithers-studio" = smithersStudio;
            "smithers-studio-deps" = studioDeps;
          };

          apps = {
            default = {
              type = "app";
              program = "${smithersStudio}/bin/smithers-studio";
            };
            "smithers-studio" = {
              type = "app";
              program = "${smithersStudio}/bin/smithers-studio";
            };
          };
        }
      );
    in
    perSystem
    // {
      homeManagerModules = {
        default = homeManagerModule;
        smithers-studio = homeManagerModule;
      };
    };
}
