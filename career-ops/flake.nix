{
  description = "career-ops - AI job search pipeline";

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
        nodejs = pkgs.nodejs_22;
        pname = "career-ops";

        # Builder: derive a career-ops package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/rev/hash
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            rev = entry.rev;
            lockDir = ./deps + "/${version}";

            githubSrc = pkgs.fetchFromGitHub {
              owner = "santifer";
              repo = "career-ops";
              inherit rev;
              hash = entry.hash;
            };

            # Upstream ships no lockfile. Inject our committed, fully-pinned
            # package.json + package-lock.json + .npmrc. This is what makes
            # the dependency set reproducible: importNpmLock fetches every
            # module as its own content-addressed derivation keyed to the
            # lockfile's integrity hashes — there is no drift-prone recursive
            # hash FOD.
            src = pkgs.runCommand "${pname}-${version}-src" { } ''
              mkdir -p $out
              cp -r ${githubSrc}/. $out/
              chmod -R u+w $out
              cp ${lockDir}/package.json $out/package.json
              cp ${lockDir}/package-lock.json $out/package-lock.json
              cp ${lockDir}/.npmrc $out/.npmrc
            '';

            npmDeps = pkgs.importNpmLock { npmRoot = src; };
          in
          pkgs.stdenv.mkDerivation {
            inherit pname version src npmDeps;

            meta = with pkgs.lib; {
              description = "AI-powered job search pipeline built on Claude Code";
              homepage = "https://github.com/santifer/career-ops";
              license = licenses.mit;
              mainProgram = "career-ops";
              platforms = systems;
            };

            # npmConfigHook runs `npm ci`-equivalent offline against npmDeps
            # during the configure phase, populating node_modules.
            nativeBuildInputs = [
              nodejs
              nodejs.passthru.python
              pkgs.importNpmLock.npmConfigHook
              pkgs.makeWrapper
            ];

            dontBuild = true;

            # Prevent `npm rebuild`'s implicit rebuild-scripts pass (which
            # runs the root package's lifecycle scripts, including
            # playwright's browser-download postinstall) from executing
            # inside the sandbox.
            npmRebuildFlags = [ "--ignore-scripts" ];

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/${pname} $out/bin
              shopt -s dotglob
              cp -r ./* $out/lib/${pname}/
              shopt -u dotglob

              cat > $out/bin/career-ops <<'EOF'
              #!/usr/bin/env bash
              set -euo pipefail

              app_dir="@app_dir@"
              node="@node@"
              cmd="''${1:-doctor}"
              if [ "$cmd" = "init" ]; then
                target="''${2:-.}"
                mkdir -p "$target"
                shopt -s dotglob
                for entry in "$app_dir"/*; do
                  name="$(basename "$entry")"
                  [ "$name" = "node_modules" ] && continue
                  [ -e "$target/$name" ] && continue
                  cp -R "$entry" "$target/$name"
                done
                shopt -u dotglob
                ln -sfn "$app_dir/node_modules" "$target/node_modules"
                chmod -R u+w "$target"
                echo "Initialized career-ops in $target"
                exit 0
              fi

              case "$cmd" in
                doctor) script="doctor.mjs" ;;
                verify) script="verify-pipeline.mjs" ;;
                normalize) script="normalize-statuses.mjs" ;;
                dedup) script="dedup-tracker.mjs" ;;
                merge) script="merge-tracker.mjs" ;;
                pdf) script="generate-pdf.mjs" ;;
                latex) script="generate-latex.mjs" ;;
                sync-check) script="cv-sync-check.mjs" ;;
                update) script="update-system.mjs" ;;
                liveness) script="check-liveness.mjs" ;;
                scan) script="scan.mjs" ;;
                gemini-eval) script="gemini-eval.mjs" ;;
                analyze-patterns) script="analyze-patterns.mjs" ;;
                followup-cadence) script="followup-cadence.mjs" ;;
                test-all) script="test-all.mjs" ;;
                *)
                  echo "unknown career-ops command: $cmd" >&2
                  echo "commands: init doctor verify normalize dedup merge pdf latex sync-check update liveness scan gemini-eval analyze-patterns followup-cadence test-all" >&2
                  exit 2
                  ;;
              esac
              shift || true

              if [ -f ./package.json ] && grep -q '"name": "career-ops"' ./package.json; then
                [ -e ./node_modules ] || ln -s "$app_dir/node_modules" ./node_modules
                exec "$node" "./$script" "$@"
              fi

              echo "career-ops project not found in the current directory; run 'career-ops init .' first" >&2
              exit 2
              EOF

              substituteInPlace $out/bin/career-ops \
                --replace '@app_dir@' "$out/lib/${pname}" \
                --replace '@node@' "${nodejs}/bin/node"
              chmod +x $out/bin/career-ops

              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `career-ops_<sanitized-key>` package per entry in the table.
        versionPackages = builtins.listToAttrs (
          builtins.map
            (key: {
              name = "${pname}_${sanitize key}";
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
        packages = versionPackages // {
          default = latestPkg;
          career-ops = latestPkg;
        };

        apps.default = {
          type = "app";
          program = "${latestPkg}/bin/career-ops";
        };
      }
    );
}
