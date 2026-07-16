{
  description = "polymarket-cli - Polymarket's official command-line interface (prebuilt release binaries)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # Portable config-file generator, exposed at the flake's top-level `lib`
      # output so ANY consumer (any system) can render a polymarket config.json
      # from a plain attrset. Non-secret use only — never pass private_key here
      # if the result will land in the Nix store.
      #
      #   polymarket-cli.lib.mkConfig {
      #     inherit pkgs;
      #     settings = { chain_id = 137; signature_type = "proxy"; };
      #   }
      mkConfig =
        { pkgs, settings }:
        (pkgs.formats.json { }).generate "polymarket-config.json" settings;

      # home-manager module: programs.polymarket-cli.
      #
      # The CLI reads a HARDCODED path ~/.config/polymarket/config.json (no
      # --config / XDG override). config.rs writes it mode 0600 inside a 0700
      # dir. The wallet private key is a SECRET, so it must never enter the
      # /nix/store: we render only the non-secret fields into the store and
      # merge the key in IMPERATIVELY at activation time.
      homeManagerModule =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.polymarket-cli;
          # Non-secret portion is safe to materialise in the store.
          nonSecretConfig = mkConfig {
            inherit pkgs;
            settings = cfg.settings;
          };
          keyPath = lib.escapeShellArg (toString cfg.privateKeyFile);
        in
        {
          options.programs.polymarket-cli = {
            enable = lib.mkEnableOption "polymarket-cli, Polymarket's official command-line interface";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
              defaultText = lib.literalExpression "inputs.polymarket-cli.packages.\${pkgs.stdenv.hostPlatform.system}.default";
              description = "The polymarket-cli package to use.";
            };

            settings = lib.mkOption {
              type = (pkgs.formats.json { }).type;
              default = { };
              example = lib.literalExpression ''{ chain_id = 137; signature_type = "proxy"; }'';
              description = ''
                NON-SECRET fields written to ~/.config/polymarket/config.json
                (e.g. chain_id, signature_type). Do NOT set private_key here —
                use `privateKeyFile` so the wallet key never enters the Nix
                store.
              '';
            };

            privateKeyFile = lib.mkOption {
              type = lib.types.nullOr (lib.types.either lib.types.str lib.types.path);
              default = null;
              example = "/run/secrets/polymarket-private-key";
              description = ''
                Path to a file containing the wallet private key. It is read at
                home-manager activation time and merged into config.json; it is
                never copied into the Nix store. When null, only the non-secret
                settings are written and the key can instead be supplied via the
                POLYMARKET_PRIVATE_KEY environment variable or
                `polymarket wallet import`.
              '';
            };
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ cfg.package ];

            # config.rs's `Config` requires BOTH private_key and chain_id (only
            # signature_type has a serde default), so a config.json is VALID only
            # when it carries a key. We therefore write it ONLY when
            # privateKeyFile is set; with no key the binary is installed and the
            # key/chain are supplied via `polymarket wallet import` or the
            # POLYMARKET_PRIVATE_KEY env var. Writing a keyless config would
            # produce a file the CLI fails to parse, so we don't.
            assertions = [
              {
                assertion = cfg.privateKeyFile == null || (cfg.settings ? chain_id);
                message = "programs.polymarket-cli: settings.chain_id must be set when privateKeyFile is used (config.rs requires chain_id).";
              }
            ];

            # Secret merged in imperatively at activation and never symlinked from
            # the store. Only runs when a key file is configured.
            home.activation.polymarketConfig = lib.mkIf (cfg.privateKeyFile != null) (
              lib.hm.dag.entryAfter [ "writeBoundary" ] ''
                _pmDir="$HOME/.config/polymarket"
                _pmFile="$_pmDir/config.json"
                if [ -r ${keyPath} ]; then
                  $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -d -m700 "$_pmDir"
                  _pmTmp="$(${pkgs.coreutils}/bin/mktemp)"
                  ${pkgs.jq}/bin/jq --rawfile pk ${keyPath} \
                    '. + { private_key: ($pk | sub("[[:space:]]+$"; "")) }' \
                    ${nonSecretConfig} > "$_pmTmp"
                  $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -m600 "$_pmTmp" "$_pmFile"
                  ${pkgs.coreutils}/bin/rm -f "$_pmTmp"
                else
                  echo "polymarket-cli: privateKeyFile (${toString cfg.privateKeyFile}) is not readable; leaving config.json untouched" >&2
                fi
              ''
            );
          };
        };
    in
    flake-utils.lib.eachSystem systems (
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
          x86_64-darwin = "x86_64-apple-darwin";
          aarch64-darwin = "aarch64-apple-darwin";
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
              platforms = systems;
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

            nativeBuildInputs = [
              pkgs.gnutar
              pkgs.gzip
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.autoPatchelfHook
            ];

            # Dynamic GNU binary: autoPatchelfHook rewrites the interpreter and
            # RPATH. libgcc_s comes from the compiler runtime; glibc (libc/libm)
            # is supplied automatically.
            buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
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
        }
        // versionPackages;

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
    )
    // {
      # Portable, non-per-system helpers.
      lib = {
        inherit mkConfig;
      };

      homeManagerModules = {
        default = homeManagerModule;
        polymarket-cli = homeManagerModule;
      };
    };
}
