{
  description = "kestractl - Kestra CLI for managing Kestra instances";

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
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];

      # Map a nix system to the upstream release-asset OS/arch tokens.
      releaseBySystem = {
        "x86_64-linux" = {
          os = "linux";
          arch = "amd64";
        };
        "aarch64-linux" = {
          os = "linux";
          arch = "arm64";
        };
        "x86_64-darwin" = {
          os = "darwin";
          arch = "amd64";
        };
        "aarch64-darwin" = {
          os = "darwin";
          arch = "arm64";
        };
      };
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        currentRelease =
          releaseBySystem.${system} or (throw "Unsupported system for kestractl flake: ${system}");

        # Builder: derive a kestractl package from one releases.json entry.
        mk =
          key: entry:
          let
            version = entry.version;
            binarySha256 = entry.hashes.${system} or (throw "Missing hashes entry for system: ${system}");
            asset = "kestractl_${version}_${currentRelease.os}_${currentRelease.arch}";
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "kestractl";
            inherit version;

            meta = with lib; {
              description = "kestractl - Kestra CLI for managing Kestra instances";
              homepage = "https://github.com/kestra-io/kestractl";
              license = licenses.asl20;
              mainProgram = "kestractl";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/kestra-io/kestractl/releases/download/v${version}/${asset}";
              hash = binarySha256;
            };

            dontUnpack = true;
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;

            nativeBuildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.autoPatchelfHook
            ];

            buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.stdenv.cc.cc.lib
            ];

            installPhase = ''
              runHook preInstall
              install -m755 -D "$src" "$out/bin/kestractl"
              runHook postInstall
            '';
          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `kestractl_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "kestractl_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          kestractl = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/kestractl";
          };
          kestractl = {
            type = "app";
            program = "${latestPkg}/bin/kestractl";
          };
        };
      }
    );
}
