{
  description = "askii - TUI based ASCII diagram editor packaged from GitHub releases";

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
      linuxSystems = [ "x86_64-linux" ];
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        version = "0.6.0";

        askii = pkgs.stdenv.mkDerivation rec {
          pname = "askii";
          inherit version;

          meta = with lib; {
            description = "TUI based ASCII diagram editor";
            homepage = "https://github.com/nytopop/askii";
            license = licenses.mit;
            mainProgram = "askii";
            platforms = linuxSystems;
            maintainers = [ ];
          };

          src = pkgs.fetchurl {
            url = "https://github.com/nytopop/askii/releases/download/v${version}/askii";
            hash = "sha256-J5pIr+qUA/M0h4FPgUOX9R9ocdJtL8PVoolh+xFnJmA=";
          };

          dontUnpack = true;
          dontBuild = true;
          dontConfigure = true;
          dontStrip = true;

          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = [
            (lib.getLib pkgs.stdenv.cc.cc)
            pkgs.libbsd
            pkgs.libmd
            pkgs.libxau
            pkgs.libxdmcp
            pkgs.libxcb
          ];

          installPhase = ''
            runHook preInstall
            install -m755 -D "$src" "$out/bin/askii"
            runHook postInstall
          '';

        };
      in
      {
        packages = {
          default = askii;
          inherit askii;
        };

        apps = {
          default = {
            type = "app";
            program = "${askii}/bin/askii";
          };
          askii = {
            type = "app";
            program = "${askii}/bin/askii";
          };
        };
      }
    );
}
