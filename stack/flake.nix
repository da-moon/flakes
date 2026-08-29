{
  description = "stack - squash-safe stacked PR/MR repair CLI for GitHub and GitLab";

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
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        pname = "stack";

        # Version table: consumers select the latest OR any past version.
        # New entries are appended by scripts/update-version.sh via jq — do
        # NOT hand-edit the version data in this file.
        releases = builtins.fromJSON (builtins.readFile ./releases.json);

        mk =
          key: entry:
          let
            version = entry.version;
          in
          pkgs.stdenv.mkDerivation {
            inherit pname version;

            # The npm tarball ships the fully bundled dist/cli.js (built by
            # upstream's `prepack: bun run build`) — no node_modules needed.
            # The hash is arch-agnostic: same file for every system.
            src = pkgs.fetchurl {
              url = "https://registry.npmjs.org/@kitlangton/${pname}/-/${pname}-${version}.tgz";
              hash = entry.hash;
            };

            nativeBuildInputs = [ pkgs.makeWrapper ];
            dontUnpack = true;
            dontBuild = true;
            dontConfigure = true;

            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib/${pname} $out/bin
              tar -xzf $src -C $out/lib/${pname} --strip-components=1
              makeWrapper ${pkgs.bun}/bin/bun $out/bin/stack \
                --add-flags "$out/lib/${pname}/dist/cli.js"
              runHook postInstall
            '';

            meta = with lib; {
              description = "Squash-safe stacked PR/MR repair CLI for GitHub and GitLab";
              homepage = "https://github.com/kitlangton/stack";
              license = licenses.mit;
              mainProgram = "stack";
              platforms = systems;
              maintainers = [ ];
            };
          };

        sanitizeKey = key: builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] key;

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "stack_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          stack = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/stack";
          };
          stack = {
            type = "app";
            program = "${latestPkg}/bin/stack";
          };
        };
      }
    );
}
