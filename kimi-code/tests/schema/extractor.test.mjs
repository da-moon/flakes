import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const extractor = fileURLToPath(new URL("../../scripts/extract-config-schema.mjs", import.meta.url));

function extract(source) {
  const directory = mkdtempSync(join(tmpdir(), "kimi-schema-test-"));
  try {
    const binary = join(directory, "binary");
    const output = join(directory, "schema.json");
    writeFileSync(binary, source);
    const result = spawnSync(process.execPath, [
      extractor, "--binary", binary, "--version", "2.4.0", "--output", output,
    ], { encoding: "utf8" });
    return {
      status: result.status,
      stderr: result.stderr,
      schema: result.status === 0 ? JSON.parse(readFileSync(output, "utf8")) : null,
    };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

function fixture(object, strictObject) {
  const sections = Array.from({ length: 10 }, (_, i) => `
Section${i} = ${i % 2 ? strictObject : object}({ value: string() });
registerConfigSection("section${i}", Section${i});`).join("\n");
  return `throw new Error("Schema extraction must never execute this source");
KimiConfigSchema = ${object}({ providers: record(string()) });
${sections}
TuiConfigFileSchema = ${object}({
  theme: string(),
  editor: ${object}({ command: string() }),
  notifications: ${object}({ enabled: boolean() })
});`;
}

for (const suffix of ["", "$1", "$12"]) {
  test(`extracts object and strictObject helpers with suffix '${suffix}'`, () => {
    const result = extract(fixture(`object${suffix}`, `strictObject${suffix}`));
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(result.schema.structural.topLevel, ["providers"]);
    assert.equal(Object.keys(result.schema.structural.sections).length, 10);
    for (const section of Object.values(result.schema.structural.sections)) {
      assert.deepEqual(section, { fields: ["value"], deprecations: [] });
    }
    assert.deepEqual(result.schema.structural.tui, {
      topLevel: ["theme"],
      sections: { editor: ["command"], notifications: ["enabled"] },
    });
  });
}

test("rejects incomplete or unrecognized schema constructors", () => {
  for (const source of ["not a schema", fixture("objectUnsafe", "strictObjectUnsafe")]) {
    const result = extract(source);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /extraction looks incomplete/);
  }
});
