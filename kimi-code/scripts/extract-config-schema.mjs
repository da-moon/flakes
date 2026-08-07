#!/usr/bin/env node

/**
 * Extract the Kimi Code configuration contract from the compiled CLI binary
 * without importing or executing any code from the package under inspection.
 *
 * The release binary embeds its bundled JavaScript sources as plain text, so
 * the zod schemas and the v2 config-section registry (including the key
 * deprecation table) are statically readable.
 *
 * Sources inside the binary:
 *   - KimiConfigSchema = object({...})            -> top-level config.toml keys
 *   - registerConfigSection(NAME, Schema, {...})  -> v2 sections, fields, deprecations
 *   - TuiConfigFileSchema = object({...})         -> tui.toml keys
 *
 * Artifact layout (schemaVersion 1):
 *   package    : { name, version }
 *   structural : { topLevel, sections, tui }  -- removals or deprecation-table
 *                changes force human review (--accept-schema-drift); pure
 *                additions classify as catalog-only drift.
 *   catalogs   : {} -- reserved; kimi exposes no high-churn catalogs yet.
 */

import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";
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

// Balanced-delimiter scan honoring string literals.
function balanced(text, startIdx, open, close) {
  let depth = 0, inStr = null, esc = false;
  for (let i = startIdx; i < text.length; i++) {
    const c = text[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === "\\") esc = true;
      else if (c === inStr) inStr = null;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") { inStr = c; continue; }
    if (c === open) depth++;
    else if (c === close) { depth--; if (depth === 0) return text.slice(startIdx, i + 1); }
  }
  return null;
}

// Top-level `name:` entries of an object-literal block (one per line, or
// inline right after `{` for single-line objects).
function objectFields(block) {
  return [...new Set([...block.matchAll(/(?:^|\{)\s{0,4}(\w+):(?=\s)/gm)].map((m) => m[1]))].sort();
}

// Find `<name> = object({` / `strictObject({` and return its fields (sorted),
// or null when the schema is not an inline object literal.
function extractObjectSchemaFields(bin, schemaRef) {
  const decl = new RegExp(`\\b${schemaRef}\\s*=\\s*(?:object|strictObject)\\(\\s*\\{`).exec(bin);
  if (!decl) return null;
  const braceStart = bin.indexOf("{", decl.index + decl[0].length - 1);
  const block = balanced(bin, braceStart, "{", "}");
  return block ? objectFields(block) : null;
}

function extract(binaryPath, version) {
  const bin = readFileSync(binaryPath, "latin1");

  // Resolve `CONST = "value"` bindings used as section-name indirections.
  const consts = new Map();
  for (const m of bin.matchAll(/\b([A-Z][A-Z0-9_]{2,})\s*=\s*"([a-zA-Z][\w.-]{0,60})"/g)) {
    if (!consts.has(m[1])) consts.set(m[1], m[2]);
  }
  const resolveName = (ref) => {
    const literal = /^"([^"]+)"$/.exec(ref);
    if (literal) return literal[1];
    return consts.get(ref) ?? null;
  };

  // v2 config sections (config.toml), with deprecation tables.
  const sections = {};
  const sectionRe = /(?<!function )registerConfigSection\(\s*("[^"]+"|\w+)\s*,\s*(\w+)(?:\s*,\s*\{)?/g;
  for (const m of bin.matchAll(sectionRe)) {
    const [, sectionRef, schemaRef] = m;
    const name = resolveName(sectionRef);
    if (!name) continue;
    let deprecations = [];
    if (m[0].endsWith("{")) {
      const optBlock = balanced(bin, m.index + m[0].length - 1, "{", "}");
      const depM = optBlock ? /deprecations:\s*\[/.exec(optBlock) : null;
      if (depM) {
        const arr = balanced(optBlock, optBlock.indexOf("[", depM.index), "[", "]");
        if (arr) {
          deprecations = [...arr.matchAll(/key:\s*"([^"]+)"\s*,\s*replacement:\s*"([^"]+)"/g)]
            .map((d) => ({ key: d[1], replacement: d[2] }));
        }
      }
    }
    sections[name] = { fields: extractObjectSchemaFields(bin, schemaRef), deprecations };
  }

  // Top-level config.toml keys.
  const topLevel = extractObjectSchemaFields(bin, "KimiConfigSchema");

  // tui.toml: TuiConfigFileSchema keeps on-disk snake_case keys and nests
  // per-section inline objects (editor/notifications/upgrade).
  const tui = { topLevel: null, sections: {} };
  {
    const decl = /\bTuiConfigFileSchema\s*=\s*object\(\s*\{/.exec(bin);
    if (decl) {
      const block = balanced(bin, bin.indexOf("{", decl.index + decl[0].length - 1), "{", "}");
      if (block) {
        // Blank out nested inline objects so their fields do not leak top-level.
        let flat = "";
        let cursor = 0;
        const nested = /(\w+):\s*object\(\s*\{/g;
        for (const nm of block.matchAll(nested)) {
          const sub = balanced(block, block.indexOf("{", nm.index + nm[0].length - 1), "{", "}");
          if (!sub) continue;
          const end = block.indexOf(sub, nm.index) + sub.length;
          tui.sections[nm[1]] = objectFields(sub);
          flat += block.slice(cursor, nm.index) + " ".repeat(end - nm.index);
          cursor = end;
        }
        flat += block.slice(cursor);
        tui.topLevel = objectFields(flat);
      }
    }
  }

  return {
    schemaVersion: 1,
    package: { name: "kimi-code", version },
    structural: { topLevel, sections, tui },
    catalogs: {},
  };
}

try {
  const { values } = parseArgs({
    options: {
      binary: { type: "string" },
      version: { type: "string" },
      output: { type: "string" },
      "hash-output": { type: "string" },
      help: { type: "boolean", short: "h", default: false },
    },
    strict: true,
  });
  if (values.help) {
    console.log("Usage: extract-config-schema.mjs --binary FILE --version VERSION [--output FILE] [--hash-output FILE]");
    process.exit(0);
  }
  if (!values.binary || !values.version) throw new Error("--binary and --version are required");

  const artifact = extract(values.binary, values.version);
  if (!artifact.structural.topLevel || Object.keys(artifact.structural.sections).length < 10) {
    throw new Error("extraction looks incomplete (embedded sources not found); refusing to emit artifact");
  }
  const canonicalText = canonicalJson(artifact);
  const hash = sha256SRI(canonicalText);
  if (values.output) writeFileSync(values.output, canonicalText);
  if (values["hash-output"]) writeFileSync(values["hash-output"], `${hash}\n`);
  process.stdout.write(`${JSON.stringify({
    packageVersion: artifact.package.version,
    sections: Object.keys(artifact.structural.sections).length,
    deprecations: Object.values(artifact.structural.sections).reduce((n, s) => n + s.deprecations.length, 0),
    hash,
  })}\n`);
} catch (error) {
  console.error(`extract-config-schema: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 2;
}
