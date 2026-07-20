{
  description = "Plano - AI-native proxy server and data plane for agentic apps";

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
      # Upstream ships native binaries only for these three platforms; the
      # planoai CLI's native mode explicitly rejects macOS x86_64 (Intel).
      systems = [
        "x86_64-linux"
        "aarch64-linux"
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
        python = pkgs.python312;

        # Asset slug shared by katanemo/plano and tetratelabs/archive-envoy releases.
        slugBySystem = {
          x86_64-linux = "linux-amd64";
          aarch64-linux = "linux-arm64";
          aarch64-darwin = "darwin-arm64";
        };
        slug = slugBySystem.${system};

        # Builder: derive the plano parts (native runtime + Python CLI) from
        # one releases.json entry.
        mkParts =
          key: entry:
          let
            version = entry.version;
            rev = entry.rev;
            envoyVersion = entry.envoyVersion;

            # Native runtime: Envoy + brightstaff + the two proxy-wasm filters,
            # laid out exactly where planoai's native mode looks for cached
            # downloads ($PLANO_BIN_DIR, $PLANO_PLUGINS_DIR), including the
            # version-stamp files that keep the CLI from re-downloading them.
            plano-runtime = pkgs.stdenv.mkDerivation {
              pname = "plano-runtime";
              inherit version;

              meta = with lib; {
                description = "Plano native runtime (Envoy, brightstaff, proxy-wasm filters)";
                homepage = "https://github.com/katanemo/plano";
                license = licenses.asl20;
                platforms = systems;
              };

              # archive-envoy tarball; contains envoy-<ver>-<slug>/bin/envoy.
              src = pkgs.fetchurl {
                url = "https://github.com/tetratelabs/archive-envoy/releases/download/${envoyVersion}/envoy-${envoyVersion}-${slug}.tar.xz";
                sha256 = entry.envoyHashes.${system};
              };

              # Gzipped single files published on the katanemo/plano release.
              brightstaffGz = pkgs.fetchurl {
                url = "https://github.com/katanemo/plano/releases/download/${rev}/brightstaff-${slug}.gz";
                sha256 = entry.brightstaffHashes.${system};
              };
              promptGatewayGz = pkgs.fetchurl {
                url = "https://github.com/katanemo/plano/releases/download/${rev}/prompt_gateway.wasm.gz";
                sha256 = entry.wasmHashes.prompt_gateway;
              };
              llmGatewayGz = pkgs.fetchurl {
                url = "https://github.com/katanemo/plano/releases/download/${rev}/llm_gateway.wasm.gz";
                sha256 = entry.wasmHashes.llm_gateway;
              };

              sourceRoot = ".";

              nativeBuildInputs = [
                pkgs.gzip
              ]
              ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                pkgs.autoPatchelfHook
              ];

              buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                pkgs.stdenv.cc.cc.lib
                pkgs.openssl
              ];

              dontBuild = true;
              dontConfigure = true;

              installPhase = ''
                runHook preInstall

                mkdir -p $out/bin $out/plugins

                install -m755 -D */bin/envoy $out/bin/envoy
                printf '%s' '${envoyVersion}' > $out/bin/envoy.version

                gzip -dc $brightstaffGz > $out/bin/brightstaff
                chmod 755 $out/bin/brightstaff
                printf '%s' '${version}' > $out/bin/brightstaff.version

                gzip -dc $promptGatewayGz > $out/plugins/prompt_gateway.wasm
                gzip -dc $llmGatewayGz > $out/plugins/llm_gateway.wasm
                printf '%s' '${version}' > $out/plugins/wasm.version

                runHook postInstall
              '';
            };

            # The user-facing CLI (planoai on PyPI). Patched so its native-mode
            # cache directories point at the pinned runtime above instead of
            # ~/.plano, making `planoai up` fully nix-managed and offline.
            plano = python.pkgs.buildPythonApplication {
              pname = "plano";
              inherit version;

              meta = with lib; {
                description = "Plano - AI-native proxy server and data plane for agentic apps";
                longDescription = ''
                  Plano is an AI-native proxy server and data plane for agentic
                  apps: smart LLM routing, agent orchestration, guardrails, and
                  observability, built on Envoy.

                  This package wraps the planoai Python CLI and pins its native
                  runtime (Envoy, brightstaff, and the proxy-wasm filters) in
                  the nix store, so the CLI never downloads binaries at runtime.
                '';
                homepage = "https://github.com/katanemo/plano";
                license = licenses.asl20;
                mainProgram = "planoai";
                platforms = systems;
                maintainers = [ ];
              };

              format = "wheel";

              src = pkgs.fetchPypi {
                pname = "planoai";
                inherit version;
                format = "wheel";
                dist = "py3";
                python = "py3";
                hash = entry.wheelHash;
              };

              # Redirect the CLI's native-mode binary/plugin cache dirs from
              # ~/.plano to the pinned runtime in the nix store. The version
              # stamps there satisfy the CLI's cache checks, so it uses the
              # store paths as-is. Wheels are not unpacked before install, so
              # patch the installed module instead.
              postInstall = ''
                substituteInPlace $out/lib/python*/site-packages/planoai/consts.py \
                  --replace-fail 'PLANO_BIN_DIR = os.path.join(PLANO_HOME, "bin")' \
                                 'PLANO_BIN_DIR = "${plano-runtime}/bin"' \
                  --replace-fail 'PLANO_PLUGINS_DIR = os.path.join(PLANO_HOME, "plugins")' \
                                 'PLANO_PLUGINS_DIR = "${plano-runtime}/plugins"'
              '';

              propagatedBuildInputs = with python.pkgs; [
                click
                grpcio
                jinja2
                jsonschema
                opentelemetry-proto
                questionary
                pyyaml
                requests
                urllib3
                rich
                rich-click
              ];

              pythonImportsCheck = [ "planoai" ];
              doCheck = false;
            };
          in
          {
            inherit plano plano-runtime;
          };

        # Builder: derive the default (CLI) plano package from one entry.
        mk = key: entry: (mkParts key entry).plano;

        latestParts = mkParts releases.latest releases.versions.${releases.latest};
        latestPkg = latestParts.plano;

        # One `plano_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "plano_${sanitizeKey key}" (mk key entry)
        ) releases.versions;

      in
      {
        packages = {
          default = latestPkg;
          plano = latestPkg;
          plano-runtime = latestParts.plano-runtime;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/planoai";
          };
          plano = {
            type = "app";
            program = "${latestPkg}/bin/planoai";
          };
        };
      }
    );
}
