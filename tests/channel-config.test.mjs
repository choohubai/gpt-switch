import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import {
  validateChannels, writeChannelState, readChannelState, loadChannelState,
  modelProviderFromToml, readProviderTable, upsertProviderTable, setModelProvider,
  applyChannelToCodex, restoreCodexConfig, importChannelsFromCodex, handlePanelRequest,
  discoverChannelModels, modelFromToml, recordedProxyPort, repointProxyUrl,
  readProxySettings, validateProxySettings, writeProxySettings, recordedProxyAddress,
} from "../Sources/channel-config.mjs";

const CONFIG = [
  'model_provider = "OpenAI"',
  'model = "gpt-6-astra"',
  "",
  "[model_providers.OpenAI]",
  'name = "ChooHub"',
  'base_url = "https://choohub.net/api-proxy/v1"',
  'wire_api = "responses"',
  "requires_openai_auth = true",
  'http_headers = { "x-openai-actor-authorization" = "actor-token" }',
  "",
  '[projects."/tmp/demo"]',
  'trust_level = "trusted"',
  "",
].join("\n");

/// validateChannels 会把模型补成面板保存后的完整形状（没填显示名就落成模型 ID），断言里用它对齐。
const model = (over = {}) => ({
  displayName: String(over.id ?? ""), inputModalities: ["text", "image"],
  ...over,
});

const channel = (over = {}) => ({
  id: "relay", name: "Relay", baseUrl: "https://relay.example/v1",
  apiKey: "sk-relay", headerName: "", headerValue: "", enabled: true,
  models: [model({ id: "m-one", context: 128 })],
  ...over,
});

const sandbox = (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "gpt-switch-channel-"));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const codexHome = path.join(directory, ".codex");
  fs.mkdirSync(codexHome, { recursive: true });
  return {
    directory,
    userConfigPath: path.join(codexHome, "config.toml"),
    authPath: path.join(codexHome, "auth.json"),
    recordPath: path.join(directory, ".gptswitch", "codex.json"),
    configPath: path.join(directory, ".gptswitch", "channels.json"),
    proxyConfigPath: path.join(directory, ".gptswitch", "proxy.json"),
    agentsStatePath: path.join(directory, ".gptswitch", "agents.json"),
    agentsPath: path.join(codexHome, "AGENTS.md"),
    codexHome,
  };
};

test("validateChannels trims rows, keeps ids unique and rejects bad input", () => {
  assert.deepEqual(validateChannels([]), []);
  const [first] = validateChannels([{ id: " acme-gateway ", baseUrl: "https://a.example/v1" }]);
  assert.equal(first.id, "acme-gateway");
  assert.equal(first.name, "acme-gateway", "没填显示名称时用 Provider ID");
  assert.equal(first.apiKey, "");
  assert.deepEqual(first.models, []);
  const [named] = validateChannels([{ id: "relay", name: " 自用中转 ", baseUrl: "https://a.example" }]);
  assert.equal(named.name, "自用中转");
  assert.deepEqual(validateChannels([{ id: "x", baseUrl: "https://a.example", models: [{ id: "m" }] }])[0].models,
    [model({ id: "m", context: 272 })]);
  assert.equal("supportsSearchTool" in validateChannels([{
    id: "x", baseUrl: "https://a.example",
    models: [{ id: "m", supportsSearchTool: true }],
  }])[0].models[0], false, "旧配置里的模型搜索字段保存时被丢掉");
  assert.equal("supportsParallelToolCalls" in validateChannels([{
    id: "x", baseUrl: "https://a.example",
    models: [{ id: "m", supportsParallelToolCalls: true }],
  }])[0].models[0], false, "旧配置里的模型工具能力字段保存时被丢掉");
  for (const invalid of [null, {}, [{}], [{ id: "" }], [{ id: "bad id" }], [{ id: 123 }],
    [{ id: "x".repeat(33) }],
    [{ id: "a", baseUrl: "https://a" }, { id: "a", baseUrl: "https://b" }],
    [{ id: "x", baseUrl: "ftp://x" }],
    [{ id: "x", baseUrl: "https://a", headerName: "X-Key" }],
    [{ id: "x", baseUrl: "https://a", headerValue: "v" }],
    [{ id: "x", baseUrl: "https://a", headerName: "bad header" }]]) {
    assert.throws(() => validateChannels(invalid));
  }
  assert.equal(validateChannels([{ id: "x", baseUrl: "" }])[0].baseUrl, "");
});

test("proxy settings default to loopback and use the CC Switch port range", (context) => {
  const { proxyConfigPath } = sandbox(context);
  const direct = { outboundProxy: "", outboundUsername: "", outboundPassword: "" };
  assert.deepEqual(readProxySettings(proxyConfigPath), { host: "127.0.0.1", port: 47123, ...direct });
  assert.deepEqual(validateProxySettings({ host: " 127.0.0.1 ", port: "47124" }),
    { host: "127.0.0.1", port: 47124, ...direct });
  assert.deepEqual(validateProxySettings({ host: "192.168.1.20", port: 47124 }),
    { host: "192.168.1.20", port: 47124, ...direct });
  assert.deepEqual(writeProxySettings(proxyConfigPath, { host: "127.0.0.1", port: 47125 }),
    { host: "127.0.0.1", port: 47125, ...direct });
  assert.deepEqual(readProxySettings(proxyConfigPath), { host: "127.0.0.1", port: 47125, ...direct });
  for (const invalid of [
    { host: "localhost", port: 47123 },
    { host: "999.1.1.1", port: 47123 },
    { host: "192.168.1", port: 47123 },
    { host: "127.0.0.1", port: 1023 },
    { host: "127.0.0.1", port: 65536 },
  ]) {
    assert.throws(() => validateProxySettings(invalid));
  }
});

test("outbound proxy reads old configs and rejects self loops", (context) => {
  const { proxyConfigPath } = sandbox(context);
  fs.mkdirSync(path.dirname(proxyConfigPath), { recursive: true });
  fs.writeFileSync(proxyConfigPath, JSON.stringify({ host: "127.0.0.1", port: 47123 }));
  assert.equal(readProxySettings(proxyConfigPath).outboundProxy, "", "老配置没有出站字段就是直连");

  const saved = validateProxySettings({
    host: "127.0.0.1",
    port: 47123,
    outboundProxy: " http://127.0.0.1:7897/ ",
    outboundUsername: " user ",
    outboundPassword: "p@ss:word",
  });
  assert.deepEqual(saved, {
    host: "127.0.0.1",
    port: 47123,
    outboundProxy: "http://127.0.0.1:7897",
    outboundUsername: "user",
    outboundPassword: "p@ss:word",
  });
  assert.deepEqual(validateProxySettings({ ...saved, outboundProxy: "" }), {
    host: "127.0.0.1", port: 47123, outboundProxy: "", outboundUsername: "", outboundPassword: "",
  }, "清空地址要把用户名密码一起清掉");
  writeProxySettings(proxyConfigPath, saved);
  assert.deepEqual(readProxySettings(proxyConfigPath), saved);
  assert.equal(fs.statSync(proxyConfigPath).mode & 0o777, 0o600, "带密码的配置只有本人能读");

  for (const [invalid, message] of [
    [{ outboundProxy: "socks5://127.0.0.1:7897" }, "只支持 http"],
    [{ outboundProxy: "http://127.0.0.1:47123" }, "不能指向本地转发服务自己"],
    [{ outboundProxy: "http://0.0.0.0:47123" }, "不能指向本地转发服务自己"],
    [{ outboundProxy: "http://user:pass@127.0.0.1:7897" }, "用户名和密码请分开填"],
    [{ outboundProxy: "http://127.0.0.1:7897/v1" }, "不要带路径"],
    [{ outboundProxy: "not a url" }, "不是合法的 URL"],
    [{ outboundProxy: "http://127.0.0.1:7897", outboundPassword: "secret" }, "填了密码就要填用户名"],
    [{ outboundProxy: "http://127.0.0.1:7897", outboundUsername: "u", outboundPassword: "p\nw" }, "不能包含控制字符"],
  ]) {
    assert.throws(() => validateProxySettings({ host: "127.0.0.1", port: 47123, ...invalid }),
      new RegExp(message));
  }
  // 监听在 0.0.0.0 时，用本机网卡地址连同一个端口同样会转回自己。
  const lan = Object.values(os.networkInterfaces()).flat()
    .find((item) => item && item.family === "IPv4" && !item.internal);
  if (lan) {
    assert.throws(() => validateProxySettings({
      host: "0.0.0.0", port: 47123, outboundProxy: `http://${lan.address}:47123`,
    }), /不能指向本地转发服务自己/);
  }
});

test("panel test-proxy probes through the drafted proxy without saving", async (context) => {
  const paths = sandbox(context);
  const { options } = panelOptions(paths);
  const seen = [];
  const proxy = http.createServer((req, res) => {
    seen.push(req.url);
    res.writeHead(200, { "content-type": "application/json" });
    res.end("{}");
  });
  await new Promise((resolve) => proxy.listen(0, "127.0.0.1", resolve));
  context.after(() => proxy.close());

  const tested = await handlePanelRequest({
    action: "test-proxy",
    proxy: { host: "127.0.0.1", port: 47123, outboundProxy: `http://127.0.0.1:${proxy.address().port}` },
  }, { ...options, proxyTestUrl: "http://probe.test/" });
  assert.equal(tested.ok, true);
  assert.equal(typeof tested.latencyMs, "number");
  assert.deepEqual(seen, ["http://probe.test/"], "探测请求要经过面板里填的代理");
  assert.equal(fs.existsSync(paths.proxyConfigPath), false, "测试不落盘");

  const empty = await handlePanelRequest({ action: "test-proxy", proxy: { host: "127.0.0.1", port: 47123 } }, options);
  assert.equal(empty.ok, false);
  assert.match(empty.error, /请先填代理地址/);

  const unreachable = await handlePanelRequest({
    action: "test-proxy",
    proxy: { host: "127.0.0.1", port: 47123, outboundProxy: `http://127.0.0.1:${await closedPort()}` },
  }, options);
  assert.equal(unreachable.ok, false);
  assert.match(unreachable.error, /测试连接失败/);
});

test("proxy save persists values without applying them to the running service", async (context) => {
  const paths = sandbox(context);
  const { options } = panelOptions(paths);
  const saved = await handlePanelRequest({
    action: "save", restart: false, scope: "proxy",
    proxy: { host: "127.0.0.1", port: 47129 },
  }, options);
  assert.equal(saved.ok, true);
  assert.equal(saved.restartNeeded, true);
  assert.equal(readProxySettings(paths.proxyConfigPath).port, 47129);
  const loaded = await handlePanelRequest({ action: "load" }, options);
  assert.equal(loaded.ok, true);
  assert.deepEqual(loaded.proxy, {
    host: "127.0.0.1", port: 47129, outboundProxy: "", outboundUsername: "", outboundPassword: "",
  });
});

test("switching reports the saved proxy value used by the restart", async (context) => {
  const paths = sandbox(context);
  const { options } = panelOptions(paths);
  writeProxySettings(paths.proxyConfigPath, { host: "127.0.0.1", port: 47131 });
  const result = await handlePanelRequest({
    action: "switch",
    restart: true,
    current: "relay",
    channels: [channel()],
  }, {
    ...options,
  });
  assert.equal(result.ok, true);
  assert.deepEqual(result.proxy, {
    host: "127.0.0.1", port: 47131, outboundProxy: "", outboundUsername: "", outboundPassword: "",
  });
});

test("toml helpers read the existing provider and rewrite only their own table", () => {
  assert.equal(modelProviderFromToml(CONFIG), "OpenAI");
  assert.equal(modelFromToml(CONFIG), "gpt-6-astra");
  assert.equal(modelFromToml("model = 'gpt-6-astra'\n"), "gpt-6-astra");
  assert.equal(modelFromToml("[profiles.work]\nmodel = \"inside\"\n"), null, "表头之后的同名键不算顶层");
  assert.deepEqual(readProviderTable(CONFIG, "OpenAI"), {
    name: "ChooHub",
    base_url: "https://choohub.net/api-proxy/v1",
    wire_api: "responses",
    requires_openai_auth: true,
    http_headers: { "x-openai-actor-authorization": "actor-token" },
  });
  assert.equal(readProviderTable(CONFIG, "openai"), null);
  const added = setModelProvider(upsertProviderTable(CONFIG, channel()), "relay");
  assert.match(added, /^model_provider = "relay"\n/);
  assert.match(added, /\[model_providers\.relay\]\nname = "Relay"\nbase_url = "https:\/\/relay\.example\/v1"\nwire_api = "responses"\nrequires_openai_auth = true\n/);
  assert.equal(added.includes('[model_providers.OpenAI]'), true);
  assert.equal(added.includes('trust_level = "trusted"'), true);
  const twice = setModelProvider(upsertProviderTable(added, channel({ name: "Relay 2" })), "relay");
  assert.equal((twice.match(/\[model_providers\.relay\]/g) || []).length, 1);
  assert.equal(twice.includes('name = "Relay 2"'), true);
  assert.equal(twice.includes('name = "Relay"\n'), false);
  const withHeader = upsertProviderTable(added, channel({ headerName: "Authorization", headerValue: "Bearer sk-x" }));
  assert.equal(withHeader.includes('http_headers = { "Authorization" = "Bearer sk-x" }'), true);
});

test("switching writes auth.json and config.toml, clearing puts both back", (context) => {
  const { userConfigPath, authPath, recordPath } = sandbox(context);
  fs.writeFileSync(userConfigPath, CONFIG);
  fs.writeFileSync(authPath, JSON.stringify({ tokens: { id: "keep-me" }, OPENAI_API_KEY: "sk-old" }, null, 2));
  applyChannelToCodex({ channel: channel(), authPath, userConfigPath, recordPath });
  const auth = JSON.parse(fs.readFileSync(authPath, "utf8"));
  assert.equal(auth.OPENAI_API_KEY, "sk-relay");
  assert.deepEqual(auth.tokens, { id: "keep-me" });
  const written = fs.readFileSync(userConfigPath, "utf8");
  assert.match(written, /^model_provider = "relay"$/m);
  assert.match(written, /\[model_providers\.relay\]/);
  if (process.platform !== "win32") {
    assert.equal(fs.statSync(authPath).mode & 0o777, 0o600);
    assert.equal(fs.statSync(recordPath).mode & 0o777, 0o600);
  }
  applyChannelToCodex({
    channel: channel({ id: "second", name: "Second", baseUrl: "https://b.example/v1" }),
    authPath, userConfigPath, recordPath,
  });
  assert.equal(JSON.parse(fs.readFileSync(authPath, "utf8")).OPENAI_API_KEY, "sk-relay");
  const switched = fs.readFileSync(userConfigPath, "utf8");
  assert.match(switched, /^model_provider = "second"$/m);
  assert.equal(readProviderTable(switched, "relay").base_url, "https://b.example/v1",
    "换 id 后旧的段改成新渠道，别删：回话绑着它");
  assert.equal(readProviderTable(switched, "OpenAI").base_url, "https://b.example/v1",
    "原来的 provider 段也要跟着指到当前渠道");
  restoreCodexConfig({ authPath, userConfigPath, recordPath });
  assert.equal(fs.readFileSync(userConfigPath, "utf8"), CONFIG);
  assert.equal(JSON.parse(fs.readFileSync(authPath, "utf8")).OPENAI_API_KEY, "sk-old");
  assert.equal(JSON.parse(fs.readFileSync(authPath, "utf8")).tokens.id, "keep-me");
  assert.equal(fs.existsSync(recordPath), false);
  assert.equal(restoreCodexConfig({ authPath, userConfigPath, recordPath }), null);
});

test("switching points every provider id a thread may have pinned at the active channel", (context) => {
  const { userConfigPath, authPath, recordPath } = sandbox(context);
  fs.writeFileSync(userConfigPath, CONFIG);
  fs.writeFileSync(authPath, JSON.stringify({ OPENAI_API_KEY: "sk-old" }));
  const channelIds = ["OpenAI", "feiyu", "ChooHub"];
  applyChannelToCodex({
    channel: channel({ id: "feiyu", baseUrl: "https://www.feiyutoken.com/v1" }),
    channelIds, authPath, userConfigPath, recordPath,
  });
  let written = fs.readFileSync(userConfigPath, "utf8");
  assert.match(written, /^model_provider = "feiyu"$/m);
  for (const id of channelIds) {
    assert.equal(readProviderTable(written, id).base_url, "https://www.feiyutoken.com/v1", `${id} 要指到当前渠道`);
  }
  applyChannelToCodex({
    channel: channel({ id: "ChooHub", name: "ChooHub", baseUrl: "https://choohub.net" }),
    channelIds, authPath, userConfigPath, recordPath,
  });
  written = fs.readFileSync(userConfigPath, "utf8");
  for (const id of channelIds) {
    assert.equal(readProviderTable(written, id).base_url, "https://choohub.net", `${id} 来回切也要跟着走`);
  }
  restoreCodexConfig({ authPath, userConfigPath, recordPath });
  assert.equal(fs.readFileSync(userConfigPath, "utf8"), CONFIG, "还原只留用户原来那张表");
});

test("switching over a provider table the user already had puts it back on clear", (context) => {
  const { userConfigPath, authPath, recordPath } = sandbox(context);
  const original = CONFIG.replace("requires_openai_auth = true",
    "requires_openai_auth = true\nrequest_max_retries = 4\n# 自己的注释");
  fs.writeFileSync(userConfigPath, original);
  fs.writeFileSync(authPath, JSON.stringify({ OPENAI_API_KEY: "sk-old" }));
  const [imported] = importChannelsFromCodex({ userConfigPath, authPath, modelPaths: [] }).channels;
  applyChannelToCodex({ channel: imported, authPath, userConfigPath, recordPath });
  assert.equal(fs.readFileSync(userConfigPath, "utf8").includes("request_max_retries"), false,
    "启用时按插件格式重写这张表");
  restoreCodexConfig({ authPath, userConfigPath, recordPath });
  assert.equal(fs.readFileSync(userConfigPath, "utf8"), original, "还原要连多余字段和注释一起放回去");
});

test("clearing does not resurrect a provider table that is already gone", (context) => {
  const { userConfigPath, authPath, recordPath } = sandbox(context);
  fs.writeFileSync(userConfigPath, CONFIG);
  fs.writeFileSync(authPath, JSON.stringify({ OPENAI_API_KEY: "sk-old" }));
  // 旧版本留下的备份：这段表早就不在 config.toml 里了，还原时不要再补出来。
  fs.mkdirSync(path.dirname(recordPath), { recursive: true });
  fs.writeFileSync(recordPath, JSON.stringify({
    auth: null,
    modelProvider: { existed: true, value: "OpenAI" },
    tablesAdded: [],
    tablesOriginal: { gone: '[model_providers.gone]\nname = "gone"\n' },
    appliedId: "OpenAI",
  }));
  restoreCodexConfig({ authPath, userConfigPath, recordPath });
  const text = fs.readFileSync(userConfigPath, "utf8");
  assert.equal(text.includes("[model_providers.gone]"), false, "已经不在配置里的段不要凭空补回来");
  assert.equal(text, CONFIG);
  assert.equal(JSON.parse(fs.readFileSync(authPath, "utf8")).OPENAI_API_KEY, "sk-old");
});

test("switching into a channel without a key leaves auth.json alone", (context) => {
  const { userConfigPath, authPath, recordPath } = sandbox(context);
  fs.writeFileSync(userConfigPath, CONFIG);
  fs.writeFileSync(authPath, JSON.stringify({ OPENAI_API_KEY: "sk-old" }));
  assert.throws(() => applyChannelToCodex({
    channel: channel({ apiKey: "", baseUrl: "" }), authPath, userConfigPath, recordPath,
  }), /还没填地址/);
  applyChannelToCodex({ channel: channel({ apiKey: "" }), authPath, userConfigPath, recordPath });
  assert.equal(JSON.parse(fs.readFileSync(authPath, "utf8")).OPENAI_API_KEY, "sk-old");
  restoreCodexConfig({ authPath, userConfigPath, recordPath });
  assert.equal(fs.readFileSync(userConfigPath, "utf8"), CONFIG);
  assert.equal(JSON.parse(fs.readFileSync(authPath, "utf8")).OPENAI_API_KEY, "sk-old");
});

test("importChannelsFromCodex lifts the current provider, key and legacy models", (context) => {
  const { userConfigPath, authPath, directory } = sandbox(context);
  fs.writeFileSync(userConfigPath, CONFIG);
  fs.writeFileSync(authPath, JSON.stringify({ OPENAI_API_KEY: "sk-choohub" }));
  const legacy = path.join(directory, "models.json");
  fs.writeFileSync(legacy, JSON.stringify({ models: [{ id: "gpt-6-astra", context: 300 }] }));
  const imported = importChannelsFromCodex({ userConfigPath, authPath, modelPaths: [path.join(directory, "missing.json"), legacy] });
  assert.equal(imported.current, "OpenAI");
  assert.deepEqual(imported.channels, [{
    id: "OpenAI",
    name: "ChooHub",
    baseUrl: "https://choohub.net/api-proxy/v1",
    apiKey: "sk-choohub",
    headerName: "x-openai-actor-authorization",
    headerValue: "actor-token",
    models: [model({ id: "gpt-6-astra", context: 300 })],
  }]);
  const empty = importChannelsFromCodex({
    userConfigPath: path.join(directory, "nope.toml"), authPath: path.join(directory, "nope.json"), modelPaths: [],
  });
  assert.deepEqual(empty, { channels: [], current: null });
});

test("a provider the importer cannot take does not block the panel", (context) => {
  const { userConfigPath, authPath, configPath } = sandbox(context);
  fs.writeFileSync(userConfigPath, CONFIG.replace('"actor-token"', `"${"x".repeat(600)}"`));
  assert.deepEqual(loadChannelState(configPath, { userConfigPath, authPath, modelPaths: [] }),
    { channels: [], current: null });
});

test("channel state imports once, then round-trips through the file", (context) => {
  const { userConfigPath, authPath, configPath, directory } = sandbox(context);
  fs.writeFileSync(userConfigPath, CONFIG);
  fs.writeFileSync(authPath, JSON.stringify({ OPENAI_API_KEY: "sk-choohub" }));
  const first = loadChannelState(configPath, { userConfigPath, authPath, modelPaths: [] });
  assert.equal(first.channels.length, 1);
  assert.equal(first.current, "OpenAI");
  assert.equal(JSON.parse(fs.readFileSync(configPath, "utf8")).channels.length, 1);
  fs.rmSync(userConfigPath);
  const second = loadChannelState(configPath, { userConfigPath, authPath, modelPaths: [] });
  assert.deepEqual(second, first);
  writeChannelState(configPath, { channels: [channel()], current: "relay" });
  assert.deepEqual(readChannelState(configPath), { channels: [channel()], current: "relay" });
  writeChannelState(configPath, { channels: [channel()], current: "gone" });
  assert.equal(readChannelState(configPath).current, null);
  assert.equal(fs.readdirSync(path.dirname(configPath)).includes("channels.json"), true);
});

test("a renamed current channel is recognised again from the codex config", (context) => {
  const { userConfigPath, authPath, configPath, recordPath } = sandbox(context);
  const options = { userConfigPath, authPath, recordPath, modelPaths: [] };
  fs.writeFileSync(userConfigPath, '# user config\n');
  // 切换时还叫 OpenAI，之后在面板里把 ID 改成了 choohub。
  applyChannelToCodex({
    channel: channel({ id: "OpenAI", name: "ChooHub", baseUrl: "https://choohub.net/api-proxy/v1" }),
    authPath, userConfigPath, recordPath,
  });
  writeChannelState(configPath, {
    channels: [channel({ id: "choohub", name: "ChooHub", baseUrl: "https://choohub.net/api-proxy/v1" })],
    current: null,
  });
  const healed = loadChannelState(configPath, options);
  assert.equal(healed.current, "choohub", "还指着那次切换写进去的 provider，就该认回这条渠道");
  assert.equal(readChannelState(configPath).current, "choohub", "认回来要落盘，下次打开还在");

  // 还原之后记录没了，配置也不再指着我们写的那段，不能再当成在用。
  writeChannelState(configPath, { channels: healed.channels, current: null });
  restoreCodexConfig({ authPath, userConfigPath, recordPath });
  assert.equal(loadChannelState(configPath, options).current, null);
});

const panelOptions = (paths, over = {}) => {
  const calls = { applied: [], repointed: [], catalogs: [], restarts: [], restored: 0, cleared: 0 };
  const options = {
    configPath: paths.configPath,
    proxyConfigPath: paths.proxyConfigPath,
    codexHome: paths.codexHome,
    agentsStatePath: paths.agentsStatePath,
    importOptions: {
      userConfigPath: paths.userConfigPath, authPath: paths.authPath, modelPaths: [],
    },
    applyCodex: (active, channelIds) => { calls.applied.push(active.id); calls.repointed.push(channelIds); },
    restoreCodex: () => { calls.restored += 1; },
    applyCatalog: (models) => { calls.catalogs.push(models); },
    clearCatalog: () => { calls.cleared += 1; },
    // 注入什么由渠道列表决定，所以这里记的是「重启那一刻 current 是谁」：注入器就按它判断。
    restart: () => { calls.restarts.push(readChannelState(paths.configPath).current); },
    ...over,
  };
  return { options, calls };
};

test("panel save stores channels and switch applies the active one", async (context) => {
  const paths = sandbox(context);
  const { options, calls } = panelOptions(paths);
  const loaded = await handlePanelRequest({ action: "load" }, options);
  assert.equal(loaded.ok, true);
  assert.deepEqual(loaded.channels, []);

  const channels = [
    channel({ id: "a", name: "A" }),
    channel({ id: "b", name: "B", models: [{ id: "deepseek-v4-pro", context: 64 }] }),
  ];
  const saved = await handlePanelRequest({ action: "save", restart: false, channels, current: null }, options);
  assert.equal(saved.ok, true);
  assert.equal(saved.current, null);
  assert.equal(calls.applied.length, 0);
  assert.equal(readChannelState(paths.configPath).channels.length, 2);

  const invalid = await handlePanelRequest({
    action: "save", restart: false, current: null, channels: [{ name: "" }],
  }, options);
  assert.equal(invalid.ok, false);
  assert.equal(readChannelState(paths.configPath).channels.length, 2);

  const switched = await handlePanelRequest({ action: "switch", restart: true, channels, current: "b" }, options);
  assert.equal(switched.ok, true);
  assert.equal(switched.restarted, true);
  assert.equal(switched.current, "b");
  assert.deepEqual(calls.applied, ["b"]);
  assert.deepEqual(calls.repointed, [["a", "b"]], "切换要把渠道列表的 ID 一起交给写入");
  const expectedModels = [model({ id: "deepseek-v4-pro", context: 64 })];
  assert.deepEqual(calls.catalogs, [expectedModels]);
  assert.deepEqual(calls.restarts, ["b"], "重启前 current 已经落盘：注入器按它决定注入哪些渠道的模型");

  // 「重启」不针对某一条渠道：面板给的 current 认不出来时沿用上一条，再不然用第一条。
  const missing = await handlePanelRequest({ action: "switch", restart: true, channels, current: "nope" }, options);
  assert.equal(missing.ok, true);
  assert.equal(missing.current, "b", "认不出就沿用上一次生效的那条");
  const blank = await handlePanelRequest({ action: "switch", restart: true, channels, current: "" }, options);
  assert.equal(blank.ok, true);
  assert.equal(blank.current, "b");
  assert.equal((await handlePanelRequest({ action: "switch", restart: "yes", channels, current: "a" }, options)).ok, false);

  const failed = await handlePanelRequest({ action: "switch", restart: true, channels, current: "a" },
    { ...options, applyCodex: async () => { throw new Error("测试用失败"); } });
  assert.equal(failed.ok, false);
  assert.equal(failed.saved, true);
  assert.match(failed.error, /配置已保存，但未能生效：测试用失败/);

  // 面板送来的是输入框原文，可能带首尾空格：落盘的 ID 会 trim，比对时也要按 trim 后的值。
  const renamed = [
    channel({ id: "b-2 ", name: "B", models: [{ id: "m-b", context: 64 }] }),
    channel({ id: "a", name: "A" }),
  ];
  const keep = await handlePanelRequest({ action: "save", restart: false, channels: renamed, current: "b-2 " }, options);
  assert.equal(keep.ok, true);
  assert.equal(keep.current, "b-2", "改了运行中渠道的 ID（带空格）之后「运行中」要跟着新 ID");
  assert.equal(readChannelState(paths.configPath).current, "b-2");
});

test("panel agents load an editable default and merge only the edited block", async (context) => {
  const paths = sandbox(context);
  fs.writeFileSync(paths.agentsPath, "原公共指令\n");
  const { options } = panelOptions(paths);
  const loaded = await handlePanelRequest({ action: "load" }, options);
  assert.equal(loaded.ok, true);
  assert.equal(loaded.agents.source, "plugin");
  assert.equal(loaded.agents.enabled, false);
  assert.match(loaded.agents.content, /请遵循以下全局工作方式/);
  assert.doesNotMatch(loaded.agents.content, /原公共指令/);
  const saved = await handlePanelRequest({
    action: "save",
    scope: "agents",
    agents: { content: "# 我编辑的公共指令\n", enabled: true },
  }, options);
  assert.equal(saved.ok, true);
  const merged = fs.readFileSync(paths.agentsPath, "utf8");
  assert.match(merged, /# 我编辑的公共指令/);
  assert.doesNotMatch(merged, /请遵循以下全局工作方式/);
  assert.match(merged, /原公共指令\n$/);
  assert.equal(saved.agents.path, paths.agentsPath);
  assert.equal(saved.agents.keptUserFile, true);
  assert.equal(saved.agents.enabled, true);

  const reloaded = await handlePanelRequest({ action: "load" }, options);
  assert.equal(reloaded.agents.content, "# 我编辑的公共指令\n");
  assert.equal(reloaded.agents.source, "user");
});

test("agents state corruption keeps the template available and can be overwritten", async (context) => {
  const paths = sandbox(context);
  const { options } = panelOptions(paths);
  fs.mkdirSync(path.dirname(paths.agentsStatePath), { recursive: true });
  fs.writeFileSync(paths.agentsStatePath, "{broken");
  const loaded = await handlePanelRequest({ action: "load" }, options);
  assert.equal(loaded.ok, true);
  assert.match(loaded.agents.content, /请遵循以下全局工作方式/);
  assert.equal(loaded.agents.enabled, false);
  assert.equal(loaded.agents.error, "");
  assert.doesNotThrow(() => JSON.parse(fs.readFileSync(paths.agentsStatePath, "utf8")));
  const saved = await handlePanelRequest({
    action: "save",
    scope: "agents",
    agents: { content: "# 覆盖损坏状态\n", enabled: true },
  }, options);
  assert.equal(saved.ok, true);
  assert.equal(saved.agents.enabled, true);
  const state = JSON.parse(fs.readFileSync(paths.agentsStatePath, "utf8"));
  assert.equal(state.content, "# 覆盖损坏状态\n");
});

test("agents load trusts the active AGENTS block when the state file is corrupt", async (context) => {
  const paths = sandbox(context);
  const { options } = panelOptions(paths);
  fs.mkdirSync(path.dirname(paths.agentsStatePath), { recursive: true });
  fs.writeFileSync(paths.agentsStatePath, "{broken");
  fs.writeFileSync(
    paths.agentsPath,
    "<!-- GPTSWITCH_AGENTS_START -->\n# 文件里仍在生效\n<!-- GPTSWITCH_AGENTS_END -->\n");
  const loaded = await handlePanelRequest({ action: "load" }, options);
  assert.equal(loaded.agents.enabled, true);
  assert.equal(loaded.agents.content, "# 文件里仍在生效\n");
  assert.equal(loaded.agents.error, "");
  assert.deepEqual(JSON.parse(fs.readFileSync(paths.agentsStatePath, "utf8")), {
    enabled: true,
    content: "# 文件里仍在生效\n",
  });
});

test("panel clear restores codex config, keeps the channels and restarts with no current", async (context) => {
  const paths = sandbox(context);
  const { options, calls } = panelOptions(paths);
  const channels = [channel({ id: "a", name: "A" })];
  fs.writeFileSync(paths.agentsPath, "用户原有指令\n");
  await handlePanelRequest({
    action: "save",
    scope: "agents",
    agents: { content: "# 可恢复的公共指令\n", enabled: true },
  }, options);
  assert.equal((await handlePanelRequest({ action: "switch", restart: true, channels, current: "a" }, options)).ok, true);

  const cleared = await handlePanelRequest({ action: "clear" }, options);
  assert.equal(cleared.ok, true);
  assert.equal(cleared.cleared, true);
  assert.equal(cleared.current, null);
  assert.equal(cleared.channels.length, 1);
  assert.equal(calls.restored, 1);
  assert.equal(calls.cleared, 1);
  assert.deepEqual(calls.restarts.at(-1), null, "没有当前渠道时注入器什么都不注入");
  assert.equal(readChannelState(paths.configPath).current, null);
  assert.equal(fs.readFileSync(paths.agentsPath, "utf8"), "用户原有指令\n");
  const savedAgents = JSON.parse(fs.readFileSync(paths.agentsStatePath, "utf8"));
  assert.equal(savedAgents.enabled, false);
  assert.equal(savedAgents.content, "# 可恢复的公共指令\n");
  assert.equal(cleared.agents.enabled, false);

  const failed = await handlePanelRequest({ action: "clear" },
    { ...options, restart: async () => { throw new Error("测试用失败"); } });
  assert.equal(failed.ok, false);
  assert.equal(failed.cleared, true);
  assert.match(failed.error, /Codex 配置已还原，但清理或重启失败/);
});

/// /models 探针：起一个真的本地端点，发现模型走的就是运行期那条出站请求。
const withEndpoint = async (handler, run) => {
  const server = http.createServer((req, res) => handler(req, res));
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    return await run(`http://127.0.0.1:${server.address().port}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
};

/// 先占一个端口再放掉：用它当「没人监听」的地址，比随便挑一个端口可靠。
const closedPort = async () => {
  const server = http.createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
};

/// 断言失败信息里带着某段文字，省得为正则转义 URL 里的斜杠。
const rejectsWith = (run, expected) =>
  assert.rejects(run, (error) => error.message.includes(expected));

const listing = (res, body, status = 200, headers = {}) => {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(JSON.stringify(body));
};

test("discoverChannelModels reads both listing shapes and normalizes rows", async () => {
  const seen = [];
  const models = await withEndpoint((req, res) => {
    seen.push({ url: req.url, headers: req.headers });
    listing(res, { data: [
      {
        id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", context_length: 128000,
        supports_search_tool: true, supports_parallel_tool_calls: false,
      },
      { id: "glm-5.3" },
      { id: "  " },
      { id: "deepseek-v4-pro" },
      { name: "没有 id" },
      null,
      "裸字符串",
      { id: "long-name", name: "x".repeat(200) },
      { id: "control-name", name: "bad\nname" },
    ], models: { ignored: {} } });
  }, (base) => discoverChannelModels({
    baseUrl: `${base}/v1/`, apiKey: "sk-x", headerName: "x-actor", headerValue: "actor",
  }));
  assert.equal(seen[0].url, "/v1/models", "去掉末尾斜杠、保留路径段");
  assert.equal(seen[0].headers.authorization, "Bearer sk-x");
  assert.equal(seen[0].headers["x-actor"], "actor");
  assert.equal(seen[0].headers.accept, "application/json");
  assert.deepEqual(models, [
    {
      id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", context: 128,
    },
    { id: "glm-5.3" },
    { id: "long-name" },
    { id: "control-name" },
  ], "data 数组优先；去重、跳过 null／不是对象／没有 id 的行，token 折成 k；不导入 Agent 工具能力");

  const mapped = await withEndpoint((req, res) => listing(res, {
    models: { "glm-5.3": { name: "GLM 5.3" }, "deepseek-v4-pro": { id: "ignored" }, bad: 3, list: [] },
  }), (base) => discoverChannelModels({ baseUrl: base }));
  assert.deepEqual(mapped, [
    { id: "glm-5.3", displayName: "GLM 5.3" },
    { id: "deepseek-v4-pro" },
  ], "models 对象用属性名当 id，非对象条目忽略");
});

test("discoverChannelModels reports the failures the panel shows", async () => {
  await rejectsWith(() => discoverChannelModels({ baseUrl: "" }), "请先填渠道地址");
  await rejectsWith(() => discoverChannelModels({ baseUrl: "ftp://a.example" }), "http:// 或 https://");
  const offline = await closedPort();
  await rejectsWith(() => discoverChannelModels({ baseUrl: `http://127.0.0.1:${offline}/v1` }),
    `连不上 http://127.0.0.1:${offline}/v1/models`);
  await withEndpoint((req, res) => listing(res, {}, 401), async (base) => {
    await rejectsWith(() => discoverChannelModels({ baseUrl: `${base}/v1` }), "返回 401，检查 API 密钥");
  });
  await withEndpoint((req, res) => {
    res.writeHead(200, { "content-type": "text/html" });
    res.end("<html>");
  }, async (base) => {
    await rejectsWith(() => discoverChannelModels({ baseUrl: `${base}/v1` }),
      "返回的不是 JSON，这个地址返回的是网页；中转站一般要带上 /v1");
  });
  // 不是 HTML 的坏响应别乱猜地址。
  await withEndpoint((req, res) => {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("nope");
  }, async (base) => {
    await assert.rejects(
      () => discoverChannelModels({ baseUrl: `${base}/v1` }),
      (error) => error.message === `${base}/v1/models 返回的不是 JSON`,
    );
  });
  await withEndpoint((req, res) => listing(res, { nope: true }), async (base) => {
    await rejectsWith(() => discoverChannelModels({ baseUrl: `${base}/v1` }),
      "没有 data 数组也没有 models 对象");
  });
  await withEndpoint((req, res) => listing(res, { data: [] }), async (base) => {
    await rejectsWith(() => discoverChannelModels({ baseUrl: `${base}/v1` }), "没有公布任何模型");
  });
  // 端点自己报的体积过大就别去读了。
  await withEndpoint((req, res) => listing(res, { data: [] }, 200, { "content-length": "9000000" }), async (base) => {
    await rejectsWith(() => discoverChannelModels({ baseUrl: `${base}/v1` }), "超过 8MB");
  });
  // 不带长度、边算边发的流也要按实际读到的字节数掐掉。
  await withEndpoint((req, res) => {
    res.writeHead(200, { "content-type": "application/json" });
    res.on("error", () => {});
    res.end("x".repeat(9 * 1024 * 1024));
  }, async (base) => {
    await rejectsWith(() => discoverChannelModels({ baseUrl: `${base}/v1` }), "超过 8MB");
  });
});

test("discoverChannelModels requests the Codex catalog for the running client", async () => {
  let requested = "";
  const models = await withEndpoint((req, res) => {
    requested = req.url;
    listing(res, { models: [{ slug: "glm-5.3-flash", supports_search_tool: false }] });
  }, (base) => discoverChannelModels({
    baseUrl: `${base}/v1?region=cn`,
    clientVersion: "0.164.0",
  }));
  assert.equal(requested,
    "/v1/models?region=cn&client_version=0.164.0");
  assert.deepEqual(models, [{
    id: "glm-5.3-flash",
  }]);
});

test("panel list-models answers with the endpoint's models", async (context) => {
  const paths = sandbox(context);
  const { options } = panelOptions(paths);
  const listed = await withEndpoint((req, res) => listing(res, { data: [{ id: "m-one" }] }),
    (base) => handlePanelRequest({ action: "list-models", baseUrl: `${base}/v1` }, options));
  assert.deepEqual(listed, {
    ok: true,
    models: [{ id: "m-one" }],
  });

  const bad = await handlePanelRequest({ action: "list-models", baseUrl: "" }, options);
  assert.equal(bad.ok, false);
  assert.match(bad.error, /请先填渠道地址/);

  let requested = "";
  const versioned = await withEndpoint((req, res) => {
    requested = req.url;
    listing(res, { models: [{ slug: "glm-5.3-flash", supports_search_tool: false }] });
  }, (base) => handlePanelRequest(
    { action: "list-models", baseUrl: `${base}/v1` },
    { ...options, codexClientVersion: () => "0.164.0" },
  ));
  assert.equal(requested, "/v1/models?client_version=0.164.0");
  assert.deepEqual(versioned.models, [{
    id: "glm-5.3-flash",
  }]);
});

test("switching adds raw reasoning without changing the Agent web search setting", (context) => {
  const { userConfigPath, authPath, recordPath } = sandbox(context);
  fs.writeFileSync(userConfigPath, CONFIG);
  fs.writeFileSync(authPath, JSON.stringify({ OPENAI_API_KEY: "sk-old" }));
  applyChannelToCodex({ channel: channel(), authPath, userConfigPath, recordPath });
  let written = fs.readFileSync(userConfigPath, "utf8");
  assert.equal(written.includes("web_search"), false, "Agent 没写搜索配置时 GPT Switch 也不补");
  assert.match(written, /^show_raw_agent_reasoning = true$/m);
  assert.match(written, /^compact_prompt = ".*继续使用该语言.*"$/m, "压缩提示要求跟着用户的语言走");
  applyChannelToCodex({
    channel: channel({ id: "second", baseUrl: "https://b.example/v1" }),
    authPath, userConfigPath, recordPath,
  });
  written = fs.readFileSync(userConfigPath, "utf8");
  assert.equal(written.includes("web_search"), false);
  restoreCodexConfig({ authPath, userConfigPath, recordPath });
  assert.equal(fs.readFileSync(userConfigPath, "utf8"), CONFIG, "用户没写过的键还原时删掉");
});

test("switching leaves the Agent web search value untouched", (context) => {
  const { userConfigPath, authPath, recordPath } = sandbox(context);
  const original = `web_search = "live"\n${CONFIG}`;
  fs.writeFileSync(userConfigPath, original);
  fs.writeFileSync(authPath, JSON.stringify({ OPENAI_API_KEY: "sk-old" }));
  applyChannelToCodex({ channel: channel(), authPath, userConfigPath, recordPath });
  const written = fs.readFileSync(userConfigPath, "utf8");
  assert.match(written, /^web_search = "live"$/m);
  assert.equal((written.match(/^web_search/gm) || []).length, 1);
  assert.equal("web_search" in JSON.parse(fs.readFileSync(recordPath, "utf8")).globalKeys, false,
    "当前版本不再备份或接管 Agent 的搜索键");
  restoreCodexConfig({ authPath, userConfigPath, recordPath });
  const restored = fs.readFileSync(userConfigPath, "utf8");
  assert.match(restored, /^web_search = "live"$/m, "还原时也不碰 Agent 当前搜索配置");
  assert.match(restored, /^model_provider = "OpenAI"$/m);
});

test("clearing leaves legacy Agent web search values untouched", (context) => {
  const { userConfigPath, authPath, recordPath } = sandbox(context);
  fs.writeFileSync(authPath, JSON.stringify({ OPENAI_API_KEY: "sk-old" }));
  fs.mkdirSync(path.dirname(recordPath), { recursive: true });
  const cases = [
    { current: null, backup: null },
    { current: "live", backup: "disabled" },
    { current: "indexed", backup: "disabled" },
  ];
  for (const item of cases) {
    const current = item.current ? `web_search = "${item.current}"\n` : "";
    const expected = item.current ? current : "";
    fs.writeFileSync(userConfigPath, current);
    fs.writeFileSync(recordPath, JSON.stringify({
      auth: null,
      modelProvider: null,
      tablesAdded: [],
      globalKeys: {
        web_search: item.backup === null ? null : `web_search = "${item.backup}"`,
      },
    }));
    restoreCodexConfig({ authPath, userConfigPath, recordPath });
    assert.equal(fs.readFileSync(userConfigPath, "utf8"), expected,
      "旧备份不能覆盖或删除 Agent 当前值");
  }
});

test("switching keeps the current model and only falls back when the channel lacks it", (context) => {
  const { userConfigPath, authPath, recordPath } = sandbox(context);
  fs.writeFileSync(userConfigPath, CONFIG);
  fs.writeFileSync(authPath, JSON.stringify({ OPENAI_API_KEY: "sk-old" }));
  const models = [model({ id: "gpt-6-astra", context: 128 }), model({ id: "m-two", context: 128 })];
  applyChannelToCodex({ channel: channel({ models }), authPath, userConfigPath, recordPath });
  assert.match(fs.readFileSync(userConfigPath, "utf8"), /^model = "gpt-6-astra"$/m,
    "当前模型在新渠道里有就留着");
  applyChannelToCodex({
    channel: channel({ id: "second", baseUrl: "https://b.example/v1", models }),
    authPath, userConfigPath, recordPath,
  });
  assert.match(fs.readFileSync(userConfigPath, "utf8"), /^model = "gpt-6-astra"$/m);
  applyChannelToCodex({
    channel: channel({ id: "third", baseUrl: "https://c.example/v1", models: [model({ id: "m-one", context: 128 })] }),
    authPath, userConfigPath, recordPath,
  });
  assert.match(fs.readFileSync(userConfigPath, "utf8"), /^model = "m-one"$/m,
    "新渠道没有这个模型就退回渠道里的第一个");
  restoreCodexConfig({ authPath, userConfigPath, recordPath });
  assert.equal(fs.readFileSync(userConfigPath, "utf8"), CONFIG, "还原放回用户原来的模型");
});

test("switching picks the channel's first model when config has no model", (context) => {
  const { userConfigPath, authPath, recordPath } = sandbox(context);
  fs.writeFileSync(userConfigPath, "# user config\n");
  fs.writeFileSync(authPath, JSON.stringify({ OPENAI_API_KEY: "sk-old" }));
  applyChannelToCodex({ channel: channel(), authPath, userConfigPath, recordPath });
  assert.match(fs.readFileSync(userConfigPath, "utf8"), /^model = "m-one"$/m);
  restoreCodexConfig({ authPath, userConfigPath, recordPath });
  assert.equal(fs.readFileSync(userConfigPath, "utf8"), "# user config\n", "用户没写过 model 就删掉");
});

test("recordedProxyPort only trusts the provider table we wrote", (context) => {
  const { userConfigPath, recordPath } = sandbox(context);
  // 用户自己的本地服务排在我们前面：全文取第一处 127.0.0.1 会认成我们的转发端口。
  fs.writeFileSync(userConfigPath, [
    "[model_providers.ollama]",
    'base_url = "http://127.0.0.1:11434/v1"',
    "",
    "[model_providers.relay]",
    'base_url = "http://127.0.0.1:47123/v1"',
    "",
  ].join("\n"));
  fs.mkdirSync(path.dirname(recordPath), { recursive: true });
  assert.equal(recordedProxyPort({ userConfigPath, recordPath }), 0, "没有写入记录时当没配过");
  fs.writeFileSync(recordPath, JSON.stringify({ appliedId: "relay" }));
  assert.equal(recordedProxyPort({ userConfigPath, recordPath }), 47123,
    "只认我们自己那段 provider 的地址，不能拿 Ollama 的端口");
  fs.writeFileSync(userConfigPath, '[model_providers.relay]\nbase_url = "https://relay.example/v1"\n');
  assert.equal(recordedProxyPort({ userConfigPath, recordPath }), 0, "直连渠道不算本地转发端口");
});

test("recorded proxy address imports both host and port from our provider", (context) => {
  const { userConfigPath, recordPath } = sandbox(context);
  fs.writeFileSync(userConfigPath, '[model_providers.relay]\nbase_url = "http://192.168.1.20:47123/v1"\n');
  fs.mkdirSync(path.dirname(recordPath), { recursive: true });
  fs.writeFileSync(recordPath, JSON.stringify({ appliedId: "relay" }));
  assert.deepEqual(recordedProxyAddress({ userConfigPath, recordPath }),
    { host: "192.168.1.20", port: 47123 });
});

test("repointProxyUrl moves only base_url when the forward port changed", (context) => {
  const { userConfigPath, recordPath } = sandbox(context);
  fs.writeFileSync(userConfigPath, [
    'model = "m-one"',
    'web_search = "live"',
    "",
    "[model_providers.ollama]",
    'base_url = "http://127.0.0.1:11434/v1"',
    "",
    "[model_providers.relay]",
    'name = "relay"',
    'base_url = "http://127.0.0.1:47123/v1"',
    'wire_api = "responses"',
    "",
    "[model_providers.old]",
    'base_url = "http://127.0.0.1:47123/v1"',
    "",
  ].join("\n"));
  fs.mkdirSync(path.dirname(recordPath), { recursive: true });
  fs.writeFileSync(recordPath, JSON.stringify({ appliedId: "relay", tablesAdded: ["old"] }));
  const baseUrl = "http://127.0.0.1:47124/v1";
  assert.equal(repointProxyUrl({ userConfigPath, recordPath, baseUrl }), true);
  const text = fs.readFileSync(userConfigPath, "utf8");
  assert.equal(text.split(`base_url = "${baseUrl}"`).length - 1, 2, "我们写过的两段都改到新端口");
  assert.match(text, /^model = "m-one"$/m, "全局键不动");
  assert.match(text, /^wire_api = "responses"$/m, "段里别的键保留");
  assert.match(text, /\[model_providers\.ollama\]\nbase_url = "http:\/\/127\.0\.0\.1:11434\/v1"/,
    "用户自己的本地服务不许碰");
  assert.equal(repointProxyUrl({ userConfigPath, recordPath, baseUrl }), false, "已经是新地址就不用再写一次");
  assert.equal(repointProxyUrl({ userConfigPath, recordPath, baseUrl: "" }), false);
});
