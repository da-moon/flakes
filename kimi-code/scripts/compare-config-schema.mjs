#!/usr/bin/env node

/**
 * Classify drift between two Kimi Code schema-v1 artifacts.
 *
 *   structural    : a section, field, top-level, or tui key was REMOVED, or
 *                   a deprecation table changed -> human review required
 *                   (exit 20; updater refuses without --accept-schema-drift)
 *   catalog-only  : only additions             -> allowed (exit 10)
 *   metadata-only : only package metadata      -> allowed (exit 0)
 *   unchanged     : byte-identical semantics   -> exit 0
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
    throw new Error(`${path} is not a Kimi Code schema-v1 artifact`);
  }
  return parsed;
}

// Diff two sorted-or-unsorted string lists (null treated as opaque, never diffed).
function listDiff(before, after) {
  if (before === null || after === null) return { added: [], removed: [] };
  const b = new Set(before), a = new Set(after);
  return {
    added: [...a].filter((x) => !b.has(x)).sort(),
    removed: [...b].filter((x) => !a.has(x)).sort(),
  };
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

  const base = readSchema(values.baseline).structural;
  const cand = readSchema(values.candidate).structural;
  const basePkg = readSchema(values.baseline).package;
  const candPkg = readSchema(values.candidate).package;

  const removed = [];
  const added = [];

  const top = listDiff(base.topLevel ?? [], cand.topLevel ?? []);
  top.removed.forEach((k) => removed.push(`top-level key '${k}'`));
  top.added.forEach((k) => added.push(`top-level key '${k}'`));

  for (const name of new Set([...Object.keys(base.sections ?? {}), ...Object.keys(cand.sections ?? {})])) {
    const b = base.sections?.[name];
    const c = cand.sections?.[name];
    if (b && !c) { removed.push(`section '${name}'`); continue; }
    if (!b && c) { added.push(`section '${name}'`); continue; }
    const f = listDiff(b.fields, c.fields);
    f.removed.forEach((k) => removed.push(`field '${name}.${k}'`));
    f.added.forEach((k) => added.push(`field '${name}.${k}'`));
    if (stable(b.deprecations ?? []) !== stable(c.deprecations ?? [])) {
      removed.push(`deprecation table of '${name}' changed`);
    }
  }

  const tuiTop = listDiff(base.tui?.topLevel ?? [], cand.tui?.topLevel ?? []);
  tuiTop.removed.forEach((k) => removed.push(`tui key '${k}'`));
  tuiTop.added.forEach((k) => added.push(`tui key '${k}'`));
  for (const name of new Set([...Object.keys(base.tui?.sections ?? {}), ...Object.keys(cand.tui?.sections ?? {})])) {
    const f = listDiff(base.tui?.sections?.[name], cand.tui?.sections?.[name]);
    f.removed.forEach((k) => removed.push(`tui field '${name}.${k}'`));
    f.added.forEach((k) => added.push(`tui field '${name}.${k}'`));
  }

  const metadataChanged = stable(basePkg) !== stable(candPkg);
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
