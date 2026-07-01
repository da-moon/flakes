{
  description = "OpenAI Codex CLI - AI coding assistant";

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
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Architecture-specific asset naming (musl release tarballs).
        archBySystem = {
          "aarch64-linux" = "aarch64";
          "x86_64-linux" = "x86_64";
        };

        # Get arch for current system, fallback to x86_64 if unknown
        currentArch = archBySystem.${system} or "x86_64";

        # Builder: derive a codex package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src-url/hash
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            sha256 = entry.hashes.${system} or entry.hashes."x86_64-linux";
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "codex";
            inherit version;

            meta = with pkgs.lib; {
              description = "OpenAI Codex CLI - AI coding assistant for terminal";
              longDescription = ''
                Codex is a lightweight coding agent that runs in your terminal.
                It can read and modify files, execute commands, search the web,
                and help you with various coding tasks through natural language.
              '';
              homepage = "https://github.com/openai/codex";
              platforms = [ "aarch64-linux" "x86_64-linux" ];
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-${currentArch}-unknown-linux-musl.tar.gz";
              inherit sha256;
            };

            sourceRoot = ".";

            # No build needed - precompiled binary
            dontBuild = true;
            dontConfigure = true;

            installPhase = ''
              runHook preInstall
              install -m755 -D codex-${currentArch}-unknown-linux-musl $out/bin/codex
              runHook postInstall
            '';

            # Don't try to patch static musl binary
            dontStrip = true;
            dontPatchELF = true;

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `codex_<sanitized-key>` package per entry in the table.
        versionPackages = builtins.listToAttrs (
          builtins.map (key: {
            name = "codex_${sanitizeKey key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
        );

      in
      {
        packages = versionPackages // {
          default = latestPkg;
          codex = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/codex";
          };
          codex = {
            type = "app";
            program = "${latestPkg}/bin/codex";
          };
        };
      }
    );
}
