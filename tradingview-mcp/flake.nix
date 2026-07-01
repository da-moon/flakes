{
  description = "TradingView MCP bridge for TradingView Desktop";

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
        nodejs = pkgs.nodejs_22;

        tradingview-mcp = pkgs.buildNpmPackage rec {
          pname = "tradingview-mcp";
          version = "1.0.0-unstable-2026-07-01";

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

          rev = "4795784a19dd64ff4e2649d2499a536b01bd2d68";

          src = pkgs.fetchFromGitHub {
            owner = "tradesdontlie";
            repo = "tradingview-mcp";
            inherit rev;
            hash = "sha256-BWpFSYnb44nt+BYw4UQi/ar5TBlUKNPxy/T/M2SBjKQ=";
          };

          npmDepsHash = "sha256-7yfQf47RpHUa3zg5fwrFBtek6EVR2TeLKs1oN4eD2W0=";
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
      in
      {
        packages = {
          default = tradingview-mcp;
          inherit tradingview-mcp;
        };

        apps = {
          default = {
            type = "app";
            program = "${tradingview-mcp}/bin/tradingview-mcp";
          };
          tv = {
            type = "app";
            program = "${tradingview-mcp}/bin/tv";
          };
        };
      }
    );
}
