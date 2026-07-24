# Command Code configuration schema

This flake derives its configuration contract from the packaged Command Code
bundle and cross-checks it against the public documentation. Command Code does
not publish an aggregate JSON Schema, and several settings are only discoverable
in the application source. The selected schema is therefore coupled to the
selected package release and checked during version updates.

The 1.1.1 review cross-referenced the public [documentation index](https://commandcode.ai/docs),
[hook guide](https://commandcode.ai/docs/hooks), [MCP guide](https://commandcode.ai/docs/mcp),
[model reference](https://commandcode.ai/docs/reference/cli/models), and
[Taste guide](https://commandcode.ai/docs/taste) against the statically extracted
[`schema/upstream.json`](../schema/upstream.json) evidence. The source artifact
records the exact npm package and entrypoint hashes used for that comparison.

The 1.3.1 review found catalog-only drift (new entries in the bundled model
catalog); the structural schema is unchanged from 1.1.1, so the typed surface
below still applies.

## Configuration scopes

| Scope | File | Nix ownership |
| --- | --- | --- |
| Global preferences | `~/.commandcode/config.json` | Declared preference leaves only |
| Global settings | `~/.commandcode/settings.json` | Declared settings and exact managed hooks |
| Global MCP | `~/.commandcode/mcp.json` | Non-secret declared server leaves only |
| Project-local settings | `.commandcode/settings.local.json` | Declared local leaves only |
| Project-local MCP | `~/.commandcode/projects/<slug>/mcp.json` | Non-secret declared server leaves only |

The project module never writes the shared `.commandcode/settings.json` or
`.mcp.json` files. Unknown fields and application-owned state in mutable files
are preserved by a manifest-backed merge rather than replaced by Nix store
symlinks.

## Typed global preferences

The global `config.json` surface includes:

- `provider`: `command-code`, `anthropic`, `github-copilot`, or `codex`
- `model`: model identifier string
- `reasoningEffort`: model identifier to `low`, `medium`, `high`, `xhigh`, or
  `max`
- `theme`: `dark` or `light`
- `compactMode`: `default` or `fast`
- `telemetry`, `tasteLearning`, and `autoInstallExtension`: booleans
- `featureModels`: fixed feature keys whose values are model identifier strings

Model identifiers remain strings because the bundled catalog changes between
releases and Command Code accepts dynamically available model IDs. The fixed
shape and the enums that Command Code itself enforces remain strict.

## Typed settings

Global and project-local settings support `disabledSkills`,
`input.collapsePastedText`, and hooks. Project-local settings additionally
support `tasteLearning` and the functional portion of `permissions`.

Hook events are `PreToolUse`, `PostToolUse`, `Stop`, and `SessionStart`. Command
entries support a non-empty command, a positive timeout up to 600 seconds, and
the `async` and `failClosed` flags. An asynchronous hook cannot fail closed and
is rejected by the Nix schema.

Only `permissions.defaultMode = "acceptEdits"`, the create/update/delete
auto-approval flags, and `Bash(...)` allow entries affect Command Code 1.1.1.
Although the application may write a `deny` array, this release never reads it;
the module does not expose a misleading security option for it.

## MCP boundary

MCP servers use a strict transport union:

- `stdio` requires `command` and may include `args`.
- `http` requires `url` and may include public OAuth endpoints, client ID, and
  scopes.

Server names follow the CLI restriction and may not contain `__`. OAuth tokens
and client secrets remain in Command Code's private token store.

The documentation says strings such as `${API_KEY}` are expanded at runtime.
The 1.1.1 load and transport path passes configured environment and header
strings through literally. To prevent credentials entering the world-readable
Nix store, this module deliberately does not expose MCP `headers`, explicit
`env` maps, or `oauth.clientSecret`. Stdio processes still inherit the parent
environment, and manually managed secret leaves are preserved.

## Application-owned state

The module never manages authentication files, MCP token storage, trusted-hook
state, histories, transcripts, update state, project onboarding state, agents,
skills, commands, memory, or learned Taste content. It also leaves
`forceOAuth`, `installed`, `firstMessageSent`, and `tasteOnboarding` to Command
Code. Unknown historical fields such as `manual` are preserved but are not part
of the declarative schema.

## Documentation differences

The public docs describe global and shared settings but only document
`settings.local.json` for Taste. The application also reads local hooks,
disabled skills, input behavior, and permissions. The docs omit `async` and
`failClosed` hook fields and do not publish the full MCP union or preference
file schema. Where documentation and the selected bundle disagree, this flake
uses the behavior of the pinned bundle and records the difference here.
