import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";

const fail = message => {
  throw new Error(`command-code Nix sync: ${message}`);
};

function parseArgs(argv) {
  const result = { force: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--force") {
      result.force = true;
      continue;
    }
    if (!["--scope", "--data-dir", "--state-dir", "--config", "--settings", "--mcp", "--hooks-dir"].includes(argument)) {
      fail(`unknown argument ${JSON.stringify(argument)}`);
    }
    if (index + 1 >= argv.length) fail(`${argument} requires a value`);
    result[argument.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = argv[++index];
  }
  for (const required of ["scope", "dataDir", "stateDir", "settings", "mcp", "hooksDir"]) {
    if (!result[required]) fail(`--${required.replace(/[A-Z]/g, letter => `-${letter.toLowerCase()}`)} is required`);
  }
  return result;
}

const options = parseArgs(process.argv.slice(2));
const manifestPath = path.join(options.stateDir, "ownership.json");
const legacyManifestPath = path.join(options.hooksDir, ".nix-managed-hooks");

function parseDesired(variable) {
  const filename = process.env[variable];
  if (!filename) fail(`internal desired-state variable ${variable} is missing`);
  return fs.readFile(filename, "utf8").then(text => JSON.parse(text));
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function deepEqual(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function leafEntries(value, prefix = []) {
  if (!isObject(value)) return [[prefix, value]];
  return Object.entries(value).flatMap(([key, child]) => leafEntries(child, [...prefix, key]));
}

function hasPath(value, keys) {
  let cursor = value;
  for (const key of keys) {
    if (!isObject(cursor) || !Object.hasOwn(cursor, key)) return false;
    cursor = cursor[key];
  }
  return true;
}

function getPath(value, keys) {
  return keys.reduce((cursor, key) => cursor[key], value);
}

function unmanagedPathConflict(value, keys, next) {
  let cursor = value;
  for (const key of keys) {
    if (!isObject(cursor)) return true;
    if (!Object.hasOwn(cursor, key)) return false;
    cursor = cursor[key];
  }
  return !deepEqual(cursor, next);
}

function setPath(value, keys, next) {
  let cursor = value;
  for (const key of keys.slice(0, -1)) {
    if (!isObject(cursor[key])) cursor[key] = {};
    cursor = cursor[key];
  }
  cursor[keys.at(-1)] = clone(next);
}

function deletePath(value, keys) {
  const parents = [];
  let cursor = value;
  for (const key of keys.slice(0, -1)) {
    if (!isObject(cursor) || !Object.hasOwn(cursor, key)) return;
    parents.push([cursor, key]);
    cursor = cursor[key];
  }
  if (isObject(cursor)) delete cursor[keys.at(-1)];
  for (const [parent, key] of parents.reverse()) {
    if (isObject(parent[key]) && Object.keys(parent[key]).length === 0) delete parent[key];
    else break;
  }
}

function omitPaths(value, paths) {
  const result = clone(value);
  for (const keys of paths) deletePath(result, keys);
  return result;
}

function pathLabel(keys) {
  return `/${keys.map(key => String(key).replaceAll("~", "~0").replaceAll("/", "~1")).join("/")}`;
}

function mergeManagedFields({ current, previous, desired, force, label }) {
  if (!isObject(current) || !isObject(previous) || !isObject(desired)) {
    fail(`${label} must contain JSON objects`);
  }
  const previousPaths = new Set(leafEntries(previous).map(([keys]) => JSON.stringify(keys)));
  const conflicts = leafEntries(desired).filter(([keys, next]) =>
    !previousPaths.has(JSON.stringify(keys))
      && unmanagedPathConflict(current, keys, next)
  );
  if (conflicts.length > 0 && !force) {
    fail(`${label} has unmanaged conflicts at ${conflicts.map(([keys]) => pathLabel(keys)).join(", ")}; use migration.force for first adoption`);
  }
  const result = clone(current);
  const desiredPaths = new Set(leafEntries(desired).map(([keys]) => JSON.stringify(keys)));
  for (const [keys] of leafEntries(previous)) {
    if (!desiredPaths.has(JSON.stringify(keys))) deletePath(result, keys);
  }
  for (const [keys, next] of leafEntries(desired)) setPath(result, keys, next);
  return result;
}

function readStringSet(document, keys, label) {
  if (!hasPath(document, keys)) return [];
  const value = getPath(document, keys);
  if (!Array.isArray(value) || value.some(item => typeof item !== "string")) {
    fail(`${label}${pathLabel(keys)} must be an array of strings`);
  }
  return value;
}

function mergeManagedSet({ document, previous, desired, keys, label }) {
  const currentItems = readStringSet(document, keys, label);
  const previousItems = readStringSet(previous, keys, "ownership manifest");
  const desiredItems = readStringSet(desired, keys, "desired settings");
  const old = new Set(previousItems);
  const result = [];
  for (const item of [...currentItems.filter(item => !old.has(item)), ...desiredItems]) {
    if (!result.includes(item)) result.push(item);
  }
  if (result.length === 0) deletePath(document, keys);
  else setPath(document, keys, result);
}

function validateHooksDocument(document) {
  if (!isObject(document)) fail("settings.json must contain a JSON object");
  if (!Object.hasOwn(document, "hooks")) return;
  if (!isObject(document.hooks)) fail("settings.json /hooks must be an object");
  for (const [event, groups] of Object.entries(document.hooks)) {
    if (!Array.isArray(groups)) fail(`settings.json /hooks/${event} must be an array`);
    for (const group of groups) {
      if (!isObject(group) || !Array.isArray(group.hooks)) {
        fail(`settings.json /hooks/${event} contains an invalid hook group`);
      }
    }
  }
}

function matcherOf(group) {
  return typeof group.matcher === "string" ? group.matcher : null;
}

function normalizedHookEntry(entry) {
  return {
    type: entry.type,
    command: entry.command,
    timeout: entry.timeout ?? 30,
    async: entry.async ?? false,
    failClosed: entry.failClosed ?? false,
  };
}

function desiredEntry(hook) {
  return normalizedHookEntry({ type: "command", ...hook });
}

function forEachHook(document, callback) {
  if (!isObject(document.hooks)) return;
  for (const [event, groups] of Object.entries(document.hooks)) {
    for (const group of groups) {
      for (const entry of group.hooks) callback({ event, matcher: matcherOf(group), entry });
    }
  }
}

function pruneHooks(document) {
  if (!isObject(document.hooks)) return;
  for (const event of Object.keys(document.hooks)) {
    document.hooks[event] = document.hooks[event].filter(group => group.hooks.length > 0);
    if (document.hooks[event].length === 0) delete document.hooks[event];
  }
  if (Object.keys(document.hooks).length === 0) delete document.hooks;
}

function removeHook(document, predicate) {
  if (!isObject(document.hooks)) return;
  for (const [event, groups] of Object.entries(document.hooks)) {
    for (const group of groups) {
      group.hooks = group.hooks.filter(entry => !predicate({ event, matcher: matcherOf(group), entry }));
    }
  }
  pruneHooks(document);
}

function addHook(document, hook) {
  document.hooks ??= {};
  document.hooks[hook.event] ??= [];
  let group = document.hooks[hook.event].find(candidate => matcherOf(candidate) === hook.matcher);
  if (!group) {
    group = hook.matcher === null ? { hooks: [] } : { matcher: hook.matcher, hooks: [] };
    document.hooks[hook.event].push(group);
  }
  group.hooks.push(desiredEntry(hook));
}

function sameHook(location, hook) {
  return location.event === hook.event
    && location.matcher === hook.matcher
    && deepEqual(normalizedHookEntry(location.entry), desiredEntry(hook));
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function legacyCommandMatches(command, name, hooksDir) {
  if (typeof command !== "string") return false;
  if (command === path.join(hooksDir, `${name}.sh`)) return true;
  const suffix = `/bin/${escapeRegex(name)}\\.sh`;
  return new RegExp(`^/nix/store/[a-z0-9]+-command-code-hooks[^/]*${suffix}$`).test(command);
}

function mergeHooks({ document, previousHooks, desiredHooks, legacyNames, force }) {
  validateHooksDocument(document);
  for (const hook of previousHooks) {
    removeHook(document, location =>
      location.event === hook.event
        && location.matcher === hook.matcher
        && location.entry.command === hook.command
    );
  }
  for (const name of legacyNames) {
    removeHook(document, location => legacyCommandMatches(location.entry.command, name, options.hooksDir));
  }

  const commands = desiredHooks.map(hook => hook.command);
  if (new Set(commands).size !== commands.length) fail("desired hooks must have unique commands");
  for (const hook of desiredHooks) {
    const existing = [];
    forEachHook(document, location => {
      if (location.entry.command === hook.command) existing.push(location);
    });
    const exact = existing.filter(location => sameHook(location, hook));
    const conflicting = existing.filter(location => !sameHook(location, hook));
    if (conflicting.length > 0 && !force) {
      fail(`settings.json has an unmanaged conflict for hook command ${JSON.stringify(hook.command)}`);
    }
    if (existing.length === 1 && exact.length === 1) continue;
    if (existing.length > 0) removeHook(document, location => location.entry.command === hook.command);
    addHook(document, hook);
  }
}

async function safeStat(filename) {
  try {
    return await fs.lstat(filename);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

async function ensureDirectory(directory, mode = 0o700) {
  const existing = await safeStat(directory);
  if (existing?.isSymbolicLink() || (existing && !existing.isDirectory())) {
    fail(`refusing unsafe directory ${directory}`);
  }
  if (!existing) await fs.mkdir(directory, { recursive: false, mode });
  await fs.chmod(directory, mode);
}

async function readRegular(filename) {
  const stat = await safeStat(filename);
  if (!stat) return { exists: false, data: null, mode: null, hash: "missing" };
  if (stat.isSymbolicLink() || !stat.isFile()) fail(`refusing unsafe file ${filename}`);
  const data = await fs.readFile(filename);
  return {
    exists: true,
    data,
    mode: stat.mode & 0o777,
    hash: crypto.createHash("sha256").update(data).digest("hex"),
  };
}

function parseDocument(snapshot, filename) {
  if (!snapshot.exists) return {};
  try {
    const parsed = JSON.parse(snapshot.data.toString("utf8"));
    if (!isObject(parsed)) fail(`${filename} must contain a JSON object`);
    return parsed;
  } catch (error) {
    if (error.message.startsWith("command-code Nix sync:")) throw error;
    fail(`invalid JSON in ${filename}: ${error.message}`);
  }
}

async function stage(filename, data, mode) {
  const temporary = path.join(path.dirname(filename), `.${path.basename(filename)}.tmp.${process.pid}.${crypto.randomBytes(5).toString("hex")}`);
  const handle = await fs.open(temporary, "wx", mode);
  try {
    await handle.writeFile(data);
    await handle.sync();
  } finally {
    await handle.close();
  }
  await fs.chmod(temporary, mode);
  return temporary;
}

async function unchanged(filename, snapshot) {
  return (await readRegular(filename)).hash === snapshot.hash;
}

async function restore(filename, snapshot) {
  if (!snapshot.exists) {
    await fs.rm(filename, { force: true });
    return;
  }
  const temporary = await stage(filename, snapshot.data, snapshot.mode);
  await fs.rename(temporary, filename);
}

function jsonBytes(value) {
  return Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
}

async function main() {
  const [desiredConfig, desiredSettings, desiredHooks, desiredMcp, desiredHookFiles] = await Promise.all([
    parseDesired("CMDC_DESIRED_CONFIG"),
    parseDesired("CMDC_DESIRED_SETTINGS"),
    parseDesired("CMDC_DESIRED_HOOKS"),
    parseDesired("CMDC_DESIRED_MCP"),
    parseDesired("CMDC_DESIRED_HOOK_FILES"),
  ]);
  if (!isObject(desiredConfig) || !isObject(desiredSettings) || !Array.isArray(desiredHooks)
      || !isObject(desiredMcp) || !Array.isArray(desiredHookFiles)) {
    fail("internal desired state has an invalid shape");
  }

  await ensureDirectory(options.dataDir);
  const stateParent = path.dirname(options.stateDir);
  if (stateParent !== options.dataDir) await ensureDirectory(stateParent);
  await ensureDirectory(options.stateDir);
  await ensureDirectory(options.hooksDir);

  for (const target of [options.config, options.settings, options.mcp]) {
    if (target && path.dirname(target) !== options.dataDir) fail(`target must be directly inside ${options.dataDir}: ${target}`);
  }

  const manifestSnapshot = await readRegular(manifestPath);
  const manifest = manifestSnapshot.exists ? parseDocument(manifestSnapshot, manifestPath) : null;
  if (manifest) {
    if (manifest.schemaVersion !== 1 || manifest.commandCodeVersion !== "0.51.0" || manifest.scope !== options.scope) {
      fail(`unsupported or mismatched ownership manifest ${manifestPath}`);
    }
    if (options.force) fail("migration.force is one-time only and must be disabled after the ownership manifest exists");
    if (!isObject(manifest.targets) || !isObject(manifest.desired)
        || !Array.isArray(manifest.desired.hooks) || !Array.isArray(manifest.hookFiles)) {
      fail(`invalid ownership manifest ${manifestPath}`);
    }
  }
  const targets = {
    config: options.config ?? null,
    settings: options.settings,
    mcp: options.mcp,
    hooksDir: options.hooksDir,
  };
  const concreteTargets = Object.values(targets).filter(value => value !== null);
  if (new Set(concreteTargets).size !== concreteTargets.length) fail("managed target paths must be distinct");
  if (manifest && !deepEqual(manifest.targets, targets)) fail("managed target paths changed; remove the ownership manifest only after manual review");

  const legacySnapshot = await readRegular(legacyManifestPath);
  const legacyNames = legacySnapshot.exists
    ? legacySnapshot.data.toString("utf8").split(/\r?\n/).filter(Boolean)
    : [];
  for (const name of legacyNames) {
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(name) || name.includes("__")) {
      fail(`unsafe name ${JSON.stringify(name)} in legacy hook manifest`);
    }
  }

  const previous = manifest?.desired ?? { config: {}, settings: {}, hooks: [], mcp: {} };
  const snapshots = new Map();
  const outputs = new Map();

  if (options.config) {
    const snapshot = await readRegular(options.config);
    snapshots.set(options.config, snapshot);
    outputs.set(options.config, jsonBytes(mergeManagedFields({
      current: parseDocument(snapshot, options.config),
      previous: previous.config ?? {},
      desired: desiredConfig,
      force: options.force,
      label: "config.json",
    })));
  }

  {
    const snapshot = await readRegular(options.settings);
    snapshots.set(options.settings, snapshot);
    const current = parseDocument(snapshot, options.settings);
    const setPaths = [["disabledSkills"], ["permissions", "allow"]];
    const merged = mergeManagedFields({
      current,
      previous: omitPaths(previous.settings ?? {}, setPaths),
      desired: omitPaths(desiredSettings, setPaths),
      force: options.force,
      label: "settings.json",
    });
    for (const keys of setPaths) mergeManagedSet({
      document: merged,
      previous: previous.settings ?? {},
      desired: desiredSettings,
      keys,
      label: "settings.json",
    });
    mergeHooks({
      document: merged,
      previousHooks: previous.hooks ?? [],
      desiredHooks,
      legacyNames,
      force: options.force,
    });
    outputs.set(options.settings, jsonBytes(merged));
  }

  {
    const snapshot = await readRegular(options.mcp);
    snapshots.set(options.mcp, snapshot);
    const merged = mergeManagedFields({
      current: parseDocument(snapshot, options.mcp),
      previous: previous.mcp ?? {},
      desired: desiredMcp,
      force: options.force,
      label: "mcp.json",
    });
    if (isObject(merged.mcpServers)) {
      for (const name of Object.keys(merged.mcpServers)) {
        if (isObject(merged.mcpServers[name]) && Object.keys(merged.mcpServers[name]).length === 0) delete merged.mcpServers[name];
      }
      if (Object.keys(merged.mcpServers).length === 0) delete merged.mcpServers;
    }
    outputs.set(options.mcp, jsonBytes(merged));
  }

  const previousHookFiles = manifest?.hookFiles ?? legacyNames;
  for (const name of [...new Set([...previousHookFiles, ...desiredHookFiles])]) {
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(name) || name.includes("__")) fail(`invalid managed hook filename ${JSON.stringify(name)}`);
    const destination = path.join(options.hooksDir, `${name}.sh`);
    snapshots.set(destination, await readRegular(destination));
  }

  const hooksPackage = process.env.CMDC_HOOKS_PACKAGE;
  for (const name of desiredHookFiles) {
    const source = path.join(hooksPackage, "bin", `${name}.sh`);
    const sourceData = await fs.readFile(source);
    const destination = path.join(options.hooksDir, `${name}.sh`);
    const wasOwned = previousHookFiles.includes(name) || legacyNames.includes(name);
    const existing = snapshots.get(destination);
    if (existing.exists && !wasOwned && !existing.data.equals(sourceData) && !options.force) {
      fail(`unmanaged hook file conflicts at ${destination}`);
    }
    outputs.set(destination, sourceData);
  }

  const nextManifest = {
    schemaVersion: 1,
    commandCodeVersion: "0.51.0",
    scope: options.scope,
    targets,
    desired: {
      config: desiredConfig,
      settings: desiredSettings,
      hooks: desiredHooks,
      mcp: desiredMcp,
    },
    hookFiles: desiredHookFiles,
  };
  outputs.set(manifestPath, jsonBytes(nextManifest));
  snapshots.set(manifestPath, manifestSnapshot);
  snapshots.set(legacyManifestPath, legacySnapshot);

  const staged = new Map();
  try {
    for (const [filename, data] of outputs) {
      staged.set(filename, await stage(filename, data, filename.endsWith(".sh") ? 0o700 : 0o600));
    }
    for (const [filename, snapshot] of snapshots) {
      if (!await unchanged(filename, snapshot)) fail(`concurrent modification detected for ${filename}`);
    }

    const modified = [];
    try {
      for (const [filename, temporary] of staged) {
        if (filename === manifestPath) continue;
        await fs.rename(temporary, filename);
        staged.delete(filename);
        modified.push(filename);
      }
      for (const name of previousHookFiles) {
        if (desiredHookFiles.includes(name)) continue;
        const filename = path.join(options.hooksDir, `${name}.sh`);
        await fs.rm(filename, { force: true });
        modified.push(filename);
      }
      if (legacySnapshot.exists) {
        await fs.rm(legacyManifestPath, { force: true });
        modified.push(legacyManifestPath);
      }
      await fs.rename(staged.get(manifestPath), manifestPath);
      staged.delete(manifestPath);
      modified.push(manifestPath);
    } catch (error) {
      for (const filename of modified.reverse()) {
        const snapshot = snapshots.get(filename) ?? { exists: false };
        try { await restore(filename, snapshot); } catch { /* best effort; original error remains primary */ }
      }
      throw error;
    }
  } finally {
    await Promise.all([...staged.values()].map(filename => fs.rm(filename, { force: true })));
  }
}

main().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
