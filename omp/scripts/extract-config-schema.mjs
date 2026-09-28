#!/usr/bin/env node

/**
 * Extract the oh-my-pi (omp) settings contract from the compiled CLI binary
 * without importing or executing any code from the package under inspection.
 *
 * The release binary embeds its bundled JavaScript sources as plain text,
 * including the canonical settings registry. In recent releases the registry
 * is a contiguous block of individual calls like
 *   `<var> = se({ id: "...", type: "...", default: ... });`
 * rather than a single object literal.
 *
 * Artifact layout (schemaVersion 1):
 *   package    : { name, version }
 *   structural : { settings }  -- key removals, type changes, or enum-value
 *                removals force human review (--accept-schema-drift); pure
 *                additions classify as catalog-only drift.
 *   catalogs   : {} -- reserved.
 *
 * Scalar defaults are recorded when literal (string/number/boolean/null);
 * computed or reference defaults are recorded as null (opaque).
 */

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { parseArgs } from "node:util";

const REGISTRY_ANCHOR = 'se({ id: "setupVersion", type: "number", default: 0 })';
const SCAN_WINDOW_BYTES = 15 * 1024 * 1024;
const MIN_SETTINGS_COUNT = 40;

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

function parseScalar(token) {
  if (token === null || token === undefined) return null;
  token = token.trim();
  if (token === "undefined") return null;
  if (token === "true") return true;
  if (token === "false") return false;
  if (/^-?\d+(\.\d+)?$/.test(token)) return Number(token);
  try { return JSON.parse(token); } catch { return null; }
}

function splitTopLevel(body) {
  const parts = [];
  let depth = 0, inStr = null, esc = false, start = 0;
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === "\\") esc = true;
      else if (c === inStr) inStr = null;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") { inStr = c; continue; }
    if (c === "{" || c === "[" || c === "(") depth++;
    else if (c === "}" || c === "]" || c === ")") depth--;
    if (depth === 0 && c === ",") {
      parts.push(body.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(body.slice(start));
  return parts.map((p) => p.trim()).filter((p) => p.length > 0);
}

function parseTopLevelString(body, prop) {
  for (const part of splitTopLevel(body)) {
    const m = new RegExp(`^${prop}\\s*:\\s*"([^"]*)"`).exec(part);
    if (m) return m[1];
  }
  return null;
}

function parseTopLevelDefault(body) {
  for (const part of splitTopLevel(body)) {
    if (/^default\s*:/.test(part)) {
      return parseScalar(part.replace(/^default\s*:\s*/, ""));
    }
  }
  return null;
}

function extract(binaryPath, version) {
  const bin = readFileSync(binaryPath, "latin1");

  const anchorIdx = bin.indexOf(REGISTRY_ANCHOR);
  if (anchorIdx === -1) throw new Error(`registry anchor not found (${JSON.stringify(REGISTRY_ANCHOR)})`);

  // Registry entries appear in a contiguous block starting near the anchor.
  const scanStart = Math.max(0, anchorIdx - 1024);
  const scanEnd = Math.min(bin.length, scanStart + SCAN_WINDOW_BYTES);
  const scan = bin.slice(scanStart, scanEnd);

  const entries = {};
  let pos = 0;
  while (true) {
    const idx = scan.indexOf("se({", pos);
    if (idx === -1) break;
    const obj = balanced(scan, idx + 3, "{", "}");
    if (obj) {
      const body = obj.slice(1, -1);
      const id = parseTopLevelString(body, "id");
      const type = parseTopLevelString(body, "type");
      if (id && type) {
        entries[id] = { type, default: parseTopLevelDefault(body) };
      }
    }
    pos = idx + 1;
  }

  return {
    schemaVersion: 1,
    package: { name: "omp", version },
    structural: { settings: entries },
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
  const count = Object.keys(artifact.structural.settings).length;
  if (count < MIN_SETTINGS_COUNT) {
    throw new Error(`extraction looks incomplete (${count} settings); refusing to emit artifact`);
  }
  const canonicalText = canonicalJson(artifact);
  const hash = sha256SRI(canonicalText);
  if (values.output) writeFileSync(values.output, canonicalText);
  if (values["hash-output"]) writeFileSync(values["hash-output"], `${hash}\n`);
  process.stdout.write(`${JSON.stringify({ packageVersion: artifact.package.version, settings: count, hash })}\n`);
} catch (error) {
  console.error(`extract-config-schema: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 2;
}
