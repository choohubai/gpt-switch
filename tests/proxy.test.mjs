import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { test } from "node:test";
import {
  proxyModelId, parseProxyModelId, resolveRoute, upstreamUrl, buildUpstreamHeaders,
  startProxy, proxyBaseUrl, switchProxyAndRestart, pickerModelsFromState, pickerGroupNameFromState,
  pickerChannelNamesFromState,
} from "../Sources/proxy.mjs";
import { writeProxySettings } from "../Sources/channel-config.mjs";

const channel = (over = {}) => ({
  id: "relay", name: "Relay", baseUrl: "https://relay.example/v1", apiKey: "sk-relay",
  headerName: "", headerValue: "", ...over,
});

test("proxy model ids carry the channel and round-trip", () => {
  assert.equal(proxyModelId("feiyu", "glm-5.3"), "gpts-feiyu/glm-5.3");
  assert.deepEqual(parseProxyModelId("gpts-feiyu/glm-5.3"), { channelId: "feiyu", upstreamModel: "glm-5.3" });
  // 模型名里带斜杠时只切第一个：后面整段都是上游模型名。
  assert.deepEqual(parseProxyModelId("gpts-a/b/c"), { channelId: "a", upstreamModel: "b/c" });
  for (const bad of ["glm-5.3", "gpts-relay", "gpts-/glm", "gpts-relay/", "", null, undefined, 7]) {
    assert.equal(parseProxyModelId(bad), null, `${String(bad)} 不该被当成带渠道的模型`);
  }
});

test("requests route by prefix, bare names go to the current channel untouched", () => {
  const state = { channels: [channel(), channel({ id: "feiyu", name: "feiyu" })], current: "feiyu" };

  const prefixed = resolveRoute("gpts-relay/glm-5.3", state);
  assert.equal(prefixed.channel.id, "relay");
  assert.equal(prefixed.upstreamModel, "glm-5.3");

  const bare = resolveRoute("glm-5.3", state);
  assert.equal(bare.channel.id, "feiyu", "裸名交给当前渠道");
  assert.equal(bare.upstreamModel, "glm-5.3", "裸名原样转发");

  assert.match(resolveRoute("gpts-gone/glm-5.3", state).error, /已经不存在/);
  assert.match(resolveRoute("glm-5.3", { channels: [], current: null }).error, /还没有启用的渠道/);
  assert.match(resolveRoute("glm-5.3", { channels: [channel({ baseUrl: "" })], current: "relay" }).error, /没有填 API 地址/);
});

test("a disabled channel is out of the picker and out of routing", () => {
  const state = {
    channels: [
      channel({ id: "ChooHub", name: "ChooHub", enabled: false, models: [{ id: "glm-5.3", displayName: "glm-5.3" }] }),
      channel({ id: "feiyu", name: "feiyu", models: [{ id: "kimi-k2", displayName: "kimi-k2" }] }),
    ],
    current: "ChooHub",
  };
  assert.deepEqual(pickerModelsFromState(state).map((model) => model.id), ["gpts-feiyu/kimi-k2"],
    "禁用的渠道不进选择器");
  assert.deepEqual(pickerChannelNamesFromState(state), ["feiyu"], "分组表头也不带禁用的渠道");
  assert.match(resolveRoute("gpts-ChooHub/glm-5.3", state).error, /已经禁用/);
  assert.equal(resolveRoute("glm-5.3", state).channel.id, "feiyu",
    "当前渠道被禁用时，裸模型名落到下一个启用的渠道");
  assert.match(resolveRoute("glm-5.3", { channels: [channel({ enabled: false })], current: "relay" }).error,
    /还没有启用的渠道/);
});

test("upstream url keeps the channel path and drops the /v1 the client used", () => {
  assert.equal(upstreamUrl("https://choohub.net/api-proxy/v1", "/v1/responses").href,
    "https://choohub.net/api-proxy/v1/responses");
  assert.equal(upstreamUrl("https://choohub.net/api-proxy/v1/", "/v1/responses?stream=true").href,
    "https://choohub.net/api-proxy/v1/responses?stream=true");
  assert.equal(upstreamUrl("https://relay.example", "/v1/responses").href,
    "https://relay.example/responses");
  assert.equal(upstreamUrl("https://relay.example/v1", "/responses").href,
    "https://relay.example/v1/responses");
  assert.equal(upstreamUrl("不是地址", "/v1/responses"), null);
});

test("forwarded headers drop the client's key and custom header, then set the channel's", () => {
  const headers = buildUpstreamHeaders({
    host: "127.0.0.1:47123",
    authorization: "Bearer client-key",
    "x-actor": "client-value",
    "content-type": "application/json",
    "openai-beta": "responses=experimental",
    "transfer-encoding": "chunked",
  }, channel({ headerName: "x-actor", headerValue: "channel-value" }));
  assert.equal(headers.authorization, "Bearer sk-relay");
  assert.equal(headers["x-actor"], "channel-value");
  assert.equal(headers.host, undefined);
  assert.equal(headers["content-type"], "application/json");
  assert.equal(headers["openai-beta"], "responses=experimental");
  // 转发时要补 content-length，两个长度头同时出现是非法请求，上游会直接回 400。
  assert.equal(headers["transfer-encoding"], undefined);
});

/// 起一个假上游，按收到的东西回答，用来验证真实转发链路。
const withUpstream = async (handler, run) => {
  const upstream = http.createServer(handler);
  await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
  const { port } = upstream.address();
  try {
    return await run({ origin: `http://127.0.0.1:${port}`, port });
  } finally {
    await new Promise((resolve) => upstream.close(resolve));
  }
};

const withProxy = async (state, run) => {
  const events = [];
  const proxy = await startProxy({
    loadState: () => state,
    log: (message, detail) => events.push({ message, detail }),
  });
  try {
    return await run({ baseUrl: proxy.baseUrl, port: proxy.port, events });
  } finally {
    await new Promise((resolve) => proxy.server.close(resolve));
  }
};

test("proxy rewrites the model, swaps the key and streams the answer back", async () => {
  await withUpstream(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    assert.equal(req.url, "/v1/responses");
    assert.equal(body.model, "glm-5.3", "带前缀的模型名要换回上游真名");
    assert.equal(req.headers.authorization, "Bearer sk-feiyu");
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(`data: ${JSON.stringify({ got: body.model, key: req.headers.authorization })}\n\n`);
    setTimeout(() => res.end("data: [DONE]\n\n"), 30);
  }, async ({ origin, port }) => {
    const state = { channels: [channel({ id: "feiyu", name: "feiyu", baseUrl: `${origin}/v1`, apiKey: "sk-feiyu" })], current: "feiyu" };
    await withProxy(state, async ({ baseUrl, events }) => {
      const response = await fetch(`${baseUrl}/responses`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: "Bearer client-key" },
        body: JSON.stringify({ model: "gpts-feiyu/glm-5.3", input: "hi", stream: true }),
      });
      assert.equal(response.status, 200);
      assert.equal(response.headers.get("content-type"), "text/event-stream");
      const text = await response.text();
      assert.match(text, /"got":"glm-5\.3"/);
      assert.match(text, /Bearer sk-feiyu/);
      assert.match(text, /data: \[DONE\]/);
      const routed = events.find((item) => item.message === "proxy_routed");
      assert.equal(routed.detail.channel, "feiyu");
      assert.equal(routed.detail.upstream, "glm-5.3");
      assert.equal(routed.detail.target, origin);
    });
  });
});

test("proxy answers a readable error when the channel is gone", async () => {
  const state = { channels: [channel({ id: "feiyu", name: "feiyu" })], current: "feiyu" };
  await withProxy(state, async ({ baseUrl, events }) => {
    const response = await fetch(`${baseUrl}/responses`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ model: "gpts-removed/glm-5.3", input: "hi" }),
    });
    assert.equal(response.status, 400);
    const body = await response.json();
    assert.match(body.error.message, /已经不存在/);
    assert.equal(events.at(-1).message, "proxy_rejected");
  });
});

test("picker models keep the current channel bare and mark the others", () => {
  const state = {
    channels: [
      { id: "ChooHub", name: "ChooHub", models: [
        { id: "glm-5.3", displayName: "glm-5.3", context: 128, inputModalities: ["text"] },
        { id: "grok-4.7", displayName: "grok-4.7", context: 200, inputModalities: ["text", "image"] },
      ] },
      { id: "feiyu", name: "feiyu", models: [
        { id: "glm-5.3", displayName: "glm-5.3", context: 128, inputModalities: ["text"] },
        { id: "deepseek-flash", displayName: "deepseek-flash", context: 128, inputModalities: ["text"] },
      ] },
    ],
    current: "ChooHub",
  };
  const models = pickerModelsFromState(state);
  assert.deepEqual(models.map((model) => model.id), [
    "glm-5.3", "grok-4.7", "gpts-feiyu/glm-5.3", "gpts-feiyu/deepseek-flash",
  ], "当前渠道裸名，其他渠道带前缀");
  assert.deepEqual(models.map((model) => model.displayName), [
    "glm-5.3（ChooHub）", "grok-4.7（ChooHub）", "glm-5.3（feiyu）", "deepseek-flash（feiyu）",
  ], "每个渠道的显示名都带渠道后缀，分组表头认它");
  assert.equal(models[0].context, 128, "上下文窗口跟着过去");
  assert.equal(models[2].context, 128);
  assert.equal(pickerGroupNameFromState(state), "ChooHub");
  assert.equal(pickerGroupNameFromState({ channels: [], current: null }), "");
  assert.deepEqual(pickerChannelNamesFromState(state), ["ChooHub", "feiyu"], "选择器分组表头要用的渠道名清单");
  assert.deepEqual(pickerChannelNamesFromState({ channels: [{ id: "x" }, { id: "x" }], current: null }), ["x"], "没填名字就用 ID，重复的只留一次");

  // 同一个 id 出现在两个渠道时两条都在，各自带自己的身份（选择器里分组不同）。
  const ids = models.map((model) => model.id);
  assert.ok(ids.includes("glm-5.3") && ids.includes("gpts-feiyu/glm-5.3"));
  assert.equal(new Set(ids).size, ids.length, "拼出来的 id 不能互相撞车");
});

test("injection template still carries both substitution markers", () => {
  const template = fs.readFileSync(new URL("../Sources/injection.js", import.meta.url), "utf8");
  // injector.mjs 靠这几行把模型、默认分组名和渠道名清单替换进去，改动它们会让注入整段失效。
  for (const marker of ["const BOOT_MODELS = [];", 'const DEFAULT_GROUP_NAME = "";',
    "const KNOWN_GROUP_NAMES = [];", 'const MODEL_ID_PREFIX = "";']) {
    assert.equal(template.split(marker).length - 1, 1, `注入模板里应该有且只有一处 ${marker}`);
  }
  // 面板保存后的热推送走「已经装过」那条分支：渠道名清单必须跟着一起推，
  // 否则新增或改名的渠道，它的模型后缀认不出来，会被当成外来行藏掉直到重启。
  assert.match(template, /update\(BOOT_MODELS, DEFAULT_GROUP_NAME, KNOWN_GROUP_NAMES\)/,
    "热推送要把渠道名清单一起带上");
});

test("proxy reports an unreachable channel instead of hanging", async () => {
  // 端口 1 上不会有人监听。
  const state = { channels: [channel({ id: "dead", name: "dead", baseUrl: "http://127.0.0.1:1/v1" })], current: "dead" };
  await withProxy(state, async ({ baseUrl }) => {
    const response = await fetch(`${baseUrl}/responses`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ model: "gpts-dead/glm-5.3", input: "hi" }),
    });
    assert.equal(response.status, 502);
    assert.match((await response.json()).error.message, /连不上渠道/);
  });
});

/// 裸 socket 发一个 chunked 请求体：客户端不带 content-length 时就是这个形状。
const rawChunkedPost = (port, body) => new Promise((resolve) => {
  const socket = net.connect(port, "127.0.0.1", () => {
    let head = `POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n`
      + "Content-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n";
    for (const piece of body.match(/.{1,8}/g) ?? []) head += `${piece.length.toString(16)}\r\n${piece}\r\n`;
    socket.write(`${head}0\r\n\r\n`);
  });
  let data = "";
  socket.on("data", (chunk) => { data += chunk; });
  socket.on("close", () => resolve(data));
});

test("a chunked request body reaches the upstream as a plain request", async () => {
  const seen = [];
  await withUpstream(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    seen.push({
      te: req.headers["transfer-encoding"] ?? null,
      length: req.headers["content-length"] ?? null,
      model: JSON.parse(Buffer.concat(chunks).toString("utf8")).model,
    });
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
  }, async ({ origin }) => {
    const state = { channels: [channel({ id: "feiyu", name: "feiyu", baseUrl: `${origin}/v1`, apiKey: "sk-feiyu" })], current: "feiyu" };
    await withProxy(state, async ({ port }) => {
      const raw = await rawChunkedPost(port, JSON.stringify({ model: "gpts-feiyu/glm-5.3", input: "hi" }));
      assert.match(raw.split("\r\n")[0], / 200 /, "客户端发 chunked 时上游会收到两个长度头，这里就会变成 400");
      assert.equal(seen.length, 1, "上游要真的收到这条请求");
      assert.equal(seen[0].te, null);
      assert.equal(seen[0].model, "glm-5.3");
      assert.equal(seen[0].length, String(Buffer.byteLength(JSON.stringify({ model: "glm-5.3", input: "hi" }))));
    });
  });
});

test("a broken channel file fails one request instead of killing the process", async () => {
  const events = [];
  const proxy = await startProxy({
    loadState: () => { throw new Error("channels.json 损坏"); },
    log: (message, detail) => events.push({ message, detail }),
  });
  try {
    const post = (body) => fetch(`${proxy.baseUrl}/responses`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
    });
    const response = await post(JSON.stringify({ model: "glm-5.3", input: "hi" }));
    assert.equal(response.status, 503);
    assert.match((await response.json()).error.message, /读不到渠道列表/);
    assert.equal(events.at(-1).message, "proxy_state_failed");
    // 抛出去会变成未处理的 rejection 把进程带走；这里确认同一个代理还能回答下一个请求。
    assert.equal((await post("{}")).status, 503);
  } finally {
    await new Promise((resolve) => proxy.server.close(resolve));
  }
});

test("startProxy moves to the next port when the preferred one is taken", async () => {
  const blocker = http.createServer(() => {});
  await new Promise((resolve) => blocker.listen(0, "127.0.0.1", resolve));
  const taken = blocker.address().port;
  const proxy = await startProxy({
    loadState: () => ({ channels: [], current: null }),
    log: () => {},
    host: "127.0.0.1",
    port: taken,
  });
  try {
    assert.notEqual(proxy.port, taken, "占着的端口要往后顺延");
    assert.equal(proxy.baseUrl, `http://127.0.0.1:${proxy.port}/v1`);
    assert.equal(proxy.requestedPort, taken);
    const response = await fetch(`${proxy.baseUrl}/responses`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ model: "glm-5.3" }),
    });
    assert.equal(response.status, 400, "顺延之后要真的在应答，不能是个空壳");
  } finally {
    await new Promise((resolve) => proxy.server.close(resolve));
    await new Promise((resolve) => blocker.close(resolve));
  }
});

const proxySwitchSandbox = (context) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "gpt-switch-switch-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const codexHome = path.join(root, ".codex");
  fs.mkdirSync(codexHome, { recursive: true });
  return {
    root,
    proxyConfigPath: path.join(root, ".gptswitch", "proxy.json"),
    userConfigPath: path.join(codexHome, "config.toml"),
    recordPath: path.join(root, ".gptswitch", "codex.json"),
  };
};

test("proxy address changes are applied to Codex after ChatGPT restart", async (context) => {
  const files = proxySwitchSandbox(context);
  fs.mkdirSync(path.dirname(files.recordPath), { recursive: true });
  const oldProxy = await startProxy({ loadState: () => ({ channels: [], current: null }), log: () => {} });
  context.after(() => oldProxy.server.close());
  const nextProxy = await startProxy({ loadState: () => ({ channels: [], current: null }), log: () => {} });
  const nextPort = nextProxy.port;
  await new Promise((resolve) => nextProxy.server.close(resolve));
  fs.writeFileSync(files.userConfigPath, `[model_providers.relay]\nbase_url = "http://127.0.0.1:${oldProxy.port}/v1"\n`);
  fs.writeFileSync(files.recordPath, JSON.stringify({ appliedId: "relay", tablesAdded: ["relay"] }));
  writeProxySettings(files.proxyConfigPath, { host: "127.0.0.1", port: nextPort });
  let oldClosed = false;
  oldProxy.server.once("close", () => { oldClosed = true; });

  const switched = await switchProxyAndRestart({
    settings: { host: "127.0.0.1", port: nextPort },
    currentServer: oldProxy.server,
    currentHost: "127.0.0.1",
    currentPort: oldProxy.port,
    restartClient: async () => { assert.equal(oldClosed, false, "客户端重启期间旧代理不能提前关掉"); },
    updateCodex: async (baseUrl) => {
      fs.writeFileSync(files.userConfigPath, `[model_providers.relay]\nbase_url = "${baseUrl}"\n`);
      return true;
    },
    log: () => {},
    proxyConfigPath: files.proxyConfigPath,
    userConfigPath: files.userConfigPath,
    recordPath: files.recordPath,
  });
  context.after(() => switched.server.close());
  assert.equal(switched.host, "127.0.0.1");
  assert.match(fs.readFileSync(files.userConfigPath, "utf8"), new RegExp(`base_url = "http://127\\.0\\.0\\.1:${nextPort}/v1"`));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(oldClosed, true, "客户端重启成功后要关掉旧代理");
});

test("failed ChatGPT restart keeps old proxy and restores proxy and Codex files", async (context) => {
  const files = proxySwitchSandbox(context);
  fs.mkdirSync(path.dirname(files.recordPath), { recursive: true });
  const originalCodex = `[model_providers.relay]\nbase_url = "http://127.0.0.1:47123/v1"\n`;
  fs.writeFileSync(files.userConfigPath, originalCodex);
  fs.writeFileSync(files.recordPath, JSON.stringify({ appliedId: "relay", tablesAdded: ["relay"] }));
  writeProxySettings(files.proxyConfigPath, { host: "127.0.0.1", port: 47125 });
  const beforeProxy = fs.readFileSync(files.proxyConfigPath, "utf8");
  const oldProxy = await startProxy({ loadState: () => ({ channels: [], current: null }), log: () => {} });
  context.after(() => oldProxy.server.close());
  let oldClosed = false;
  oldProxy.server.once("close", () => { oldClosed = true; });

  await assert.rejects(switchProxyAndRestart({
    settings: { host: "127.0.0.1", port: 47125 },
    currentServer: oldProxy.server,
    currentHost: "127.0.0.1",
    currentPort: oldProxy.port,
    restartClient: async () => { throw new Error("客户端启动失败"); },
    updateCodex: async (baseUrl) => {
      fs.writeFileSync(files.userConfigPath, `[model_providers.relay]\nbase_url = "${baseUrl}"\n`);
      return true;
    },
    log: () => {},
    proxyConfigPath: files.proxyConfigPath,
    userConfigPath: files.userConfigPath,
    recordPath: files.recordPath,
  }), /客户端启动失败/);
  assert.equal(oldClosed, false, "重启失败必须保留旧代理");
  assert.equal(fs.readFileSync(files.proxyConfigPath, "utf8"), beforeProxy);
  assert.equal(fs.readFileSync(files.userConfigPath, "utf8"), originalCodex);
});
