{
  description = "amber-lsp - Amber's Language Server Protocol";

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
      # Upstream publishes prebuilt tarballs for these targets only — there is
      # NO aarch64-linux release asset, so it is intentionally absent here.
      systems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Map a nix system to the upstream release-asset target triple.
        # Linux uses the musl tarball: static-pie linked, so it runs on any
        # distro without patchelf.
        releaseTargetBySystem = {
          "x86_64-linux" = "x86_64-unknown-linux-musl";
          "x86_64-darwin" = "x86_64-apple-darwin";
          "aarch64-darwin" = "aarch64-apple-darwin";
        };

        # Builder: derive an amber-lsp package from one releases.json entry.
        # Only version/src-url/hash come from `entry`; the install logic is
        # fixed.
        mk =
          key: entry:
          let
            version = entry.version;
            target = releaseTargetBySystem.${system};
            binarySha256 = entry.hashes.${system} or (throw "Missing hashes entry for system: ${system}");
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "amber-lsp";
            inherit version;

            meta = with pkgs.lib; {
              description = "Amber's Language Server Protocol";
              longDescription = ''
                Language Server Protocol implementation for the Amber
                programming language. Provides diagnostics, completions and
                other editor integrations for .ab source files.
              '';
              homepage = "https://github.com/amber-lang/amber-lsp";
              license = licenses.gpl3Only;
              platforms = systems;
              mainProgram = "amber-lsp";
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/amber-lang/amber-lsp/releases/download/v${version}/amber-lsp-${target}.tar.gz";
              sha256 = binarySha256;
            };

            sourceRoot = "amber-lsp-${target}";

            # No build needed - precompiled binary
            dontBuild = true;
            dontConfigure = true;

            installPhase = ''
              runHook preInstall
              install -m755 -D amber-lsp $out/bin/amber-lsp
              runHook postInstall
            '';

            # Don't strip: keep the shipped binary byte-for-byte unchanged.
            dontStrip = true;
          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `amber-lsp_<sanitized-key>` package per entry in the table.
        versionedPackages = builtins.listToAttrs (
          builtins.map (key: {
            name = "amber-lsp_${sanitize key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
        );

      in
      {
        packages = versionedPackages // {
          default = latestPkg;
          amber-lsp = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/amber-lsp";
          };
          amber-lsp = {
            type = "app";
            program = "${latestPkg}/bin/amber-lsp";
          };
        };
      }
    );
}
