# Upstream configuration schema

`upstream.json` is canonical, version-coupled evidence extracted from the
`command-code` npm bundle. The extractor reads `package.json.main`, parses the
entrypoint as ECMAScript syntax, and never imports or executes package code.

`upstream.sha256` is the SRI SHA-256 of the exact canonical JSON bytes. The
matching release entry must contain the same scalar value:

```json
{
  "schemaSha256": "sha256-...="
}
```

Regenerate through `scripts/update-version.sh`. Structural drift exits with
status 3 and leaves the candidate staging directory intact. After reviewing
the candidate, rerun with `--accept-schema-drift`. Catalog-only and metadata-
only changes are non-blocking. `--no-build` skips package build verification,
but intentionally does not skip schema extraction or verification.

Run the focused checks with:

```sh
./tests/schema/run.sh
node scripts/verify-config-schema.mjs \
  --schema schema/upstream.json \
  --hash schema/upstream.sha256
```
