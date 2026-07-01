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
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nodejs = pkgs.nodejs_22;
        pname = "career-ops";

        # Builder: derive a career-ops package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/rev/hash(es)
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            rev = entry.rev;

            src = pkgs.fetchFromGitHub {
              owner = "santifer";
              repo = "career-ops";
              inherit rev;
              hash = entry.hash;
            };

            npmDeps = pkgs.stdenv.mkDerivation {
              name = "${pname}-${version}-npm-deps";
              inherit src;

              nativeBuildInputs = [
                nodejs
                pkgs.cacert
              ];

              dontPatchShebangs = true;
              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              outputHash =
                entry.npmDepsHashes.${system}
                  or (throw "Missing npmDepsHashes entry for system: ${system}");

              buildPhase = ''
                runHook preBuild

                export HOME=$TMPDIR
                export npm_config_cache=$TMPDIR/.npm
                export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
                export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true

                cp -r $src/. .
                chmod -R u+w .

                ${nodejs}/bin/node <<'NODE'
                const fs = require("fs");
                const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));

                function exactSpec(spec) {
                  if (typeof spec !== "string") return spec;
                  if (/^(file:|link:|workspace:|git\+|https?:)/.test(spec)) return spec;
                  const bare = spec.match(/^[~^](\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)$/);
                  return bare ? bare[1] : spec;
                }

                function isExactInstallSpec(spec) {
                  return /^(file:|link:|workspace:|git\+|https?:)/.test(spec)
                    || /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(spec);
                }

                const unresolved = [];
                for (const field of ["dependencies", "devDependencies", "optionalDependencies"]) {
                  for (const [name, spec] of Object.entries(pkg[field] || {})) {
                    const next = exactSpec(spec);
                    pkg[field][name] = next;
                    if (typeof next === "string" && !isExactInstallSpec(next)) {
                      unresolved.push(field + "." + name + "=" + next);
                    }
                  }
                }

                if (unresolved.length > 0) {
                  throw new Error("Non-exact dependency specs remain: " + unresolved.join(", "));
                }

                fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n");
                NODE
                npm install --omit=dev --ignore-scripts

                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall
                mkdir -p $out
                shopt -s dotglob
                cp -r ./* $out/
                shopt -u dotglob
                runHook postInstall
              '';
            };
          in
          pkgs.stdenv.mkDerivation {
            inherit pname version;

            meta = with pkgs.lib; {
              description = "AI-powered job search pipeline built on Claude Code";
              homepage = "https://github.com/santifer/career-ops";
              license = licenses.mit;
              mainProgram = "career-ops";
              platforms = linuxSystems;
            };

            src = npmDeps;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            dontBuild = true;
            dontConfigure = true;

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/${pname} $out/bin
              shopt -s dotglob
              cp -r $src/* $out/lib/${pname}/
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
          builtins.map (key: {
            name = "${pname}_${sanitize key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
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
