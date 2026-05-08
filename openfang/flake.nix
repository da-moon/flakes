{
  description = "OpenFang CLI packaged as a Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        version = "0.6.4";

        releaseBySystem = {
          "x86_64-linux" = {
            target = "x86_64-unknown-linux-gnu";
            hash = "sha256-sjEkPosSTgKKOLN8LYysqwYhzxhsBSScm3aiy2zmnfM=";
          };
          "aarch64-linux" = {
            target = "aarch64-unknown-linux-gnu";
            hash = "sha256-L1o4dNMtCc9Z4cbRnd3lth2kklSol/eKp/yjfjMURGg=";
          };
        };

        release =
          releaseBySystem.${system}
            or (throw "Unsupported system for openfang: ${system}");

        openfang = pkgs.stdenv.mkDerivation rec {
          pname = "openfang";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/RightNow-AI/openfang/releases/download/v${version}/openfang-${release.target}.tar.gz";
            inherit (release) hash;
          };

          sourceRoot = ".";
          dontBuild = true;
          dontConfigure = true;
          dontStrip = true;

          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = [ (lib.getLib pkgs.stdenv.cc.cc) ];

          installPhase = ''
            runHook preInstall
            install -m755 -D openfang $out/bin/openfang
            runHook postInstall
          '';

          meta = with lib; {
            description = "OpenFang CLI";
            homepage = "https://github.com/RightNow-AI/openfang";
            mainProgram = "openfang";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = openfang;
          inherit openfang;
        };

        apps = {
          default = {
            type = "app";
            program = "${openfang}/bin/openfang";
          };
          openfang = {
            type = "app";
            program = "${openfang}/bin/openfang";
          };
        };
      }
    );
}
