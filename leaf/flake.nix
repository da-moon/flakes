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
        version = "1.24.2";

        releaseBySystem = {
          "x86_64-linux" = {
            asset = "leaf-linux-x86_64";
            hash = "sha256-uYXu/P0MS3TXLAxde5/6SuwEUCK0nwljbCOItXwM4YM=";
          };
          "aarch64-linux" = {
            asset = "leaf-linux-arm64";
            hash = "sha256-sjJsDpaLK8jOcFtVWWZYLHDUE0PUZhR56a/6IQ8uhkE=";
          };
        };

        release =
          releaseBySystem.${system}
            or (throw "Unsupported system for leaf: ${system}");

        leaf = pkgs.stdenv.mkDerivation rec {
          pname = "leaf";
          inherit version;

          meta = with lib; {
            description = "Leaf terminal AI client";
            homepage = "https://github.com/RivoLink/leaf";
            mainProgram = "leaf";
            platforms = linuxSystems;
            maintainers = [ ];
          };

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
