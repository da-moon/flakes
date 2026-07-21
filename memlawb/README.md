# memlawb

Nix flake for [memlawb](https://github.com/Gitlawb/memlawb) — open-source,
self-hostable, zero-knowledge agent memory. Server, sync CLI, and stdio MCP
server in one `memlawb` binary (Bun runs the TypeScript entrypoint directly).

Current release: `0.1.0-unstable-2026-06-27` (`0c9f82d`, versioned alias
`memlawb_0c9f82d`). Upstream has no release tags, so entries in
`releases.json` are keyed by short commit hash; `scripts/update-version.sh`
tracks `HEAD`.

## Outputs

- `packages.<system>.{default,memlawb,memlawb_<key>}` — the package
- `apps.<system>.{default,memlawb}` — the CLI (`push`/`pull`/`mcp`/`serve`)
- `apps.<system>.memlawb-mcp` / `apps.<system>.memlawb-serve` — convenience entrypoints
- `homeManagerModules.{default,memlawb}` — `programs.memlawb` (wrapped CLI + optional server service)
- `flakeModules.{default,memlawb}` — `memlawb.project` flake-parts module
- `checks.<system>.{package,cli,server,mcp-stdio,module-eval}`

All configuration from the upstream
[.env.example](https://github.com/Gitlawb/memlawb/blob/main/.env.example) is
managed as typed Nix options (see `modules/options.nix`).

## Home-manager

Runs the server as a systemd user service and installs the CLI wrapped with
the client environment, so `memlawb mcp` works for any MCP client out of the
box:

```nix
{
  inputs.memlawb.url = "git+https://github.com/da-moon/flakes.git?dir=memlawb";

  # home-manager configuration:
  imports = [ inputs.memlawb.homeManagerModules.default ];

  programs.memlawb = {
    enable = true;

    client = {
      url = "http://localhost:8080";       # MEMLAWB_URL (null = upstream default)
      namespace = "user:me";               # MEMLAWB_NAMESPACE
      scan = "block";                      # MEMLAWB_SCAN: block|warn|off
      # Secrets stay out of the store — a file with MEMLAWB_PASSPHRASE=...
      # (and MEMLAWB_API_KEY=... if the server requires auth):
      environmentFile = "/home/alice/.secrets/memlawb";
    };

    server = {
      enable = true;                       # systemd user service (Linux only)
      port = 8080;                         # PORT
      store = "fs";                        # STORE: fs|s3
      # dataDir defaults to ~/.local/share/memlawb  (DATA_DIR)
      allowUnauthenticated = true;         # single-user self-host ONLY
      # staticApiKeys / supabase / s3 / limits / rateLimit map 1:1 to the
      # upstream env vars; secrets belong in server.environmentFile.
    };
  };
}
```

Then point your MCP client at `memlawb mcp`, e.g.
`claude mcp add memlawb -- memlawb mcp`.

## Project flake (flake-parts)

Gives a project the CLI and MCP server with per-project client settings, and
manages a `memlawb` entry in the project's `.mcp.json`:

```nix
{
  inputs.memlawb.url = "git+https://github.com/da-moon/flakes.git?dir=memlawb";

  imports = [ inputs.memlawb.flakeModules.default ];

  memlawb.project = {
    enable = true;
    namespace = "project:myrepo";
    url = "https://memory.example.com";    # or null for localhost:8080
    # environmentFile = "/home/alice/.secrets/memlawb";
  };
}
```

Per-system overrides are available too:

```nix
perSystem = { pkgs, ... }: {
  memlawb.project.extraPackages = [ pkgs.bun ];
};
```

Resulting outputs on the consuming flake:

- `devShells.memlawb` — shell with the wrapped `memlawb` CLI on `PATH`
- `apps.memlawb` / `apps.memlawb-mcp` — run the CLI / stdio MCP server
- `apps.memlawb-mcp-sync` — write/merge the memlawb entry into `.mcp.json`
  (existing entries are preserved; commit the file afterwards)
- `checks.memlawb-mcp-drift` — fails when `.mcp.json` drifts from the Nix
  configuration (set `memlawb.project.mcp.enable = false` to opt out)

The MCP passphrase is never managed by Nix: export `MEMLAWB_PASSPHRASE` (or
use `environmentFile`) so agents inherit it at launch.

## Updating

```sh
./scripts/update-version.sh            # track upstream HEAD
./scripts/update-version.sh --check    # exit 1 when an update is available
./scripts/update-version.sh --rehash   # re-pin the current rev
```

The script pins the rev in `releases.json`, regenerates the committed
deps-only lockfiles under `deps/<key>/` (upstream's `package.json` lacks the
imported-but-undeclared `zod`, which the script merges in), verifies the
build, and auto-commits (`--no-commit` to skip).
