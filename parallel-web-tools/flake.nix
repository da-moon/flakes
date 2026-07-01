{
  description = "Parallel Web Tools - CLI for web search, content extraction, and deep research via the Parallel API";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix (mirrors the
      # updater's sanitize_key).
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Architecture-specific release-asset name.
        archBySystem = {
          "aarch64-linux" = "linux-arm64";
          "x86_64-linux" = "linux-x64";
        };

        # Builder: derive a parallel-cli package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src-url/hash
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;

            # Get arch string + hash for current system, fallback to x86_64 if unknown.
            arch = archBySystem.${system} or archBySystem."x86_64-linux";
            sha256 = entry.hashes.${system} or entry.hashes."x86_64-linux";
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "parallel-cli";
            inherit version;

            meta = with pkgs.lib; {
              description = "CLI for web search, content extraction, and deep research via the Parallel API";
              homepage = "https://github.com/parallel-web/parallel-web-tools";
              platforms = [ "aarch64-linux" "x86_64-linux" ];
              maintainers = [ ];
            };

            src = pkgs.fetchzip {
              url = "https://github.com/parallel-web/parallel-web-tools/releases/download/v${version}/parallel-cli-${arch}.zip";
              inherit sha256;
              stripRoot = true;
            };

            # autoPatchelfHook fixes ELF interpreter/rpath for NixOS
            nativeBuildInputs = [ pkgs.autoPatchelfHook ];

            # Runtime libraries needed by PyInstaller bundle
            buildInputs = [
              pkgs.stdenv.cc.cc.lib # libstdc++
              pkgs.zlib
            ];

            # No build needed - precompiled binary
            dontBuild = true;
            dontConfigure = true;

            # Don't strip PyInstaller binaries
            dontStrip = true;

            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib/parallel-cli $out/bin
              cp -r . $out/lib/parallel-cli/
              chmod +x $out/lib/parallel-cli/parallel-cli
              ln -s $out/lib/parallel-cli/parallel-cli $out/bin/parallel-cli
              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `parallel-cli_<key>` (and alias `parallel-web-tools_<key>`)
        # package per entry in the table.
        versionPackages = builtins.foldl' (acc: key:
          let pkg = mk key releases.versions.${key};
          in acc // {
            "parallel-cli_${sanitizeKey key}" = pkg;
            "parallel-web-tools_${sanitizeKey key}" = pkg;
          }
        ) { } (builtins.attrNames releases.versions);

      in
      {
        packages = versionPackages // {
          default = latestPkg;
          parallel-cli = latestPkg;
          parallel-web-tools = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/parallel-cli";
          };
          parallel-cli = {
            type = "app";
            program = "${latestPkg}/bin/parallel-cli";
          };
        };
      }
    );
}
