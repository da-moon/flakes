{
  description = "Universal Reddit Scraper Suite packaged as a Nix flake";

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
        pythonEnv = pkgs.python312.withPackages (
          ps: with ps; [
            aiofiles
            aiohttp
            fastapi
            openpyxl
            pandas
            pyarrow
            requests
            streamlit
            uvicorn
          ]
        );

        reddit-universal-scraper = pkgs.stdenv.mkDerivation rec {
          pname = "reddit-universal-scraper";
          version = "unstable-2026-06-11";

          meta = with lib; {
            description = "Reddit scraper with dashboard, REST API, scheduled scraping, and exports";
            homepage = "https://github.com/ksanjeev284/reddit-universal-scraper";
            mainProgram = "reddit-universal-scraper";
            platforms = linuxSystems;
            maintainers = [ ];
          };

          rev = "1a537ff3b1306c0d414a277f4720fe21e09737a4";

          src = pkgs.fetchFromGitHub {
            owner = "ksanjeev284";
            repo = "reddit-universal-scraper";
            inherit rev;
            hash = "sha256-SIL7+CIwWuMZi1uIjRydMyMsvN9NJO+GJT3eyhXA/f4=";
          };

          nativeBuildInputs = [ pkgs.makeWrapper ];
          dontBuild = true;
          dontConfigure = true;

          postPatch = ''
            substituteInPlace main.py \
              --replace 'os.system("streamlit run dashboard/app.py")' \
                        'subprocess.call(["streamlit", "run", str(Path(__file__).resolve().parent / "dashboard" / "app.py")])'
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out/lib/${pname} $out/bin
            cp -R . $out/lib/${pname}/

            makeWrapper ${pythonEnv}/bin/python $out/bin/reddit-universal-scraper \
              --add-flags "$out/lib/${pname}/main.py" \
              --prefix PATH : ${lib.makeBinPath [ pythonEnv pkgs.ffmpeg ]} \
              --prefix PYTHONPATH : "$out/lib/${pname}"

            ln -s $out/bin/reddit-universal-scraper $out/bin/reddit-scraper

            runHook postInstall
          '';

        };
      in
      {
        packages = {
          default = reddit-universal-scraper;
          inherit reddit-universal-scraper;
        };

        apps = {
          default = {
            type = "app";
            program = "${reddit-universal-scraper}/bin/reddit-universal-scraper";
          };
          reddit-scraper = {
            type = "app";
            program = "${reddit-universal-scraper}/bin/reddit-scraper";
          };
        };
      }
    );
}
