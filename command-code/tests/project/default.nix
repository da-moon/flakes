# Isolated local-only project-integration regression test.
{ pkgs, lib }:
let
  fakeCommandCode = pkgs.writeShellScriptBin "cmdc" ''
    set -euo pipefail
    printf '%s\n' "$PWD"
    settings="$PWD/.commandcode/settings.local.json"
    tmp="$(mktemp "$PWD/.commandcode/.fake-cmdc.XXXXXX")"
    jq '.permissions.defaultMode = "acceptEdits" | .runtimeSentinel = "kept"' \
      "$settings" >"$tmp"
    mv "$tmp" "$settings"
  '';

  factory = import ../../modules/project-integration.nix {
    inherit lib;
    commandCodePackage = fakeCommandCode;
  };

  mkIntegration =
    {
      tasteLearning ? false,
      defaultMode ? "ask",
      mcpUrl ? "https://example.invalid/mcp",
      disabledSkills ? [ "managed-v1" ],
      allow ? [ "Bash(nix:*)" ],
    }:
    factory.mkProjectIntegration {
      inherit pkgs;
      projectRoot = "packages/api";
      slugifyModule = ./fixtures/slugify.mjs;
      settings = {
        inherit tasteLearning disabledSkills;
        permissions = {
          inherit defaultMode allow;
          autoApprove.update = true;
        };
      };
      hooks = [
        {
          name = "fixture-hook";
          event = "PreToolUse";
          matcher = "SHELL";
          timeout = 30;
          script = ''
            jq -n '{ continue: true }'
          '';
          runtimeInputs = [ pkgs.jq ];
        }
      ];
      mcpServers.fixture = {
        transport = "http";
        url = mcpUrl;
      };
    };

  integrationV1 = mkIntegration { };
  integrationV2 = mkIntegration {
    tasteLearning = true;
    defaultMode = "acceptEdits";
    mcpUrl = "https://example.invalid/v2";
    disabledSkills = [ "managed-v2" ];
    allow = [ "Bash(git:*)" ];
  };

  invalidRoots = [
    ""
    "/absolute"
    "packages//api"
    "packages/./api"
    "packages/../api"
    "packages/api/"
    "packages\napi"
  ];

  integrationSucceeds =
    overrides:
    (builtins.tryEval (
      builtins.deepSeq (factory.mkProjectIntegration (
        {
          inherit pkgs;
          package = fakeCommandCode;
          slugifyModule = ./fixtures/slugify.mjs;
        }
        // overrides
      )) true
    )).success;

  invalidDeclarations = [
    { settings.futureSetting = true; }
    {
      hooks = [
        {
          name = "bad.name";
          command = "false";
        }
      ];
    }
    {
      hooks = [
        {
          name = "both-sources";
          command = "false";
          script = "exit 0";
        }
      ];
    }
    {
      hooks = [
        {
          name = "invalid-mode";
          command = "false";
          async = true;
          failClosed = true;
        }
      ];
    }
    {
      mcpServers.secret = {
        transport = "http";
        url = "https://example.invalid/mcp";
        headers.Authorization = "must-not-enter-store";
      };
    }
    {
      mcpServers.mixed = {
        transport = "http";
        command = "false";
        url = "https://example.invalid/mcp";
      };
    }
  ];

  validationAssertions =
    assert factory.validateProjectRoot "." == ".";
    assert factory.validateProjectRoot "packages/api" == "packages/api";
    assert builtins.all (
      root: !(builtins.tryEval (factory.validateProjectRoot root)).success
    ) invalidRoots;
    assert builtins.all (declaration: !(integrationSucceeds declaration)) invalidDeclarations;
    true;

  interfaceAssertions =
    assert
      builtins.attrNames integrationV1.apps == [
        "command-code"
        "command-code-project-drift"
        "command-code-project-sync"
      ];
    assert builtins.hasAttr "command-code-project-config" integrationV1.checks;
    assert builtins.hasAttr "command-code-project-config" integrationV1.packages;
    assert builtins.hasAttr "command-code" integrationV1.devShells;
    true;
in
assert validationAssertions;
assert interfaceAssertions;
{
  command-code-project-integration =
    pkgs.runCommand "command-code-project-integration-test"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.diffutils
          pkgs.findutils
          pkgs.git
          pkgs.gnugrep
          pkgs.jq
          pkgs.nodejs_22
        ];
      }
      ''
        set -euo pipefail

        sync_v1=${lib.escapeShellArg integrationV1.apps.command-code-project-sync.program}
        drift_v1=${lib.escapeShellArg integrationV1.apps.command-code-project-drift.program}
        command_v1=${lib.escapeShellArg integrationV1.apps.command-code.program}
        config_check=${lib.escapeShellArg (toString integrationV1.checks.command-code-project-config)}
        sync_v2=${lib.escapeShellArg integrationV2.apps.command-code-project-sync.program}
        drift_v2=${lib.escapeShellArg integrationV2.apps.command-code-project-drift.program}
        config_package=${lib.escapeShellArg (toString integrationV1.packages.command-code-project-config)}

        expect_failure() {
          if "$@" >expect-failure.stdout 2>expect-failure.stderr; then
            printf 'command unexpectedly succeeded:' >&2
            printf ' %q' "$@" >&2
            printf '\n' >&2
            exit 1
          fi
        }

        init_repo() {
          local repo="$1"
          mkdir -p "$repo/packages/api/nested/cwd"
          printf '{}\n' >"$repo/flake.nix"
          git -C "$repo" init -q
          git -C "$repo" config user.email command-code-test@example.invalid
          git -C "$repo" config user.name 'Command Code project integration test'
          git -C "$repo" add flake.nix
          git -C "$repo" commit -qm fixtures
        }

        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"

        test -f "$config_package/share/command-code/settings.local.json"
        test -f "$config_package/share/command-code/mcp.json"
        test -f "$config_package/share/command-code/manifest.json"
        test -f "$config_check/manifest.json"

        repo="$TMPDIR/repo with spaces"
        project="$repo/packages/api"
        init_repo "$repo"
        printf 'exclude sentinel\n' >>"$repo/.git/info/exclude"

        cd "$project/nested/cwd"
        "$sync_v1"

        settings="$project/.commandcode/settings.local.json"
        test -f "$settings"
        test "$(stat -c '%a' "$settings")" = 600
        jq -e '
          .tasteLearning == false
          and .permissions.defaultMode == "ask"
          and .permissions.autoApprove.update == true
          and .disabledSkills == ["managed-v1"]
          and .permissions.allow == ["Bash(nix:*)"]
          and ([.hooks.PreToolUse[] | select(.matcher == "SHELL") | .hooks[]
            | select(.command | endswith("/command-code-hook-fixture-hook"))] | length) == 1
        ' "$settings" >/dev/null

        slug="$(node --input-type=module - "$project" ${./fixtures/slugify.mjs} <<'NODE'
        import { pathToFileURL } from 'node:url';
        const [projectDir, modulePath] = process.argv.slice(2);
        const { default: slugify } = await import(pathToFileURL(modulePath).href);
        process.stdout.write(slugify(projectDir));
        NODE
        )"
        mcp="$HOME/.commandcode/projects/$slug/mcp.json"
        state="$HOME/.commandcode/nix-state/projects/$slug.json"
        test -f "$mcp"
        test "$(stat -c '%a' "$mcp")" = 600
        test "$(stat -c '%a' "$state")" = 600
        jq -e '.mcpServers.fixture.url == "https://example.invalid/mcp"' "$mcp" >/dev/null

        ignore_line="/packages/api/.commandcode/settings.local.json"
        test "$(grep -Fxc -- "$ignore_line" "$repo/.git/info/exclude")" = 1
        grep -Fqx 'exclude sentinel' "$repo/.git/info/exclude"
        "$drift_v1"

        # Synchronization owns declared leaves but preserves runtime state,
        # unknown settings, unrelated hooks, private headers, and other servers.
        settings_tmp="$(mktemp "$project/.commandcode/.settings.XXXXXX")"
        jq '
          .unknownRuntime = { keep: true }
          | .disabledSkills += ["manual-skill"]
          | .permissions.allow += ["Bash(manual:*)"]
          | .hooks.PostToolUse = [{ hooks: [{ type: "command", command: "manual-hook" }] }]
        ' "$settings" >"$settings_tmp"
        mv "$settings_tmp" "$settings"
        chmod 0600 "$settings"
        mcp_tmp="$(mktemp "$HOME/.commandcode/projects/$slug/.mcp.XXXXXX")"
        jq '
          .mcpServers.fixture.headers = { Authorization: "secret sentinel" }
          | .mcpServers.manual = { command: "manual-server" }
        ' "$mcp" >"$mcp_tmp"
        mv "$mcp_tmp" "$mcp"
        chmod 0600 "$mcp"
        "$sync_v1" --quiet
        jq -e '
          .unknownRuntime.keep == true
          and (.disabledSkills | index("manual-skill")) != null
          and (.permissions.allow | index("Bash(manual:*)")) != null
          and .hooks.PostToolUse[0].hooks[0].command == "manual-hook"
        ' "$settings" >/dev/null
        jq -e '
          .mcpServers.fixture.headers.Authorization == "secret sentinel"
          and .mcpServers.manual.command == "manual-server"
        ' "$mcp" >/dev/null

        # Managed values advance without force once a valid manifest exists.
        "$sync_v2" --quiet
        "$drift_v2"
        expect_failure "$drift_v1"
        jq -e '.tasteLearning == true and .permissions.defaultMode == "acceptEdits"' "$settings" >/dev/null
        jq -e '
          (.disabledSkills | index("managed-v1")) == null
          and (.disabledSkills | index("managed-v2")) != null
          and (.disabledSkills | index("manual-skill")) != null
          and (.permissions.allow | index("Bash(nix:*)")) == null
          and (.permissions.allow | index("Bash(git:*)")) != null
          and (.permissions.allow | index("Bash(manual:*)")) != null
        ' "$settings" >/dev/null
        jq -e '
          .mcpServers.fixture.url == "https://example.invalid/v2"
          and .mcpServers.fixture.headers.Authorization == "secret sentinel"
        ' "$mcp" >/dev/null

        # The wrapped command always runs at projectRoot and post-run repair
        # restores fields destructively rewritten by the client.
        printf 'false\n' >expected-false
        "$sync_v1" --quiet
        output="$(cd "$project/nested/cwd" && "$command_v1")"
        test "$output" = "$project"
        jq -e '
          .permissions.defaultMode == "ask"
          and .runtimeSentinel == "kept"
          and .unknownRuntime.keep == true
        ' "$settings" >/dev/null
        "$drift_v1"

        # Drift detects managed mutations, and sync repairs duplicate exclude lines.
        settings_tmp="$(mktemp "$project/.commandcode/.settings.XXXXXX")"
        jq '.tasteLearning = true' "$settings" >"$settings_tmp"
        mv "$settings_tmp" "$settings"
        chmod 0600 "$settings"
        expect_failure "$drift_v1"
        printf '%s\n' "$ignore_line" >>"$repo/.git/info/exclude"
        "$sync_v1" --quiet
        test "$(grep -Fxc -- "$ignore_line" "$repo/.git/info/exclude")" = 1

        # First-run conflicts require explicit adoption.
        conflict_home="$TMPDIR/conflict-home"
        conflict_repo="$TMPDIR/conflict-repo"
        mkdir -p "$conflict_home"
        init_repo "$conflict_repo"
        mkdir -p "$conflict_repo/packages/api/.commandcode"
        printf '{"tasteLearning":true}\n' >"$conflict_repo/packages/api/.commandcode/settings.local.json"
        chmod 0600 "$conflict_repo/packages/api/.commandcode/settings.local.json"
        export HOME="$conflict_home"
        cd "$conflict_repo/packages/api/nested/cwd"
        expect_failure "$sync_v1"
        "$sync_v1" --force --quiet
        jq -e '.tasteLearning == false' "$conflict_repo/packages/api/.commandcode/settings.local.json" >/dev/null

        # A tracked local file is unconditionally rejected, even with --force.
        git -C "$conflict_repo" add -f packages/api/.commandcode/settings.local.json
        expect_failure "$sync_v1" --force
        git -C "$conflict_repo" reset -q HEAD -- packages/api/.commandcode/settings.local.json

        # Neither target files nor projectRoot may resolve through symlinks.
        rm "$conflict_repo/packages/api/.commandcode/settings.local.json"
        outside="$TMPDIR/outside-settings.json"
        printf '{"outside":true}\n' >"$outside"
        ln -s "$outside" "$conflict_repo/packages/api/.commandcode/settings.local.json"
        expect_failure "$sync_v1" --force
        jq -e '.outside == true' "$outside" >/dev/null

        linked_repo="$TMPDIR/linked-repo"
        init_repo "$linked_repo"
        mv "$linked_repo/packages/api" "$TMPDIR/outside-project"
        ln -s "$TMPDIR/outside-project" "$linked_repo/packages/api"
        cd "$linked_repo"
        expect_failure "$sync_v1" --force

        touch "$out"
      '';
}
