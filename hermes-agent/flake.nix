{
  description = "Hermes Agent - self-improving AI agent";

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
    nixpkgs,
    flake-utils,
    pyproject-nix,
    uv2nix,
    pyproject-build-systems,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pname = "hermes-agent";
        version = "unstable-2026-03-10";
        revision = "8eefbef91cd715cfe410bba8c13cfab4eb3040df";

        sourceHashBySystem = {
          "aarch64-linux" = "sha256-IDXGmhcUMwuA878cUppQufHOcum5efp6u3eXucUBPh4=";
          "x86_64-linux" = "sha256-IDXGmhcUMwuA878cUppQufHOcum5efp6u3eXucUBPh4=";
        };

        sourceRoot = pkgs.fetchFromGitHub {
          owner = "NousResearch";
          repo = "hermes-agent";
          rev = revision;
          hash = sourceHashBySystem.${system} or (throw "Missing source hash for system ${system}");
        };

        patchedSource = pkgs.runCommand "${pname}-source-${version}" { } ''
          cp -r ${sourceRoot} "$out"
          chmod -R u+w "$out"

          ${pkgs.perl}/bin/perl -0pi -e 's@# Path to tinker-atropos submodule \(relative to hermes-agent root\)\nHERMES_ROOT = Path\(__file__\)\.parent\.parent\nTINKER_ATROPOS_ROOT = HERMES_ROOT / "tinker-atropos"\nENVIRONMENTS_DIR = TINKER_ATROPOS_ROOT / "tinker_atropos" / "environments"\nCONFIGS_DIR = TINKER_ATROPOS_ROOT / "configs"\nLOGS_DIR = TINKER_ATROPOS_ROOT / "logs"\n\n# Ensure logs directory exists\nLOGS_DIR\.mkdir\(exist_ok=True\)@# Path to tinker-atropos workspace (defaulting to a user-writable Hermes home path)\nHERMES_HOME = Path(os.getenv("HERMES_HOME", Path.home() / ".hermes"))\nHERMES_ROOT = Path(__file__).parent.parent\nTINKER_ATROPOS_ROOT = Path(os.getenv("TINKER_ATROPOS_ROOT", str(HERMES_HOME / "tinker-atropos")))\nENVIRONMENTS_DIR = TINKER_ATROPOS_ROOT / "tinker_atropos" / "environments"\nCONFIGS_DIR = TINKER_ATROPOS_ROOT / "configs"\nLOGS_DIR = Path(os.getenv("TINKER_LOGS_DIR", str(HERMES_HOME / "logs" / "tinker-atropos")))\n\n# Ensure logs directory exists\nLOGS_DIR.mkdir(parents=True, exist_ok=True)@s' "$out/tools/rl_training_tool.py"

          PATCHED_ROOT="$out" ${pkgs.python3}/bin/python - <<'PY'
from os import environ
from pathlib import Path
import re

root = Path(environ["PATCHED_ROOT"])

doctor_path = root / "hermes_cli" / "doctor.py"
doctor_new = """    # Node.js + agent-browser (for browser automation tools)
    agent_browser_on_path = shutil.which("agent-browser")
    local_agent_browser = PROJECT_ROOT / "node_modules" / "agent-browser"
    hermes_nix_managed = os.getenv("HERMES_NIX_MANAGED") == "1"

    if agent_browser_on_path:
        detail = "(browser automation via PATH)"
        if hermes_nix_managed:
            detail = "(browser automation via Nix PATH)"
        check_ok("agent-browser", detail)
    elif local_agent_browser.exists():
        if shutil.which("node"):
            check_ok("Node.js")
        else:
            check_warn("Node.js not found", "(local repo agent-browser still needs Node.js)")
        check_ok("agent-browser (Node.js)", "(browser automation)")
    elif shutil.which("node"):
        check_ok("Node.js")
        check_warn("agent-browser not installed", "(run: npm install)")
    else:
        check_warn("agent-browser not found", "(optional, install agent-browser or enable the Nix browser integration)")
"""
doctor_text = doctor_path.read_text()
doctor_pattern = re.compile(
    r'    # Node\.js \+ agent-browser \(for browser automation tools\)\n.*?(?=    # npm audit for all Node\.js packages)',
    re.S,
)
doctor_match = doctor_pattern.search(doctor_text)
if not doctor_match:
    raise SystemExit("Failed to locate browser diagnostics block in hermes_cli/doctor.py")
doctor_path.write_text(doctor_text[:doctor_match.start()] + doctor_new + doctor_text[doctor_match.end():])

PY

          if ! ${pkgs.gnugrep}/bin/grep -q "TINKER_LOGS_DIR" "$out/tools/rl_training_tool.py"; then
            echo "Failed to patch rl_training_tool.py for writable Tinker paths" >&2
            exit 1
          fi

          if ! ${pkgs.gnugrep}/bin/grep -q "browser automation via Nix PATH" "$out/hermes_cli/doctor.py"; then
            echo "Failed to patch hermes_cli/doctor.py for PATH-based browser diagnostics" >&2
            exit 1
          fi

        '';

        hermes-agent =
          let
            inherit (pkgs)
              bash
              callPackage
              coreutils
              gnugrep
              lib
              python312
              stdenvNoCC
              ;

            python = python312;
            workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = sourceRoot; };
            overlay = workspace.mkPyprojectOverlay {
              sourcePreference = "wheel";
            };
            pythonSet = (callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
              lib.composeManyExtensions [
                pyproject-build-systems.overlays.wheel
                overlay
              ]
            );

            hermesEnv = pythonSet.mkVirtualEnv "${pname}-virtual-env-${version}" {
              hermes-agent = [
                "cli"
                "cron"
                "mcp"
                "messaging"
                "pty"
                "slack"
              ];
            };

            runtimePath = lib.makeBinPath [
              bash
              coreutils
              gnugrep
            ];
          in
          stdenvNoCC.mkDerivation {
            inherit pname version;
            dontUnpack = true;

            installPhase = ''
              runHook preInstall

              mkdir -p "$out/bin" "$out/share"
              ln -s ${patchedSource} "$out/share/hermes-agent"

              cat > "$out/bin/hermes" <<'EOF'
#!${bash}/bin/bash
set -euo pipefail

export PATH="${runtimePath}:$PATH"
export HERMES_NIX_MANAGED=1
hermes_home="''${HERMES_HOME:-$HOME/.hermes}"
export HERMES_HOME="$hermes_home"
env_file="$hermes_home/.env"
export TINKER_ATROPOS_ROOT="''${TINKER_ATROPOS_ROOT:-$hermes_home/tinker-atropos}"
export TINKER_LOGS_DIR="''${TINKER_LOGS_DIR:-$hermes_home/logs/tinker-atropos}"
if [ -n "''${PYTHONPATH:-}" ]; then
  export PYTHONPATH="${patchedSource}:$PYTHONPATH"
else
  export PYTHONPATH="${patchedSource}"
fi

if [ "''${WHATSAPP_ENABLED:-}" = "true" ] || ([ -f "$env_file" ] && ${gnugrep}/bin/grep -Eiq '^[[:space:]]*WHATSAPP_ENABLED[[:space:]]*=[[:space:]]*(true|1|yes)[[:space:]]*$' "$env_file"); then
  echo "WhatsApp is not supported in the Nix package yet. Leave WHATSAPP_ENABLED unset or false." >&2
  exit 1
fi

case "''\${1-}" in
  setup|uninstall|update|whatsapp)
    echo "hermes ''\${1} is disabled in the Nix package. Configure Hermes declaratively or edit ~/.hermes manually." >&2
    exit 1
    ;;
  gateway)
    case "''\${2-}" in
      install|restart|setup|start|stop|uninstall)
        echo "hermes gateway ''\${2} is disabled in the Nix package. Manage the gateway with Nix/Home Manager instead." >&2
        exit 1
        ;;
    esac
    ;;
esac

exec ${hermesEnv}/bin/python -m hermes_cli.main "$@"
EOF
              chmod +x "$out/bin/hermes"

              cat > "$out/bin/hermes-agent" <<'EOF'
#!${bash}/bin/bash
set -euo pipefail

export PATH="${runtimePath}:$PATH"
export HERMES_NIX_MANAGED=1
hermes_home="''${HERMES_HOME:-$HOME/.hermes}"
export HERMES_HOME="$hermes_home"
export TINKER_ATROPOS_ROOT="''${TINKER_ATROPOS_ROOT:-$hermes_home/tinker-atropos}"
export TINKER_LOGS_DIR="''${TINKER_LOGS_DIR:-$hermes_home/logs/tinker-atropos}"
if [ -n "''${PYTHONPATH:-}" ]; then
  export PYTHONPATH="${patchedSource}:$PYTHONPATH"
else
  export PYTHONPATH="${patchedSource}"
fi

exec ${hermesEnv}/bin/python -m run_agent "$@"
EOF
              chmod +x "$out/bin/hermes-agent"

              runHook postInstall
            '';

            doInstallCheck = true;
            installCheckPhase = ''
              runHook preInstallCheck
              "$out/bin/hermes" --help >/dev/null

              tmp_home="$TMPDIR/hermes-home"
              mkdir -p "$tmp_home/.hermes" "$TMPDIR/bin"
              cat > "$TMPDIR/bin/agent-browser" <<'EOF'
#!/bin/sh
exit 0
EOF
              chmod +x "$TMPDIR/bin/agent-browser"

              doctor_output="$(HOME="$tmp_home" PATH="$TMPDIR/bin:$PATH" "$out/bin/hermes" doctor 2>&1 || true)"
              printf '%s\n' "$doctor_output" | ${gnugrep}/bin/grep -q "browser automation via Nix PATH"

              if printf '%s\n' "$doctor_output" | ${gnugrep}/bin/grep -q "run: npm install"; then
                echo "doctor still suggested npm install under Nix-managed browser tooling" >&2
                printf '%s\n' "$doctor_output" >&2
                exit 1
              fi

              if printf '%s\n' "$doctor_output" | ${gnugrep}/bin/grep -q "Node.js not found"; then
                echo "doctor still warned about missing Node.js with PATH-provided agent-browser" >&2
                printf '%s\n' "$doctor_output" >&2
                exit 1
              fi

              runHook postInstallCheck
            '';

            meta = with pkgs.lib; {
              description = "Hermes Agent - self-improving AI agent";
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
