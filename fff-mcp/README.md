# fff-mcp

This subflake packages [fff-mcp](https://github.com/dmtrKovalenko/fff), the
MCP server for FFF — a frecency-ranked, typo-resistant file and content
search engine. It exposes `find_files`, `grep`, and `multi_grep` tools so AI
coding agents (Claude Code, Codex, Kimi Code, omp, ...) can search a
repository with fewer roundtrips than built-in grep/find.

Versions are tracked in `releases.json` (appended by
`scripts/update-version.sh`, never hand-edited); each entry yields a
`fff-mcp_<version>` package alongside `default`/`fff-mcp` pointing at the
latest.

## Outputs

- `packages.<system>.{default,fff-mcp}` — latest release binary
- `packages.<system>.fff-mcp_<v>` — one pinned package per `releases.json` entry
- `packages.<system>.fff-mcp-auto` — self-configuring wrapper (see below)
- `apps.<system>.{default,fff-mcp}`

## `fff-mcp-auto`: which binary to register

Bare `fff-mcp` indexes its working directory and **hard-refuses `$HOME` and
`/`** (`"Can not run certain FFF features in a file system root or home
directories"`). MCP clients spawn stdio servers with cwd = the session's
project root, so a globally registered bare `fff-mcp` crashes every session
you happen to start from your home directory.

`fff-mcp-auto` fixes this: it always passes `$PWD` as the explicit index
path (per-project indexing from one global registration), and when cwd
canonicalizes to `$HOME` or `/` it opts in via `FFF_ENABLE_HOME_SCAN` /
`FFF_ENABLE_ROOT_SCAN` and disables the filesystem watcher (`--no-watch`),
so the session degrades gracefully instead of dying. It never sets
`--frecency-db`, so the shared default ranking history is preserved.

**Register `fff-mcp-auto` in clients; reserve bare `fff-mcp` for explicit
per-project setups where you control the path argument.**

## Claude Code (global)

One-liner (writes `~/.claude.json`):

```sh
claude mcp add --scope user fff -- ~/.nix-profile/bin/fff-mcp-auto
```

or the equivalent `mcpServers` entry in `~/.claude.json`:

```json
{
  "mcpServers": {
    "fff": {
      "type": "stdio",
      "command": "/home/YOU/.nix-profile/bin/fff-mcp-auto",
      "args": [],
      "env": {}
    }
  }
}
```

Use the absolute profile path rather than a bare command name — MCP clients
do not always inherit your interactive shell `PATH`, and the profile symlink
stays stable across Home Manager generations.

## Project-local `.mcp.json`

For a repo-scoped setup (shared with collaborators via the repo), drop a
`.mcp.json` at the project root. Here the cwd is always the project, so
either binary works; bare `fff-mcp` with an explicit path is the most
self-documenting:

```json
{
  "mcpServers": {
    "fff": {
      "type": "stdio",
      "command": "fff-mcp",
      "args": ["--no-update-check", "."],
      "env": {}
    }
  }
}
```

(`fff-mcp-auto` with `"args": []` is equivalent and adds the home-dir
safety net.)

## Codex

```sh
codex mcp add fff -- ~/.nix-profile/bin/fff-mcp-auto
```

## Home Manager consumers

The wrapper is a plain extra package output — install it and point each
client's declarative MCP config at the profile path:

```nix
{
  inputs.fff-mcp = {
    url = "git+https://github.com/da-moon/flakes.git?dir=fff-mcp";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # ...
  home.packages = [ inputs.fff-mcp.packages.${system}.fff-mcp-auto ];

  # kimi-code (this repo's module)
  programs.kimi-code.mcpServers.fff = {
    command = "${config.home.profileDirectory}/bin/fff-mcp-auto";
  };

  # omp (this repo's module; renders ~/.omp/agent/mcp.json)
  programs.omp.mcpServers.fff = {
    command = "${config.home.profileDirectory}/bin/fff-mcp-auto";
  };
}
```

## Verifying

```sh
fff-mcp-auto --healthcheck          # from anywhere, including $HOME
cd some/project && fff-mcp-auto --healthcheck
```

Both must print `All checks passed.`. Note that fff walks up to the
enclosing git root: spawned from a subdirectory of a repo, it indexes the
whole repo, not just the subdirectory.
