{
  description = "fzf-tab-completion - Tab completion using fzf for bash, zsh and readline applications";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        fzf-tab-completion = pkgs.stdenv.mkDerivation rec {
          pname = "fzf-tab-completion";
          version = "unstable-2026-04-05";

          src = pkgs.fetchFromGitHub {
            owner = "lincheney";
            repo = "fzf-tab-completion";
            rev = "8ba35e65bb3792759bf17c134ce04120e5940555";
            sha256 = "sha256-qod3C01EK5S0Tm6rp2ia0dPVFMKRGaozpNaLQF+O9Xw=";
          };

          dontBuild = true;
          dontConfigure = true;

          installPhase = ''
            runHook preInstall

            # Create output directory
            mkdir -p $out/share/fzf-tab-completion

            # Copy all shell integration files
            cp -r bash $out/share/fzf-tab-completion/
            cp -r zsh $out/share/fzf-tab-completion/
            cp -r readline $out/share/fzf-tab-completion/
            cp -r python $out/share/fzf-tab-completion/
            cp -r node $out/share/fzf-tab-completion/

            # Copy documentation
            cp README.md $out/share/fzf-tab-completion/ || true
            cp LICENSE $out/share/fzf-tab-completion/ || true

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Tab completion using fzf for bash, zsh and readline applications";
            longDescription = ''
              fzf-tab-completion provides fuzzy tab completion for bash and zsh shells,
              as well as for readline-based applications like python REPL, php -a, etc.
              It integrates seamlessly with existing completion systems.
            '';
            homepage = "https://github.com/lincheney/fzf-tab-completion";
            license = licenses.gpl3;
            platforms = platforms.unix;
          };
        };

      in
      {
        packages = {
          default = fzf-tab-completion;
          fzf-tab-completion = fzf-tab-completion;
        };
      }
    );
}

# vim: ft=nix
