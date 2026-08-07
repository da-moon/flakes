#!/usr/bin/env node

/**
 * Verify an omp schema-v1 artifact (schema/upstream.json):
 *   - structural shape, canonical byte form, and SRI hash
 *   - optional expected version / hash coupling with releases.json
 *   - optional cross-check of the flake's managed defaults against the
 *     upstream registry (--defaults FILE, a JSON array of {key, value}
 *     flattened dotted-path entries from modules/defaults.nix):
 *       * every managed key must exist in the upstream settings registry
 *       * enum-typed settings only accept documented values
 *       * the Nix value type must match the upstream setting type
 */

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";

function sha256SRI(value) {
  return `sha256-${createHash("sha256").update(value).digest("base64")}`;
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  }
  return value;
}

function canonicalJson(value) {
  return `${JSON.stringify(canonical(value), null, 2)}\n`;
}

function nixType(value) {
  if (Array.isArray(value)) return "list";
  if (value === null) return "null";
  if (typeof value === "object") return "attrs";
  return typeof value; // string | number | boolean
}

const TYPE_MAP = {
  string: ["string"],
  number: ["number"],
  boolean: ["boolean"],
  enum: ["string"],
  array: ["list"],
  record: ["attrs"],
  object: ["attrs"],
};

function crossCheck(schema, defaultsFlat) {
  const errors = [];
  const settings = schema.structural.settings ?? {};
  for (const { key, value } of defaultsFlat) {
    const entry = settings[key];
    if (!entry) {
      errors.push(`managed key '${key}' is not in the upstream settings registry (removed or renamed upstream)`);
      continue;
    }
    if (entry.type && TYPE_MAP[entry.type] && !TYPE_MAP[entry.type].includes(nixType(value))) {
      errors.push(`'${key}': Nix value type '${nixType(value)}' does not match upstream type '${entry.type}'`);
    }
    if (Array.isArray(entry.values) && entry.values.length > 0 && !entry.values.includes(String(value))) {
      errors.push(`'${key}': value ${JSON.stringify(value)} not in upstream enum values ${JSON.stringify(entry.values)}`);
    }
  }
  return errors;
}

try {
  const { values } = parseArgs({
    options: {
      schema: { type: "string" },
      hash: { type: "string" },
      "expected-version": { type: "string" },
      "expected-sha256": { type: "string" },
      defaults: { type: "string" },
      help: { type: "boolean", short: "h", default: false },
    },
    strict: true,
  });
  if (values.help) {
    console.log("Usage: verify-config-schema.mjs --schema FILE [--hash FILE] [--expected-version VERSION] [--expected-sha256 SRI] [--defaults FILE]");
    process.exit(0);
  }
  if (!values.schema) throw new Error("--schema is required");
  const contents = readFileSync(values.schema, "utf8");
  const schema = JSON.parse(contents);
  if (schema.schemaVersion !== 1 || !schema.package || !schema.structural || !schema.catalogs) {
    throw new Error("not an omp schema-v1 artifact");
  }
  if (canonicalJson(schema) !== contents) throw new Error("schema JSON is not canonical");
  const actualHash = sha256SRI(contents);
  if (values.hash) {
    const recordedHash = readFileSync(values.hash, "utf8").trim();
    if (recordedHash !== actualHash) throw new Error(`schema hash mismatch: recorded ${recordedHash}, actual ${actualHash}`);
  }
  if (values["expected-sha256"] && values["expected-sha256"] !== actualHash) {
    throw new Error(`schemaSha256 mismatch: expected ${values["expected-sha256"]}, actual ${actualHash}`);
  }
  if (values["expected-version"] && values["expected-version"] !== schema.package.version) {
    throw new Error(`schema version mismatch: expected ${values["expected-version"]}, actual ${schema.package.version}`);
  }
  let checked = [];
  if (values.defaults) {
    const defaultsFlat = JSON.parse(readFileSync(values.defaults, "utf8"));
    const errors = crossCheck(schema, defaultsFlat);
    if (errors.length > 0) {
      for (const e of errors) console.error(`verify-config-schema: ${e}`);
      throw new Error(`${errors.length} managed-key violation(s) against upstream schema evidence`);
    }
    checked = ["defaults"];
  }
  process.stdout.write(`${JSON.stringify({ schemaVersion: schema.schemaVersion, packageVersion: schema.package.version, schemaSha256: actualHash, checked })}\n`);
} catch (error) {
  console.error(`verify-config-schema: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 2;
}
