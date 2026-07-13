{
  description = "Elio - Snappy, batteries-included terminal file manager packaged as a Nix flake";

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

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];

      homeManagerModule =
        { config, lib, pkgs, ... }:
        {
          imports = [ ./modules/home-manager.nix ];
          config.programs.elio.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };

      nixosModule =
        { config, lib, pkgs, ... }:
        {
          imports = [ ./modules/nixos.nix ];
          config.programs.elio.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };

      mkElioConfigLib =
        { pkgs, cfg }:
        (import ./modules/elio-lib.nix { inherit pkgs; }).mkElioConfig { inherit cfg; };

      mkElioThemeLib =
        { pkgs, cfg }:
        (import ./modules/elio-lib.nix { inherit pkgs; }).mkElioTheme { inherit cfg; };
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        # Per-system release-asset metadata (arch target + autopatchelf need).
        # The version-specific hash comes from releases.json, not here.
        releaseBySystem = {
          "x86_64-linux" = {
            target = "x86_64-unknown-linux-gnu";
            needsAutoPatchelf = true;
          };
        };

        currentRelease =
          releaseBySystem.${system}
            or (throw "Unsupported system for elio flake: ${system}");

        # Builder: derive an elio package from one releases.json entry.
        mk =
          key: entry:
          let
            version = entry.version;
            binarySha256 =
              entry.hashes.${system}
                or (throw "Missing hashes entry for system: ${system}");
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "elio";
            inherit version;

            meta = with lib; {
              description = "Elio - Snappy, batteries-included terminal file manager with rich previews, inline images, bulk actions, and trash support";
              homepage = "https://github.com/elio-fm/elio";
              license = licenses.mit;
              mainProgram = "elio";
              platforms = [ "x86_64-linux" ];
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/elio-fm/elio/releases/download/v${version}/elio-${version}-${currentRelease.target}.tar.gz";
              hash = binarySha256;
            };

            sourceRoot = "elio-${version}-${currentRelease.target}";
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
              install -m755 -D elio $out/bin/elio

              mkdir -p $out/share/applications
              install -m644 packaging/linux/elio.desktop $out/share/applications/elio.desktop

              for size in 48 128 256 512; do
                mkdir -p $out/share/icons/hicolor/''${size}x''${size}/apps
                install -m644 packaging/linux/icons/hicolor/''${size}x''${size}/apps/elio.png \
                  $out/share/icons/hicolor/''${size}x''${size}/apps/elio.png
              done

              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `elio_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "elio_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          elio = latestPkg;
        } // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/elio";
          };
          elio = {
            type = "app";
            program = "${latestPkg}/bin/elio";
          };
        };
      }
    )
    // {
      homeManagerModules = {
        default = homeManagerModule;
        elio = homeManagerModule;
      };

      nixosModules = {
        default = nixosModule;
        elio = nixosModule;
      };

      lib = {
        inherit mkElioConfigLib mkElioThemeLib;
      };
    };
}
