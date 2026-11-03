import assert from "node:assert/strict";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const require = createRequire(join(process.argv[2], "lib/context7-mcp/package.json"));
const { McpServer } = await import(pathToFileURL(require.resolve("@modelcontextprotocol/server")));
const { NodeStreamableHTTPServerTransport } = await import(pathToFileURL(require.resolve("@modelcontextprotocol/node")));

for (const parsed of [false, true]) {
  const mcp = new McpServer({ name: "dependency-check", version: "1.0.0" });
  const transport = new NodeStreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
    enableJsonResponse: true,
  });
  await mcp.connect(transport);
  const server = createServer(async (request, response) => {
    try {
      let body;
      if (parsed) {
        const chunks = [];
        for await (const chunk of request) chunks.push(chunk);
        body = JSON.parse(Buffer.concat(chunks).toString());
      }
      await transport.handleRequest(request, response, body);
    } catch (error) {
      response.writeHead(500).end(String(error));
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/mcp`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2025-03-26",
          capabilities: {},
          clientInfo: { name: "dependency-check", version: "1.0.0" },
        },
      }),
      signal: AbortSignal.timeout(10000),
    });
    assert.equal(response.status, 200);
    const reply = await response.json();
    assert.equal(reply.id, 1);
    assert.equal(reply.result.serverInfo.name, "dependency-check");
    assert.ok(reply.result.protocolVersion);
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    await mcp.close();
  }
}
console.log("Context7 HTTP dependency compatibility checks passed");
