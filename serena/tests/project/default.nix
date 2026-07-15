# Isolated project-integration regression test.
#
# Import contract:
#
#   projectTests = import ./tests/project { inherit pkgs lib; };
#
# The returned attrset is suitable for merging into `checks.${system}`. It uses
# a stub renderer and executable, so it tests the integration without building
# Serena or depending on the live upstream schema.
{ pkgs, lib }:
let
  fakeSerena = pkgs.writeShellScriptBin "serena" ''
    printf 'stub serena\n'
  '';

  mkFixtureIntegration =
    renderedText:
    let
      projectIntegration = import ../../lib/project-integration.nix {
        inherit lib;
        renderProjectConfig = { pkgs, name, ... }: pkgs.writeText name renderedText;
        serenaPackage = fakeSerena;
      };
    in
    projectIntegration.mkProjectIntegration {
      inherit pkgs;
      sourceRoot = ./fixtures/source;
      projectRoot = "packages/api";
      settings = {
        projectName = "fixture";
        languages = [ "nix" ];
      };
    };

  renderedV1 = ''
    project_name: fixture
    languages:
      - nix
  '';
  renderedV2 = ''
    project_name: fixture-renamed
    languages:
      - nix
  '';

  integrationV1 = mkFixtureIntegration renderedV1;
  integrationV2 = mkFixtureIntegration renderedV2;

  linkedIntegration =
    let
      projectIntegration = import ../../lib/project-integration.nix {
        inherit lib;
        renderProjectConfig = { pkgs, name, ... }: pkgs.writeText name renderedV1;
        serenaPackage = fakeSerena;
      };
    in
    projectIntegration.mkProjectIntegration {
      inherit pkgs;
      sourceRoot = ./fixtures/source;
      projectRoot = "linked";
      settings = {
        projectName = "fixture";
        languages = [ "nix" ];
      };
    };

  validator =
    (import ../../lib/project-integration.nix {
      inherit lib;
      renderProjectConfig = _: throw "renderer must not be evaluated by validation tests";
    }).validateProjectRoot;

  validationOnlyIntegration = import ../../lib/project-integration.nix {
    inherit lib;
    renderProjectConfig = _: throw "renderer must not be evaluated by validation tests";
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

  invalidSettings = [
    { }
    {
      projectName = "";
      languages = [ "nix" ];
    }
    {
      projectName = "fixture";
      languages = [ ];
    }
    {
      projectName = "fixture";
      languages = "nix";
    }
  ];

  validationAssertions =
    assert validator "." == ".";
    assert validator "packages/api" == "packages/api";
    assert builtins.all (root: !(builtins.tryEval (validator root)).success) invalidRoots;
    assert builtins.all (
      settings:
      !(builtins.tryEval (
        validationOnlyIntegration.mkProjectIntegration {
          pkgs = { };
          sourceRoot = ".";
          inherit settings;
        }
      )).success
    ) invalidSettings;
    true;

  interfaceAssertions =
    assert builtins.hasAttr "serena" integrationV1.apps;
    assert builtins.hasAttr "serena-project-sync" integrationV1.apps;
    assert builtins.hasAttr "serena-project-drift" integrationV1.apps;
    assert builtins.hasAttr "serena-project-drift" integrationV1.checks;
    assert builtins.hasAttr "serena-project-config" integrationV1.packages;
    assert builtins.hasAttr "serena" integrationV1.devShells;
    true;
in
assert validationAssertions;
assert interfaceAssertions;
{
  serena-project-integration =
    pkgs.runCommand "serena-project-integration-test"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.diffutils
          pkgs.findutils
          pkgs.git
          pkgs.gnugrep
        ];
      }
      ''
            set -euo pipefail

            sync_v1=${lib.escapeShellArg integrationV1.apps.serena-project-sync.program}
            drift_v1=${lib.escapeShellArg integrationV1.apps.serena-project-drift.program}
            sync_v2=${lib.escapeShellArg integrationV2.apps.serena-project-sync.program}
            drift_v2=${lib.escapeShellArg integrationV2.apps.serena-project-drift.program}
        sync_linked=${lib.escapeShellArg linkedIntegration.apps.serena-project-sync.program}
        serena_raw=${lib.escapeShellArg integrationV1.apps.serena.program}
        generated_v1=${lib.escapeShellArg (toString integrationV1.projectFile)}
        generated_v2=${lib.escapeShellArg (toString integrationV2.projectFile)}
        drift_check=${lib.escapeShellArg (toString integrationV1.checks.serena-project-drift)}
        config_package=${lib.escapeShellArg (toString integrationV1.packages.serena-project-config)}

            expect_failure() {
              if "$@" >expect-failure.stdout 2>expect-failure.stderr; then
                printf 'command unexpectedly succeeded:' >&2
                printf ' %q' "$@" >&2
                printf '\n' >&2
                exit 1
              fi
            }

        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"

        test "$("$serena_raw")" = 'stub serena'
        cmp "$generated_v1" "$drift_check/project.yml"
        cmp "$generated_v1" "$config_package/share/serena/project.yml"

            repo="$TMPDIR/repo with spaces"
            project="$repo/packages/api"
            mkdir -p "$project/.serena/cache" "$project/.serena/memories" "$project/nested/cwd"
            printf '{}\n' >"$repo/flake.nix"
            printf 'local sentinel\n' >"$project/.serena/project.local.yml"
            printf 'cache sentinel\n' >"$project/.serena/cache/sentinel"
            printf 'memory sentinel\n' >"$project/.serena/memories/sentinel"

            git -C "$repo" init -q
            git -C "$repo" config user.email serena-test@example.invalid
            git -C "$repo" config user.name 'Serena project integration test'
            git -C "$repo" add flake.nix packages/api/.serena/project.local.yml \
              packages/api/.serena/cache/sentinel packages/api/.serena/memories/sentinel
            git -C "$repo" commit -qm fixtures

            cd "$project/nested/cwd"
            "$sync_v1"
            cmp "$generated_v1" "$project/.serena/project.yml"
            grep -qx 'local sentinel' "$project/.serena/project.local.yml"
            grep -qx 'cache sentinel' "$project/.serena/cache/sentinel"
            grep -qx 'memory sentinel' "$project/.serena/memories/sentinel"
            test -z "$(find "$project/.serena" -maxdepth 1 -name '.project.yml.tmp.*' -print -quit)"

            # A byte-correct but untracked target is not accepted by the read-only app.
            expect_failure "$drift_v1"
            git -C "$repo" add packages/api/.serena/project.yml
            "$drift_v1"
            git -C "$repo" commit -qm 'track Serena configuration'

            # A clean tracked file may be advanced to newly rendered bytes.
            "$sync_v2"
            cmp "$generated_v2" "$project/.serena/project.yml"
            expect_failure "$drift_v1"
            "$drift_v2"
            git -C "$repo" add packages/api/.serena/project.yml
            git -C "$repo" commit -qm 'update Serena configuration'

            # Unstaged and staged edits are protected, while --force replaces only the
            # safe regular target file.
            printf 'unstaged edit\n' >"$project/.serena/project.yml"
            expect_failure "$sync_v2"
            "$sync_v2" --force
            cmp "$generated_v2" "$project/.serena/project.yml"

            printf 'staged edit\n' >"$project/.serena/project.yml"
            git -C "$repo" add packages/api/.serena/project.yml
            expect_failure "$sync_v2"
            "$sync_v2" --force
            cmp "$generated_v2" "$project/.serena/project.yml"
            git -C "$repo" reset -q HEAD -- packages/api/.serena/project.yml

            # Existing untracked content is never overwritten without explicit force.
            git -C "$repo" rm --cached -q packages/api/.serena/project.yml
            printf 'untracked edit\n' >"$project/.serena/project.yml"
            expect_failure "$sync_v2"
            "$sync_v2" --force
            cmp "$generated_v2" "$project/.serena/project.yml"
            git -C "$repo" add packages/api/.serena/project.yml

            # Missing and byte-different tracked files fail drift. A tracked deletion is
            # also protected from sync unless force is explicit.
            printf 'drift\n' >"$project/.serena/project.yml"
            expect_failure "$drift_v2"
            "$sync_v2" --force
            rm "$project/.serena/project.yml"
            expect_failure "$drift_v2"
            expect_failure "$sync_v2"
            "$sync_v2" --force

            # Neither force nor normal operation follows a target symlink.
            outside_target="$TMPDIR/outside-project.yml"
            printf 'outside target\n' >"$outside_target"
            rm "$project/.serena/project.yml"
            ln -s "$outside_target" "$project/.serena/project.yml"
            expect_failure "$sync_v2" --force
            grep -qx 'outside target' "$outside_target"
            rm "$project/.serena/project.yml"
            "$sync_v2" --force

            # The .serena directory itself receives the same unconditional protection.
            rm -rf "$project/.serena"
            outside_dir="$TMPDIR/outside-serena"
            mkdir "$outside_dir"
            printf 'outside directory\n' >"$outside_dir/sentinel"
            ln -s "$outside_dir" "$project/.serena"
            expect_failure "$sync_v2" --force
            grep -qx 'outside directory' "$outside_dir/sentinel"
            test ! -e "$outside_dir/project.yml"
            rm "$project/.serena"
            mkdir "$project/.serena"
            "$sync_v2" --force

            # A projectRoot symlink that escapes the Git root is rejected after its
            # physical path is resolved.
            outside_project="$TMPDIR/outside-project"
            mkdir "$outside_project"
            ln -s "$outside_project" "$repo/linked"
            cd "$repo"
            expect_failure "$sync_linked" --force
            test ! -e "$outside_project/.serena"

            # Runtime commands deliberately require a root flake.
            bootstrap="$TMPDIR/bootstrap"
            mkdir -p "$bootstrap/packages/api/nested"
            git -C "$bootstrap" init -q
            git -C "$bootstrap" config user.email serena-test@example.invalid
            git -C "$bootstrap" config user.name 'Serena project integration test'
            printf 'placeholder\n' >"$bootstrap/README"
            git -C "$bootstrap" add README
            git -C "$bootstrap" commit -qm bootstrap
            cd "$bootstrap/packages/api/nested"
            expect_failure "$sync_v1"
            printf '{}\n' >"$bootstrap/flake.nix"
            git -C "$bootstrap" add flake.nix
            git -C "$bootstrap" commit -qm flake
            "$sync_v1"
            cmp "$generated_v1" "$bootstrap/packages/api/.serena/project.yml"

            touch "$out"
      '';
}
