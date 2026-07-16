{
  description = "xurl - a curl-like CLI tool for the X API";

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

        # Prebuilt release asset name per system (stable across versions).
        assetBySystem = {
          "aarch64-linux" = "xurl_Linux_arm64.tar.gz";
          "x86_64-linux" = "xurl_Linux_x86_64.tar.gz";
          "aarch64-darwin" = "xurl_Darwin_arm64.tar.gz";
          "x86_64-darwin" = "xurl_Darwin_x86_64.tar.gz";
        };

        # Builder: derive an xurl package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/rev/hash
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            asset = assetBySystem.${system} or (throw "Unsupported system for xurl flake: ${system}");
            sha256 =
              entry.hashes.${system} or (throw "Missing hash for system ${system} in xurl release ${key}");
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "xurl";
            inherit version;

            meta = with lib; {
              description = "Official curl-like CLI for the X (Twitter) API";
              homepage = "https://github.com/xdevplatform/xurl";
              license = licenses.mit;
              mainProgram = "xurl";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/xdevplatform/xurl/releases/download/${entry.rev}/${asset}";
              hash = sha256;
            };

            sourceRoot = ".";
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;
            dontPatchELF = true;

            installPhase = ''
              runHook preInstall
              install -m755 -D xurl $out/bin/xurl
              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `xurl_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "xurl_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          xurl = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/xurl";
          };
          xurl = {
            type = "app";
            program = "${latestPkg}/bin/xurl";
          };
        };
      }
    );
}
