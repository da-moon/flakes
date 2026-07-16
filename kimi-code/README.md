# kimi-code flake

[Kimi Code](https://www.kimi.com/code/docs/en/) CLI packaged as a Nix flake,
with Nix-managed configuration at two levels:

- **Home Manager module** — manages the global `~/.kimi-code/` data directory
  (`config.toml`, `tui.toml`, `mcp.json`, `[[hooks]]`) from typed Nix options.
- **Project integration** — a flake-parts module (plus a plain-flake
  `lib.mkProjectIntegration`) that manages the committed
  `.kimi-code/mcp.json`, with optional project-local `KIMI_CODE_HOME`
  isolation for fully per-project config (including hooks).

Current release table: see `releases.json` (`latest` plus pinned past
versions; `scripts/update-version.sh` appends new ones).

## Outputs

- `packages.{default, kimi-code, kimi-code_<version>}` — the `kimi` binary
  (one versioned attr per `releases.json` entry, e.g. `kimi-code_0_26_0`).
- `apps.{default, kimi}` — `nix run` the latest package.
- `homeManagerModules.{default, kimi-code, kimi-code_<version>}` — the
  Home Manager module; the versioned aliases pair the module with a pinned
  package version explicitly.
- `flakeModules.{default, kimi-code}` — the flake-parts project module.
- `lib.{mkProjectIntegration, mkGlobalConfig, mkProjectConfig, configSchema,
  tuiConfigSchema, projectModule}` — consumer API.
- `checks.{module-eval, config-merge, kimi-project-integration,
  kimi-project-drift-fixture}` — run via `nix flake check`.

## Home Manager usage

```nix
{
  inputs.kimi-code = {
    url = "git+https://github.com/da-moon/flakes.git?dir=kimi-code";
    inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-utils.follows = "flake-utils";
    };
  };

  outputs = { home-manager, kimi-code, ... }: {
    homeConfigurations.you = home-manager.lib.homeManagerConfiguration {
      # ...
      modules = [
        kimi-code.homeManagerModules.kimi-code_0_26_0
        ({ pkgs, ... }: {
          programs.kimi-code = {
            enable = true;
            package = kimi-code.packages.${pkgs.system}.kimi-code_0_26_0;

            # ~/.kimi-code/config.toml (declarative core, see semantics below)
            settings = {
              defaultModel = "kimi-code/k3";
              thinking = { enabled = true; effort = "max"; };
              loopControl = {
                maxRetriesPerStep = 3;
                # freeform passthrough for keys the typed schema doesn't cover:
                extraSettings = { compaction_trigger_ratio = 0.85; };
              };
              providers."managed:kimi-code" = {
                type = "kimi";
                baseUrl = "https://api.kimi.com/coding/v1";
                apiKey = "";   # OAuth via /login; grafted back on each switch
              };
              models."kimi-code/k3" = {
                provider = "managed:kimi-code";
                model = "k3";
                maxContextSize = 1048576;
              };
              permission.rules = [
                { decision = "allow"; pattern = "Read"; }
                { decision = "deny"; pattern = "Bash(rm -rf*)"; }
              ];
            };

            # ~/.kimi-code/tui.toml (fully managed; upgrade.auto_install
            # defaults to false so the CLI won't self-update around Nix)
            tui = {
              theme = "dark";
              notifications = { enabled = true; notificationCondition = "unfocused"; };
            };

            # ~/.kimi-code/mcp.json (fully declarative)
            mcpServers = {
              "parallel-search" = {
                url = "https://search-mcp.parallel.ai/mcp";
                bearerTokenEnvVar = "PARALLEL_API_KEY"; # no secret in the store
              };
            };

            # Hooks are NOT bundled with the flake — define scripts in your
            # own config and pass them in. Upserted by name in [[hooks]].
            hooks = [
              {
                name = "redirect-web-tools";
                event = "PreToolUse";
                timeout = 5;
                runtimeInputs = [ pkgs.gnugrep pkgs.gnused pkgs.coreutils ];
                script = ''
                  payload="$(cat)"
                  tool_name="$(printf '%s' "$payload" \
                    | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
                    | head -n1 \
                    | sed 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
                  case "$tool_name" in
                    WebSearch|FetchURL)
                      echo "use the parallel-search MCP instead" >&2
                      exit 2
                      ;;
                    *) exit 0 ;;
                  esac
                '';
              }
            ];
          };
        })
      ];
    };
  };
}
```

### Configuration model (home-manager level)

The CLI mutates its config at runtime (`/login` injects
`[providers.*.oauth]`, `/provider` edits provider entries, `/theme` writes
`tui.toml`), so the module does **not** symlink store files. On each
`home-manager switch` an activation script merges the Nix-rendered config
into the live files with declarative-core semantics:

- **Declared keys win.** Runtime edits to declared keys are reset on the
  next switch.
- **Typed-but-undeclared keys inside a declared section are removed** (back
  to upstream defaults). Sections (`thinking`, `loop_control`, `background`,
  `subagent`, `image`) and scalars are only managed when declared.
- **Replace tables** (`providers`, `models`, `services`, `permission`) are
  replaced wholesale when declared — hand-added entries are dropped.
- **OAuth graft:** `[providers.<name>.oauth]` and `[services.<name>.oauth]`
  references injected by `/login` are copied back onto declared entries.
- **Unknown keys are preserved** anywhere (forward-compat with new CLI
  versions); `extraSettings` per section lets you also *declare* keys the
  typed schema doesn't cover yet.
- **Hooks** are upserted by name; stale Nix-managed hook entries are pruned
  (tracked via `~/.kimi-code/hooks/.nix-managed-hooks`); foreign hand-added
  hooks are preserved.
- **`mcp.json` is fully declarative** when `mcpServers` is set — the file
  contains exactly the declared servers. Use `bearerTokenEnvVar` instead of
  literal `Authorization` headers so secrets never enter the Nix store.
- Runtime state (`sessions/`, `credentials/`, `logs/`, `updates/`, `bin/`,
  `plugins/`, `local.toml`, …) is never touched.

## Project usage (flake-parts)

```nix
{
  inputs.kimi-code.url = "git+https://github.com/da-moon/flakes.git?dir=kimi-code";
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";

  outputs = inputs@{ flake-parts, kimi-code, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];
      imports = [ kimi-code.flakeModules.default ];

      kimi.project = {
        enable = true;
        # committed .kimi-code/mcp.json (team-shared):
        mcpServers = {
          firecrawl = {
            url = "https://mcp.firecrawl.dev/mcp";
            bearerTokenEnvVar = "FIRECRAWL_API_KEY";
          };
        };
        # optional: project-local KIMI_CODE_HOME (per-project config + hooks)
        isolation = {
          enable = true;
          shareCredentials = true; # reuse the global OAuth login (default)
        };
        settings.defaultPermissionMode = "auto";
        hooks = [
          { name = "guard"; event = "PreToolUse"; matcher = "Bash"; script = "..."; }
        ];
      };
    };
}
```

This gives you:

- `nix run .#kimi-project-sync` — writes the Nix-rendered
  `.kimi-code/mcp.json` into the worktree (atomic, refuses to clobber
  untracked or dirty files unless `--force`). Commit the result.
- `nix run .#kimi-project-drift` — read-only diff against the render.
- `nix flake check` — includes a drift check comparing the committed file
  against the render, so CI fails when they diverge.
- `nix build .#kimi-project-mcp-config` — the rendered file for inspection.
- `nix develop .#kimi` — a shell with the `kimi` binary; when
  `isolation.enable = true` it exports
  `KIMI_CODE_HOME=<repo>/.kimi-code/home` and renders the declared
  `config.toml`/`tui.toml`/`mcp.json`/hooks there on entry (gitignore
  `.kimi-code/home/`). With `shareCredentials = true` (default) the isolated
  home symlinks `credentials/` to the global one and grafts OAuth references
  from the global `config.toml`, so no per-project re-login is needed.

Kimi Code has no native project-level `config.toml`/`tui.toml`/hooks
mechanism — project `settings`, `tui`, and `hooks` therefore only take
effect under isolation. `.kimi-code/mcp.json` is native and works with or
without isolation (project entries override user-level ones by name).

## Project usage (plain flake, no flake-parts)

```nix
{
  outputs = { self, nixpkgs, kimi-code, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      integration = kimi-code.lib.mkProjectIntegration {
        inherit pkgs;
        sourceRoot = self.outPath;      # enables the drift check
        projectRoot = ".";              # or "packages/api"
        mcpServers = {
          test-server = {
            url = "https://example.com/mcp";
            bearerTokenEnvVar = "TEST_TOKEN";
          };
        };
        isolation = { enable = true; shareCredentials = true; };
      };
    in
    {
      inherit (integration) apps checks devShells packages;
    };
}
```

## Notes

- Provider credentials are read only from `config.toml` (never from shell
  environment variables) — OAuth via `/login` is the recommended flow and is
  preserved by the oauth graft.
- `tui.upgrade.autoInstall` defaults to `false` here (upstream default is
  `true`): the binary is Nix-managed, so updates come from
  `scripts/update-version.sh`, not self-update.
- `scripts/update-version.sh` appends new upstream releases to
  `releases.json` and verifies the build; it does not touch the module code.
