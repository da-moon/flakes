{
  description = "fzf-tab-completion - Tab completion using fzf for bash, zsh and readline applications";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Builder: derive a fzf-tab-completion package from one releases.json
        # entry. PRESERVES the original build logic exactly; only
        # version/rev/hash now come from `entry`.
        mk =
          key: entry:
          pkgs.stdenv.mkDerivation rec {
            pname = "fzf-tab-completion";
            version = entry.version;

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

            src = pkgs.fetchFromGitHub {
              owner = "lincheney";
              repo = "fzf-tab-completion";
              rev = entry.rev;
              sha256 = entry.hash;
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

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `fzf-tab-completion_<sanitized-key>` package per entry.
        versionedPackages = builtins.listToAttrs (
          builtins.map (key: {
            name = "fzf-tab-completion_${sanitize key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
        );

      in
      {
        packages = versionedPackages // {
          default = latestPkg;
          fzf-tab-completion = latestPkg;
        };
      }
    );
}

# vim: ft=nix
