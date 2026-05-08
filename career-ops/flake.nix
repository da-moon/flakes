{
  description = "career-ops - AI job search pipeline";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
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
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nodejs = pkgs.nodejs_20;
        pname = "career-ops";
        version = "1.7.0";
        rev = "career-ops-v1.7.0";

        src = pkgs.fetchFromGitHub {
          owner = "santifer";
          repo = "career-ops";
          inherit rev;
          hash = "sha256-SnLPuA7ByCmiMKDTkB1MSRXzf0JswspCrmo69vAn9ZM=";
        };

        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-FXCxbq+OUmB7JrKd3dF949W75C33A7pqIeilLJHqQI8=";
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
            outputHashBySystem.${system} or (throw "Missing outputHashBySystem entry for system: ${system}");

          buildPhase = ''
            runHook preBuild

            export HOME=$TMPDIR
            export npm_config_cache=$TMPDIR/.npm
            export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
            export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true

            cp -r $src/. .
            chmod -R u+w .

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

        career-ops = pkgs.stdenv.mkDerivation {
          inherit pname version;
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

          meta = with pkgs.lib; {
            description = "AI-powered job search pipeline built on Claude Code";
            homepage = "https://github.com/santifer/career-ops";
            license = licenses.mit;
            mainProgram = "career-ops";
            platforms = linuxSystems;
          };
        };
      in
      {
        packages = {
          default = career-ops;
          inherit career-ops;
        };

        apps.default = {
          type = "app";
          program = "${career-ops}/bin/career-ops";
        };
      }
    );
}
