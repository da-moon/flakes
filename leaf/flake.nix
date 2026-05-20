{
  description = "Leaf CLI packaged as a Nix flake";

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
        version = "1.22.3";

        releaseBySystem = {
          "x86_64-linux" = {
            asset = "leaf-linux-x86_64";
            hash = "sha256-ZM7Ef8IGT/9i8KYWMz1VC6XSp0ATE3NxdQ48Gopc+8k=";
          };
          "aarch64-linux" = {
            asset = "leaf-linux-arm64";
            hash = "sha256-B7jI1bhvvwAY2o2PQs2uQZbCfZUGS2UaTXcu+2vDQ8w=";
          };
        };

        release =
          releaseBySystem.${system}
            or (throw "Unsupported system for leaf: ${system}");

        leaf = pkgs.stdenv.mkDerivation rec {
          pname = "leaf";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/RivoLink/leaf/releases/download/${version}/${release.asset}";
            inherit (release) hash;
          };

          dontUnpack = true;
          dontBuild = true;
          dontConfigure = true;
          dontStrip = true;

          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = [ (lib.getLib pkgs.stdenv.cc.cc) ];

          installPhase = ''
            runHook preInstall
            install -m755 -D $src $out/bin/leaf
            runHook postInstall
          '';

          meta = with lib; {
            description = "Leaf terminal AI client";
            homepage = "https://github.com/RivoLink/leaf";
            mainProgram = "leaf";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = leaf;
          inherit leaf;
        };

        apps = {
          default = {
            type = "app";
            program = "${leaf}/bin/leaf";
          };
          leaf = {
            type = "app";
            program = "${leaf}/bin/leaf";
          };
        };
      }
    );
}
