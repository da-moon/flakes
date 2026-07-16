{
  description = "Kimi Code - native cross-platform CLI packaged as a Nix flake with Home Manager hook module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      home-manager,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      homeManagerModule =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        {
          imports = [ ./modules/home-manager.nix ];
          config.programs.kimi-cli.package =
            lib.mkDefault
              self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };
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

        releasePlatformBySystem = {
          x86_64-linux = "linux-x64";
          aarch64-linux = "linux-arm64";
          x86_64-darwin = "darwin-x64";
          aarch64-darwin = "darwin-arm64";
        };

        releasePlatform = releasePlatformBySystem.${system};

        # Builder: derive a kimi-cli package from one releases.json entry.
        mk =
          key: entry:
          let
            version = entry.version;
            binarySha256 = entry.hashes.${system};
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "kimi-cli";
            inherit version;

            meta = with lib; {
              description = "Kimi Code - AI coding assistant CLI for terminal";
              homepage = "https://code.kimi.com";
              license = licenses.asl20;
              mainProgram = "kimi";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://code.kimi.com/kimi-code/binaries/${version}/kimi-code-${releasePlatform}";
              sha256 = binarySha256;
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

              mkdir -p $out/bin
              install -m755 $src $out/bin/kimi

              runHook postInstall
            '';
          };

        # Sanitize a JSON key into a valid attribute-name suffix.
        sanitizeKey = key: builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] key;

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `kimi-cli_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "kimi-cli_${sanitizeKey key}" (mk key entry)
        ) releases.versions;

        moduleCheck = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            homeManagerModule
            {
              home.username = "kimi-test";
              home.homeDirectory =
                if pkgs.stdenv.hostPlatform.isDarwin then "/Users/kimi-test" else "/home/kimi-test";
              home.stateVersion = "24.11";
              programs.home-manager.enable = true;
              programs.kimi-cli.enable = true;
            }
          ];
        };
      in
      {
        packages = {
          default = latestPkg;
          kimi-cli = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/kimi";
          };
          kimi = {
            type = "app";
            program = "${latestPkg}/bin/kimi";
          };
        };

        checks = {
          module-eval = moduleCheck.activationPackage;
        };
      }
    )
    // {
      homeManagerModules = {
        default = homeManagerModule;
        kimi-cli = homeManagerModule;
      };
    };
}
