{
  description = "Fabric - open-source framework for augmenting humans using AI";

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

        # Version table: consumers select the latest OR any past version.
        # New entries are appended by scripts/update-version.sh via jq — do
        # NOT hand-edit the version data in this file.
        releases = builtins.fromJSON (builtins.readFile ./releases.json);

        assetBySystem = {
          "x86_64-linux" = "fabric_Linux_x86_64.tar.gz";
          "aarch64-linux" = "fabric_Linux_arm64.tar.gz";
          "x86_64-darwin" = "fabric_Darwin_x86_64.tar.gz";
          "aarch64-darwin" = "fabric_Darwin_arm64.tar.gz";
        };

        systemAsset = assetBySystem.${system} or (throw "Unsupported system for fabric: ${system}");

        mk =
          key: entry:
          let
            version = entry.version;
            binaryHash = entry.hashes.${system} or (throw "Missing hash for system ${system} in fabric ${key}");
          in
          pkgs.stdenv.mkDerivation {
            pname = "fabric";
            inherit version;

            src = pkgs.fetchurl {
              url = "https://github.com/danielmiessler/Fabric/releases/download/v${version}/${systemAsset}";
              hash = binaryHash;
            };

            sourceRoot = ".";
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;

            installPhase = ''
              runHook preInstall
              install -m755 -D fabric $out/bin/fabric
              runHook postInstall
            '';

            meta = with lib; {
              description = "Open-source framework for augmenting humans using AI";
              homepage = "https://github.com/danielmiessler/Fabric";
              license = licenses.mit;
              mainProgram = "fabric";
              platforms = systems;
              maintainers = [ ];
            };
          };

        sanitizeKey = key: builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] key;

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "fabric_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          fabric = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/fabric";
          };
          fabric = {
            type = "app";
            program = "${latestPkg}/bin/fabric";
          };
        };
      }
    );
}
