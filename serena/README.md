# Serena

This subflake packages [Serena](https://github.com/oraios/serena) and exposes
its complete stable YAML configuration surface as typed Nix options for Home
Manager and project flakes.

The selected release is one immutable stable tag. The current selection is
`v1.5.3` at commit `2449313c0d7427275c4c66aedff7d4881782f713`.
The package and Home Manager module therefore both have a `serena_1_5_3`
alias, so a consumer cannot accidentally combine a package with another
configuration schema.

## Outputs

- `packages.<system>.{default,serena,serena_1_5_3}`
- `apps.<system>.{default,serena}`
- `homeManagerModules.{default,serena,serena_1_5_3}`
- `flakeModules.{default,serena}` for flake-parts projects
- `lib.mkProjectIntegration` for plain project flakes
- `lib.mkGlobalConfig` and `lib.mkProjectConfig` render complete YAML
- `lib.mkBashLanguageServerWrapper` wires ShellCheck into Bash LS
- `lib.configSchema` exposes the selected schema manifest and mappings

## Home Manager

```nix
{
  inputs.serena = {
    url = "git+https://github.com/da-moon/flakes.git?dir=serena";
    inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-utils.follows = "flake-utils";
      home-manager.follows = "home-manager";
    };
  };

  outputs =
    { home-manager, nixpkgs, serena, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      bashLs = serena.lib.mkBashLanguageServerWrapper { inherit pkgs; };
    in
    {
      homeConfigurations.me = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          serena.homeManagerModules.serena_1_5_3
          {
            programs.serena = {
              enable = true;
              package = serena.packages.${system}.serena_1_5_3;

              runtimePackages = [
                pkgs.gopls
                pkgs.pyright
                pkgs.rust-analyzer
                pkgs.typescript-language-server
                pkgs.marksman
                bashLs
              ];

              global = {
                webDashboard = true;
                webDashboardOpenOnLaunch = false;
                webDashboardInterface = "browser";
                webDashboardListenAddress = "127.0.0.1";

                lsSpecificSettings = {
                  python.lsPath = "${pkgs.pyright}/bin/pyright-langserver";
                  rust.lsPath = "${pkgs.rust-analyzer}/bin/rust-analyzer";
                  typescript.lsPath = "${pkgs.typescript-language-server}/bin/typescript-language-server";
                  markdown.lsPath = "${pkgs.marksman}/bin/marksman";
                  bash.lsPath = "${bashLs}/bin/serena-bash-language-server";
                };
              };

              contexts.headless = {
                prompt = "Operate without graphical tools.";
                singleProject = true;
              };

              modes.review = {
                prompt = "Review the project without editing it.";
                excludedTools = [ "replace_symbol_body" ];
              };

              promptTemplates.local.onboardingPrompt =
                "Read the project instructions before changing files.";
            };
          }
        ];
      };
    };
}
```

The module installs Serena and wraps it with `SERENA_HOME` plus a private
`PATH` containing `runtimePackages`. It writes complete `0600` regular files
under `~/.serena`, rather than Home Manager store symlinks, because Serena
updates its registered-project list at runtime. Every Home Manager activation
restores the declared Nix configuration and removes only files recorded in its
own managed-file manifest.

Serena v1.5.3 exposes dashboard enablement, auto-open behavior, interface, and
listen address in YAML. It does **not** expose a dashboard port setting. The
CLI `--port` option configures the MCP HTTP transport port, not a persistent
dashboard YAML port, so this module deliberately does not invent one.

## Configuration model

Nix option names use lower camel case and render to Serena's snake-case YAML.
Typed options cover:

- every global and project field in the v1.5.3 source;
- all 64 `Language` enum values;
- all source- and documentation-discovered language-server settings;
- custom contexts and modes, including source-supported `fixed_tools`;
- every prompt-template key and arbitrary additional prompt keys.

Each scope has a free-form JSON-compatible escape hatch for forward
compatibility:

- `global.extraSettings`
- project `extraSettings`
- context and mode `extraSettings`
- `lsSpecificSettings.extraSettings`
- each typed language's `extraSettings`
- prompt file `extraPrompts`

Typed values always win if an escape-hatch key overlaps a typed option. No
literal `extra_settings` key is emitted.

## Plain project flakes

`lib.mkProjectIntegration` returns the app, sync and drift tools, drift check,
generated config package, and named development shell:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    serena.url = "git+https://github.com/da-moon/flakes.git?dir=serena";
  };

  outputs =
    { self, nixpkgs, serena }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      integration = serena.lib.mkProjectIntegration {
        inherit pkgs;
        sourceRoot = self.outPath;
        projectRoot = ".";
        package = serena.packages.${system}.serena_1_5_3;
        settings = {
          projectName = "example";
          languages = [ "nix" ];
          ignoredPaths = [ ".direnv" ];
        };
        extraPackages = [ pkgs.nixd ];
      };
    in
    {
      apps.${system} = integration.apps;
      checks.${system} = integration.checks;
      packages.${system} = integration.packages;
      devShells.${system} = integration.devShells;
    };
}
```

## flake-parts projects

```nix
{
  imports = [ inputs.serena.flakeModules.default ];

  serena.project = {
    enable = true;
    projectRoot = ".";
    settings = {
      projectName = "example";
      languages = [ "nix" ];
    };
  };

  perSystem = { pkgs, ... }: {
    serena.project.extraPackages = [ pkgs.nixd ];
  };
}
```

Both integrations expose:

- `nix run .#serena`
- `nix run .#serena-project-sync`
- `nix run .#serena-project-drift`
- `nix build .#serena-project-config`
- `nix develop .#serena`

The sync app writes only `.serena/project.yml`. It requires a root flake,
refuses path traversal and symlinks, protects staged, modified, and untracked
collisions, and writes atomically. Use `--force` only after reviewing a safe
regular-file collision. The drift app and check require the tracked file to be
byte-identical to the Nix output. Neither tool manages `project.local.yml`,
memories, caches, indexes, or logs.

## Updating

`scripts/update-version.sh` maintains the sole selected release in
`releases.json`, including the immutable revision, NAR hash, and source-derived
schema hash.

```console
./scripts/update-version.sh --check
./scripts/update-version.sh
./scripts/update-version.sh --tag v1.5.2
./scripts/update-version.sh --rehash
./scripts/update-version.sh --no-commit
```

With no explicit tag, the updater selects the highest final SemVer tag. An
explicit older final tag supports a deliberate rollback. `--rehash` keeps the
recorded tag and revision while recomputing hashes and schema evidence.

Updates are staged, package-built, and checked before atomic application. The
script refuses moved tags, concurrent managed-file changes, and dirty Serena
paths before its scoped auto-commit. There is intentionally no `--no-build`
escape hatch. Any source, fixture, prompt, language enum, language-server
setting, or guarded documentation drift exits with status 3 and retains the
candidate staging directory for typed-schema review.
