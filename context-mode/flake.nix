{
  description = "Context Mode - MCP plugin for context-efficient coding on Linux";

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
        lib = nixpkgs.lib;

        # Use Node 22 on Linux so runtime falls back to built-in node:sqlite
        # instead of needing the optional better-sqlite3 native addon.
        pname = "context-mode";
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ pname ];
        };
        nodejs = pkgs.nodejs_22;

        # Builder: derive a context-mode package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src-url/hash(es)
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;

            npmDeps = pkgs.stdenv.mkDerivation {
              name = "${pname}-${version}-npm-deps";

              src = pkgs.fetchurl {
                url = "https://registry.npmjs.org/context-mode/-/context-mode-${version}.tgz";
                hash = entry.hash;
              };

              nativeBuildInputs = [
                nodejs
                pkgs.pnpm
                pkgs.cacert
              ];

              dontPatchShebangs = true;

              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              outputHash = entry.npmDepsHash;

              buildPhase = ''
                runHook preBuild

                export HOME=$TMPDIR
                tar -xzf $src
                cd package

                ${nodejs}/bin/node -e '
                  const fs = require("fs");
                  const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
                  delete pkg.devDependencies;
                  delete pkg.optionalDependencies;
                  delete pkg.packageManager;
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
                  fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2));
                '

                pnpm install --prod --ignore-scripts --shamefully-hoist

                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall
                mkdir -p $out
                cp -r . $out/
                runHook postInstall
              '';
            };
          in
          pkgs.stdenv.mkDerivation {
            inherit pname version;

            meta = with lib; {
              description = "MCP plugin for context-efficient AI coding workflows";
              homepage = "https://github.com/mksglu/context-mode";
              license = licenses.elastic20;
              mainProgram = "context-mode";
              platforms = linuxSystems;
              maintainers = [ ];
            };

            src = npmDeps;

            nativeBuildInputs = [ pkgs.makeWrapper ];
            dontBuild = true;
            dontConfigure = true;

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/${pname}
              mkdir -p $out/bin
              cp -r $src/* $out/lib/${pname}/

              makeWrapper ${nodejs}/bin/node $out/bin/.context-mode-real \
                --add-flags "$out/lib/${pname}/cli.bundle.mjs" \
                --set NODE_PATH "$out/lib/${pname}/node_modules" \
                --set NODE_ENV "production" \
                --prefix PATH : ${lib.makeBinPath [
                  pkgs.git
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.ripgrep
                ]}

              cat > $out/bin/context-mode <<'EOF'
              #!/usr/bin/env bash
              set -euo pipefail

              case "''${1:-}" in
                --version|-V)
                  echo "context-mode __VERSION__"
                  exit 0
                  ;;
                --help|-h)
                  cat <<'USAGE'
              context-mode <command>

              Common commands:
                context-mode setup
                context-mode doctor
                context-mode --version

              With no arguments, the upstream CLI starts the MCP server on stdio.
              USAGE
                  exit 0
                  ;;
              esac

              exec "__REAL_BIN__" "$@"
              EOF
              substituteInPlace $out/bin/context-mode \
                --replace-fail "__VERSION__" "${version}" \
                --replace-fail "__REAL_BIN__" "$out/bin/.context-mode-real"
              chmod +x $out/bin/context-mode

              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `context-mode_<sanitized-key>` package per entry in the table.
        versionPackages = builtins.listToAttrs (
          builtins.map (key: {
            name = "context-mode_${sanitize key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
        );
      in
      {
        packages = versionPackages // {
          default = latestPkg;
          "context-mode" = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/context-mode";
          };
          "context-mode" = {
            type = "app";
            program = "${latestPkg}/bin/context-mode";
          };
        };
      }
    );
}
