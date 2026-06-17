{
  description = "Elio - Terminal music player packaged as a Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
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

      homeManagerModule =
        { config, lib, pkgs, ... }:
        let
          cfg = config.programs.elio;
        in
        {
          options.programs.elio = {
            enable = lib.mkEnableOption "elio terminal music player";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
              defaultText = lib.literalExpression "inputs.elio.packages.\${pkgs.stdenv.hostPlatform.system}.default";
              description = "The elio package to use.";
            };

            enableBashIntegration = lib.mkEnableOption "bash integration" // {
              default = true;
            };

            enableZshIntegration = lib.mkEnableOption "zsh integration";

            enableFishIntegration = lib.mkEnableOption "fish integration";
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ cfg.package ];

            programs.bash.initExtra = lib.mkIf cfg.enableBashIntegration ''
              eval "$(${cfg.package}/bin/elio shell init bash)"
            '';

            programs.zsh.initExtra = lib.mkIf cfg.enableZshIntegration ''
              eval "$(${cfg.package}/bin/elio shell init zsh)"
            '';

            programs.fish.interactiveShellInit = lib.mkIf cfg.enableFishIntegration ''
              ${cfg.package}/bin/elio shell init fish | source
            '';
          };
        };
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        version = "1.9.0";

        releaseBySystem = {
          "x86_64-linux" = {
            target = "x86_64-unknown-linux-gnu";
            sha256 = "sha256-eX64XxJnvTjm3yRR6gf7Ym1kvUO3FCGPaB8R2LJ++AU=";
            needsAutoPatchelf = true;
          };
        };

        currentRelease =
          releaseBySystem.${system}
            or (throw "Unsupported system for elio flake: ${system}");

        elio = pkgs.stdenv.mkDerivation rec {
          pname = "elio";
          inherit version;

          meta = with lib; {
            description = "Elio - Terminal music player";
            homepage = "https://github.com/elio-fm/elio";
            license = licenses.mit;
            mainProgram = "elio";
            platforms = [ "x86_64-linux" ];
            maintainers = [ ];
          };

          src = pkgs.fetchurl {
            url = "https://github.com/elio-fm/elio/releases/download/v${version}/elio-${version}-${currentRelease.target}.tar.gz";
            hash = currentRelease.sha256;
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
      in
      {
        packages = {
          default = elio;
          inherit elio;
        };

        apps = {
          default = {
            type = "app";
            program = "${elio}/bin/elio";
          };
          elio = {
            type = "app";
            program = "${elio}/bin/elio";
          };
        };
      }
    )
    // {
      homeManagerModules = {
        default = homeManagerModule;
        elio = homeManagerModule;
      };
    };
}
