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
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Linux ships a ready-to-flatten bundle. Darwin's package archive has
        # the same binaries under bin/ plus signed native resources.
        releaseBySystem = {
          "aarch64-linux" = {
            asset = "codex-aarch64-unknown-linux-musl-bundle.tar.zst";
            packageLayout = false;
          };
          "x86_64-linux" = {
            asset = "codex-x86_64-unknown-linux-musl-bundle.tar.zst";
            packageLayout = false;
          };
          "aarch64-darwin" = {
            asset = "codex-package-aarch64-apple-darwin.tar.gz";
            packageLayout = true;
          };
          "x86_64-darwin" = {
            asset = "codex-package-x86_64-apple-darwin.tar.gz";
            packageLayout = true;
          };
        };

        release = releaseBySystem.${system};

        # Builder: derive a codex package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src-url/hash
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            sha256 = entry.hashes.${system};
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
              platforms = systems;
              mainProgram = "codex";
              maintainers = [ ];
            };

            # The `-bundle` asset carries the sidecars the CLI expects to find
            # beside itself; the plain codex-*.tar.gz ships only `codex`.
            src = pkgs.fetchurl {
              url = "https://github.com/openai/codex/releases/download/rust-v${version}/${release.asset}";
              inherit sha256;
            };

            nativeBuildInputs = [ pkgs.zstd ];

            sourceRoot = ".";

            # No build needed - precompiled binary
            dontBuild = true;
            dontConfigure = true;

            # codex resolves `codex-code-mode-host` and `codex-resources/bwrap`
            # relative to the realpath of its own executable, so both must sit
            # next to $out/bin/codex.
            installPhase = ''
              runHook preInstall
              ${
                if release.packageLayout then
                  ''
                    install -m755 -D bin/codex $out/bin/codex
                    install -m755 -D bin/codex-code-mode-host $out/bin/codex-code-mode-host
                    cp -R codex-resources $out/bin/codex-resources
                  ''
                else
                  ''
                    install -m755 -D codex $out/bin/codex
                    install -m755 -D codex-code-mode-host $out/bin/codex-code-mode-host
                    cp -R codex-resources $out/bin/codex-resources
                  ''
              }
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
