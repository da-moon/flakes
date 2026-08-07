# Upstream configuration schema

`upstream.json` is canonical, version-coupled evidence extracted from the
`kimi-code` release binary. The extractor reads the bundled JavaScript sources
embedded in the compiled binary (the zod `KimiConfigSchema`, the v2
`registerConfigSection` registry with its key-deprecation table, and the
`TuiConfigFileSchema`) and never executes package code.

`upstream.sha256` is the SRI SHA-256 of the exact canonical JSON bytes. The
matching release entry must contain the same scalar value:

```json
{
  "schemaSha256": "sha256-...="
}
```

Regenerate through `scripts/update-version.sh`. Structural drift (removed
sections/fields/keys, or any deprecation-table change) exits with status 3 and
leaves the candidate staging directory intact. After reviewing the candidate
(and updating `modules/config-schema.nix`, including its `schemaVersion`
marker), rerun with `--accept-schema-drift`. Additive (catalog-only) and
metadata-only changes are non-blocking. `--no-build` skips package build
verification, but intentionally does not skip schema extraction or
verification.

Run the focused checks with:

```sh
nix build .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).schema-artifact
node scripts/verify-config-schema.mjs \
  --schema schema/upstream.json \
  --hash schema/upstream.sha256
```
