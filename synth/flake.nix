{
  description = "synth - The Declarative Data Generator";

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
      # Upstream publishes prebuilt tarballs for these targets only — there is
      # NO aarch64-darwin release asset, so it is intentionally absent here.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
      ];

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Map a nix system to the upstream release-asset file name.
        releaseAssetBySystem = {
          "x86_64-linux" = "synth-ubuntu-18.04-x86_64.tar.gz";
          "aarch64-linux" = "synth-ubuntu-latest-arm64.tar.gz";
          "x86_64-darwin" = "synth-macos-latest-x86_64.tar.gz";
        };

        # Builder: derive a synth package from one releases.json entry.
        # Only version/rev/asset/hash come from `entry`; the install logic is
        # fixed.
        mk =
          key: entry:
          let
            version = entry.version;
            rev = entry.rev;
            asset = releaseAssetBySystem.${system};
            binarySha256 = entry.hashes.${system} or (throw "Missing hashes entry for system: ${system}");
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "synth";
            inherit version;

            meta = with pkgs.lib; {
              description = "The Declarative Data Generator";
              longDescription = ''
                Synth is a tool for generating realistic data using a declarative
                data model. Describe the shape of your data and synth generates
                it for you for testing, seeding databases, and benchmarking.
              '';
              homepage = "https://www.getsynth.com/";
              license = licenses.asl20;
              platforms = systems;
              mainProgram = "synth";
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/shuttle-hq/synth/releases/download/${rev}/${asset}";
              sha256 = binarySha256;
            };

            sourceRoot = ".";

            # No build needed - precompiled binary
            dontBuild = true;
            dontConfigure = true;

            # Don't strip: keep the shipped binary byte-for-byte unchanged.
            dontStrip = true;
            # Don't rewrite the ELF interpreter on Darwin.
            dontPatchELF = pkgs.stdenv.hostPlatform.isDarwin;

            nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.autoPatchelfHook
            ];
            buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.stdenv.cc.cc.lib
            ];

            installPhase = ''
              runHook preInstall
              install -m755 -D synth $out/bin/synth
              runHook postInstall
            '';
          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `synth_<sanitized-key>` package per entry in the table.
        versionedPackages = builtins.listToAttrs (
          builtins.map (key: {
            name = "synth_${sanitize key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
        );

      in
      {
        packages = versionedPackages // {
          default = latestPkg;
          synth = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/synth";
          };
          synth = {
            type = "app";
            program = "${latestPkg}/bin/synth";
          };
        };
      }
    );
}
