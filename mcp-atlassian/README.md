# mcp-atlassian

This subflake packages [mcp-atlassian](https://github.com/sooperset/mcp-atlassian),
an MCP server bridging Atlassian **Jira** and **Confluence** (Cloud and
Server/Data Center) with AI models. It is pure Python, so a single build from
the PyPI sdist serves `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, and
`aarch64-darwin`.

Versions are tracked in `releases.json` (appended by
`scripts/update-version.sh`, never hand-edited); each entry yields an
`mcp-atlassian_<version>` package alongside `default`/`mcp-atlassian` pointing
at the latest.

## Outputs

- `packages.<system>.{default,mcp-atlassian}` — latest release
- `packages.<system>.mcp-atlassian_<v>` — one pinned package per `releases.json` entry
- `packages.<system>.mcp-atlassian-auto` — env-guarded wrapper (see below)
- `apps.<system>.{default,mcp-atlassian,mcp-atlassian-auto}`

## `mcp-atlassian-auto`: which binary to register

The bare `mcp-atlassian` binary starts a stdio server that, with **no
credentials and no `--help`**, boots and then immediately errors out — so a
global MCP registration would **crash-loop every session** you start before
you've supplied credentials.

`mcp-atlassian-auto` fixes this: it fails fast with a clear message when
**neither** `JIRA_URL` **nor** `CONFLUENCE_URL` is set, otherwise it execs the
real server with all args/env passed through unchanged. It runs with just Jira,
just Confluence, or both.

**Register `mcp-atlassian-auto` in clients; reserve bare `mcp-atlassian` for
explicit per-project setups where you pass credentials as CLI flags.**

## Environment variables

Credentials are supplied via the MCP client's `env` block (the wrapper reads
them from the environment). Pick **at least one product**:

| Variable | Cloud | Server / Data Center |
|---|---|---|
| Jira | `JIRA_URL` + `JIRA_USERNAME` + `JIRA_API_TOKEN` | `JIRA_URL` + `JIRA_PERSONAL_TOKEN` |
| Confluence | `CONFLUENCE_URL` + `CONFLUENCE_USERNAME` + `CONFLUENCE_API_TOKEN` | `CONFLUENCE_URL` + `CONFLUENCE_PERSONAL_TOKEN` |

Get a Cloud API token at <https://id.atlassian.com/manage-profile/security/api-tokens>.

## Claude Code (global, `~/.claude.json`)

One-liner (writes `~/.claude.json`, `--scope user`):

```sh
claude mcp add --scope user mcp-atlassian \
  -e JIRA_URL='https://your-company.atlassian.net' \
  -e JIRA_USERNAME='you@company.com' \
  -e JIRA_API_TOKEN='your_api_token' \
  -e CONFLUENCE_URL='https://your-company.atlassian.net/wiki' \
  -e CONFLUENCE_USERNAME='you@company.com' \
  -e CONFLUENCE_API_TOKEN='your_api_token' \
  -- ~/.nix-profile/bin/mcp-atlassian-auto
```

Equivalent `mcpServers` entry in `~/.claude.json`:

```json
{
  "mcpServers": {
    "mcp-atlassian": {
      "type": "stdio",
      "command": "/home/YOU/.nix-profile/bin/mcp-atlassian-auto",
      "args": [],
      "env": {
        "JIRA_URL": "https://your-company.atlassian.net",
        "JIRA_USERNAME": "you@company.com",
        "JIRA_API_TOKEN": "your_api_token",
        "CONFLUENCE_URL": "https://your-company.atlassian.net/wiki",
        "CONFLUENCE_USERNAME": "you@company.com",
        "CONFLUENCE_API_TOKEN": "your_api_token"
      }
    }
  }
}
```

Use the absolute profile path rather than a bare command name — MCP clients do
not always inherit your interactive shell `PATH`, and the profile symlink stays
stable across Home Manager generations. To register **only Confluence**, drop
the three `JIRA_*` pairs (and vice-versa).

## Project-local `.mcp.json`

For a repo-scoped setup shared via the repo, drop a `.mcp.json` at the project
root. Credentials still come from `env` (the wrapper validates them):

```json
{
  "mcpServers": {
    "mcp-atlassian": {
      "type": "stdio",
      "command": "mcp-atlassian-auto",
      "args": [],
      "env": {
        "CONFLUENCE_URL": "https://your-company.atlassian.net/wiki",
        "CONFLUENCE_USERNAME": "you@company.com",
        "CONFLUENCE_API_TOKEN": "your_api_token"
      }
    }
  }
}
```

> Don't commit real tokens. Prefer environment expansion supported by your
> client, or keep `.mcp.json` in `.gitignore` and share a `.mcp.json.example`.

## Codex

CLI (writes `~/.codex/config.toml`):

```sh
codex mcp add mcp-atlassian \
  --env JIRA_URL='https://your-company.atlassian.net' \
  --env JIRA_USERNAME='you@company.com' \
  --env JIRA_API_TOKEN='your_api_token' \
  -- ~/.nix-profile/bin/mcp-atlassian-auto
```

Equivalent `[mcp_servers.mcp-atlassian]` table in `~/.codex/config.toml`:

```toml
[mcp_servers.mcp-atlassian]
command = "/home/YOU/.nix-profile/bin/mcp-atlassian-auto"
args = []

[mcp_servers.mcp-atlassian.env]
JIRA_URL = "https://your-company.atlassian.net"
JIRA_USERNAME = "you@company.com"
JIRA_API_TOKEN = "your_api_token"
CONFLUENCE_URL = "https://your-company.atlassian.net/wiki"
CONFLUENCE_USERNAME = "you@company.com"
CONFLUENCE_API_TOKEN = "your_api_token"
```

## Home Manager consumers

Install the package and point each client's declarative MCP config at the
profile path:

```nix
{
  inputs.mcp-atlassian = {
    url = "git+https://github.com/da-moon/flakes.git?dir=mcp-atlassian";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.flake-utils.follows = "flake-utils";
  };

  # ...
  home.packages = [
    inputs.mcp-atlassian.packages.${system}.mcp-atlassian-auto
  ];

  # Declarative MCP registration example (adapt to your client's module):
  # programs.omp.mcpServers.mcp-atlassian = {
  #   command = "${config.home.profileDirectory}/bin/mcp-atlassian-auto";
  #   env = {
  #     JIRA_URL = "https://your-company.atlassian.net";
  #     # ...do NOT put tokens here: HM store paths are world-readable.
  #     # Keep secrets in your shell env, a secrets manager, or an env file
  #     # consumed by the BARE binary (see Secrets below).
  #   };
  # };
}
```

> **Secrets:** Home Manager configs are world-readable store paths — never put
> API tokens in `env` inside the Nix file. The `mcp-atlassian-auto` wrapper
> reads credentials from the process environment only; it does **not** parse
> `--env-file`. To load credentials from a file, use the **bare** binary
> (`mcp-atlassian --env-file ~/.config/mcp-atlassian.env`) — it reads the env
> file directly — or inject the variables into your shell / secrets manager
> before launching the wrapper.

## Verifying

```sh
mcp-atlassian-auto            # unconfigured → prints the guard message, exit 1
JIRA_URL=https://x mcp-atlassian-auto --help   # configured → prints server help
mcp-atlassian --help          # bare binary, always works
```
