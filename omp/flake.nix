{
  description = "omp - AI coding agent CLI packaged from GitHub releases, with Home Manager and NixOS modules";

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

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Hard schema contract (command-code convention): the committed upstream
      # settings-registry evidence, the reviewed Nix defaults, and the latest
      # releases.json entry must all agree, or evaluation throws. Bump-time
      # workflow lives in scripts/update-version.sh (extract -> classify
      # drift -> record).
      latestRelease = releases.versions.${releases.latest};
      defaults = import ./modules/defaults.nix { };
      uncheckedConfigSchema = builtins.fromJSON (builtins.readFile ./schema/upstream.json);
      recordedSchemaHash = nixpkgs.lib.removeSuffix "\n" (builtins.readFile ./schema/upstream.sha256);
      upstreamConfigSchema =
        if uncheckedConfigSchema.package.version != latestRelease.version then
          throw "omp schema artifact version does not match releases.json"
        else if defaults.schemaVersion != latestRelease.version then
          throw "omp Nix schema version does not match releases.json"
        else if recordedSchemaHash != (latestRelease.schemaSha256 or "") then
          throw "omp schema hash does not match releases.json"
        else
          uncheckedConfigSchema;

      # Flatten nested settings attrsets to dotted-path entries (empty
      # attrsets are leaves: they are record-valued settings).
      flattenSettings =
        prefix: attrs:
        builtins.concatLists (
          map (
            k:
            let
              v = attrs.${k};
              p = if prefix == "" then k else "${prefix}.${k}";
            in
            if builtins.isAttrs v && v != { } then flattenSettings p v else [ { key = p; value = v; } ]
          ) (builtins.attrNames attrs)
        );

      # Overlay consumed by other flakes that want `omp` in nixpkgs.
      overlay = final: prev: {
        omp =
          self.packages.${prev.stdenv.hostPlatform.system}.omp
            or (self.packages.${prev.stdenv.hostPlatform.system}.default);
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

        releasePlatformBySystem = {
          x86_64-linux = "linux-x64";
          aarch64-linux = "linux-arm64";
          x86_64-darwin = "darwin-x64";
          aarch64-darwin = "darwin-arm64";
        };

        releasePlatform = releasePlatformBySystem.${system};

        # Builder: derive an omp package from one releases.json entry.
        mk =
          key: entry:
          let
            version = entry.version;
            binarySha256 = entry.hashes.${system};
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "omp";
            inherit version;

            meta = with lib; {
              description = "omp - AI coding agent CLI";
              homepage = "https://github.com/can1357/oh-my-pi";
              license = licenses.mit;
              mainProgram = "omp";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/can1357/oh-my-pi/releases/download/v${version}/omp-${releasePlatform}";
              sha256 = binarySha256;
            };

            dontUnpack = true;
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;

            nativeBuildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.autoPatchelfHook
            ];

            buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.stdenv.cc.cc.lib
            ];

            installPhase = ''
              runHook preInstall

              mkdir -p $out/bin
              install -m755 $src $out/bin/omp

              runHook postInstall
            '';
          };

        # Sanitize a JSON key into a valid attribute-name suffix.
        sanitizeKey = key: builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ] key;

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `omp_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "omp_${sanitizeKey key}" (mk key entry)
        ) releases.versions;

        defaultsJson = pkgs.writeText "omp-defaults-flat.json" (
          builtins.toJSON (flattenSettings "" defaults.defaultSettings)
        );

        # Hard schema-artifact check: re-extract the settings registry from
        # the built binary, byte-compare it with the committed evidence, and
        # cross-check every key modules/defaults.nix manages against it
        # (existence, type, enum membership). Fails when upstream removes or
        # renames a setting the flake still writes.
        schemaArtifactCheck =
          pkgs.runCommand "omp-schema-artifact-check"
            { nativeBuildInputs = [ pkgs.nodejs ]; }
            ''
              node ${./scripts/extract-config-schema.mjs} \
                --binary ${latestPkg}/bin/omp \
                --version ${lib.escapeShellArg upstreamConfigSchema.package.version} \
                --output candidate.json \
                --hash-output candidate.sha256
              diff -u ${./schema/upstream.json} candidate.json
              diff -u ${./schema/upstream.sha256} candidate.sha256
              node ${./scripts/verify-config-schema.mjs} \
                --schema ${./schema/upstream.json} \
                --hash ${./schema/upstream.sha256} \
                --expected-version ${lib.escapeShellArg upstreamConfigSchema.package.version} \
                --expected-sha256 ${lib.escapeShellArg latestRelease.schemaSha256} \
                --defaults ${defaultsJson} \
                > "$out"
              test -x ${latestPkg}/bin/omp
            '';

      in
      {
        packages = {
          default = latestPkg;
          omp = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/omp";
          };
          omp = {
            type = "app";
            program = "${latestPkg}/bin/omp";
          };
        };

        checks = {
          schema-artifact = schemaArtifactCheck;
        };
      }
    )
    // {
      overlays.default = overlay;

      homeManagerModules.default = ./modules/home-manager.nix;
      nixosModules.default = ./modules/nixos.nix;

      lib = {
        inherit upstreamConfigSchema;
      };
    };
}
