{
  description = "TradingView MCP bridge for TradingView Desktop";

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
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nodejs = pkgs.nodejs_22;

        # Builder: derive a tradingview-mcp package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/rev/hash(es)
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          pkgs.buildNpmPackage rec {
          pname = "tradingview-mcp";
          version = entry.version;

          meta = with pkgs.lib; {
            description = "MCP bridge for TradingView Desktop via Chrome DevTools Protocol";
            longDescription = ''
              This package installs only the MCP bridge and tv CLI. It does not
              package TradingView Desktop itself; the external TradingView
              Desktop runtime must be installed and launched separately with a
              Chrome DevTools Protocol port such as --remote-debugging-port=9222.
            '';
            homepage = "https://github.com/tradesdontlie/tradingview-mcp";
            license = licenses.mit;
            mainProgram = "tradingview-mcp";
            platforms = linuxSystems;
          };

          rev = entry.rev;

          src = pkgs.fetchFromGitHub {
            owner = "tradesdontlie";
            repo = "tradingview-mcp";
            inherit rev;
            hash = entry.hash;
          };

          npmDepsHash = entry.npmDepsHash;
          dontNpmBuild = true;

          postPatch = ''
            ${nodejs}/bin/node <<'NODE'
            const fs = require("fs");
            const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));

            function exactFromPackageLock(name) {
              if (!fs.existsSync("package-lock.json")) return null;
              const lock = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));
              const lockedPackage = lock.packages && lock.packages["node_modules/" + name];
              if (lockedPackage && lockedPackage.version) return lockedPackage.version;
              const lockedDependency = lock.dependencies && lock.dependencies[name];
              return lockedDependency && lockedDependency.version ? lockedDependency.version : null;
            }

            function exactSpec(name, spec) {
              if (typeof spec !== "string") return spec;
              if (/^(file:|link:|workspace:|git\+|https?:)/.test(spec)) return spec;
              const locked = exactFromPackageLock(name);
              if (locked) return locked;
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
                const next = exactSpec(name, spec);
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
          '';

          nativeBuildInputs = [ pkgs.makeWrapper ];

          installPhase = ''
            runHook preInstall

            mkdir -p $out/lib/${pname} $out/bin
            shopt -s dotglob
            cp -r ./* $out/lib/${pname}/
            shopt -u dotglob

            makeWrapper ${nodejs}/bin/node $out/bin/tradingview-mcp \
              --add-flags "$out/lib/${pname}/src/server.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules"

            makeWrapper ${nodejs}/bin/node $out/bin/tv \
              --add-flags "$out/lib/${pname}/src/cli/index.js" \
              --set NODE_PATH "$out/lib/${pname}/node_modules"

            runHook postInstall
          '';

        };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `tradingview-mcp_<sanitized-key>` package per entry in the table.
        versionPackages = builtins.listToAttrs (
          builtins.map (key: {
            name = "tradingview-mcp_${sanitizeKey key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
        );
      in
      {
        packages = versionPackages // {
          default = latestPkg;
          tradingview-mcp = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/tradingview-mcp";
          };
          tv = {
            type = "app";
            program = "${latestPkg}/bin/tv";
          };
        };
      }
    );
}
