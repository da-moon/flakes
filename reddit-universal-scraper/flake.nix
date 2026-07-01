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

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
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

        # Builder: derive a reddit-universal-scraper package from one
        # releases.json entry. PRESERVES the original build logic exactly;
        # only version/rev/hash now come from `entry`.
        mk =
          key: entry:
          let
            version = entry.version;
            rev = entry.rev;
          in
          pkgs.stdenv.mkDerivation rec {
          pname = "reddit-universal-scraper";
          inherit version;

          meta = with lib; {
            description = "Reddit scraper with dashboard, REST API, scheduled scraping, and exports";
            homepage = "https://github.com/ksanjeev284/reddit-universal-scraper";
            mainProgram = "reddit-universal-scraper";
            platforms = linuxSystems;
            maintainers = [ ];
          };

          src = pkgs.fetchFromGitHub {
            owner = "ksanjeev284";
            repo = "reddit-universal-scraper";
            inherit rev;
            hash = entry.hash;
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

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `reddit-universal-scraper_<sanitized-key>` package per entry.
        versionPackages = builtins.listToAttrs (
          builtins.map (key: {
            name = "reddit-universal-scraper_${sanitize key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
        );
      in
      {
        packages = versionPackages // {
          default = latestPkg;
          reddit-universal-scraper = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/reddit-universal-scraper";
          };
          reddit-scraper = {
            type = "app";
            program = "${latestPkg}/bin/reddit-scraper";
          };
        };
      }
    );
}
