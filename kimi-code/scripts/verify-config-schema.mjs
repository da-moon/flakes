#!/usr/bin/env node

/**
 * Verify a Kimi Code schema-v1 artifact (schema/upstream.json):
 *   - structural shape, canonical byte form, and SRI hash
 *   - optional expected version / hash coupling with releases.json
 *   - optional cross-check of the flake's Nix merge manifests against the
 *     upstream evidence (--manifest, --tui-manifest):
 *       * every managed scalar must be a known top-level key
 *       * every managed section key must be a live upstream field and must
 *         NOT be deprecated upstream (reports the replacement when it is)
 *       * every retired key must carry upstream deprecation evidence
 *       * every upstream deprecation in a managed section must be accounted
 *         for (still managed, or listed under `retired`)
 *     tui.toml keys are on-disk snake_case; config.toml section keys are
 *     snake_case mapped onto the binary's camelCase fields.
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

const camel = (snake) => snake.replace(/_([a-z])/g, (_, c) => c.toUpperCase());

function crossCheck(schema, manifest, tuiManifest) {
  const errors = [];
  const { topLevel, sections, tui } = schema.structural;

  for (const scalar of manifest.scalars ?? []) {
    if (!(topLevel ?? []).includes(camel(scalar))) {
      errors.push(`managed scalar '${scalar}' is not a known top-level config.toml key upstream`);
    }
  }
  for (const [section, keys] of Object.entries(manifest.sections ?? {})) {
    const upstream = sections[camel(section)];
    if (!upstream || !Array.isArray(upstream.fields)) {
      errors.push(`managed section '${section}' has no extractable upstream schema`);
      continue;
    }
    const retired = (manifest.retired ?? {})[section] ?? [];
    for (const key of keys) {
      if (retired.includes(key)) {
        errors.push(`[${section}] '${key}' is both managed and retired`);
        continue;
      }
      const dep = upstream.deprecations.find((d) => d.key === key);
      if (dep) {
        errors.push(`[${section}] '${key}' is deprecated upstream; rename it to '${dep.replacement}' (or retire it)`);
      } else if (!upstream.fields.includes(camel(key))) {
        errors.push(`[${section}] '${key}' is not a known upstream field`);
      }
    }
    for (const key of retired) {
      if (!upstream.deprecations.some((d) => d.key === key)) {
        errors.push(`[${section}] retired key '${key}' has no upstream deprecation evidence; drop it from 'retired'`);
      }
    }
    for (const dep of upstream.deprecations) {
      if (!keys.includes(dep.key) && !retired.includes(dep.key)) {
        errors.push(`[${section}] upstream deprecates '${dep.key}' (rename to '${dep.replacement}') but the manifest neither manages nor retires it`);
      }
    }
  }

  if (tuiManifest) {
    const tuiTop = tui?.topLevel ?? [];
    const tuiSections = tui?.sections ?? {};
    for (const scalar of tuiManifest.scalars ?? []) {
      if (!tuiTop.includes(scalar)) {
        errors.push(`managed tui.toml scalar '${scalar}' is not a known upstream tui key`);
      }
    }
    for (const [section, keys] of Object.entries(tuiManifest.sections ?? {})) {
      const fields = tuiSections[section];
      if (!Array.isArray(fields)) {
        errors.push(`managed tui.toml section '${section}' has no extractable upstream schema`);
        continue;
      }
      for (const key of keys) {
        if (!fields.includes(key)) {
          errors.push(`[tui.${section}] '${key}' is not a known upstream field`);
        }
      }
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
      manifest: { type: "string" },
      "tui-manifest": { type: "string" },
      help: { type: "boolean", short: "h", default: false },
    },
    strict: true,
  });
  if (values.help) {
    console.log("Usage: verify-config-schema.mjs --schema FILE [--hash FILE] [--expected-version VERSION] [--expected-sha256 SRI] [--manifest FILE] [--tui-manifest FILE]");
    process.exit(0);
  }
  if (!values.schema) throw new Error("--schema is required");
  const contents = readFileSync(values.schema, "utf8");
  const schema = JSON.parse(contents);
  if (schema.schemaVersion !== 1 || !schema.package || !schema.structural || !schema.catalogs) {
    throw new Error("not a Kimi Code schema-v1 artifact");
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
  if (values.manifest || values["tui-manifest"]) {
    const manifest = values.manifest ? JSON.parse(readFileSync(values.manifest, "utf8")) : {};
    const tuiManifest = values["tui-manifest"] ? JSON.parse(readFileSync(values["tui-manifest"], "utf8")) : null;
    const errors = crossCheck(schema, manifest, tuiManifest);
    if (errors.length > 0) {
      for (const e of errors) console.error(`verify-config-schema: ${e}`);
      throw new Error(`${errors.length} managed-key violation(s) against upstream schema evidence`);
    }
    checked = [values.manifest ? "manifest" : null, values["tui-manifest"] ? "tui-manifest" : null].filter(Boolean);
  }
  process.stdout.write(`${JSON.stringify({ schemaVersion: schema.schemaVersion, packageVersion: schema.package.version, schemaSha256: actualHash, checked })}\n`);
} catch (error) {
  console.error(`verify-config-schema: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 2;
}
