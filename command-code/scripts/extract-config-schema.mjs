#!/usr/bin/env node

/**
 * Extract the Command Code configuration contract without importing or
 * executing any code from the package under inspection.
 *
 * The npm bundle is intentionally minified.  This extractor therefore builds
 * a small syntax tree from ECMAScript tokens and keys its analysis to literal
 * property names, semantic __name() labels, and package metadata.  Minified
 * binding names are evidence, never part of the emitted schema.
 */

import { createHash } from "node:crypto";
import {
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { parseArgs } from "node:util";

const FORMAT_VERSION = 1;

const GLOBAL_FIELD_TYPES = {
  provider: "string",
  model: "string",
  reasoningEffort: "attrsOf(reasoningEffort)",
  theme: "enum(theme)",
  compactMode: "enum(compactMode)",
  telemetry: "boolean",
  tasteLearning: "boolean",
  featureModels: "attrsOf(modelId)",
  autoInstallExtension: "boolean",
  forceOAuth: "boolean",
  installed: "boolean",
  firstMessageSent: "boolean",
};

const GLOBAL_RUNTIME_FIELDS = new Set([
  "forceOAuth",
  "installed",
  "firstMessageSent",
]);

const REQUIRED_GLOBAL_FIELDS = [
  "provider",
  "model",
  "reasoningEffort",
  "theme",
  "compactMode",
  "telemetry",
  "tasteLearning",
  "featureModels",
  "autoInstallExtension",
  "forceOAuth",
  "installed",
  "firstMessageSent",
];

const REQUIRED_PATH_LITERALS = [
  "config.json",
  "settings.json",
  "settings.local.json",
  "mcp.json",
  "mcp-tokens.json",
  "trusted-hooks.json",
];

function fail(message) {
  throw new Error(message);
}

function sha256SRI(value) {
  return `sha256-${createHash("sha256").update(value).digest("base64")}`;
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonical(value[key])]),
    );
  }
  return value;
}

function canonicalJson(value) {
  return `${JSON.stringify(canonical(value), null, 2)}\n`;
}

function atomicWrite(path, contents) {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.tmp-${process.pid}`;
  writeFileSync(temporary, contents, { mode: 0o600 });
  renameSync(temporary, path);
}

function decodeQuoted(raw) {
  if (raw[0] === "`") {
    if (raw.includes("${")) return null;
    return raw.slice(1, -1).replace(/\\`/g, "`").replace(/\\\\/g, "\\");
  }
  try {
    return JSON.parse(raw[0] === "'" ? `"${raw.slice(1, -1)
      .replace(/\\'/g, "'")
      .replace(/"/g, '\\"')}"` : raw);
  } catch {
    return raw.slice(1, -1);
  }
}

function isIdentifierStart(character) {
  return /[A-Za-z_$]/.test(character);
}

function isIdentifierPart(character) {
  return /[A-Za-z0-9_$]/.test(character);
}

function scanQuoted(source, start, quote) {
  let index = start + 1;
  while (index < source.length) {
    if (source[index] === "\\") {
      index += 2;
      continue;
    }
    if (source[index] === quote) return index + 1;
    index += 1;
  }
  fail(`unterminated ${quote === "`" ? "template" : "string"} at byte ${start}`);
}

function scanRegexLiteral(source, start) {
  let index = start + 1;
  let inClass = false;
  while (index < source.length) {
    if (source[index] === "\\") {
      index += 2;
      continue;
    }
    if (source[index] === "[") inClass = true;
    else if (source[index] === "]") inClass = false;
    else if (source[index] === "/" && !inClass) {
      index += 1;
      while (/[A-Za-z]/.test(source[index] ?? "")) index += 1;
      return index;
    }
    index += 1;
  }
  fail(`unterminated regular expression at byte ${start}`);
}

function templateRegexMayStart(source, index) {
  let cursor = index - 1;
  while (cursor >= 0 && /\s/.test(source[cursor])) cursor -= 1;
  if (cursor < 0) return true;
  if ("([{,:;=!?&|".includes(source[cursor])) return true;
  const prefix = source.slice(0, cursor + 1).match(/([A-Za-z_$][\w$]*)$/)?.[1];
  return new Set(["return", "case", "throw", "yield", "typeof", "void", "delete"]).has(prefix);
}

function scanTemplateExpression(source, start) {
  let index = start;
  let depth = 1;
  while (index < source.length) {
    const character = source[index];
    if (character === "'" || character === '"') {
      index = scanQuoted(source, index, character);
      continue;
    }
    if (character === "`") {
      index = scanTemplateLiteral(source, index);
      continue;
    }
    if (character === "/" && source[index + 1] === "/") {
      const newline = source.indexOf("\n", index + 2);
      index = newline === -1 ? source.length : newline + 1;
      continue;
    }
    if (character === "/" && source[index + 1] === "*") {
      const end = source.indexOf("*/", index + 2);
      if (end === -1) fail(`unterminated block comment at byte ${index}`);
      index = end + 2;
      continue;
    }
    if (character === "/" && templateRegexMayStart(source, index)) {
      index = scanRegexLiteral(source, index);
      continue;
    }
    if (character === "{") depth += 1;
    else if (character === "}" && --depth === 0) return index + 1;
    index += 1;
  }
  fail(`unterminated template expression at byte ${start - 2}`);
}

function scanTemplateLiteral(source, start) {
  let index = start + 1;
  while (index < source.length) {
    if (source[index] === "\\") {
      index += 2;
      continue;
    }
    if (source[index] === "`") return index + 1;
    if (source[index] === "$" && source[index + 1] === "{") {
      index = scanTemplateExpression(source, index + 2);
      continue;
    }
    index += 1;
  }
  fail(`unterminated template at byte ${start}`);
}

function regexMayStartAfter(previous) {
  if (!previous) return true;
  const expressionKeywords = new Set(["return", "case", "throw", "yield", "else", "do", "typeof", "void", "delete", "in", "of"]);
  if (previous.type === "identifier") return expressionKeywords.has(previous.value);
  if (previous.type === "number" || previous.type === "string" || previous.type === "regex") return false;
  return new Set([
    "(", "[", "{", ",", ";", ":", "=", "==", "===", "!=", "!==",
    "!", "&&", "||", "??", "?", "=>",
  ]).has(previous.value);
}

function tokenize(source) {
  const tokens = [];
  let index = source.startsWith("#!") ? source.indexOf("\n") + 1 : 0;
  let previous = null;
  const push = (token) => {
    tokens.push(token);
    previous = token;
  };

  while (index < source.length) {
    const start = index;
    const character = source[index];

    if (/\s/.test(character)) {
      index += 1;
      continue;
    }

    if (character === "/" && source[index + 1] === "/") {
      index = source.indexOf("\n", index + 2);
      if (index === -1) break;
      continue;
    }

    if (character === "/" && source[index + 1] === "*") {
      const end = source.indexOf("*/", index + 2);
      if (end === -1) fail(`unterminated block comment at byte ${start}`);
      index = end + 2;
      continue;
    }

    if (character === "`") {
      index = scanTemplateLiteral(source, start);
      const raw = source.slice(start, index);
      push({ type: "string", value: decodeQuoted(raw), raw, start, end: index });
      continue;
    }

    if (character === "'" || character === '"') {
      const quote = character;
      index = scanQuoted(source, start, quote);
      const raw = source.slice(start, index);
      push({ type: "string", value: decodeQuoted(raw), raw, start, end: index });
      continue;
    }

    if (character === "/" && regexMayStartAfter(previous)) {
      index = scanRegexLiteral(source, start);
      push({ type: "regex", value: source.slice(start, index), start, end: index });
      continue;
    }

    if (isIdentifierStart(character)) {
      index += 1;
      while (index < source.length && isIdentifierPart(source[index])) index += 1;
      const value = source.slice(start, index);
      push({ type: "identifier", value, start, end: index });
      continue;
    }

    if (/[0-9]/.test(character) || (character === "." && /[0-9]/.test(source[index + 1] ?? ""))) {
      index += 1;
      while (index < source.length && /[0-9A-Fa-f_xXobOB.eE+-]/.test(source[index])) index += 1;
      push({ type: "number", value: source.slice(start, index), start, end: index });
      continue;
    }

    const operator = ["===", "!==", "=>", "?.", "??", "&&", "||", "==", "!=", "<=", ">=", "++", "--", "**", "..."].find(
      (candidate) => source.startsWith(candidate, index),
    );
    const value = operator ?? character;
    index += value.length;
    push({ type: "punctuator", value, start, end: index });
  }

  return tokens;
}

function buildSyntaxTree(tokens) {
  const root = { type: "Program", children: [], start: 0, end: 0 };
  const stack = [root];
  const pairs = new Map([["(", ")"], ["[", "]"], ["{", "}"]]);
  const closing = new Set(pairs.values());

  for (let tokenIndex = 0; tokenIndex < tokens.length; tokenIndex += 1) {
    const token = tokens[tokenIndex];
    if (token.type === "punctuator" && pairs.has(token.value)) {
      const close = pairs.get(token.value);
      const group = {
        type: "Group",
        delimiter: `${token.value}${close}`,
        children: [],
        start: token.start,
        end: null,
      };
      stack.at(-1).children.push(group);
      stack.push(group);
    } else if (token.type === "punctuator" && closing.has(token.value)) {
      if (stack.length === 1 || stack.at(-1).delimiter[1] !== token.value) {
        const open = stack.at(-1).delimiter ?? "program";
        const context = tokens.slice(Math.max(0, tokenIndex - 8), tokenIndex + 2).map((item) => `${item.type}:${item.value}`).join(" ");
        fail(`unbalanced ${token.value} (${token.type}) at byte ${token.start}; current group ${open} opened at byte ${stack.at(-1).start}; tokens ${context}`);
      }
      stack.at(-1).end = token.end;
      stack.pop();
    } else {
      stack.at(-1).children.push(token);
    }
  }

  if (stack.length !== 1) fail(`unclosed ${stack.at(-1).delimiter[0]} at byte ${stack.at(-1).start}`);
  root.end = tokens.at(-1)?.end ?? 0;
  return root;
}

function* walkGroups(node) {
  if (node.type === "Group") yield node;
  for (const child of node.children ?? []) {
    if (child.type === "Group") yield* walkGroups(child);
  }
}

function splitChildren(children, separator = ",") {
  const parts = [[]];
  for (const child of children) {
    if (child.type === "punctuator" && child.value === separator) parts.push([]);
    else parts.at(-1).push(child);
  }
  return parts;
}

function propertyEntries(group) {
  if (group?.delimiter !== "{}") return new Map();
  const result = new Map();
  for (const part of splitChildren(group.children)) {
    const colon = part.findIndex((child) => child.type === "punctuator" && child.value === ":");
    if (colon <= 0) continue;
    const keyNode = part[colon - 1];
    if (keyNode.type !== "identifier" && keyNode.type !== "string") continue;
    const key = keyNode.value;
    if (typeof key !== "string") continue;
    result.set(key, part.slice(colon + 1));
  }
  return result;
}

function firstMeaningful(nodes) {
  return nodes.find((node) => !(node.type === "punctuator" && ["...", "+", "-", "!"].includes(node.value)));
}

function scalar(nodes, symbolStrings = new Map()) {
  const first = firstMeaningful(nodes);
  if (!first) return null;
  if (first.type === "string") return first.value;
  if (first.type === "number") return Number(first.value);
  if (first.type === "identifier") {
    if (first.value === "true") return true;
    if (first.value === "false") return false;
    return symbolStrings.get(first.value) ?? null;
  }
  if (nodes.length >= 2 && nodes[0]?.value === "!" && nodes[1]?.type === "number") {
    return Number(nodes[1].value) === 0;
  }
  return null;
}

function directGroup(nodes, delimiter) {
  return nodes.find((node) => node.type === "Group" && node.delimiter === delimiter) ?? null;
}

function stringArray(nodes, symbolStrings = new Map()) {
  const group = directGroup(nodes, "[]");
  if (!group) return [];
  return splitChildren(group.children)
    .map((part) => scalar(part, symbolStrings))
    .filter((value) => typeof value === "string");
}

function collectSymbolStrings(tree) {
  const symbols = new Map();
  const visit = (node) => {
    const children = node.children ?? [];
    for (let index = 0; index + 2 < children.length; index += 1) {
      const [name, equals, value] = children.slice(index, index + 3);
      if (
        name.type === "identifier" &&
        equals.type === "punctuator" && equals.value === "=" &&
        value.type === "string" && typeof value.value === "string" &&
        children[index - 1]?.value !== "."
      ) symbols.set(name.value, value.value);
    }
    for (const child of children) if (child.type === "Group") visit(child);
  };
  visit(tree);
  return symbols;
}

function collectSemanticBindings(tree) {
  const result = new Map();
  const visit = (node) => {
    const children = node.children ?? [];
    for (let index = 0; index + 1 < children.length; index += 1) {
      const callee = children[index];
      const args = children[index + 1];
      if (callee.type !== "identifier" || args.type !== "Group" || args.delimiter !== "()") continue;
      const parts = splitChildren(args.children);
      const binding = parts[0]?.find((candidate) => candidate.type === "identifier");
      const label = scalar(parts[1] ?? []);
      if (binding && typeof label === "string" && /^[A-Za-z_$][\w$]*$/.test(label)) {
        result.set(label, binding.value);
      }
    }
    for (const child of children) if (child.type === "Group") visit(child);
  };
  visit(tree);
  return result;
}

function collectCallObjectKeys(tree, binding) {
  const keys = new Set();
  const visit = (node) => {
    const children = node.children ?? [];
    for (let index = 0; index + 1 < children.length; index += 1) {
      if (children[index].type !== "identifier" || children[index].value !== binding) continue;
      const args = children[index + 1];
      if (args?.type !== "Group" || args.delimiter !== "()") continue;
      const firstArgument = splitChildren(args.children)[0] ?? [];
      const object = directGroup(firstArgument, "{}");
      for (const key of propertyEntries(object).keys()) keys.add(key);
    }
    for (const child of children) if (child.type === "Group") visit(child);
  };
  visit(tree);
  return keys;
}

function countPropertyTokens(tokens) {
  const counts = new Map();
  for (const token of tokens) {
    if (token.type === "identifier" || token.type === "string") {
      counts.set(token.value, (counts.get(token.value) ?? 0) + 1);
    }
  }
  return counts;
}

function collectMemberChains(tokens) {
  const chains = [];
  for (let index = 0; index < tokens.length; index += 1) {
    if (tokens[index].type !== "identifier") continue;
    const parts = [tokens[index].value];
    let cursor = index + 1;
    while (
      (tokens[cursor]?.value === "." || tokens[cursor]?.value === "?.") &&
      tokens[cursor + 1]?.type === "identifier"
    ) {
      parts.push(tokens[cursor + 1].value);
      cursor += 2;
    }
    if (parts.length > 1) chains.push(parts);
  }
  return chains;
}

function extractPermissionAutoApproveKeys(tokens) {
  const keys = new Set();
  for (const chain of collectMemberChains(tokens)) {
    for (let index = 0; index + 2 < chain.length; index += 1) {
      if (chain[index] === "permissions" && chain[index + 1] === "autoApprove") {
        keys.add(chain[index + 2]);
      }
    }
  }
  if (keys.size === 0) fail("could not locate permissions.autoApprove settings reads");
  return [...keys].sort();
}

function extractModels(tree, symbolStrings) {
  const models = new Map();
  for (const group of walkGroups(tree)) {
    const properties = propertyEntries(group);
    if (!properties.has("id") || !properties.has("inputModalities") || !properties.has("provider") || !properties.has("label")) continue;
    const id = scalar(properties.get("id"), symbolStrings);
    const label = scalar(properties.get("label"), symbolStrings);
    if (typeof id !== "string" || typeof label !== "string") continue;
    const item = {
      id,
      label,
      inputModalities: stringArray(properties.get("inputModalities"), symbolStrings).sort(),
    };
    const efforts = stringArray(properties.get("reasoningEfforts") ?? [], symbolStrings);
    if (efforts.length > 0) item.reasoningEfforts = efforts;
    const contextWindow = scalar(properties.get("contextWindow") ?? [], symbolStrings);
    if (typeof contextWindow === "number" && Number.isFinite(contextWindow)) item.contextWindow = contextWindow;
    const hidden = scalar(properties.get("hidden") ?? [], symbolStrings);
    if (typeof hidden === "boolean") item.hidden = hidden;
    models.set(id, item);
  }
  return [...models.values()].sort((left, right) => left.id.localeCompare(right.id));
}

function extractFeatureModels(tree, symbolStrings) {
  const candidates = [];
  for (const group of walkGroups(tree)) {
    if (group.delimiter !== "[]") continue;
    const items = group.children
      .filter((child) => child.type === "Group" && child.delimiter === "{}")
      .map((child) => propertyEntries(child))
      .filter((properties) => properties.has("key") && properties.has("label"));
    const keys = items.map((properties) => scalar(properties.get("key"), symbolStrings));
    if (keys.includes("tasteLearning") && keys.length >= 3) candidates.push(items);
  }
  const items = candidates.sort((left, right) => right.length - left.length)[0];
  if (!items) fail("could not locate featureModels catalog");
  return items
    .map((properties) => ({
      key: scalar(properties.get("key"), symbolStrings),
      label: scalar(properties.get("label"), symbolStrings),
      description: scalar(properties.get("description") ?? [], symbolStrings),
      hasFixedDefault: properties.has("defaultLabel"),
    }))
    .filter((item) => typeof item.key === "string")
    .sort((left, right) => left.key.localeCompare(right.key));
}

function extractProviders(tree, symbolStrings) {
  const providers = new Map();
  for (const group of walkGroups(tree)) {
    const properties = propertyEntries(group);
    if (!properties.has("id") || !properties.has("supportedModelProviders")) continue;
    const id = scalar(properties.get("id"), symbolStrings);
    if (typeof id !== "string") continue;
    const provider = {
      id,
      label: scalar(properties.get("label") ?? [], symbolStrings),
      requiresAuth: scalar(properties.get("requiresAuth") ?? [], symbolStrings),
    };
    providers.set(id, provider);
  }
  if (providers.size === 0) fail("could not locate provider catalog");
  return [...providers.values()].sort((left, right) => left.id.localeCompare(right.id));
}

function extractSelfAssignmentEnum(tree, requiredValue) {
  const candidates = [];
  for (const group of walkGroups(tree)) {
    const values = [];
    const children = group.children;
    for (let index = 0; index + 4 < children.length; index += 1) {
      const [object, dot, property, equals, value] = children.slice(index, index + 5);
      if (
        object.type === "identifier" && dot.value === "." && property.type === "identifier" &&
        equals.value === "=" && value.type === "string" && property.value === value.value
      ) values.push(value.value);
    }
    if (values.includes(requiredValue)) candidates.push([...new Set(values)]);
  }
  const result = candidates.sort((left, right) => right.length - left.length)[0];
  if (!result) fail(`could not locate enum containing ${requiredValue}`);
  return result.sort();
}

function findExactStringArray(tree, required) {
  const wanted = [...required].sort();
  for (const group of walkGroups(tree)) {
    if (group.delimiter !== "[]") continue;
    const values = splitChildren(group.children).map((part) => scalar(part)).filter((value) => typeof value === "string").sort();
    if (values.length === wanted.length && values.every((value, index) => value === wanted[index])) return wanted;
  }
  fail(`could not locate enum [${required.join(", ")}]`);
}

function buildGlobalFields(propertyCounts, updatedKeys) {
  const observed = new Set(updatedKeys);
  for (const name of REQUIRED_GLOBAL_FIELDS) {
    if ((propertyCounts.get(name) ?? 0) > 0) observed.add(name);
  }
  for (const required of REQUIRED_GLOBAL_FIELDS) {
    if (!observed.has(required)) fail(`required global config field is absent: ${required}`);
  }
  return Object.fromEntries(
    [...observed]
      .sort()
      .map((name) => [name, {
        type: GLOBAL_FIELD_TYPES[name] ?? "unknown",
        ownership: GLOBAL_RUNTIME_FIELDS.has(name) ? "runtime-preserved" : "declarative",
      }]),
  );
}

function extractSchema(packageDirectory) {
  const packageRoot = realpathSync(packageDirectory);
  const packageJsonPath = resolve(packageRoot, "package.json");
  const packageJsonSource = readFileSync(packageJsonPath, "utf8");
  const packageJson = JSON.parse(packageJsonSource);
  if (packageJson.name !== "command-code") fail(`expected package command-code, got ${packageJson.name}`);
  if (typeof packageJson.version !== "string" || !packageJson.version) fail("package.json version is missing");
  if (typeof packageJson.main !== "string" || !packageJson.main) fail("package.json main is missing");
  if (isAbsolute(packageJson.main)) fail("package.json main must be relative");

  const entrypointPath = realpathSync(resolve(packageRoot, packageJson.main));
  const relativeEntrypoint = relative(packageRoot, entrypointPath);
  if (relativeEntrypoint === ".." || relativeEntrypoint.startsWith(`..${sep}`) || isAbsolute(relativeEntrypoint)) {
    fail("package.json main escapes the package root");
  }
  if (!statSync(entrypointPath).isFile()) fail("package.json main is not a regular file");

  const source = readFileSync(entrypointPath, "utf8");
  const tokens = tokenize(source);
  const tree = buildSyntaxTree(tokens);
  const symbolStrings = collectSymbolStrings(tree);
  const semanticBindings = collectSemanticBindings(tree);
  const propertyCounts = countPropertyTokens(tokens);
  const updateBinding = semanticBindings.get("updateUserConfig") ?? "updateUserConfig";
  const updatedKeys = collectCallObjectKeys(tree, updateBinding);

  const stringCounts = new Map();
  for (const token of tokens.filter((token) => token.type === "string" && typeof token.value === "string")) {
    stringCounts.set(token.value, (stringCounts.get(token.value) ?? 0) + 1);
  }
  for (const literal of REQUIRED_PATH_LITERALS) {
    if (!(stringCounts.get(literal) > 0)) fail(`required configuration path literal is absent: ${literal}`);
  }

  const models = extractModels(tree, symbolStrings);
  if (models.length < 5) fail(`model catalog extraction is implausibly small (${models.length})`);
  const featureModels = extractFeatureModels(tree, symbolStrings);
  const providers = extractProviders(tree, symbolStrings);
  const hookEvents = extractSelfAssignmentEnum(tree, "PreToolUse");
  const mcpTransports = findExactStringArray(tree, ["stdio", "http"]);
  findExactStringArray(tree, ["dark", "light"]);

  const reasoningEfforts = [...new Set(models.flatMap((model) => model.reasoningEfforts ?? []))].sort();
  const globalFields = buildGlobalFields(propertyCounts, updatedKeys);
  const permissionAutoApproveKeys = extractPermissionAutoApproveKeys(tokens);

  const structural = {
    files: {
      globalConfig: { format: "json", path: "~/.commandcode/config.json", scope: "user" },
      userSettings: { format: "json", path: "~/.commandcode/settings.json", scope: "user" },
      projectSharedSettings: { format: "json", path: ".commandcode/settings.json", scope: "project-shared" },
      projectLocalSettings: { format: "json", path: ".commandcode/settings.local.json", scope: "project-local" },
      userMcp: { format: "json", path: "~/.commandcode/mcp.json", scope: "user" },
      projectSharedMcp: { format: "json", path: ".mcp.json", scope: "project-shared" },
      projectLocalMcp: { format: "json", path: "~/.commandcode/projects/<slug>/mcp.json", scope: "project-local" },
    },
    globalConfig: {
      fields: globalFields,
      unknownKeys: "preserve",
    },
    settings: {
      fields: {
        disabledSkills: { scopes: ["user", "project-shared", "project-local"], type: "listOf(string)" },
        hooks: { scopes: ["user", "project-shared", "project-local"], type: "attrsOf(listOf(hookDefinition))" },
        input: {
          fields: { collapsePastedText: { type: "boolean" } },
          scopes: ["user", "project-shared", "project-local"],
          type: "object",
        },
        permissions: {
          fields: {
            allow: { type: "listOf(string)" },
            autoApprove: {
              fields: Object.fromEntries(permissionAutoApproveKeys.map((key) => [key, { type: "boolean" }])),
              type: "object",
            },
            defaultMode: { enum: ["acceptEdits", "ask"], type: "enum" },
            deny: { ownership: "runtime-preserved", type: "listOf(string)" },
          },
          scopes: ["project-local"],
          type: "object",
        },
        tasteLearning: { scopes: ["project-shared", "project-local"], type: "boolean" },
      },
      precedence: {
        disabledSkills: ["project-local", "project-shared", "user"],
        hooks: ["project-local", "project-shared", "user"],
        input: ["project-local", "project-shared", "user"],
        tasteLearning: ["project-local", "project-shared", "user-config"],
      },
      unknownKeys: "preserve",
    },
    hooks: {
      events: hookEvents,
      fields: {
        async: { type: "boolean" },
        command: { required: true, type: "string" },
        failClosed: { type: "boolean" },
        timeout: { maximum: 600, minimum: 1, type: "integer-seconds" },
        type: { enum: ["command"], type: "enum" },
      },
    },
    mcp: {
      fields: {
        args: { transport: "stdio", type: "listOf(string)" },
        command: { requiredFor: "stdio", type: "string" },
        enabled: { default: true, type: "boolean" },
        env: { ownership: "secret-preserved", type: "attrsOf(string)" },
        headers: { ownership: "secret-preserved", type: "attrsOf(string)" },
        oauth: { ownership: "secret-preserved", type: "object" },
        transport: { enum: mcpTransports, required: true, type: "enum" },
        url: { requiredFor: "http", type: "url" },
      },
      precedence: ["project-local", "project-shared", "user"],
      serverMapKey: "mcpServers",
    },
    excludedRuntimeFiles: [
      "~/.commandcode/auth.json",
      "~/.commandcode/mcp-tokens.json",
      "~/.commandcode/trusted-hooks.json",
    ],
  };

  const catalogs = {
    featureModels,
    models,
    providers,
    reasoningEfforts,
  };

  return {
    schemaVersion: FORMAT_VERSION,
    package: {
      name: packageJson.name,
      version: packageJson.version,
      entrypoint: relativeEntrypoint.split(sep).join("/"),
      packageJsonHash: sha256SRI(packageJsonSource),
      entrypointHash: sha256SRI(source),
    },
    structural,
    catalogs,
    evidence: {
      analysis: "static-ecmascript-syntax-tree",
      bundleBytes: Buffer.byteLength(source),
      modelCount: models.length,
      permissionAutoApproveKeys,
      pathLiteralCounts: Object.fromEntries(REQUIRED_PATH_LITERALS.map((literal) => [literal, stringCounts.get(literal)])),
      semanticBindings: [...semanticBindings.keys()].filter((name) => [
        "loadUserConfig", "updateUserConfig", "settingsFilePaths", "loadMergedMcpConfig",
      ].includes(name)).sort(),
      tokenCount: tokens.length,
    },
  };
}

function main() {
  const { values } = parseArgs({
    options: {
      "package-dir": { type: "string" },
      output: { type: "string" },
      "hash-output": { type: "string" },
      stdout: { type: "boolean", default: false },
      help: { type: "boolean", short: "h", default: false },
    },
    strict: true,
  });

  if (values.help) {
    console.log("Usage: extract-config-schema.mjs --package-dir DIR [--output FILE --hash-output FILE] [--stdout]");
    return;
  }
  if (!values["package-dir"]) fail("--package-dir is required");
  if (!values.stdout && !values.output) fail("--output is required unless --stdout is used");

  const schema = extractSchema(values["package-dir"]);
  const contents = canonicalJson(schema);
  const hash = sha256SRI(contents);
  if (values.output) atomicWrite(resolve(values.output), contents);
  if (values["hash-output"]) atomicWrite(resolve(values["hash-output"]), `${hash}\n`);
  if (values.stdout) process.stdout.write(contents);
  if (!values.stdout) process.stdout.write(`${JSON.stringify({
    schemaVersion: FORMAT_VERSION,
    packageVersion: schema.package.version,
    entrypoint: schema.package.entrypoint,
    hash,
    structuralHash: sha256SRI(canonicalJson(schema.structural)),
    catalogHash: sha256SRI(canonicalJson(schema.catalogs)),
  })}\n`);
}

try {
  main();
} catch (error) {
  console.error(`extract-config-schema: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 2;
}
