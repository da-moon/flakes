{
  description = "Dashlane CLI - access your secrets from the terminal";

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

      supportedSystems = [
        "x86_64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
    in
    flake-utils.lib.eachSystem supportedSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        # Map nix system -> Dashlane release-asset file name. Dashlane ships
        # prebuilt pkg executables as raw per-target binaries named dcli-<target>.
        assetBySystem = {
          "x86_64-linux" = "dcli-linux-x64";
          "aarch64-darwin" = "dcli-macos-arm64";
          "x86_64-darwin" = "dcli-macos-x64";
        };

        # Builder: derive a dashlane-cli package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/hash now come
        # from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            asset = assetBySystem.${system};
            sha256 = entry.hashes.${system};

            meta = with lib; {
              description = "Dashlane CLI - access your secrets in your terminal, servers and CI/CD";
              longDescription = ''
                The Dashlane CLI lets you interact with your Dashlane vault from the
                terminal. You can read passwords, secure notes, and OTPs, inject
                secrets into CI/CD pipelines, and manage your Dashlane Business
                account programmatically.
              '';
              homepage = "https://github.com/Dashlane/dashlane-cli";
              license = licenses.asl20;
              mainProgram = "dcli";
              platforms = supportedSystems;
              maintainers = [ ];
            };

            # Raw prebuilt asset. It is kept unchanged (no ELF patching) because
            # pkg executables append a compressed Node snapshot at the end of the
            # file; rewriting the ELF rpath/interpreter corrupts that snapshot.
            unwrapped = pkgs.stdenv.mkDerivation {
              pname = "dashlane-cli-unwrapped";
              inherit version meta;

              src = pkgs.fetchurl {
                url = "https://github.com/Dashlane/dashlane-cli/releases/download/v${version}/${asset}";
                inherit sha256;
              };

              dontUnpack = true;
              dontBuild = true;
              dontConfigure = true;
              dontStrip = true;

              installPhase = ''
                runHook preInstall
                install -m755 -D "$src" "$out/bin/dcli"
                runHook postInstall
              '';
            };
          in
          if pkgs.stdenv.hostPlatform.isLinux then
            # Run the unpatched Linux binary inside an FHS environment so the
            # bundled Node interpreter finds a standard /lib64/ld-linux and the
            # C++ runtime it expects, without modifying the pkg executable.
            let
              fhs = pkgs.buildFHSEnv {
                name = "dcli";
                inherit meta;

                targetPkgs = pkgs: [ pkgs.stdenv.cc.cc.lib ];
                runScript = "${unwrapped}/bin/dcli";
              };
            in
            pkgs.runCommand "dashlane-cli-${version}" {
              inherit version meta;
            } ''
              runHook preInstall
              mkdir -p "$out/bin"
              ln -s "${fhs}/bin/dcli" "$out/bin/dcli"
              runHook postInstall
            ''
          else
            pkgs.stdenv.mkDerivation {
              pname = "dashlane-cli";
              inherit version meta;

              dontUnpack = true;
              dontBuild = true;
              dontConfigure = true;
              dontStrip = true;

              installPhase = ''
                runHook preInstall
                install -m755 -D "${unwrapped}/bin/dcli" "$out/bin/dcli"
                runHook postInstall
              '';
            };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `dashlane-cli_<sanitized-key>` package per entry in the table.
        versionedPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "dashlane-cli_${sanitize key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          dashlane-cli = latestPkg;
        } // versionedPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/dcli";
          };
          dashlane-cli = {
            type = "app";
            program = "${latestPkg}/bin/dcli";
          };
        };
      }
    );
}
