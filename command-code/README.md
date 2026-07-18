# Command Code

This subflake packages Command Code and provides version-coupled, typed Nix
configuration for global Home Manager use and private project-local use. The
current package and schema are Command Code 0.52.1.

## Outputs

- `packages.<system>.{default,command-code,command-code_0_52_1}`
- `apps.<system>.{default,command-code}`
- `homeManagerModules.{default,command-code,command-code_0_52_1}`
- `flakeModules.{default,command-code}` for flake-parts projects
- `lib.{configSchema,mkGlobalConfig,mkProjectConfig,mkProjectIntegration}`

The versioned Home Manager module rejects a package from another Command Code
release. Historical packages remain available, but this flake does not pretend
that the 0.52.1 configuration contract applies to them.

## Home Manager

```nix
{
  inputs.command-code = {
    url = "git+https://github.com/da-moon/flakes.git?dir=command-code";
    inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-utils.follows = "flake-utils";
      home-manager.follows = "home-manager";
    };
  };

  # In the Home Manager module list:
  # inputs.command-code.homeManagerModules.command-code_0_52_1

  programs.command-code = {
    enable = true;
    package = inputs.command-code.packages.${pkgs.system}.command-code_0_52_1;

    config = {
      provider = "command-code";
      model = "zai-org/GLM-5.2";
      reasoningEffort."zai-org/GLM-5.2" = "max";
    };

    hooks.enableDefaultStripCoauthor = true;
  };
}
```

The module materializes regular writable files rather than Home Manager store
symlinks. It owns only declared JSON fields and exact managed hooks; Command
Code can continue writing runtime state to the same files. A private ownership
manifest makes removal and later activation idempotent.

First adoption refuses a conflicting value that Nix does not already own. After
reviewing the conflict, set `migration.force = true` for one activation and
remove it immediately afterward. The sync engine rejects `force` once an
ownership manifest exists, so it cannot become a permanent overwrite switch.

## Project flakes

```nix
{
  imports = [ inputs.command-code.flakeModules.default ];

  command-code.project = {
    enable = true;
    projectRoot = ".";

    settings = {
      tasteLearning = false;
      input.collapsePastedText = true;
    };
  };

  perSystem = { pkgs, ... }: {
    command-code.project.extraPackages = [ pkgs.jq ];
  };
}
```

The project module writes Command Code configuration only to
`.commandcode/settings.local.json` and the private per-project MCP file under
`~/.commandcode/projects`. It also keeps a private ownership manifest and an
exact `.git/info/exclude` entry. It refuses tracked local settings and never
writes the shared `.commandcode/settings.json` or `.mcp.json` files.

It exposes:

- `nix run .#command-code-project-sync` to apply local configuration
- `nix run .#command-code-project-drift` to check it without changing files
- `nix run .#command-code` to synchronize, run from the canonical project root,
  and repair managed fields on exit
- `nix develop .#command-code` for the same synchronized project environment

The plain-flake `lib.mkProjectIntegration` helper returns the same apps, check,
package, and development shell without requiring flake-parts.

## Schema and secrets

See [docs/configuration-schema.md](docs/configuration-schema.md) for the full
source/docs cross-reference and the declarative boundary. Authentication,
tokens, trust decisions, sessions, histories, and learned Taste content are not
managed. MCP secret-bearing headers, environment maps, and OAuth client secrets
are intentionally excluded so they cannot enter the Nix store.

## Updating

`scripts/update-version.sh` fetches the npm release, derives the platform hash,
and statically extracts configuration evidence without executing Command Code.
Structural schema drift stops the update for review; catalog-only model changes
refresh metadata because model identifiers are intentionally typed as strings.
