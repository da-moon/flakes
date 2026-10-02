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
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem systems (
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
              platforms = systems;
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
              substituteInPlace config.py \
                --replace-fail 'DATA_DIR = BASE_DIR / "data"' \
                  'DATA_DIR = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "reddit-universal-scraper"' \
                --replace-fail 'DATA_DIR.mkdir(exist_ok=True)' \
                  'DATA_DIR.mkdir(parents=True, exist_ok=True)'
              substituteInPlace dashboard/app.py \
                --replace-fail "Path(__file__).parent.parent / 'data'" "Path.cwd() / 'data'" \
                --replace-fail 'cwd=str(Path(__file__).parent.parent)' 'cwd=os.getcwd()' \
                --replace-fail '"main.py"' 'str(Path(__file__).parent.parent / "main.py")'
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
                --prefix PATH : ${
                  lib.makeBinPath [
                    pythonEnv
                    pkgs.ffmpeg
                  ]
                } \
                --prefix PYTHONPATH : "$out/lib/${pname}"

              ln -s $out/bin/reddit-universal-scraper $out/bin/reddit-scraper

              runHook postInstall
            '';

            doInstallCheck = true;
            installCheckPhase = ''
              runHook preInstallCheck
              export HOME="$TMPDIR/scraper-home"
              export XDG_DATA_HOME="$TMPDIR/scraper-state/nested"
              mkdir -p "$HOME"
              $out/bin/reddit-universal-scraper --help > /dev/null
              test -d "$XDG_DATA_HOME/reddit-universal-scraper"
              test ! -e "$out/lib/reddit-universal-scraper/data"
              unset XDG_DATA_HOME
              $out/bin/reddit-universal-scraper --help > /dev/null
              test -d "$HOME/.local/share/reddit-universal-scraper"
              PYTHONPYCACHEPREFIX="$TMPDIR/pycache" ${pythonEnv}/bin/python \
                -m py_compile "$out/lib/reddit-universal-scraper/dashboard/app.py"
              runHook postInstallCheck
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
