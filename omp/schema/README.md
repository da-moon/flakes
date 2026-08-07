# Upstream configuration schema

`upstream.json` is canonical, version-coupled evidence extracted from the
`omp` release binary. The extractor reads the settings registry embedded in
the compiled binary's bundled JavaScript sources (every documented setting
with its type, scalar default, and enum values) and never executes package
code.

`upstream.sha256` is the SRI SHA-256 of the exact canonical JSON bytes. The
matching release entry must contain the same scalar value:

```json
{
  "schemaSha256": "sha256-...="
}
```

Regenerate through `scripts/update-version.sh`. Structural drift (removed
settings keys, type changes, or removed enum values) exits with status 3 and
leaves the candidate staging directory intact. After reviewing the candidate
(and updating `modules/defaults.nix`, including its `schemaVersion` marker),
rerun with `--accept-schema-drift`. Additive (catalog-only) and metadata-only
changes are non-blocking. `--no-build` skips package build verification, but
intentionally does not skip schema extraction or verification.

The `checks.<system>.schema-artifact` flake check re-extracts the registry
from the built package, byte-compares it with the committed artifact, and
cross-checks every key `modules/defaults.nix` manages against the registry
(existence, type, enum membership).

Run the focused checks with:

```sh
nix build .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).schema-artifact
node scripts/verify-config-schema.mjs \
  --schema schema/upstream.json \
  --hash schema/upstream.sha256
```
