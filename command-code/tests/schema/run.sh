#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$(cd -- "${test_dir}/../.." && pwd)"
extractor="${pkg_dir}/scripts/extract-config-schema.mjs"
comparator="${pkg_dir}/scripts/compare-config-schema.mjs"
verifier="${pkg_dir}/scripts/verify-config-schema.mjs"
fixtures="${test_dir}/fixtures"
tmp="$(mktemp -d -t command-code-schema-tests.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

extract() {
  local package_dir="$1" name="$2"
  node "$extractor" \
    --package-dir "$package_dir" \
    --output "$tmp/${name}.json" \
    --hash-output "$tmp/${name}.sha256" \
    >"$tmp/${name}.metadata.json"
}

expect_status() {
  local expected="$1"; shift
  set +e
  "$@"
  local actual=$?
  set -e
  if [ "$actual" -ne "$expected" ]; then
    echo "expected exit $expected, got $actual: $*" >&2
    exit 1
  fi
}

extract "$fixtures/package-0.41" old
extract "$fixtures/package-0.42" changed-entrypoint

[ "$(jq -r '.package.entrypoint' "$tmp/old.json")" = "dist/index.mjs" ]
[ "$(jq -r '.package.entrypoint' "$tmp/changed-entrypoint.json")" = "dist/cli.mjs" ]
[ "$(jq -r '.entrypoint' "$tmp/changed-entrypoint.metadata.json")" = "dist/cli.mjs" ]
jq -e '.structural.settings.fields.permissions.fields.autoApprove.fields | keys == ["create", "delete", "update"]' "$tmp/changed-entrypoint.json" >/dev/null

comparison="$(node "$comparator" --baseline "$tmp/old.json" --candidate "$tmp/changed-entrypoint.json")"
[ "$(printf '%s' "$comparison" | jq -r '.classification')" = "metadata-only" ]

node "$verifier" \
  --schema "$tmp/changed-entrypoint.json" \
  --hash "$tmp/changed-entrypoint.sha256" \
  --package-dir "$fixtures/package-0.42" \
  --expected-version 0.42.0 \
  >/dev/null

extract "$fixtures/package-0.42" deterministic
cmp "$tmp/changed-entrypoint.json" "$tmp/deterministic.json"
cmp "$tmp/changed-entrypoint.sha256" "$tmp/deterministic.sha256"

cp -R "$fixtures/package-0.42" "$tmp/structural-package"
perl -0pi -e 's/a\(\{provider:"command-code"\}\);/a({provider:"command-code"});a({experimentalFlag:true});/' "$tmp/structural-package/dist/cli.mjs"
extract "$tmp/structural-package" structural
expect_status 20 node "$comparator" --baseline "$tmp/changed-entrypoint.json" --candidate "$tmp/structural.json"
[ "$(jq -r '.structural.globalConfig.fields.experimentalFlag.type' "$tmp/structural.json")" = "unknown" ]

cp -R "$fixtures/package-0.42" "$tmp/catalog-package"
perl -0pi -e 's/model-5/model-5-new/g; s/Model 5/Model 5 New/g' "$tmp/catalog-package/dist/cli.mjs"
extract "$tmp/catalog-package" catalog
expect_status 10 node "$comparator" --baseline "$tmp/changed-entrypoint.json" --candidate "$tmp/catalog.json"

cp "$tmp/changed-entrypoint.json" "$tmp/tampered.json"
printf ' ' >>"$tmp/tampered.json"
expect_status 2 node "$verifier" --schema "$tmp/tampered.json" --hash "$tmp/changed-entrypoint.sha256"

cp "$tmp/changed-entrypoint.json" "$tmp/tampered-canonical.json"
perl -0pi -e 's/"version": "0\.42\.0"/"version": "9.9.9"/' "$tmp/tampered-canonical.json"
node - "$tmp/tampered-canonical.json" "$tmp/tampered-canonical.sha256" <<'NODE'
const fs = require("fs");
const crypto = require("crypto");
const contents = fs.readFileSync(process.argv[2]);
fs.writeFileSync(process.argv[3], `sha256-${crypto.createHash("sha256").update(contents).digest("base64")}\n`);
NODE
expect_status 2 node "$verifier" \
  --schema "$tmp/tampered-canonical.json" \
  --hash "$tmp/tampered-canonical.sha256" \
  --package-dir "$fixtures/package-0.42"

echo "schema tests: ok"
