{
  description = "omp - AI coding agent CLI packaged from GitHub releases, with Home Manager and NixOS modules";

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
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # Overlay consumed by other flakes that want `omp` in nixpkgs.
      overlay = final: prev: {
        omp = self.packages.${prev.stdenv.hostPlatform.system}.omp or (self.packages.${prev.stdenv.hostPlatform.system}.default);
      };
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        # Version table: consumers select the latest OR any past version.
        # New entries are appended by scripts/update-version.sh via jq — do
        # NOT hand-edit the version data in this file.
        releases = builtins.fromJSON (builtins.readFile ./releases.json);

        releasePlatformBySystem = {
          x86_64-linux = "linux-x64";
          aarch64-linux = "linux-arm64";
        };

        releasePlatform = releasePlatformBySystem.${system};

        # Builder: derive an omp package from one releases.json entry.
        mk =
          key: entry:
          let
            version = entry.version;
            binarySha256 = entry.hashes.${system};
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "omp";
            inherit version;

            meta = with lib; {
              description = "omp - AI coding agent CLI";
              homepage = "https://github.com/can1357/oh-my-pi";
              license = licenses.mit;
              mainProgram = "omp";
              platforms = linuxSystems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/can1357/oh-my-pi/releases/download/v${version}/omp-${releasePlatform}";
              sha256 = binarySha256;
            };

            dontUnpack = true;
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;

            nativeBuildInputs = with pkgs; [
              autoPatchelfHook
            ];

            buildInputs = [
              pkgs.stdenv.cc.cc.lib
            ];

            installPhase = ''
              runHook preInstall

              mkdir -p $out/bin
              install -m755 $src $out/bin/omp

              runHook postInstall
            '';
          };

        # Sanitize a JSON key into a valid attribute-name suffix.
        sanitizeKey = key: builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] key;

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `omp_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "omp_${sanitizeKey key}" (mk key entry)
        ) releases.versions;

      in
      {
        packages = {
          default = latestPkg;
          omp = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/omp";
          };
          omp = {
            type = "app";
            program = "${latestPkg}/bin/omp";
          };
        };
      }
    )
    // {
      overlays.default = overlay;

      homeManagerModules.default = ./modules/home-manager.nix;
      nixosModules.default = ./modules/nixos.nix;
    };
}
