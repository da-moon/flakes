# sentrux (Nix flake)

[sentrux/sentrux](https://github.com/sentrux/sentrux) — pure-Rust, single-binary
**architectural sensor** that scans a codebase into 5 root-cause metrics
(modularity, acyclicity, depth, equality, redundancy) and one 0–10000 score, so
AI coding agents get a real feedback loop on code quality. MIT licensed.

This flake packages the upstream prebuilt binary **and** bundles the tree-sitter
language grammars (`$out/share/sentrux/grammars`, exposed via
`SENTRUX_GRAMMARS_DIR`) — so unlike the bare upstream binary there is **no
one-time ~30 MB grammar download** on first run.

## Commands

```sh
sentrux                 # interactive GUI (live treemap) — needs a display
sentrux /path/to/proj   # GUI scanning a specific directory
sentrux check .         # CI-friendly rules check (exits 0 / 1)
sentrux gate --save .   # save a quality baseline before an agent session
sentrux gate .          # compare against baseline — catches degradation
sentrux mcp             # start the MCP server over stdio (see below)
```

`mcp` and `check` / `gate` are headless and need no display; the GTK/Wayland/X11
closure is only for the GUI. On this headless host you'll use `sentrux mcp` and
`sentrux check`.

---

## Running sentrux as an MCP server

The server speaks stdio and is launched with **`sentrux mcp`** (the upstream
README also accepts the flag form `sentrux --mcp`; both are equivalent). Once a
harness has it registered, the agent can read live structural scores, run rules,
and diff baselines through the standard MCP tool interface.

Below: each harness gets **(a)** a CLI one-liner where one exists, and
**(b)** the raw config-file form. Pick one.

### Claude Code

Has a dedicated `mcp` subcommand:

```sh
# user scope = available in every project (recommended for a sensor).
# drop `-s user` for project-local scope (writes .mcp.json instead).
claude mcp add -s user sentrux -- sentrux --mcp
claude mcp list            # verify it registered
```

Raw config — project-level `.mcp.json` (or the `mcpServers` block in
`~/.claude.json` for user scope):

```json
{
  "mcpServers": {
    "sentrux": { "command": "sentrux", "args": ["--mcp"] }
  }
}
```

> Claude Code also ships a first-class sentrux plugin:
> `/plugin marketplace add sentrux/sentrux` then `/plugin install sentrux`. The
> MCP config above is the transport-only equivalent for non-plugin setups.

### Codex (OpenAI)

Has a dedicated `mcp` subcommand:

```sh
codex mcp add sentrux -- sentrux --mcp
codex mcp list
```

Raw config — append to `~/.codex/config.toml`:

```toml
[mcp_servers.sentrux]
command = "sentrux"
args = ["--mcp"]
```

### kimi-code

**No `mcp add` CLI** — kimi-code is config-file driven (`~/.kimi-code/mcp.json`,
fully declarative when managed). Two ways to add it:

Declarative (Home Manager) — in your `programs.kimi-code` block:

```nix
programs.kimi-code.mcpServers.sentrux = {
  command = "sentrux";
  args = [ "--mcp" ];
};
```

Ad-hoc shell (writes the user-level file directly):

```sh
mkdir -p ~/.kimi-code && cat >> ~/.kimi-code/mcp.json <<'EOF'
{
  "mcpServers": {
    "sentrux": { "command": "sentrux", "args": ["--mcp"] }
  }
}
EOF
```

If `mcp.json` already has other servers, merge this `sentrux` entry into the
existing `mcpServers` object instead of appending a second top-level object.
Validate with `kimi doctor`.

### omp (oh-my-pi)

**No `mcp add` CLI** — omp reads `~/.omp/agent/mcp.json` (written declaratively
by the Home Manager module). Two ways to add it:

Declarative (Home Manager) — in your `programs.omp` block:

```nix
programs.omp.mcpServers.sentrux = {
  type = "stdio";
  command = "sentrux";
  args = [ "--mcp" ];
};
```

Ad-hoc shell (writes the file directly):

```sh
mkdir -p ~/.omp/agent && cat >> ~/.omp/agent/mcp.json <<'EOF'
{
  "mcpServers": {
    "sentrux": {
      "type": "stdio",
      "enabled": true,
      "command": "sentrux",
      "args": ["--mcp"]
    }
  }
}
EOF
```

As with kimi-code, merge into an existing `mcpServers` object rather than
appending a duplicate top-level key.

---

## Verifying the server

```sh
# 1. binary is on PATH and grammars are bundled (no download expected):
sentrux --version

# 2. server speaks MCP over stdio — send initialize, expect a JSON-RPC reply:
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' \
  | sentrux mcp
```

Within a harness, list its MCP servers and confirm `sentrux` appears, then ask
the agent to call a sentrux tool (e.g. report the current quality score for the
working directory).

## Platforms

This flake builds for `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`
(matching upstream's release assets). There is **no `x86_64-darwin` (Intel Mac)
build** — consumer flakes that mirror this tool should gate the entry on
`aarch64-darwin` so they still evaluate on Intel Macs.
