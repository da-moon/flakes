#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  }
  return value;
}

function stable(value) {
  return JSON.stringify(canonical(value));
}

function readSchema(path) {
  const parsed = JSON.parse(readFileSync(path, "utf8"));
  if (parsed.schemaVersion !== 1 || !parsed.structural || !parsed.catalogs || !parsed.package) {
    throw new Error(`${path} is not a Command Code schema-v1 artifact`);
  }
  return parsed;
}

try {
  const { values } = parseArgs({
    options: {
      baseline: { type: "string" },
      candidate: { type: "string" },
      help: { type: "boolean", short: "h", default: false },
    },
    strict: true,
  });
  if (values.help) {
    console.log("Usage: compare-config-schema.mjs --baseline FILE --candidate FILE");
    process.exit(0);
  }
  if (!values.baseline || !values.candidate) throw new Error("--baseline and --candidate are required");

  const baseline = readSchema(values.baseline);
  const candidate = readSchema(values.candidate);
  const structuralChanged = stable(baseline.structural) !== stable(candidate.structural);
  const catalogChanged = stable(baseline.catalogs) !== stable(candidate.catalogs);
  const metadataChanged = stable(baseline.package) !== stable(candidate.package) || stable(baseline.evidence) !== stable(candidate.evidence);
  const classification = structuralChanged
    ? "structural"
    : catalogChanged
      ? "catalog-only"
      : metadataChanged
        ? "metadata-only"
        : "unchanged";
  process.stdout.write(`${JSON.stringify({ classification, structuralChanged, catalogChanged, metadataChanged })}\n`);
  if (structuralChanged) process.exitCode = 20;
  else if (catalogChanged) process.exitCode = 10;
} catch (error) {
  console.error(`compare-config-schema: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 2;
}
