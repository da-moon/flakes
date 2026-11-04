import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = process.argv[2];
const crypto = await import(`${root}/lib/memlawb/client/crypto.ts`);
const key = crypto.deriveKey("fixture-passphrase", "user:fixture");
assert.equal(key.toString("hex"),
  "27a2e80c3311ed0f0274d40f3c7abcb49036c2d6979ca02a9f1e886e06ffc387");
assert.equal(crypto.decryptEntry(key, "fixture.md",
  "ASGOlR7cCsRenJA3+wwgUqBZoTgw71lVZdZSM6w1OAyrzUwt1SLATahhM8qRjLYX6nVNWLNQ"),
  "existing encrypted memory");
assert.throws(() => crypto.decryptEntry(key, "other.md",
  "ASGOlR7cCsRenJA3+wwgUqBZoTgw71lVZdZSM6w1OAyrzUwt1SLATahhM8qRjLYX6nVNWLNQ"));

const fixtureDirectory = mkdtempSync(join(tmpdir(), "memlawb-compat-"));
const server = spawn(`${root}/bin/memlawb`, ["serve"], {
  env: {
    PATH: process.env.PATH, PORT: "8080", DATA_DIR: join(fixtureDirectory, "data"),
    MEMLAWB_HOME: fixtureDirectory, ALLOW_UNAUTHENTICATED: "false",
    STATIC_API_KEYS: "fixture:fixture-key,legacy:legacy-key",
  },
  stdio: ["ignore", "pipe", "pipe"],
});
let serverLog = "";
server.stdout.on("data", (data) => { serverLog += data; });
server.stderr.on("data", (data) => { serverLog += data; });
const serverClosed = new Promise<void>((resolve) => server.once("close", () => resolve()));
function initialize(extra: Record<string, string>, expectedStatus = 0) {
  const result = spawnSync(`${root}/bin/memlawb`, ["mcp"], {
    env: {
      PATH: process.env.PATH, MEMLAWB_HOME: fixtureDirectory,
      MEMLAWB_PASSPHRASE: "fixture", MEMLAWB_API_KEY: "fixture-key",
      MEMLAWB_NAMESPACE: "user:fixture", ...extra,
    },
    input: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {
      protocolVersion: "2024-11-05", capabilities: {},
      clientInfo: { name: "compat-test", version: "0" },
    } }) + "\n",
    encoding: "utf8", timeout: 15000,
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, expectedStatus, result.stderr);
  if (expectedStatus === 0) {
    assert.match(result.stdout, /"protocolVersion"/);
    assert.match(result.stderr, /\[(memlawb|openrecall) mcp\] ready/);
  } else {
    assert.doesNotMatch(result.stdout, /"protocolVersion"/);
  }
  assert.doesNotMatch(result.stderr, /not set up/);
  return result.stderr;
}
try {
  let ready = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    assert.equal(server.exitCode, null, serverLog);
    if (serverLog.includes("listening on :8080")) {
      ready = (await fetch("http://127.0.0.1:8080/health")).ok;
      if (ready) break;
    }
    await Bun.sleep(100);
  }
  assert.ok(ready, serverLog);
  assert.match(initialize({}), /store=http:\/\/localhost:8080/);
  const output = initialize({
    MEMLAWB_URL: "http://127.0.0.1:8080", OPENRECALL_URL: "local",
    MEMLAWB_API_KEY: "legacy-key", OPENRECALL_API_KEY: "wrong-key",
    MEMLAWB_NAMESPACE: "user:legacy", OPENRECALL_NAMESPACE: "user:new",
  });
  assert.match(output, /store=http:\/\/127.0.0.1:8080/);
  assert.match(output, /namespace=user:legacy/);
  assert.match(initialize({ MEMLAWB_API_KEY: "wrong-key" }, 1), /401/);
} finally {
  server.kill();
  await serverClosed;
  rmSync(fixtureDirectory, { recursive: true, force: true });
}
console.log("Memlawb encryption and client compatibility checks passed");
