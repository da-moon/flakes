{
  description = "Kimi CLI - AI agent in Python";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    pyproject-nix,
    uv2nix,
    pyproject-build-systems,
  }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pname = "kimi-cli";
        version = "1.16.0";

        sourceHashBySystem = {
          "aarch64-linux" = "sha256-TgeZAlZ8TMc8UEaelRzZhah5yzK1mjCcdwNu8iTeLvE=";
          "x86_64-linux" = "sha256-TgeZAlZ8TMc8UEaelRzZhah5yzK1mjCcdwNu8iTeLvE=";
        };

        source = let
          source_archive = pkgs.fetchurl {
            url = "https://github.com/MoonshotAI/kimi-cli/archive/refs/tags/${version}.tar.gz";
            hash = sourceHashBySystem.${system} or (throw "Missing source hash for system ${system}");
          };
        in
          pkgs.runCommand "${pname}-source-${version}" { } ''
            tar -xzf ${source_archive}
            cp -r "${pname}-${version}/." "$out/"
          '';

        source_root = source;

        kimi-cli =
          let
            inherit (pkgs)
              lib
              callPackage
              python313
              ripgrep
              stdenvNoCC
              makeWrapper
              versionCheckHook
              ;
            python = python313;
            pyproject = lib.importTOML "${source_root}/pyproject.toml";
            workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = source_root; };
            overlay = workspace.mkPyprojectOverlay {
              sourcePreference = "wheel";
            };
            extraBuildOverlay = final: prev: {
              # Add setuptools build dependency for ripgrepy.
              ripgrepy = prev.ripgrepy.overrideAttrs (old: {
                nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.setuptools ];
              });

              # Replace README symlink with real file for Nix builds.
              "kimi-code" = prev."kimi-code".overrideAttrs (old: {
                postPatch = (old.postPatch or "") + ''
                  rm -f README.md
                  cp ${source_root}/README.md README.md
                '';
              });
            };
            pythonSet = (callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
              lib.composeManyExtensions [
                pyproject-build-systems.overlays.wheel
                overlay
                extraBuildOverlay
              ]
            );
            kimiCliPackage = pythonSet.mkVirtualEnv "${pname}-virtual-env-${version}" workspace.deps.default;
          in
          stdenvNoCC.mkDerivation ({
            inherit pname version;
            dontUnpack = true;

            nativeBuildInputs = [ makeWrapper ];
            buildInputs = [ ripgrep ];

            installPhase = ''
              runHook preInstall

              mkdir -p $out/bin
              makeWrapper ${kimiCliPackage}/bin/kimi $out/bin/kimi \
                --prefix PATH : ${lib.makeBinPath [ ripgrep ]} \
                --set KIMI_CLI_NO_AUTO_UPDATE "1"

              runHook postInstall
            '';

            nativeInstallCheckInputs = [
              versionCheckHook
            ];
            versionCheckProgramArg = "--version";
            doInstallCheck = true;

            meta = with pkgs.lib; {
              description = "Kimi Code CLI is a Python-based AI coding assistant";
              homepage = "https://github.com/MoonshotAI/kimi-cli";
              license = lib.licenses.asl20;
              mainProgram = "kimi";
              sourceProvenance = with lib.sourceTypes; [ fromSource ];
              platforms = [ "aarch64-linux" "x86_64-linux" ];
            };
          });
      in
      {
        packages = {
          default = kimi-cli;
          inherit kimi-cli;
        };

        apps = {
          default = {
            type = "app";
            program = "${kimi-cli}/bin/kimi";
          };
          kimi = {
            type = "app";
            program = "${kimi-cli}/bin/kimi";
          };
        };
      }
    );
}
