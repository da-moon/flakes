{
  description = "Beads - A lightweight memory system for AI coding agents";

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
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Map a nix system to the upstream release-asset arch token.
        releaseArchBySystem = {
          "aarch64-linux" = "arm64";
          "x86_64-linux" = "amd64";
        };

        # Builder: derive a beads package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src-url/hash
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            arch = releaseArchBySystem.${system} or releaseArchBySystem."x86_64-linux";
            binarySha256 =
              entry.hashes.${system}
                or (throw "Missing hashes entry for system: ${system}");
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "beads";
            inherit version;

            meta = with pkgs.lib; {
              description = "Beads - A lightweight memory system for AI coding agents";
              longDescription = ''
                Beads is a graph-based issue tracker designed as a memory system
                for AI coding agents. It enables agents to manage complex work
                across extended sessions and multiple machines with dependency
                tracking, ready work detection, and git-based distribution.
              '';
              homepage = "https://github.com/steveyegge/beads";
              platforms = [ "aarch64-linux" "x86_64-linux" ];
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/steveyegge/beads/releases/download/v${version}/beads_${version}_linux_${arch}.tar.gz";
              sha256 = binarySha256;
            };

            sourceRoot = ".";

            # Use autoPatchelfHook to fix dynamic linker path
            nativeBuildInputs = [ pkgs.autoPatchelfHook ];
            # Beads 1.0.0 links against ICU 74 and libstdc++/libgcc at runtime.
            buildInputs = [
              pkgs.icu74
              (pkgs.lib.getLib pkgs.stdenv.cc.cc)
            ];

            # No build needed - precompiled binary
            dontBuild = true;
            dontConfigure = true;

            installPhase = ''
              runHook preInstall
              install -m755 -D bd $out/bin/bd
              runHook postInstall
            '';

            # Don't strip but do patch ELF
            dontStrip = true;

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `beads_<sanitized-key>` package per entry in the table.
        versionedPackages = builtins.listToAttrs (
          builtins.map (key: {
            name = "beads_${sanitize key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
        );

      in
      {
        packages = versionedPackages // {
          default = latestPkg;
          beads = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/bd";
          };
          bd = {
            type = "app";
            program = "${latestPkg}/bin/bd";
          };
        };
      }
    );
}
