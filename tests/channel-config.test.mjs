import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import {
  validateChannels, writeChannelState, readChannelState, loadChannelState,
  modelProviderFromToml, readProviderTable, upsertProviderTable, setModelProvider,
  applyChannelToCodex, restoreCodexConfig, importChannelsFromCodex, handlePanelRequest,
  discoverChannelModels, modelFromToml, recordedProxyPort, repointProxyUrl,
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
  displayName: String(over.id ?? ""), inputModalities: ["text", "image"], ...over,
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
    channel({ id: "b", name: "B", models: [{ id: "m-b", context: 64 }] }),
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
  const expectedModels = [model({ id: "m-b", context: 64 })];
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

test("panel clear restores codex config, keeps the channels and restarts with no current", async (context) => {
  const paths = sandbox(context);
  const { options, calls } = panelOptions(paths);
  const channels = [channel({ id: "a", name: "A" })];
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

  const failed = await handlePanelRequest({ action: "clear" },
    { ...options, restart: async () => { throw new Error("测试用失败"); } });
  assert.equal(failed.ok, false);
  assert.equal(failed.cleared, true);
  assert.match(failed.error, /Codex 配置已还原，但清理或重启失败/);
});

/// /models 探针：临时顶掉全局 fetch，只检查请求和解析，不真的发网络。
const withFetch = async (handler, run) => {
  const original = globalThis.fetch;
  globalThis.fetch = handler;
  try {
    return await run();
  } finally {
    globalThis.fetch = original;
  }
};

/// 断言失败信息里带着某段文字，省得为正则转义 URL 里的斜杠。
const rejectsWith = (run, expected) =>
  assert.rejects(run, (error) => error.message.includes(expected));

/// 用真的 Response，让读取和解析走的是运行期那条路。
const listing = (body, status = 200, headers = {}) =>
  new Response(JSON.stringify(body), { status, headers });

test("discoverChannelModels reads both listing shapes and normalizes rows", async () => {
  const seen = [];
  const models = await withFetch(async (url, init) => {
    seen.push({ url, init });
    return listing({ data: [
      { id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", context_length: 128000 },
      { id: "glm-5.3" },
      { id: "  " },
      { id: "deepseek-v4-pro" },
      { name: "没有 id" },
      null,
      "裸字符串",
      { id: "long-name", name: "x".repeat(200) },
      { id: "control-name", name: "bad\nname" },
    ], models: { ignored: {} } });
  }, () => discoverChannelModels({
    baseUrl: "https://choohub.net/v1/", apiKey: "sk-x", headerName: "x-actor", headerValue: "actor",
  }));
  assert.equal(seen[0].url, "https://choohub.net/v1/models", "去掉末尾斜杠、保留路径段");
  assert.equal(seen[0].init.headers.authorization, "Bearer sk-x");
  assert.equal(seen[0].init.headers["x-actor"], "actor");
  assert.equal(seen[0].init.headers.accept, "application/json");
  assert.deepEqual(models, [
    { id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", context: 128 },
    { id: "glm-5.3" },
    { id: "long-name" },
    { id: "control-name" },
  ], "data 数组优先；去重、跳过 null／不是对象／没有 id 的行，token 折成 k；名字缺失或存不进去就不填，保存时统一兜底");

  const mapped = await withFetch(async () => listing({
    models: { "glm-5.3": { name: "GLM 5.3" }, "deepseek-v4-pro": { id: "ignored" }, bad: 3, list: [] },
  }), () => discoverChannelModels({ baseUrl: "https://relay.example" }));
  assert.deepEqual(mapped, [
    { id: "glm-5.3", displayName: "GLM 5.3" },
    { id: "deepseek-v4-pro" },
  ], "models 对象用属性名当 id，非对象条目忽略");
});

test("discoverChannelModels reports the failures the panel shows", async () => {
  await rejectsWith(() => discoverChannelModels({ baseUrl: "" }), "请先填渠道地址");
  await rejectsWith(() => discoverChannelModels({ baseUrl: "ftp://a.example" }), "http:// 或 https://");
  await withFetch(async () => { throw new Error("offline"); }, async () => {
    await rejectsWith(() => discoverChannelModels({ baseUrl: "https://a.example/v1" }),
      "连不上 https://a.example/v1/models");
  });
  await withFetch(async () => listing({}, 401), async () => {
    await rejectsWith(() => discoverChannelModels({ baseUrl: "https://a.example/v1" }), "返回 401，检查 API 密钥");
  });
  await withFetch(async () => new Response("<html>", { status: 200 }), async () => {
    await rejectsWith(() => discoverChannelModels({ baseUrl: "https://a.example/v1" }),
      "返回的不是 JSON，这个地址返回的是网页；中转站一般要带上 /v1");
  });
  // 不是 HTML 的坏响应别乱猜地址。
  await withFetch(async () => new Response("nope", { status: 200 }), async () => {
    await assert.rejects(
      () => discoverChannelModels({ baseUrl: "https://a.example/v1" }),
      (error) => error.message === "https://a.example/v1/models 返回的不是 JSON",
    );
  });
  await withFetch(async () => listing({ nope: true }), async () => {
    await rejectsWith(() => discoverChannelModels({ baseUrl: "https://a.example/v1" }),
      "没有 data 数组也没有 models 对象");
  });
  await withFetch(async () => listing({ data: [] }), async () => {
    await rejectsWith(() => discoverChannelModels({ baseUrl: "https://a.example/v1" }), "没有公布任何模型");
  });
  // 端点自己报的体积过大就别去读了。
  await withFetch(async () => listing({ data: [] }, 200, { "content-length": "9000000" }), async () => {
    await rejectsWith(() => discoverChannelModels({ baseUrl: "https://a.example/v1" }), "超过 8MB");
  });
  // 谎报长度的流也要按实际读到的字节数掐掉。
  await withFetch(async () => new Response("x".repeat(9 * 1024 * 1024), { status: 200, headers: { "content-length": "10" } }),
    async () => {
      await rejectsWith(() => discoverChannelModels({ baseUrl: "https://a.example/v1" }), "超过 8MB");
    });
});

test("panel list-models answers with the endpoint's models", async (context) => {
  const paths = sandbox(context);
  const { options } = panelOptions(paths);
  const listed = await withFetch(async () => listing({ data: [{ id: "m-one" }] }),
    () => handlePanelRequest({ action: "list-models", baseUrl: "https://relay.example/v1" }, options));
  assert.deepEqual(listed, { ok: true, models: [{ id: "m-one" }] });

  const bad = await handlePanelRequest({ action: "list-models", baseUrl: "" }, options);
  assert.equal(bad.ok, false);
  assert.match(bad.error, /请先填渠道地址/);
});

test("switching turns web search off and shows raw reasoning, clearing removes them again", (context) => {
  const { userConfigPath, authPath, recordPath } = sandbox(context);
  fs.writeFileSync(userConfigPath, CONFIG);
  fs.writeFileSync(authPath, JSON.stringify({ OPENAI_API_KEY: "sk-old" }));
  applyChannelToCodex({ channel: channel(), authPath, userConfigPath, recordPath });
  let written = fs.readFileSync(userConfigPath, "utf8");
  assert.match(written, /^web_search = "disabled"$/m);
  assert.match(written, /^show_raw_agent_reasoning = true$/m);
  assert.match(written, /^compact_prompt = ".*继续使用该语言.*"$/m, "压缩提示要求跟着用户的语言走");
  applyChannelToCodex({
    channel: channel({ id: "second", baseUrl: "https://b.example/v1" }),
    authPath, userConfigPath, recordPath,
  });
  written = fs.readFileSync(userConfigPath, "utf8");
  assert.equal((written.match(/^web_search/gm) || []).length, 1, "来回切不要写出第二行");
  restoreCodexConfig({ authPath, userConfigPath, recordPath });
  assert.equal(fs.readFileSync(userConfigPath, "utf8"), CONFIG, "用户没写过的键还原时删掉");
});

test("switching keeps the user's own web_search value until clearing", (context) => {
  const { userConfigPath, authPath, recordPath } = sandbox(context);
  const original = `web_search = "live"\n${CONFIG}`;
  fs.writeFileSync(userConfigPath, original);
  fs.writeFileSync(authPath, JSON.stringify({ OPENAI_API_KEY: "sk-old" }));
  applyChannelToCodex({ channel: channel(), authPath, userConfigPath, recordPath });
  const written = fs.readFileSync(userConfigPath, "utf8");
  assert.match(written, /^web_search = "disabled"$/m);
  assert.equal(written.includes('web_search = "live"'), false);
  restoreCodexConfig({ authPath, userConfigPath, recordPath });
  assert.equal(fs.readFileSync(userConfigPath, "utf8"), original, "还原放回用户原来的值");
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

test("repointProxyUrl moves only base_url when the forward port changed", (context) => {
  const { userConfigPath, recordPath } = sandbox(context);
  fs.writeFileSync(userConfigPath, [
    'model = "m-one"',
    'web_search = "disabled"',
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
