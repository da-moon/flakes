# Project-level integration for kimi-code.
#
# Factory used by the flake-parts module (flake-modules/project.nix) and by
# plain consuming flakes via lib.mkProjectIntegration. Manages the project
# surfaces Kimi Code actually reads per-project
# (https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/config-files.html):
#   - .kimi-code/mcp.json   (committed; explicit sync app + drift check)
# and, when isolation is enabled, a project-local KIMI_CODE_HOME with its own
# declarative config.toml / tui.toml / mcp.json / [[hooks]] (gitignored).
{
  pkgs
, kimiPackage # default kimi-code package (dependency-injected by flake.nix)
, sourceRoot ? null # consuming flake's self.outPath (enables the drift check)
, projectRoot ? "."
, package ? null
, settings ? null # project config.toml content (isolation mode)
, tui ? null # project tui.toml content (isolation mode)
, mcpServers ? null # project .kimi-code/mcp.json content
, hooks ? [ ] # project hooks (effective under isolation)
, isolation ? {
    enable = false;
    shareCredentials = true;
  }
, extraPackages ? [ ]
, devShellName ? "kimi"
}:
let
  lib = pkgs.lib;
  helpers = import ./lib.nix { inherit pkgs; };
  render = import ./render.nix { inherit (pkgs) lib; };
  schema = import ./config-schema.nix { inherit (pkgs) lib; };

  resolvedPackage = if package != null then package else kimiPackage;

  iso = {
    enable = false;
    shareCredentials = true;
  } // isolation;

  # --- validation -----------------------------------------------------------
  validateProjectRoot =
    root:
    let
      components = lib.splitString "/" root;
      bad =
        root == ""
        || lib.hasPrefix "/" root
        || builtins.any (c: c == "" || c == "." || c == "..") components
        || builtins.match ".*\n.*" root != null;
    in
    if root == "." then
      true
    else if bad then
      throw "kimi project: invalid projectRoot \"${
        root
      }\" (must be \".\" or a normalized relative path inside the repo, no '..' components)"
    else
      true;

  invalidMcp = lib.filterAttrs (
    _: s: !((s.command == null) != (s.url == null))
  ) (if mcpServers == null then { } else mcpServers);

  projectRootRel = if projectRoot == "." then "" else projectRoot;
  dirPrefix = if projectRootRel == "" then "" else "${projectRootRel}/";
  targetRel = "${dirPrefix}.kimi-code/mcp.json";

  hasMcp = mcpServers != null;

  mcpJsonFile = if hasMcp then render.mkMcpJson { inherit pkgs; servers = mcpServers; } else null;

  # --- isolation sync (writes into the project-local KIMI_CODE_HOME) --------
  hooksPackage = helpers.mkHooksPackage { inherit hooks; };
  managedHooksJson = helpers.mkManagedHooksJson {
    inherit hooks;
    commandFor = h: "${hooksPackage}/bin/${h.name}.sh";
  };
  syncConfigScript = helpers.mkSyncConfigScript {
    manifestJson = helpers.mkManifestJson schema.manifest;
    tuiManifestJson = helpers.mkManifestJson schema.tuiManifest;
    inherit managedHooksJson hooksPackage;
    declaredConfigJson =
      if settings != null then render.mkConfigJson { inherit pkgs settings; } else null;
    declaredTuiJson = if tui != null then render.mkTuiJson { inherit pkgs tui; } else null;
    mcpJson = mcpJsonFile;
  };

  # Shared shell prelude: resolve the git root and the project directory.
  prelude = ''
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      echo "error: not inside a git repository" >&2
      exit 1
    }
    root="$(realpath "$root")"
    if [ ! -f "$root/flake.nix" ]; then
      echo "error: no flake.nix at git root $root (subdirectory flakes unsupported)" >&2
      exit 1
    fi
    if [ -z ${lib.escapeShellArg projectRootRel} ]; then
      proj="$root"
    else
      proj="$(realpath -m "$root/"${lib.escapeShellArg projectRootRel})"
      case "$proj" in
        "$root" | "$root"/*) ;;
        *)
          echo "error: projectRoot escapes the git root" >&2
          exit 1
          ;;
      esac
    fi
    target="$proj/.kimi-code/mcp.json"
    src=${mcpJsonFile}
  '';

  syncApp = pkgs.writeShellApplication {
    name = "kimi-project-sync";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
    ];
    text = ''
      force=0
      for arg in "$@"; do
        case "$arg" in
          --force) force=1 ;;
          -h | --help)
            echo "usage: kimi-project-sync [--force]"
            echo "writes the Nix-rendered ${targetRel} into the worktree"
            exit 0
            ;;
          *)
            echo "error: unknown argument: $arg" >&2
            exit 2
            ;;
        esac
      done

      ${prelude}

      if [ -L "$proj/.kimi-code" ]; then
        echo "error: $proj/.kimi-code is a symlink; refusing" >&2
        exit 1
      fi
      mkdir -p "$proj/.kimi-code"

      if [ -e "$target" ] || [ -L "$target" ]; then
        if [ -L "$target" ]; then
          echo "error: $target is a symlink; refusing" >&2
          exit 1
        fi
        if [ ! -f "$target" ]; then
          echo "error: $target is not a regular file; refusing" >&2
          exit 1
        fi
        if cmp -s "$src" "$target"; then
          echo "up to date: $target"
          exit 0
        fi
        if git -C "$root" ls-files --error-unmatch -- ${lib.escapeShellArg targetRel} >/dev/null 2>&1; then
          if [ "$force" != 1 ]; then
            if ! git -C "$root" diff --quiet -- ${lib.escapeShellArg targetRel} \
              || ! git -C "$root" diff --cached --quiet -- ${lib.escapeShellArg targetRel}; then
              echo "error: $target has uncommitted changes; commit/stash them or pass --force" >&2
              exit 1
            fi
          fi
        elif [ "$force" != 1 ]; then
          echo "error: $target exists and is not tracked by git; move it away or pass --force" >&2
          exit 1
        fi
      fi

      tmp="$(mktemp "$proj/.kimi-code/.mcp.json.XXXXXX")"
      trap 'rm -f "$tmp"' EXIT
      install -m 0644 "$src" "$tmp"
      mv -f "$tmp" "$target"
      trap - EXIT
      echo "wrote $target"
      if ! git -C "$root" ls-files --error-unmatch -- ${lib.escapeShellArg targetRel} >/dev/null 2>&1; then
        echo "note: track it with: git add ${targetRel}"
      fi
    '';
  };

  driftApp = pkgs.writeShellApplication {
    name = "kimi-project-drift";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
      pkgs.diffutils
    ];
    text = ''
      ${prelude}

      if [ ! -e "$target" ]; then
        echo "drift: $target is missing (run kimi-project-sync)" >&2
        exit 1
      fi
      if [ -L "$target" ] || [ ! -f "$target" ]; then
        echo "drift: $target is not a regular file" >&2
        exit 1
      fi
      if ! git -C "$root" ls-files --error-unmatch -- ${lib.escapeShellArg targetRel} >/dev/null 2>&1; then
        echo "drift: $target is not tracked by git; run kimi-project-sync and commit it" >&2
        exit 1
      fi
      if ! cmp -s "$src" "$target"; then
        echo "drift: $target differs from the Nix-rendered mcp.json" >&2
        diff -u "$src" "$target" || true
        echo "run kimi-project-sync to update it" >&2
        exit 1
      fi
      echo "in sync: $target"
    '';
  };

  driftCheck = pkgs.runCommand "kimi-project-drift"
    {
      nativeBuildInputs = [
        pkgs.coreutils
        pkgs.diffutils
      ];
    }
    ''
      target=${sourceRoot}/${targetRel}
      if [ ! -f "$target" ]; then
        echo "missing ${targetRel} in the consuming flake source" >&2
        echo "run: nix run .#kimi-project-sync && git add ${targetRel}" >&2
        exit 1
      fi
      if ! cmp -s ${mcpJsonFile} "$target"; then
        echo "drift: ${targetRel} differs from the Nix-rendered mcp.json" >&2
        diff -u ${mcpJsonFile} "$target" || true
        echo "run: nix run .#kimi-project-sync" >&2
        exit 1
      fi
      mkdir -p $out
      cp ${mcpJsonFile} $out/mcp.json
    '';

  devShell = pkgs.mkShell {
    name = "kimi-project";
    packages = [ resolvedPackage ] ++ extraPackages;
    shellHook = lib.optionalString iso.enable ''
      _kimi_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
      export KIMI_CODE_HOME="$_kimi_root/${dirPrefix}.kimi-code/home"
      ${syncConfigScript}/bin/kimi-sync-config "$KIMI_CODE_HOME" "$KIMI_CODE_HOME/hooks"${
        lib.optionalString iso.shareCredentials " \"$HOME/.kimi-code/config.toml\""
      }
      ${lib.optionalString iso.shareCredentials ''
        if [ -d "$HOME/.kimi-code/credentials" ] && [ ! -e "$KIMI_CODE_HOME/credentials" ]; then
          ln -s "$HOME/.kimi-code/credentials" "$KIMI_CODE_HOME/credentials"
        fi
      ''}
      if ! grep -q '^\.kimi-code/home/' "$_kimi_root/.gitignore" 2>/dev/null; then
        echo "kimi: project KIMI_CODE_HOME is $KIMI_CODE_HOME"
        echo "kimi: consider adding '${dirPrefix}.kimi-code/home/' to .gitignore"
      fi
    '';
  };
in
assert lib.assertMsg (validateProjectRoot projectRoot == true) "unreachable";
assert lib.assertMsg (
  invalidMcp == { }
) "kimi project mcpServers: each server needs exactly one of `command` (stdio) or `url` (HTTP/SSE); invalid: ${builtins.concatStringsSep ", " (builtins.attrNames invalidMcp)}";
{
  packages = lib.optionalAttrs hasMcp {
    kimi-project-mcp-config = mcpJsonFile;
  };

  apps = lib.optionalAttrs hasMcp {
    kimi-project-sync = {
      type = "app";
      program = "${syncApp}/bin/kimi-project-sync";
    };
    kimi-project-drift = {
      type = "app";
      program = "${driftApp}/bin/kimi-project-drift";
    };
  };

  checks = lib.optionalAttrs (hasMcp && sourceRoot != null) {
    kimi-project-drift = driftCheck;
  };

  devShells = {
    ${devShellName} = devShell;
  };
}
