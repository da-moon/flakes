#!/usr/bin/env node

/**
 * Classify drift between two omp schema-v1 artifacts.
 *
 *   structural    : a settings key was REMOVED, its type changed, or an enum
 *                   value was removed -> human review required
 *                   (exit 20; updater refuses without --accept-schema-drift)
 *   catalog-only  : only additions (keys or enum values) -> allowed (exit 10)
 *   metadata-only : only package metadata                -> allowed (exit 0)
 *   unchanged     : byte-identical semantics             -> exit 0
 */

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
  if (parsed.schemaVersion !== 1 || !parsed.structural || !parsed.package) {
    throw new Error(`${path} is not an omp schema-v1 artifact`);
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

  const baseSchema = readSchema(values.baseline);
  const candSchema = readSchema(values.candidate);
  const base = baseSchema.structural.settings ?? {};
  const cand = candSchema.structural.settings ?? {};

  const removed = [];
  const added = [];
  for (const key of new Set([...Object.keys(base), ...Object.keys(cand)])) {
    const b = base[key];
    const c = cand[key];
    if (b && !c) { removed.push(`setting '${key}'`); continue; }
    if (!b && c) { added.push(`setting '${key}'`); continue; }
    if (b.type !== c.type) { removed.push(`type of '${key}' (${b.type} -> ${c.type})`); continue; }
    const bVals = new Set(b.values ?? []);
    const cVals = new Set(c.values ?? []);
    [...bVals].filter((v) => !cVals.has(v)).forEach((v) => removed.push(`enum value '${key}=${v}'`));
    [...cVals].filter((v) => !bVals.has(v)).forEach((v) => added.push(`enum value '${key}=${v}'`));
    if (stable(b.default ?? null) !== stable(c.default ?? null)) {
      added.push(`default of '${key}' (${stable(b.default ?? null)} -> ${stable(c.default ?? null)})`);
    }
  }

  const metadataChanged = stable(baseSchema.package) !== stable(candSchema.package);
  const classification = removed.length > 0
    ? "structural"
    : added.length > 0
      ? "catalog-only"
      : metadataChanged
        ? "metadata-only"
        : "unchanged";
  process.stdout.write(`${JSON.stringify({ classification, added, removed, metadataChanged })}\n`);
  if (classification === "structural") process.exitCode = 20;
  else if (classification === "catalog-only") process.exitCode = 10;
} catch (error) {
  console.error(`compare-config-schema: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 2;
}
