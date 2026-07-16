# Build the local-only Command Code project integration.
{
  lib,
  commandCodePackage ? null,
}:
let
  schema = import ./schema.nix { inherit lib; };
  render = import ./render.nix { inherit lib; };

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
      throw "Command Code projectRoot must be a string relative to the consuming flake's Git root"
    else if projectRoot == "." then
      projectRoot
    else if
      projectRoot == "" || lib.hasPrefix "/" projectRoot || hasLineBreak || hasInvalidComponent
    then
      throw ''
        Invalid Command Code projectRoot ${builtins.toJSON projectRoot}: use a normalized relative
        path such as "." or "packages/api"; absolute paths, empty components, ".", and ".."
        are not allowed
      ''
    else
      projectRoot;

  resolvePackage =
    pkgs: package:
    let
      candidate = if package == null then commandCodePackage else package;
    in
    if candidate == null then
      throw "Command Code project integration requires `package` (or a default `commandCodePackage`)"
    else if builtins.isFunction candidate then
      candidate pkgs
    else
      candidate;

  evalTypedValue =
    {
      name,
      type,
      value,
    }:
    (lib.evalModules {
      modules = [
        {
          options.value = lib.mkOption {
            inherit type;
            description = "Validated ${name} value for the plain Command Code project helper.";
          };
          config.value = value;
        }
      ];
    }).config.value;

  cleanValue =
    value:
    if builtins.isAttrs value then
      let
        cleaned = lib.mapAttrs (_: cleanValue) value;
      in
      lib.filterAttrs (_: child: child != null && !(builtins.isAttrs child && child == { })) cleaned
    else if builtins.isList value then
      map cleanValue value
    else
      value;

  leafOperations =
    value:
    let
      walk =
        path: child:
        if builtins.isAttrs child then
          lib.concatMap (name: walk (path ++ [ name ]) child.${name}) (builtins.attrNames child)
        else
          [
            {
              inherit path;
              value = child;
            }
          ];
    in
    lib.concatMap (name: walk [ name ] value.${name}) (builtins.attrNames value);

  mergeLeavesJq = ''
    def at_path($document; $path):
      reduce $path[] as $key
        ({ exists: true, value: $document };
          if .exists and (.value | type) == "object" and (.value | has($key)) then
            { exists: true, value: .value[$key] }
          else
            { exists: false, value: null }
          end);

    def assert_adoptable($operations; $force; $label):
      . as $document
      | if $force then .
        else
          reduce $operations[] as $operation
            (.;
              at_path($document; $operation.path) as $current
              | if $current.exists and $current.value != $operation.value then
                  error(
                    $label + " conflicts with an unmanaged value at "
                    + ($operation.path | map(tostring) | join("."))
                    + "; inspect it and rerun command-code-project-sync --force to adopt it"
                  )
                else .
                end)
        end;

    def replace_leaves($old; $new):
      reduce $old[] as $operation
        (.;
          at_path(.; $operation.path) as $current
          | if $current.exists then delpaths([ $operation.path ]) else . end)
      | reduce $new[] as $operation
          (.; setpath($operation.path; $operation.value));

    def replace_sets($old; $new):
      reduce $old[] as $operation
        (.;
          at_path(.; $operation.path) as $current
          | if ($current.exists | not) then .
            elif ($current.value | type) != "array" then
              error("managed set path is no longer an array: " + ($operation.path | join(".")))
            else
              setpath(
                $operation.path;
                [ $current.value[] as $value
                  | select(($operation.values | index($value)) == null)
                  | $value ]
              )
            end)
      | reduce $new[] as $operation
          (.;
            at_path(.; $operation.path) as $current
            | if $current.exists and ($current.value | type) != "array" then
                error("managed set path is not an array: " + ($operation.path | join(".")))
              else
                (($current.value // [ ]) + $operation.values) as $combined
                | setpath(
                    $operation.path;
                    reduce $combined[] as $value
                      ([ ]; if index($value) == null then . + [ $value ] else . end)
                  )
              end);
  '';

  settingsMergeJq =
    pkgs:
    pkgs.writeText "command-code-project-settings-merge.jq" ''
      ${mergeLeavesJq}

      def without_commands($commands):
        if (.hooks | type) != "object" then .
        else
          .hooks |= with_entries(
            .value |= (
              map(
                if (.hooks | type) == "array" then
                  .hooks |= map(select((.command as $command | $commands | index($command)) == null))
                else .
                end
              )
              | map(select((.hooks | type) != "array" or (.hooks | length) > 0))
            )
          )
          | if .hooks == { } then del(.hooks) else . end
        end;

      def add_hook($definition):
        .hooks //= { }
        | .hooks[$definition.event] //= [ ]
        | (.hooks[$definition.event]
            | to_entries
            | map(select((.value.matcher // null) == $definition.matcher))
            | if length == 0 then null else .[0].key end) as $group_index
        | if $group_index == null then
            .hooks[$definition.event] += [
              ((if $definition.matcher == null then { } else { matcher: $definition.matcher } end)
                + { hooks: [ $definition.entry ] })
            ]
          else
            .hooks[$definition.event][$group_index].hooks += [ $definition.entry ]
          end;

      ($previous[0].settingsLeaves // [ ]) as $old_leaves
      | ($desired[0].settingsLeaves // [ ]) as $new_leaves
      | ($previous[0].settingsSets // [ ]) as $old_sets
      | ($desired[0].settingsSets // [ ]) as $new_sets
      | ($previous[0].hooks // [ ]) as $old_hooks
      | ($desired[0].hooks // [ ]) as $new_hooks
      | if $adopting then assert_adoptable($new_leaves; $force; "settings.local.json") else . end
      | replace_leaves($old_leaves; $new_leaves)
      | replace_sets($old_sets; $new_sets)
      | without_commands(
          (($old_hooks | map(.entry.command)) + ($new_hooks | map(.entry.command))) | unique
        )
      | reduce $new_hooks[] as $hook (.; add_hook($hook))
    '';

  mcpMergeJq =
    pkgs:
    pkgs.writeText "command-code-project-mcp-merge.jq" ''
      ${mergeLeavesJq}

      ($previous[0].mcpLeaves // [ ]) as $old_leaves
      | ($desired[0].mcpLeaves // [ ]) as $new_leaves
      | if $adopting then assert_adoptable($new_leaves; $force; "private mcp.json") else . end
      | replace_leaves($old_leaves; $new_leaves)
    '';

  settingsDriftJq =
    pkgs:
    pkgs.writeText "command-code-project-settings-drift.jq" ''
      ${mergeLeavesJq}

      def matching_hook_count($document; $definition):
        [
          ($document.hooks[$definition.event] // [ ])[]
          | select((.matcher // null) == $definition.matcher)
          | (.hooks // [ ])[]
          | select(. == $definition.entry)
        ] | length;

      . as $document
      | all($desired[0].settingsLeaves[];
          at_path($document; .path) as $current
          | $current.exists and $current.value == .value)
        and all($desired[0].settingsSets[];
          at_path($document; .path) as $current
          | $current.exists
            and ($current.value | type) == "array"
            and ([ .values[] as $value
                   | select(($current.value | index($value)) == null) ] | length) == 0)
        and all($desired[0].hooks[]; matching_hook_count($document; .) == 1)
    '';

  mcpDriftJq =
    pkgs:
    pkgs.writeText "command-code-project-mcp-drift.jq" ''
      ${mergeLeavesJq}

      . as $document
      | all($desired[0].mcpLeaves[];
          at_path($document; .path) as $current
          | $current.exists and $current.value == .value)
    '';
in
{
  inherit validateProjectRoot;

  mkProjectIntegration =
    {
      pkgs,
      projectRoot ? ".",
      settings ? { },
      hooks ? [ ],
      mcpServers ? { },
      package ? null,
      extraPackages ? [ ],
      # Test seam. Production derives this from Command Code's package.
      slugifyModule ? null,
    }:
    let
      normalizedProjectRoot = validateProjectRoot projectRoot;
      resolvedPackage = resolvePackage pkgs package;
      normalizedSettings = evalTypedValue {
        name = "project settings";
        type = schema.projectSettingsType;
        value = settings;
      };
      normalizedHooks = evalTypedValue {
        name = "project hooks";
        type = lib.types.listOf schema.hookType;
        value = hooks;
      };
      normalizedMcpServers = evalTypedValue {
        name = "project MCP servers";
        type = lib.types.attrsOf schema.mcpServerType;
        value = mcpServers;
      };

      assertions =
        schema.hookAssertions {
          hooks = normalizedHooks;
          label = "command-code.project.hooks";
        }
        ++ schema.mcpAssertions {
          servers = normalizedMcpServers;
          label = "command-code.project.mcpServers";
        };
      failedAssertions = builtins.filter (assertion: !assertion.assertion) assertions;
      declarationsAreValid =
        if failedAssertions == [ ] then
          true
        else
          throw (lib.concatMapStringsSep "\n" (assertion: assertion.message) failedAssertions);

      cleanedSettings = cleanValue (render.toProjectSettings normalizedSettings);
      renderedMcp = cleanValue (render.toMcpServers normalizedMcpServers);

      settingsSets =
        lib.optional (cleanedSettings ? disabledSkills) {
          path = [ "disabledSkills" ];
          values = cleanedSettings.disabledSkills;
        }
        ++ lib.optional ((cleanedSettings.permissions or { }) ? allow) {
          path = [
            "permissions"
            "allow"
          ];
          values = cleanedSettings.permissions.allow;
        };
      scalarSettings = cleanValue (
        (builtins.removeAttrs cleanedSettings [ "disabledSkills" ])
        // lib.optionalAttrs (cleanedSettings ? permissions) {
          permissions = builtins.removeAttrs cleanedSettings.permissions [ "allow" ];
        }
      );

      commandFor =
        hook:
        let
          scriptText = if builtins.isPath hook.script then builtins.readFile hook.script else hook.script;
          scriptPackage = pkgs.writeShellApplication {
            name = "command-code-hook-${hook.name}";
            runtimeInputs = hook.runtimeInputs;
            text = scriptText;
          };
        in
        if hook.command != null then
          hook.command
        else
          "${scriptPackage}/bin/command-code-hook-${hook.name}";
      hookDefinitions = render.toHookDefinitions {
        hooks = normalizedHooks;
        inherit commandFor;
      };
      renderedHooks = map (hook: {
        inherit (hook) name event matcher;
        entry = {
          type = "command";
          inherit (hook)
            command
            timeout
            async
            failClosed
            ;
        };
      }) hookDefinitions;
      settingsLeaves = leafOperations scalarSettings;
      mcpLeaves = leafOperations renderedMcp;
      desiredManifestValue = {
        schemaVersion = 1;
        projectRoot = normalizedProjectRoot;
        inherit settingsLeaves settingsSets mcpLeaves;
        hooks = renderedHooks;
      };
      desiredManifest = pkgs.writeText "command-code-project-manifest.json" (
        builtins.toJSON desiredManifestValue
      );
      emptyManifest = pkgs.writeText "command-code-empty-project-manifest.json" ''{"schemaVersion":1}'';
      settingsFragment = pkgs.writeText "command-code-settings.local.json" (
        builtins.toJSON cleanedSettings
      );
      mcpFragment = pkgs.writeText "command-code-private-mcp.json" (builtins.toJSON renderedMcp);

      slugifyPath =
        if slugifyModule == null then
          "${resolvedPackage}/lib/command-code/node_modules/@sindresorhus/slugify/index.js"
        else
          toString (
            builtins.path {
              path = slugifyModule;
              name = "command-code-project-slugify.mjs";
            }
          );

      settingsMergeProgram = settingsMergeJq pkgs;
      mcpMergeProgram = mcpMergeJq pkgs;
      settingsDriftProgram = settingsDriftJq pkgs;
      mcpDriftProgram = mcpDriftJq pkgs;

      runtimeInputs = [
        pkgs.coreutils
        pkgs.diffutils
        pkgs.flock
        pkgs.git
        pkgs.gnugrep
        pkgs.jq
        pkgs.nodejs_22
      ];

      runtimeRootPrelude = ''
        readonly configured_project_root=${lib.escapeShellArg normalizedProjectRoot}

        die() {
          printf 'command-code-project: %s\n' "$*" >&2
          exit 1
        }

        git_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
          || die "run this command from inside the consuming Git worktree"
        git_root="$(realpath -e -- "$git_root")" \
          || die "cannot resolve the Git worktree root"
        [[ -f "$git_root/flake.nix" ]] \
          || die "the Git worktree root must contain flake.nix (subdirectory flakes are unsupported)"

        if [[ "$configured_project_root" == "." ]]; then
          configured_path="$git_root"
        else
          configured_path="$git_root/$configured_project_root"
        fi
        [[ -d "$configured_path" ]] \
          || die "configured projectRoot does not name an existing directory: $configured_project_root"
        project_dir="$(realpath -e -- "$configured_path")" \
          || die "cannot resolve projectRoot: $configured_project_root"
        [[ "$project_dir" == "$configured_path" ]] \
          || die "projectRoot contains a symbolic-link component: $configured_project_root"
        case "$project_dir/" in
          "$git_root/"*) ;;
          *) die "projectRoot resolves outside the current Git worktree: $configured_project_root" ;;
        esac
      '';

      runtimePathsPrelude = ''
        ${runtimeRootPrelude}

        readonly slugify_module=${lib.escapeShellArg slugifyPath}

        settings_dir="$project_dir/.commandcode"
        settings_target="$settings_dir/settings.local.json"
        settings_relative="''${settings_target#"$git_root/"}"
        ignore_line="/$settings_relative"

        if git -C "$git_root" --literal-pathspecs ls-files --error-unmatch -- "$settings_relative" >/dev/null 2>&1; then
          die "$settings_relative is tracked by Git; local Command Code settings must remain untracked"
        fi

        project_slug="$(node --input-type=module - "$project_dir" "$slugify_module" <<'NODE'
        import { pathToFileURL } from 'node:url';
        const [projectDir, modulePath] = process.argv.slice(2);
        const { default: slugify } = await import(pathToFileURL(modulePath).href);
        const slug = slugify(projectDir);
        if (!/^[a-z0-9-]+$/.test(slug)) {
          throw new Error(`Command Code produced an unsafe project slug: ''${JSON.stringify(slug)}`);
        }
        process.stdout.write(slug);
        NODE
        )" || die "failed to derive Command Code's private project slug"

        commandcode_home="$HOME/.commandcode"
        private_project_dir="$commandcode_home/projects/$project_slug"
        mcp_target="$private_project_dir/mcp.json"
        state_dir="$commandcode_home/nix-state/projects"
        state_target="$state_dir/$project_slug.json"
      '';

      syncProgram = pkgs.writeShellApplication {
        name = "command-code-project-sync";
        inherit runtimeInputs;
        text = ''
          force=false
          quiet=false
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --force) force=true ;;
              --quiet) quiet=true ;;
              -h|--help)
                cat <<'EOF'
          Usage: command-code-project-sync [--force] [--quiet]

          Merge Nix-managed values into .commandcode/settings.local.json and
          Command Code's private per-project mcp.json. --force adopts conflicting
          first-run values; it never follows symlinks or writes tracked files.
          EOF
                exit 0
                ;;
              *)
                printf 'command-code-project-sync: unknown argument: %s\n' "$1" >&2
                exit 2
                ;;
            esac
            shift
          done

          ${runtimePathsPrelude}

          readonly desired_manifest=${lib.escapeShellArg (toString desiredManifest)}
          readonly empty_manifest=${lib.escapeShellArg (toString emptyManifest)}
          lock_target="$state_dir/$project_slug.lock"

          for parent in "$commandcode_home" "$commandcode_home/projects" "$state_dir"; do
            [[ ! -L "$parent" ]] || die "$parent is a symbolic link; refusing to write"
            if [[ -e "$parent" && ! -d "$parent" ]]; then
              die "$parent exists but is not a directory"
            fi
            install -d -m 0700 -- "$parent"
          done
          [[ ! -L "$lock_target" ]] \
            || die "$lock_target is a symbolic link; refusing to lock it"
          if [[ -e "$lock_target" && ! -f "$lock_target" ]]; then
            die "$lock_target exists but is not a regular file"
          fi
          : >"$lock_target"
          chmod 0600 "$lock_target"
          exec 9>"$lock_target"
          flock 9

          previous_manifest="$empty_manifest"
          adopting=true
          if [[ -e "$state_target" ]]; then
            [[ ! -L "$state_target" && -f "$state_target" ]] \
              || die "$state_target is not a safe regular file"
            jq -e . "$state_target" >/dev/null \
              || die "$state_target contains invalid JSON"
            jq -e --arg project_dir "$project_dir" --arg project_slug "$project_slug" '
              .schemaVersion == 1
              and .projectDir == $project_dir
              and .projectSlug == $project_slug
            ' "$state_target" >/dev/null \
              || die "$state_target belongs to a different project or schema version"
            previous_manifest="$state_target"
            adopting=false
          fi

          for directory in "$settings_dir" "$private_project_dir"; do
            [[ ! -L "$directory" ]] || die "$directory is a symbolic link; refusing to write"
            if [[ -e "$directory" && ! -d "$directory" ]]; then
              die "$directory exists but is not a directory"
            fi
          done
          install -d -m 0700 -- "$settings_dir" "$private_project_dir"

          for target in "$settings_target" "$mcp_target"; do
            [[ ! -L "$target" ]] || die "$target is a symbolic link; refusing to replace it"
            if [[ -e "$target" && ! -f "$target" ]]; then
              die "$target exists but is not a regular file"
            fi
            if [[ -f "$target" ]]; then
              jq -e 'type == "object"' "$target" >/dev/null \
                || die "$target must contain one valid JSON object"
            fi
          done

          exclude_path="$(git -C "$git_root" rev-parse --git-path info/exclude)" \
            || die "cannot locate .git/info/exclude"
          case "$exclude_path" in
            /*) ;;
            *) exclude_path="$git_root/$exclude_path" ;;
          esac
          exclude_dir="$(dirname "$exclude_path")"
          [[ ! -L "$exclude_dir" && -d "$exclude_dir" ]] \
            || die "Git info directory is missing or is a symbolic link"
          [[ ! -L "$exclude_path" ]] \
            || die "$exclude_path is a symbolic link; refusing to replace it"
          if [[ -e "$exclude_path" && ! -f "$exclude_path" ]]; then
            die "$exclude_path is not a regular file"
          fi
          touch "$exclude_path"
          exclude_lock="$exclude_dir/command-code-nix.lock"
          [[ ! -L "$exclude_lock" ]] \
            || die "$exclude_lock is a symbolic link; refusing to lock it"
          if [[ -e "$exclude_lock" && ! -f "$exclude_lock" ]]; then
            die "$exclude_lock exists but is not a regular file"
          fi
          exec 8>"$exclude_lock"
          flock 8
          exclude_count="$(grep -Fxc -- "$ignore_line" "$exclude_path" || true)"
          if [[ "$exclude_count" != 1 ]]; then
            exclude_tmp="$(mktemp "$exclude_dir/.exclude.command-code.XXXXXX")"
            cleanup_exclude() { rm -f -- "$exclude_tmp"; }
            trap cleanup_exclude EXIT HUP INT TERM
            while IFS= read -r line || [[ -n "$line" ]]; do
              [[ "$line" == "$ignore_line" ]] || printf '%s\n' "$line" >>"$exclude_tmp"
            done <"$exclude_path"
            printf '%s\n' "$ignore_line" >>"$exclude_tmp"
            chmod --reference="$exclude_path" "$exclude_tmp"
            mv -f -- "$exclude_tmp" "$exclude_path"
            trap - EXIT HUP INT TERM
          fi
          flock -u 8

          settings_input="$settings_target"
          if [[ ! -f "$settings_input" ]]; then
            settings_input="$(mktemp)"
            printf '{}\n' >"$settings_input"
          fi
          mcp_input="$mcp_target"
          if [[ ! -f "$mcp_input" ]]; then
            mcp_input="$(mktemp)"
            printf '{}\n' >"$mcp_input"
          fi

          settings_tmp="$(mktemp "$settings_dir/.settings.local.json.tmp.XXXXXX")"
          mcp_tmp="$(mktemp "$private_project_dir/.mcp.json.tmp.XXXXXX")"
          state_tmp="$(mktemp "$state_dir/.project-state.tmp.XXXXXX")"
          cleanup() {
            rm -f -- "$settings_tmp" "$mcp_tmp" "$state_tmp"
            [[ "$settings_input" == "$settings_target" ]] || rm -f -- "$settings_input"
            [[ "$mcp_input" == "$mcp_target" ]] || rm -f -- "$mcp_input"
          }
          trap cleanup EXIT HUP INT TERM

          jq \
            --argjson adopting "$adopting" \
            --argjson force "$force" \
            --slurpfile previous "$previous_manifest" \
            --slurpfile desired "$desired_manifest" \
            -f ${lib.escapeShellArg (toString settingsMergeProgram)} \
            "$settings_input" >"$settings_tmp"
          jq \
            --argjson adopting "$adopting" \
            --argjson force "$force" \
            --slurpfile previous "$previous_manifest" \
            --slurpfile desired "$desired_manifest" \
            -f ${lib.escapeShellArg (toString mcpMergeProgram)} \
            "$mcp_input" >"$mcp_tmp"
          jq \
            --arg project_dir "$project_dir" \
            --arg project_slug "$project_slug" \
            --arg ignore_line "$ignore_line" \
            '. + {
              projectDir: $project_dir,
              projectSlug: $project_slug,
              ignoreLine: $ignore_line
            }' "$desired_manifest" >"$state_tmp"

          [[ ! -L "$settings_dir" && ! -L "$settings_target" ]] \
            || die "settings path changed to a symbolic link during synchronization"
          [[ ! -L "$private_project_dir" && ! -L "$mcp_target" ]] \
            || die "private MCP path changed to a symbolic link during synchronization"
          chmod 0600 "$settings_tmp" "$mcp_tmp" "$state_tmp"
          mv -f -- "$settings_tmp" "$settings_target"
          mv -f -- "$mcp_tmp" "$mcp_target"
          mv -f -- "$state_tmp" "$state_target"
          cleanup
          trap - EXIT HUP INT TERM

          if ! $quiet; then
            printf 'Synchronized local Command Code settings: %s\n' "$settings_relative"
            printf 'Synchronized private Command Code MCP config: %s\n' "$mcp_target"
          fi
        '';
      };

      driftProgram = pkgs.writeShellApplication {
        name = "command-code-project-drift";
        inherit runtimeInputs;
        text = ''
          case "''${1-}" in
            "") ;;
            -h|--help)
              cat <<'EOF'
          Usage: command-code-project-drift

          Read-only verification of the Nix-managed project values, private MCP
          values, manifest, permissions, Git tracking state, and local exclude line.
          EOF
              exit 0
              ;;
            *)
              printf 'command-code-project-drift: unexpected argument: %s\n' "$1" >&2
              exit 2
              ;;
          esac

          ${runtimePathsPrelude}

          readonly desired_manifest=${lib.escapeShellArg (toString desiredManifest)}

          [[ ! -L "$state_target" && -f "$state_target" ]] \
            || die "managed state is missing or unsafe: $state_target"
          [[ ! -L "$settings_dir" && -d "$settings_dir" ]] \
            || die "project .commandcode directory is missing or unsafe"
          [[ ! -L "$settings_target" && -f "$settings_target" ]] \
            || die "$settings_relative is missing or unsafe"
          [[ ! -L "$private_project_dir" && -d "$private_project_dir" ]] \
            || die "private project directory is missing or unsafe"
          [[ ! -L "$mcp_target" && -f "$mcp_target" ]] \
            || die "private MCP configuration is missing or unsafe"

          for target in "$state_target" "$settings_target" "$mcp_target"; do
            [[ "$(stat -c '%a' "$target")" == 600 ]] \
              || die "$target must have mode 0600"
            jq -e 'type == "object"' "$target" >/dev/null \
              || die "$target must contain one valid JSON object"
          done

          jq -e \
            --arg project_dir "$project_dir" \
            --arg project_slug "$project_slug" \
            --arg ignore_line "$ignore_line" \
            --slurpfile desired "$desired_manifest" '
              .schemaVersion == 1
              and .projectDir == $project_dir
              and .projectSlug == $project_slug
              and .ignoreLine == $ignore_line
              and .projectRoot == $desired[0].projectRoot
              and .settingsLeaves == $desired[0].settingsLeaves
              and .settingsSets == $desired[0].settingsSets
              and .hooks == $desired[0].hooks
              and .mcpLeaves == $desired[0].mcpLeaves
            ' "$state_target" >/dev/null \
            || die "managed state differs from the Nix declaration"

          jq -e --slurpfile desired "$desired_manifest" \
            -f ${lib.escapeShellArg (toString settingsDriftProgram)} \
            "$settings_target" >/dev/null \
            || die "$settings_relative differs from the Nix-managed values"
          jq -e --slurpfile desired "$desired_manifest" \
            -f ${lib.escapeShellArg (toString mcpDriftProgram)} \
            "$mcp_target" >/dev/null \
            || die "$mcp_target differs from the Nix-managed values"

          exclude_path="$(git -C "$git_root" rev-parse --git-path info/exclude)" \
            || die "cannot locate .git/info/exclude"
          case "$exclude_path" in
            /*) ;;
            *) exclude_path="$git_root/$exclude_path" ;;
          esac
          [[ ! -L "$exclude_path" && -f "$exclude_path" ]] \
            || die ".git/info/exclude is missing or unsafe"
          [[ "$(grep -Fxc -- "$ignore_line" "$exclude_path" || true)" == 1 ]] \
            || die ".git/info/exclude must contain exactly one managed local-settings line"
          if git -C "$git_root" --literal-pathspecs ls-files --error-unmatch -- "$settings_relative" >/dev/null 2>&1; then
            die "$settings_relative is tracked by Git"
          fi

          printf 'Command Code project configuration is current: %s\n' "$settings_relative"
        '';
      };

      runnerProgram = pkgs.writeShellApplication {
        name = "command-code-project-run";
        inherit runtimeInputs;
        text = ''
          ${syncProgram}/bin/command-code-project-sync --quiet
          ${runtimeRootPrelude}
          cd "$project_dir"

          repair() {
            local status=$?
            trap - EXIT
            if ! ${syncProgram}/bin/command-code-project-sync --quiet; then
              printf 'command-code-project: post-run configuration repair failed\n' >&2
              [[ "$status" -ne 0 ]] || status=1
            fi
            exit "$status"
          }
          trap repair EXIT
          ${resolvedPackage}/bin/cmdc "$@"
        '';
      };

      wrappedPackage = pkgs.runCommand "command-code-project-wrapped" { } ''
        mkdir -p "$out/bin"
        for name in cmd cmdc command-code commandcode; do
          ln -s ${runnerProgram}/bin/command-code-project-run "$out/bin/$name"
        done
      '';

      configPackage = pkgs.runCommand "command-code-project-config" { } ''
        mkdir -p "$out/share/command-code"
        install -m 0444 ${settingsFragment} "$out/share/command-code/settings.local.json"
        install -m 0444 ${mcpFragment} "$out/share/command-code/mcp.json"
        install -m 0444 ${desiredManifest} "$out/share/command-code/manifest.json"
      '';

      configCheck =
        pkgs.runCommand "command-code-project-config-check"
          {
            nativeBuildInputs = [ pkgs.jq ];
          }
          ''
            jq -e '
              .schemaVersion == 1
              and (.projectRoot | type) == "string"
              and (.settingsLeaves | type) == "array"
              and (.settingsSets | type) == "array"
              and (.hooks | type) == "array"
              and (.mcpLeaves | type) == "array"
            ' ${desiredManifest} >/dev/null
            jq -e 'type == "object"' ${settingsFragment} >/dev/null
            jq -e '
              type == "object"
              and ([paths | select(.[-1] == "headers" or .[-1] == "env" or .[-1] == "clientSecret")]
                | length) == 0
            ' ${mcpFragment} >/dev/null
            mkdir -p "$out"
            install -m 0444 ${desiredManifest} "$out/manifest.json"
          '';
    in
    builtins.seq declarationsAreValid {
      inherit desiredManifest settingsFragment mcpFragment;

      apps = {
        command-code-project-sync = {
          type = "app";
          program = "${syncProgram}/bin/command-code-project-sync";
          meta.description = "Safely synchronize local-only Command Code project configuration";
        };
        command-code-project-drift = {
          type = "app";
          program = "${driftProgram}/bin/command-code-project-drift";
          meta.description = "Check local-only Command Code project configuration for drift";
        };
        command-code = {
          type = "app";
          program = "${wrappedPackage}/bin/cmdc";
          meta.description = "Synchronize, run Command Code at the project root, and repair configuration";
        };
      };

      packages.command-code-project-config = configPackage;
      checks.command-code-project-config = configCheck;
      devShells.command-code = pkgs.mkShell {
        name = "command-code-project-shell";
        packages = [ wrappedPackage ] ++ extraPackages;
        shellHook = ''
          ${syncProgram}/bin/command-code-project-sync --quiet
        '';
      };
    };
}
