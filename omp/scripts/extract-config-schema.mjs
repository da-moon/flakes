#!/usr/bin/env node

/**
 * Extract the oh-my-pi (omp) settings contract from the compiled CLI binary
 * without importing or executing any code from the package under inspection.
 *
 * The release binary embeds its bundled JavaScript sources as plain text,
 * including the canonical settings registry: a single object literal whose
 * entries are `key: { type: "...", default: ..., values: [...] }` with dotted
 * keys for nested settings (`todo.remindersMax`, `providers.webSearchOrder`).
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

const REGISTRY_ANCHOR = 'setupVersion: { type: "number", default: 0 }';

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
  if (token === undefined) return null;
  if (token === "undefined") return null;
  if (token === "true") return true;
  if (token === "false") return false;
  if (/^-?\d+(\.\d+)?$/.test(token)) return Number(token);
  try { return JSON.parse(token); } catch { return null; }
}

function extract(binaryPath, version) {
  const bin = readFileSync(binaryPath, "latin1");

  const anchor = bin.indexOf(REGISTRY_ANCHOR);
  if (anchor === -1) throw new Error(`registry anchor not found (${JSON.stringify(REGISTRY_ANCHOR)})`);
  const braceStart = bin.indexOf("{", bin.lastIndexOf("= {", anchor));
  const block = balanced(bin, braceStart, "{", "}");
  if (!block) throw new Error("unbalanced settings-registry block");

  const entries = {};
  let depth = 0, inStr = null, esc = false, keyStart = null, curKey = null;
  for (let i = 0; i < block.length; i++) {
    const c = block[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === "\\") esc = true;
      else if (c === inStr) inStr = null;
      continue;
    }
    if (depth === 1 && /[\w"]/.test(c)) {
      const km = /^(\w+|"[^"]+")\s*:/.exec(block.slice(i));
      if (km) {
        curKey = km[1].startsWith('"') ? km[1].slice(1, -1) : km[1];
        i += km[0].length - 1;
        continue;
      }
    }
    if (c === '"' || c === "'" || c === "`") { inStr = c; continue; }
    if (c === "{") {
      depth++;
      if (depth === 2 && curKey) keyStart = i;
    } else if (c === "}") {
      if (depth === 2 && curKey && keyStart !== null) {
        const body = block.slice(keyStart, i + 1);
        const t = /type:\s*"(\w+)"/.exec(body);
        const vals = /values:\s*\[([^\]]*)\]/.exec(body);
        const def = /default:\s*("(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?|true|false|undefined)(?=\s*[,}])/.exec(body);
        entries[curKey] = {
          type: t ? t[1] : null,
          default: def ? parseScalar(def[1]) : null,
          ...(vals ? { values: [...vals[1].matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((v) => v[1]) } : {}),
        };
        curKey = null; keyStart = null;
      }
      depth--;
    }
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
  if (count < 200) {
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
