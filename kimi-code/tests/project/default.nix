# Project-integration test: sync/drift apps in a real temp git repo, plus the
# committed-file drift check against fixtures/source.
{ pkgs, lib }:
let
  schema = import ../../modules/config-schema.nix { inherit lib; };

  normalize =
    type: value:
    (lib.evalModules {
      modules = [
        {
          options.value = lib.mkOption { inherit type; };
          config.value = value;
        }
      ];
    }).config.value;

  fixtureMcpServers = normalize (lib.types.attrsOf schema.mcpServerType) {
    test-server = {
      url = "https://example.com/mcp";
      bearerTokenEnvVar = "TEST_TOKEN";
    };
  };

  mkIntegration =
    sourceRoot:
    import ../../modules/project-integration.nix {
      inherit pkgs sourceRoot;
      kimiPackage = pkgs.hello; # stub: not exercised by these tests
      mcpServers = fixtureMcpServers;
    };

  integration = mkIntegration ./fixtures/source;
in
{
  # The committed fixture must byte-match the Nix render.
  kimi-project-drift-fixture = integration.checks.kimi-project-drift;

  kimi-project-integration = pkgs.runCommand "kimi-project-integration-test"
    {
      nativeBuildInputs = [
        pkgs.coreutils
        pkgs.git
        pkgs.gnugrep
        pkgs.diffutils
      ];
    }
    ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      git config --global user.email "test@example.com"
      git config --global user.name "test"
      git config --global init.defaultBranch master

      repo="$TMPDIR/repo with spaces"
      mkdir -p "$repo"
      cd "$repo"
      git init -q
      touch flake.nix
      git add flake.nix
      git commit -qm init

      sync="${integration.apps.kimi-project-sync.program}"
      drift="${integration.apps.kimi-project-drift.program}"
      rendered=${integration.packages.kimi-project-mcp-config}

      # sync resolves the git root from a nested cwd
      mkdir -p sub/dir
      cd sub/dir
      "$sync"
      cd "$repo"
      [ -f .kimi-code/mcp.json ]
      cmp "$rendered" .kimi-code/mcp.json

      # idempotent
      out1="$("$sync")"
      case "$out1" in
        *"up to date"*) ;;
        *)
          echo "expected up-to-date, got: $out1"
          exit 1
          ;;
      esac

      # untracked modification refused; --force overwrites
      echo '{}' > .kimi-code/mcp.json
      if "$sync" 2>err.txt; then
        echo "expected refusal on untracked collision"
        exit 1
      fi
      grep -q "not tracked" err.txt
      "$sync" --force
      cmp "$rendered" .kimi-code/mcp.json

      # drift refuses untracked files
      if "$drift" 2>err2.txt; then
        echo "expected drift failure (untracked)"
        exit 1
      fi

      git add .kimi-code/mcp.json
      git commit -qm mcp

      # tracked + clean: drift passes
      "$drift"

      # dirty tracked file refused without --force
      echo '{"mcpServers":{}}' > .kimi-code/mcp.json
      if "$sync" 2>err3.txt; then
        echo "expected refusal on dirty tracked file"
        exit 1
      fi
      grep -q "uncommitted" err3.txt

      # drift reports the difference
      if "$drift" 2>err4.txt; then
        echo "expected drift failure (modified)"
        exit 1
      fi
      grep -q "drift" err4.txt

      git checkout -q -- .kimi-code/mcp.json
      "$drift"

      touch $out
    '';
}
