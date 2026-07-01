{
  description = "polymarket-cli - Polymarket's official command-line interface (prebuilt release binaries)";

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

        # Version table: consumers select the latest OR any past version.
        # New entries are appended by scripts/update-version.sh via jq — do
        # NOT hand-edit the version data in this file.
        releases = builtins.fromJSON (builtins.readFile ./releases.json);

        # Map each nix system onto the Rust target triple used in the upstream
        # release asset names.
        rustTripleBySystem = {
          x86_64-linux = "x86_64-unknown-linux-gnu";
          aarch64-linux = "aarch64-unknown-linux-gnu";
        };

        rustTriple = rustTripleBySystem.${system};

        # Builder: derive a polymarket-cli package from one releases.json entry.
        mk =
          key: entry:
          let
            version = entry.version;
            binarySha256 = entry.hashes.${system};
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "polymarket-cli";
            inherit version;

            meta = with lib; {
              description = "Polymarket's official command-line interface";
              longDescription = ''
                polymarket-cli is Polymarket's official Rust command-line
                interface for interacting with the Polymarket prediction
                markets.

                This package installs Polymarket's prebuilt release binary and
                keeps updates pinned through the flake's JSON version table
                rather than building from source.
              '';
              homepage = "https://github.com/Polymarket/polymarket-cli";
              mainProgram = "polymarket";
              platforms = linuxSystems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/Polymarket/polymarket-cli/releases/download/v${version}/polymarket-v${version}-${rustTriple}.tar.gz";
              sha256 = binarySha256;
            };

            # The release tarball contains a single loose `polymarket` binary at
            # its root (no top-level directory), so extract it manually in the
            # install phase instead of relying on the default unpack/setSourceRoot.
            dontUnpack = true;
            dontBuild = true;
            dontConfigure = true;

            nativeBuildInputs = with pkgs; [
              autoPatchelfHook
              makeWrapper
              gnutar
              gzip
            ];

            # Dynamic GNU binary: autoPatchelfHook rewrites the interpreter and
            # RPATH. libgcc_s comes from the compiler runtime; glibc (libc/libm)
            # is supplied automatically.
            buildInputs = [
              pkgs.stdenv.cc.cc.lib
            ];

            installPhase = ''
              runHook preInstall

              mkdir -p $out/bin
              tar -xzf "$src"
              install -m755 polymarket $out/bin/polymarket

              runHook postInstall
            '';

            dontStrip = true;
          };

        # Sanitize a JSON key into a valid attribute-name suffix.
        sanitizeKey = key: builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] key;

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `polymarket-cli_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "polymarket-cli_${sanitizeKey key}" (mk key entry)
        ) releases.versions;

      in
      {
        packages = {
          default = latestPkg;
          polymarket-cli = latestPkg;
        } // versionPackages;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            curl
            wget
            jq
            git
          ];

          shellHook = ''
            echo "-----------------------------------------------"
            echo "  polymarket-cli Development Shell"
            echo "-----------------------------------------------"
            echo ""
            echo "Environment:"
            echo "  system:   ${system}"
            echo "  jq:       $(jq --version)"
            echo "  git:      $(git --version)"
            echo ""
            echo "Commands:"
            echo "  nix build .#polymarket-cli"
            echo "  ./result/bin/polymarket --version"
            echo "  ./scripts/update-version.sh --check"
            echo "-----------------------------------------------"
          '';
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/polymarket";
          };
          polymarket = {
            type = "app";
            program = "${latestPkg}/bin/polymarket";
          };
          polymarket-cli = {
            type = "app";
            program = "${latestPkg}/bin/polymarket";
          };
        };
      }
    );
}
