const assert = require("node:assert/strict");
const { once } = require("node:events");
const fs = require("node:fs");
const http = require("node:http");
const { createRequire } = require("node:module");
const os = require("node:os");
const path = require("node:path");

const root = path.join(process.argv[2], "lib/lightdash");
const load = createRequire(path.join(root, "package.json"));
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "lightdash-dependencies-"));

async function testWatcher() {
  const manifest = path.join(temporary, "manifest.json");
  fs.writeFileSync(manifest, "{}");
  const watcher = load("chokidar").watch(manifest);
  try {
    await once(watcher, "ready", { signal: AbortSignal.timeout(10000) });
    const changed = once(watcher, "change", { signal: AbortSignal.timeout(10000) });
    fs.writeFileSync(manifest, '{"updated":true}');
    assert.equal((await changed)[0], manifest);
    await watcher.unwatch(manifest);
    watcher.add(manifest);
  } finally {
    await watcher.close();
  }
}

async function testDatabricksProtocol() {
  const thrift = load("thrift");
  const service = load("@databricks/sql/thrift/TCLIService");
  const types = load("@databricks/sql/thrift/TCLIService_types");
  const Connection = load("@databricks/sql/dist/connection/connections/ThriftHttpConnection").default;
  const RetryPolicy = load("@databricks/sql/dist/connection/connections/NullRetryPolicy").default;
  const guid = Buffer.alloc(16, 1);
  const processor = new service.Processor({
    CloseSession(request, callback) {
      assert.deepEqual(request.sessionHandle.sessionId.guid, guid);
      callback(null, new types.TCloseSessionResp({
        status: new types.TStatus({ statusCode: types.TStatusCode.SUCCESS_STATUS }),
      }));
    },
  });
  const server = http.createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const output = new thrift.TBinaryProtocol(new thrift.TBufferedTransport(undefined, (data) => {
      response.writeHead(200, { "Content-Type": "application/x-thrift" });
      response.end(data);
    }));
    thrift.TBufferedTransport.receiver((transport) => {
      processor.process(new thrift.TBinaryProtocol(transport), output);
    })(Buffer.concat(chunks));
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  try {
    const connection = new Connection({
      url: `http://127.0.0.1:${server.address().port}/`,
      getRetryPolicy: async () => new RetryPolicy(),
    });
    const client = thrift.createClient(service, connection);
    const response = await client.CloseSession(new types.TCloseSessionReq({
      sessionHandle: new types.TSessionHandle({
        sessionId: new types.THandleIdentifier({ guid, secret: Buffer.alloc(16, 2) }),
      }),
    }));
    assert.equal(response.status.statusCode, types.TStatusCode.SUCCESS_STATUS);
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
}

function testSnowflakeConfig() {
  process.env.SNOWFLAKE_HOME = temporary;
  process.env.SNOWFLAKE_DEFAULT_CONNECTION_NAME = "fixture";
  fs.writeFileSync(path.join(temporary, "connections.toml"),
    '[fixture]\naccount = "offline"\nuser = "fixture"\n', { mode: 0o600 });
  const snowflake = load("snowflake-sdk");
  snowflake.configure({ logLevel: "OFF" });
  const config = load("snowflake-sdk/dist/lib/configuration/connection_configuration")
    .loadConnectionConfiguration();
  assert.equal(config.account, "offline");
  const connection = snowflake.createConnection({ ...config, password: "offline-fixture" });
  assert.equal(typeof connection.connect, "function");
  assert.equal(typeof connection.execute, "function");
}

function testChartsAndTemplates() {
  load("@lightdash/common");
  load("@lightdash/warehouses");
  const echarts = load("echarts");
  const chart = echarts.init(null, null, { renderer: "svg", ssr: true, width: 400, height: 300 });
  try {
    chart.setOption({
      dataset: { source: [["category", "value"], ["fixture", 5]] },
      xAxis: { type: "category" }, yAxis: {},
      series: [{ type: "bar", encode: { x: "category", y: "value" } }],
    });
    assert.match(chart.renderToSVGString(), /<svg/);
  } finally {
    chart.dispose();
  }
  assert.equal(load("handlebars").compile("{{value}}")({ value: "<fixture>" }), "&lt;fixture&gt;");
  assert.equal(load("sanitize-html")('<script>alert(1)</script><b>ok</b>'), "<b>ok</b>");
  assert.equal(load("moment")("2026-10-20").format("YYYY-MM-DD"), "2026-10-20");
}

(async () => {
  try {
    await testWatcher();
    await testDatabricksProtocol();
    testSnowflakeConfig();
    testChartsAndTemplates();
    console.log("Lightdash dependency compatibility checks passed");
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
