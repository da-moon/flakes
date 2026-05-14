{
  description = "HoneClaw CLI packaged as a Nix flake";

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
      linuxSystems = [ "x86_64-linux" ];
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        version = "0.11.1";

        honeclaw = pkgs.stdenv.mkDerivation rec {
          pname = "honeclaw";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/B-M-Capital-Research/honeclaw/releases/download/v${version}/honeclaw-linux-x86_64.tar.gz";
            hash = "sha256-SvzYBvhjPg1jECN8rOKcR/GPW7LvnHxVYmw3T4qBvxg=";
          };

          sourceRoot = "honeclaw-v${version}-x86_64-unknown-linux-gnu";
          dontBuild = true;
          dontConfigure = true;
          dontStrip = true;

          nativeBuildInputs = [
            pkgs.autoPatchelfHook
            pkgs.makeWrapper
          ];
          buildInputs = [
            pkgs.openssl
            (lib.getLib pkgs.stdenv.cc.cc)
          ];

          installPhase = ''
            runHook preInstall

            mkdir -p $out/lib/honeclaw $out/bin
            cp -R . $out/lib/honeclaw/

            for bin in hone-cli hone-mcp hone-imessage hone-telegram hone-discord hone-feishu hone-console-page; do
              makeWrapper "$out/lib/honeclaw/bin/$bin" "$out/bin/$bin" \
                --set HONE_INSTALL_ROOT "$out/lib/honeclaw" \
                --set HONE_SKILLS_DIR "$out/lib/honeclaw/share/honeclaw/skills" \
                --set HONE_WEB_DIST_DIR "$out/lib/honeclaw/share/honeclaw/web"
            done

            runHook postInstall
          '';

          meta = with lib; {
            description = "AI workspace orchestration CLI";
            homepage = "https://github.com/B-M-Capital-Research/honeclaw";
            mainProgram = "hone-cli";
            platforms = linuxSystems;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = honeclaw;
          inherit honeclaw;
        };

        apps = {
          default = {
            type = "app";
            program = "${honeclaw}/bin/hone-cli";
          };
          hone-cli = {
            type = "app";
            program = "${honeclaw}/bin/hone-cli";
          };
          hone-mcp = {
            type = "app";
            program = "${honeclaw}/bin/hone-mcp";
          };
        };
      }
    );
}
