{
  description = "Hermes Agent - Python AI agent CLI and gateway";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    pyproject-nix,
    uv2nix,
    pyproject-build-systems,
  }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;

        pname = "hermes-agent";
        version = "0.1.0";
        revision = "ab0f4126cf978df89be7bf6213e13a304d9b6ba8";

        sourceHashBySystem = {
          "aarch64-linux" = "sha256-hH7VWMiavpE6YzIjWBIidKUDrybAyrOo0PUP3btDtFo=";
          "x86_64-linux" = "sha256-hH7VWMiavpE6YzIjWBIidKUDrybAyrOo0PUP3btDtFo=";
        };

        supportedExtras = [
          "cli"
          "cron"
          "mcp"
          "messaging"
          "pty"
        ];

        source =
          let
            sourceArchive = pkgs.fetchurl {
              url = "https://github.com/NousResearch/hermes-agent/archive/${revision}.tar.gz";
              hash = sourceHashBySystem.${system} or (throw "Missing source hash for system ${system}");
            };
          in
          pkgs.runCommand "${pname}-source-${version}-${lib.substring 0 7 revision}" { } ''
            mkdir -p "$out"
            tar -xzf ${sourceArchive} --strip-components=1 -C "$out"
          '';

        hermes-agent =
          let
            inherit (pkgs)
              callPackage
              makeWrapper
              python311
              stdenvNoCC
              ;

            python = python311;
            workspace = uv2nix.lib.workspace.loadWorkspace {
              workspaceRoot = source;
            };
            overlay = workspace.mkPyprojectOverlay {
              sourcePreference = "wheel";
              dependencies = {
                hermes-agent = supportedExtras;
              };
            };
            pythonSet = (callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
              lib.composeManyExtensions [
                pyproject-build-systems.overlays.wheel
                overlay
              ]
            );
            hermesEnv = pythonSet.mkVirtualEnv "${pname}-virtual-env-${version}" {
              hermes-agent = supportedExtras;
            };
            runtimeTools = with pkgs; [
              bash
              coreutils
              curl
              diffutils
              findutils
              gawk
              git
              gnugrep
              gnused
              jq
              less
              openssh
              procps
              ripgrep
              rsync
              util-linux
              which
            ];
          in
          stdenvNoCC.mkDerivation {
            inherit pname version;
            dontUnpack = true;

            nativeBuildInputs = [ makeWrapper ];

            installPhase = ''
              runHook preInstall

              mkdir -p "$out/bin" "$out/share/hermes-agent"
              cp -rf ${source}/. "$out/share/hermes-agent"
              chmod -R u+w "$out/share/hermes-agent"

              ${python.interpreter} - <<PY
              from pathlib import Path

              root = Path("$out/share/hermes-agent")

              main_py = root / "hermes_cli" / "main.py"
              main_text = main_py.read_text()
              main_old = 'def cmd_update(args):\n    """Update Hermes Agent to the latest version."""\n'
              main_new = (
                  'def cmd_update(args):\n'
                  '    """Update Hermes Agent to the latest version."""\n'
                  '    print("✗ Update is disabled in the Nix package. Update the flake input or package revision instead.")\n'
                  '    return\n\n'
              )
              if main_old not in main_text:
                  raise SystemExit(f"Failed to locate cmd_update in {main_py}")
              main_py.write_text(main_text.replace(main_old, main_new, 1))

              whatsapp_py = root / "gateway" / "platforms" / "whatsapp.py"
              whatsapp_text = whatsapp_py.read_text()
              whatsapp_old = '''        # Auto-install npm dependencies if node_modules doesn't exist
              bridge_dir = bridge_path.parent
              if not (bridge_dir / "node_modules").exists():
                  print(f"[{self.name}] Installing WhatsApp bridge dependencies...")
                  try:
                      install_result = subprocess.run(
                          ["npm", "install", "--silent"],
                          cwd=str(bridge_dir),
                          capture_output=True,
                          text=True,
                          timeout=60,
                      )
                      if install_result.returncode != 0:
                          print(f"[{self.name}] npm install failed: {install_result.stderr}")
                          return False
                      print(f"[{self.name}] Dependencies installed")
                  except Exception as e:
                      print(f"[{self.name}] Failed to install dependencies: {e}")
                      return False
              '''
              whatsapp_new = '''        # WhatsApp bridge dependencies must be packaged ahead of time under Nix.
              bridge_dir = bridge_path.parent
              if not (bridge_dir / "node_modules").exists():
                  logger.warning("[%s] WhatsApp bridge dependencies are not packaged. Configure a prebuilt bridge instead.", self.name)
                  return False
              '''
              if whatsapp_old not in whatsapp_text:
                  raise SystemExit(f"Failed to locate WhatsApp bridge install block in {whatsapp_py}")
              whatsapp_py.write_text(whatsapp_text.replace(whatsapp_old, whatsapp_new, 1))
              PY

              makeWrapper ${hermesEnv}/bin/python "$out/bin/hermes" \
                --prefix PATH : ${lib.makeBinPath runtimeTools} \
                --prefix PYTHONPATH : "$out/share/hermes-agent" \
                --set HERMES_AGENT_NIX_MANAGED "1" \
                --add-flags "-m hermes_cli.main"

              makeWrapper ${hermesEnv}/bin/python "$out/bin/hermes-agent" \
                --prefix PATH : ${lib.makeBinPath runtimeTools} \
                --prefix PYTHONPATH : "$out/share/hermes-agent" \
                --set HERMES_AGENT_NIX_MANAGED "1" \
                --add-flags "-m run_agent"

              runHook postInstall
            '';

            doInstallCheck = true;
            installCheckPhase = ''
              runHook preInstallCheck

              export HOME="$(mktemp -d)"
              "$out/bin/hermes" --help >/dev/null
              "$out/bin/hermes" version >/dev/null
              "$out/bin/hermes" gateway --help >/dev/null

              runHook postInstallCheck
            '';

            meta = with lib; {
              description = "Hermes Agent CLI and gateway packaged for Nix";
              homepage = "https://github.com/NousResearch/hermes-agent";
              license = licenses.mit;
              mainProgram = "hermes";
              platforms = [ "aarch64-linux" "x86_64-linux" ];
              sourceProvenance = with sourceTypes; [ fromSource ];
            };
          };
      in
      {
        packages = {
          default = hermes-agent;
          inherit hermes-agent;
        };

        apps = {
          default = {
            type = "app";
            program = "${hermes-agent}/bin/hermes";
          };
          hermes = {
            type = "app";
            program = "${hermes-agent}/bin/hermes";
          };
          hermes-agent = {
            type = "app";
            program = "${hermes-agent}/bin/hermes-agent";
          };
        };
      }
    );
}
