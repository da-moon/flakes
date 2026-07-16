#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFileSync, realpathSync, statSync } from "node:fs";
import { isAbsolute, relative, resolve, sep } from "node:path";
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

function verifyPackage(schema, packageDirectory) {
  const packageRoot = realpathSync(packageDirectory);
  const packageJsonPath = resolve(packageRoot, "package.json");
  const packageJsonSource = readFileSync(packageJsonPath, "utf8");
  const packageJson = JSON.parse(packageJsonSource);
  if (packageJson.name !== schema.package.name) throw new Error("package name does not match schema evidence");
  if (packageJson.version !== schema.package.version) throw new Error("package version does not match schema evidence");
  if (packageJson.main !== schema.package.entrypoint) throw new Error("package.json main does not match schema entrypoint");
  if (isAbsolute(packageJson.main)) throw new Error("package.json main must be relative");
  const entrypoint = realpathSync(resolve(packageRoot, packageJson.main));
  const relativeEntrypoint = relative(packageRoot, entrypoint);
  if (relativeEntrypoint === ".." || relativeEntrypoint.startsWith(`..${sep}`) || isAbsolute(relativeEntrypoint)) {
    throw new Error("package.json main escapes the package root");
  }
  if (!statSync(entrypoint).isFile()) throw new Error("package entrypoint is not a regular file");
  if (sha256SRI(packageJsonSource) !== schema.package.packageJsonHash) throw new Error("package.json hash does not match schema evidence");
  if (sha256SRI(readFileSync(entrypoint)) !== schema.package.entrypointHash) throw new Error("entrypoint hash does not match schema evidence");
}

try {
  const { values } = parseArgs({
    options: {
      schema: { type: "string" },
      hash: { type: "string" },
      "expected-version": { type: "string" },
      "expected-sha256": { type: "string" },
      "package-dir": { type: "string" },
      help: { type: "boolean", short: "h", default: false },
    },
    strict: true,
  });
  if (values.help) {
    console.log("Usage: verify-config-schema.mjs --schema FILE [--hash FILE] [--expected-version VERSION] [--expected-sha256 SRI] [--package-dir DIR]");
    process.exit(0);
  }
  if (!values.schema) throw new Error("--schema is required");
  const contents = readFileSync(values.schema, "utf8");
  const schema = JSON.parse(contents);
  if (schema.schemaVersion !== 1 || !schema.package || !schema.structural || !schema.catalogs) {
    throw new Error("not a Command Code schema-v1 artifact");
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
  if (values["package-dir"]) verifyPackage(schema, values["package-dir"]);
  process.stdout.write(`${JSON.stringify({ schemaVersion: schema.schemaVersion, packageVersion: schema.package.version, schemaSha256: actualHash })}\n`);
} catch (error) {
  console.error(`verify-config-schema: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 2;
}
