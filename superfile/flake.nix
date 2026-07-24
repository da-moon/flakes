{
  description = "Superfile - pretty fancy and modern terminal file manager packaged as a Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];

      homeManagerModule =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        {
          imports = [ ./modules/home-manager.nix ];
          config.programs.superfile.package =
            lib.mkDefault
              self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        # Per-system release-asset metadata (arch target + autopatchelf need).
        # The version-specific hash comes from releases.json, not here.
        # Upstream ships statically linked Go binaries, so nothing needs
        # autoPatchelf — verified with `file`/`ldd` on the v1.6.0 assets.
        releaseBySystem = {
          "x86_64-linux" = {
            os = "linux";
            arch = "amd64";
            needsAutoPatchelf = false;
          };
          "aarch64-darwin" = {
            os = "darwin";
            arch = "arm64";
            needsAutoPatchelf = false;
          };
        };

        currentRelease =
          releaseBySystem.${system} or (throw "Unsupported system for superfile flake: ${system}");

        # Builder: derive a superfile package from one releases.json entry.
        mk =
          key: entry:
          let
            version = entry.version;
            binarySha256 = entry.hashes.${system} or (throw "Missing hashes entry for system: ${system}");
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "superfile";
            inherit version;

            meta = with lib; {
              description = "Superfile - pretty fancy and modern terminal file manager";
              homepage = "https://github.com/yorukot/superfile";
              license = licenses.mit;
              mainProgram = "spf";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/yorukot/superfile/releases/download/v${version}/superfile-${currentRelease.os}-v${version}-${currentRelease.arch}.tar.gz";
              hash = binarySha256;
            };

            # Tarballs contain only the `spf` binary under dist/.
            sourceRoot = "dist/superfile-${currentRelease.os}-v${version}-${currentRelease.arch}";
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;

            nativeBuildInputs = lib.optionals currentRelease.needsAutoPatchelf [
              pkgs.autoPatchelfHook
            ];

            buildInputs = lib.optionals currentRelease.needsAutoPatchelf [
              pkgs.stdenv.cc.cc.lib
            ];

            installPhase = ''
              runHook preInstall
              install -m755 -D spf $out/bin/spf
              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `superfile_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "superfile_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          superfile = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/spf";
          };
          superfile = {
            type = "app";
            program = "${latestPkg}/bin/spf";
          };
        };
      }
    )
    // {
      homeManagerModules = {
        default = homeManagerModule;
        superfile = homeManagerModule;
      };
    };
}
