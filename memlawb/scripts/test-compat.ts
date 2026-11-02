import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
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

const home = mkdtempSync(join(tmpdir(), "memlawb-compat-"));
function initialize(extra: Record<string, string>) {
  const result = spawnSync(`${root}/bin/memlawb`, ["mcp"], {
    env: { PATH: process.env.PATH, HOME: home, MEMLAWB_PASSPHRASE: "fixture", ...extra },
    input: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {
      protocolVersion: "2024-11-05", capabilities: {},
      clientInfo: { name: "compat-test", version: "0" },
    } }) + "\n",
    encoding: "utf8", timeout: 15000,
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /"protocolVersion"/);
  assert.doesNotMatch(result.stderr, /not set up/);
  return result.stderr;
}
try {
  assert.match(initialize({}), /store=http:\/\/localhost:8080/);
  const output = initialize({
    MEMLAWB_URL: "http://127.0.0.1:19876", OPENRECALL_URL: "local",
    MEMLAWB_NAMESPACE: "user:legacy", OPENRECALL_NAMESPACE: "user:new",
  });
  assert.match(output, /store=http:\/\/127.0.0.1:19876/);
  assert.match(output, /namespace=user:legacy/);
} finally {
  rmSync(home, { recursive: true, force: true });
}
console.log("Memlawb encryption and client compatibility checks passed");
