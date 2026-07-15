# Build the project-scoped Serena integration outputs.
#
# Import contract:
#
#   projectIntegration = import ./project-integration.nix {
#     inherit lib renderProjectConfig;
#     serenaPackage = pkgs: ...; # optional default; a package is also accepted
#   };
#
# Public contract:
#
#   projectIntegration.mkProjectIntegration {
#     inherit pkgs sourceRoot settings;
#     projectRoot = ".";       # relative to the consuming flake's Git root
#     package = ...;           # optional when serenaPackage was supplied
#     extraPackages = [ ];
#   }
#
# `renderProjectConfig { inherit pkgs settings; name = ...; }` must return a
# store file containing the complete, canonical `.serena/project.yml`.
{
  lib,
  renderProjectConfig,
  serenaPackage ? null,
}:
let
  validateProjectRoot =
    projectRoot:
    let
      components = if builtins.isString projectRoot then lib.splitString "/" projectRoot else [ ];
      hasInvalidComponent = builtins.any (
        component: component == "" || component == "." || component == ".."
      ) components;
      hasLineBreak =
        builtins.isString projectRoot && (lib.hasInfix "\n" projectRoot || lib.hasInfix "\r" projectRoot);
    in
    if !builtins.isString projectRoot then
      throw "Serena projectRoot must be a string relative to the consuming flake's Git root"
    else if projectRoot == "." then
      projectRoot
    else if
      projectRoot == "" || lib.hasPrefix "/" projectRoot || hasLineBreak || hasInvalidComponent
    then
      throw ''
        Invalid Serena projectRoot ${builtins.toJSON projectRoot}: use a normalized relative path
        such as "." or "packages/api"; absolute paths, empty components, ".", and ".." are not allowed
      ''
    else
      projectRoot;

  resolvePackage =
    pkgs: package:
    let
      candidate = if package == null then serenaPackage else package;
    in
    if candidate == null then
      throw "Serena project integration requires `package` (or a default `serenaPackage`)"
    else if builtins.isFunction candidate then
      candidate pkgs
    else
      candidate;

  validateSettings =
    settings:
    if !builtins.isAttrs settings then
      throw "Serena project settings must be an attribute set"
    else if
      !(settings ? projectName) || !builtins.isString settings.projectName || settings.projectName == ""
    then
      throw "Serena project settings require a non-empty `projectName` string"
    else if
      !(settings ? languages) || !builtins.isList settings.languages || settings.languages == [ ]
    then
      throw "Serena project settings require a non-empty `languages` list"
    else
      settings;

  runtimeRootPrelude = projectRoot: generatedFile: ''
    readonly generated_file=${lib.escapeShellArg (toString generatedFile)}
    readonly configured_project_root=${lib.escapeShellArg projectRoot}

    die() {
      printf 'serena-project: %s\n' "$*" >&2
      exit 1
    }

    git_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
      || die "run this command from inside the consuming Git worktree"
    git_root="$(realpath -e -- "$git_root")" \
      || die "cannot resolve the Git worktree root"
    [[ -f "$git_root/flake.nix" ]] \
      || die "the Git worktree root must contain flake.nix (subdirectory flakes are unsupported in version 1)"

    if [[ "$configured_project_root" == "." ]]; then
      configured_path="$git_root"
    else
      configured_path="$git_root/$configured_project_root"
    fi

    [[ -d "$configured_path" ]] \
      || die "configured projectRoot does not name an existing directory: $configured_project_root"
    project_dir="$(realpath -e -- "$configured_path")" \
      || die "cannot resolve projectRoot: $configured_project_root"

    case "$project_dir/" in
      "$git_root/"*) ;;
      *) die "projectRoot resolves outside the current Git worktree: $configured_project_root" ;;
    esac

    config_dir="$project_dir/.serena"
    target="$config_dir/project.yml"
    target_relative="''${target#"$git_root/"}"
  '';
in
{
  inherit validateProjectRoot;

  mkProjectIntegration =
    {
      pkgs,
      sourceRoot,
      settings,
      projectRoot ? ".",
      package ? null,
      extraPackages ? [ ],
    }:
    let
      normalizedProjectRoot = validateProjectRoot projectRoot;
      validatedSettings = validateSettings settings;
      resolvedPackage = resolvePackage pkgs package;
      projectFile = renderProjectConfig {
        inherit pkgs;
        settings = validatedSettings;
        name = "serena-project.yml";
      };
      prelude = runtimeRootPrelude normalizedProjectRoot projectFile;

      syncProgram = pkgs.writeShellApplication {
        name = "serena-project-sync";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.git
        ];
        text = ''
          force=0
          case "''${1-}" in
            "") ;;
            --force) force=1; shift ;;
            -h|--help)
              cat <<'EOF'
          Usage: serena-project-sync [--force]

          Write the Nix-rendered Serena configuration to .serena/project.yml.
          Conflicting untracked or modified files are refused unless --force is used.
          EOF
              exit 0
              ;;
            *)
              printf 'serena-project-sync: unknown argument: %s\n' "$1" >&2
              exit 2
              ;;
          esac
          [[ $# -eq 0 ]] || {
            printf 'serena-project-sync: unexpected argument: %s\n' "$1" >&2
            exit 2
          }

          ${prelude}

          if [[ -L "$config_dir" ]]; then
            die ".serena is a symbolic link; refusing to write"
          elif [[ -e "$config_dir" && ! -d "$config_dir" ]]; then
            die ".serena exists but is not a directory; refusing to write"
          elif [[ ! -e "$config_dir" ]]; then
            mkdir -- "$config_dir"
          fi

          [[ ! -L "$config_dir" && -d "$config_dir" ]] \
            || die ".serena changed while preparing the write; refusing to continue"

          if [[ -L "$target" ]]; then
            die ".serena/project.yml is a symbolic link; refusing to replace it"
          elif [[ -e "$target" && ! -f "$target" ]]; then
            die ".serena/project.yml is not a regular file; refusing to replace it"
          fi

          tracked=0
          if git -C "$git_root" --literal-pathspecs ls-files --error-unmatch -- "$target_relative" >/dev/null 2>&1; then
            tracked=1
          fi

          if [[ -f "$target" ]] && cmp -s -- "$generated_file" "$target"; then
            printf 'Serena project configuration is already current: %s\n' "$target_relative"
            if [[ "$tracked" -eq 0 ]]; then
              printf 'Track it with: git -C %q --literal-pathspecs add -- %q\n' "$git_root" "$target_relative"
            fi
            exit 0
          fi

          modified=0
          if [[ "$tracked" -eq 1 ]]; then
            git -C "$git_root" --literal-pathspecs diff --quiet -- "$target_relative" || modified=1
            git -C "$git_root" --literal-pathspecs diff --cached --quiet -- "$target_relative" || modified=1
          fi

          if [[ -e "$target" && "$tracked" -eq 0 && "$force" -ne 1 ]]; then
            die "$target_relative is untracked; inspect it, then rerun with --force to replace it"
          fi
          if [[ "$tracked" -eq 1 && "$modified" -eq 1 && "$force" -ne 1 ]]; then
            die "$target_relative has staged or unstaged changes; inspect it, then rerun with --force"
          fi

          temporary="$(mktemp "$config_dir/.project.yml.tmp.XXXXXX")"
          cleanup() {
            rm -f -- "$temporary"
          }
          trap cleanup EXIT HUP INT TERM
          install -m 0644 -- "$generated_file" "$temporary"
          mv -f -- "$temporary" "$target"
          trap - EXIT HUP INT TERM

          printf 'Wrote Serena project configuration: %s\n' "$target_relative"
          if [[ "$tracked" -eq 0 ]]; then
            printf 'Track it with: git -C %q --literal-pathspecs add -- %q\n' "$git_root" "$target_relative"
          fi
        '';
      };

      driftProgram = pkgs.writeShellApplication {
        name = "serena-project-drift";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.diffutils
          pkgs.git
        ];
        text = ''
          case "''${1-}" in
            "") ;;
            -h|--help)
              cat <<'EOF'
          Usage: serena-project-drift

          Verify that tracked .serena/project.yml is byte-identical to the
          complete configuration rendered by Nix. This command never writes.
          EOF
              exit 0
              ;;
            *)
              printf 'serena-project-drift: unexpected argument: %s\n' "$1" >&2
              exit 2
              ;;
          esac

          ${prelude}

          [[ ! -L "$config_dir" ]] \
            || die ".serena is a symbolic link; refusing to inspect it"
          [[ -d "$config_dir" ]] \
            || die "$target_relative is missing"
          [[ ! -L "$target" ]] \
            || die "$target_relative is a symbolic link"
          [[ -f "$target" ]] \
            || die "$target_relative is missing or is not a regular file"
          git -C "$git_root" --literal-pathspecs ls-files --error-unmatch -- "$target_relative" >/dev/null 2>&1 \
            || die "$target_relative is not tracked by Git"

          if ! cmp -s -- "$generated_file" "$target"; then
            printf 'serena-project: %s differs from the Nix-rendered configuration\n' "$target_relative" >&2
            diff -u \
              --label "$target_relative (worktree)" \
              --label "$target_relative (Nix rendered)" \
              "$target" "$generated_file" >&2 || true
            exit 1
          fi

          printf 'Serena project configuration is current: %s\n' "$target_relative"
        '';
      };

      driftCheck =
        pkgs.runCommand "serena-project-config-drift-check"
          {
            nativeBuildInputs = [
              pkgs.coreutils
              pkgs.diffutils
            ];
            serenaSourceRoot = sourceRoot;
          }
          ''
            relative=${lib.escapeShellArg "${normalizedProjectRoot}/.serena/project.yml"}
            committed="$serenaSourceRoot/$relative"
            generated=${lib.escapeShellArg (toString projectFile)}

            if [[ ! -f "$serenaSourceRoot/flake.nix" ]]; then
              printf 'serena-project: sourceRoot must be the consuming root flake (flake.nix is missing)\n' >&2
              exit 1
            fi

            if [[ ! -f "$committed" ]]; then
              printf 'serena-project: tracked project configuration is missing: %s\n' \
                "$relative" >&2
              printf 'Run the serena-project-sync app and add the generated file to Git.\n' >&2
              exit 1
            fi

            if ! cmp -s -- "$generated" "$committed"; then
              printf 'serena-project: tracked project configuration differs from the Nix-rendered configuration\n' >&2
              diff -u \
                --label "$relative (tracked source)" \
                --label "$relative (Nix rendered)" \
                "$committed" "$generated" >&2 || true
              exit 1
            fi

            mkdir -p "$out"
            install -m 0444 -- "$generated" "$out/project.yml"
          '';

      configPackage = pkgs.runCommand "serena-project-config" { } ''
        mkdir -p "$out/share/serena"
        install -m 0444 -- ${lib.escapeShellArg (toString projectFile)} "$out/share/serena/project.yml"
      '';
    in
    builtins.seq normalizedProjectRoot (
      builtins.seq validatedSettings {
        inherit projectFile;

        apps = {
          serena-project-sync = {
            type = "app";
            program = "${syncProgram}/bin/serena-project-sync";
            meta.description = "Safely synchronize Nix-rendered .serena/project.yml";
          };
          serena-project-drift = {
            type = "app";
            program = "${driftProgram}/bin/serena-project-drift";
            meta.description = "Check tracked .serena/project.yml for configuration drift";
          };
          serena = {
            type = "app";
            program = "${resolvedPackage}/bin/serena";
            meta.description = "Run Serena directly without synchronizing project configuration";
          };
        };

        checks.serena-project-drift = driftCheck;
        packages.serena-project-config = configPackage;
        devShells.serena = pkgs.mkShell {
          name = "serena-project-shell";
          packages = [ resolvedPackage ] ++ extraPackages;
        };
      }
    );
}
