{
  description = "HoneClaw CLI packaged as a Nix flake";

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
        lib = pkgs.lib;

        releaseBySystem = {
          "x86_64-linux" = {
            asset = "honeclaw-linux-x86_64.tar.gz";
            target = "x86_64-unknown-linux-gnu";
          };
          "x86_64-darwin" = {
            asset = "honeclaw-darwin-x86_64.tar.gz";
            target = "x86_64-apple-darwin";
          };
          "aarch64-darwin" = {
            asset = "honeclaw-darwin-aarch64.tar.gz";
            target = "aarch64-apple-darwin";
          };
        };

        # Builder: derive a honeclaw package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src-url/hash
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            release = releaseBySystem.${system};
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "honeclaw";
            inherit version;

            meta = with lib; {
              description = "HoneClaw (Hone-Financial) is dedicated to being a professional investment assistant that truly understands you.";
              homepage = "https://github.com/B-M-Capital-Research/honeclaw";
              mainProgram = "hone-cli";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/B-M-Capital-Research/honeclaw/releases/download/v${version}/${release.asset}";
              hash = entry.hashes.${system};
            };

            sourceRoot = "honeclaw-v${version}-${release.target}";
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;

            nativeBuildInputs = [
              pkgs.makeWrapper
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.autoPatchelfHook
            ];
            buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.openssl
              (lib.getLib pkgs.stdenv.cc.cc)
            ];

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/honeclaw $out/bin
              cp -R . $out/lib/honeclaw/

              for bin in hone-cli hone-mcp hone-imessage hone-telegram hone-discord hone-feishu hone-console-page; do
                makeWrapper "$out/lib/honeclaw/bin/$bin" "$out/bin/$bin" \
                  --set HONE_INSTALL_ROOT "$out/lib/honeclaw" \
                  --set HONE_SKILLS_DIR "$out/lib/honeclaw/share/honeclaw/skills" \
                  --set HONE_WEB_DIST_DIR "$out/lib/honeclaw/share/honeclaw/web"
              done

              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `honeclaw_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "honeclaw_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          honeclaw = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/hone-cli";
          };
          hone-cli = {
            type = "app";
            program = "${latestPkg}/bin/hone-cli";
          };
          hone-mcp = {
            type = "app";
            program = "${latestPkg}/bin/hone-mcp";
          };
        };
      }
    );
}
