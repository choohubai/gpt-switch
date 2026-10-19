import fs from "node:fs";
import {
  atomicWrite, MAX_LABEL_LENGTH, validateModels,
} from "./model-config.mjs";

/// 渠道配置：面板里存一份，切换渠道时写进 Codex 的 config.toml 和 auth.json。
/// 官方字段说明见 https://developers.openai.com/codex/config-reference
const MAX_CHANNELS = 50;
const MAX_NAME_LENGTH = 60;
const MAX_URL_LENGTH = 300;
const MAX_KEY_LENGTH = 400;
const MAX_HEADER_VALUE = 500;
const ID_PATTERN = /^[A-Za-z0-9_-]{1,32}$/;
const HEADER_NAME_PATTERN = /^[A-Za-z0-9!#$%&'*+.^_`|~-]{1,64}$/;
const TABLE_START = /^[ \t]*\[/m;
const MODEL_PROVIDER_LINE = /^[ \t]*model_provider[ \t]*=[ \t]*(?:"((?:[^"\\]|\\.)*)"|'([^']*)')[ \t]*\r?\n?/m;
const MODEL_LINE = /^[ \t]*model[ \t]*=[ \t]*(?:"((?:[^"\\]|\\.)*)"|'([^']*)')[ \t]*\r?\n?/m;
const AUTH_KEY = "OPENAI_API_KEY";

const MODEL_LIST_TIMEOUT_MS = 5_000;
const MAX_LISTING_BYTES = 8 * 1024 * 1024;
// shortcut: 只保留前 500 个模型，端点公布得更多时剩下的会被丢掉；真有人用到再分页或全量。
const MAX_DISCOVERED_MODELS = 500;
const PROXY_CONFIG_KEYS = new Set(["host", "port"]);
const IPV4_PATTERN = /^(?:(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)$/;

const hasControlChars = (value) => /[\u0000-\u001f\u007f]/.test(value);

const requireText = (value, label, limit) => {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${label}不能为空`);
  const trimmed = value.trim();
  if (trimmed.length > limit || hasControlChars(trimmed)) {
    throw new Error(`${label}不能包含控制字符，且不能超过 ${limit} 个字符`);
  }
  return trimmed;
};

const optionalText = (value, label, limit) => {
  if (value == null) return "";
  if (typeof value !== "string") throw new Error(`${label}必须是文本`);
  const trimmed = value.trim();
  if (!trimmed) return "";
  if (trimmed.length > limit || /[\u0000-\u001f\u007f]/.test(trimmed)) {
    throw new Error(`${label}不能包含控制字符，且不能超过 ${limit} 个字符`);
  }
  return trimmed;
};

export const validateChannels = (value) => {
  if (!Array.isArray(value)) throw new Error("渠道配置必须是列表");
  if (value.length > MAX_CHANNELS) throw new Error(`渠道数量不能超过 ${MAX_CHANNELS} 个`);
  const used = new Set();
  return value.map((channel, index) => {
    const label = `第 ${index + 1} 个渠道`;
    const trimmedId = typeof channel?.id === "string" ? channel.id.trim() : "";
    const rawId = ID_PATTERN.test(trimmedId) ? trimmedId : null;
    if (!rawId) throw new Error(`${label}的 Provider ID 只能用字母、数字、- 和 _，且不能超过 32 个字符`);
    if (used.has(rawId)) throw new Error(`Provider ID 重复：${rawId}`);
    const id = rawId;
    used.add(id);
    // 面板不再单独填显示名称，缺省就用 Provider ID。
    const name = optionalText(channel?.name, `${label}的名称`, MAX_NAME_LENGTH) || id;
    const baseUrl = optionalText(channel?.baseUrl, `${label}的地址`, MAX_URL_LENGTH);
    if (baseUrl && !/^https?:\/\//i.test(baseUrl)) {
      throw new Error(`${label}的地址必须以 http:// 或 https:// 开头`);
    }
    const apiKey = optionalText(channel?.apiKey, `${label}的密钥`, MAX_KEY_LENGTH);
    const headerName = optionalText(channel?.headerName, `${label}的请求头名`, 64);
    const headerValue = optionalText(channel?.headerValue, `${label}的请求头值`, MAX_HEADER_VALUE);
    if (Boolean(headerName) !== Boolean(headerValue)) {
      throw new Error(`${label}的请求头名和请求头值要一起填`);
    }
    if (headerName && !HEADER_NAME_PATTERN.test(headerName)) {
      throw new Error(`${label}的请求头名只能包含 HTTP 头允许的字符`);
    }
    return {
      id,
      name,
      baseUrl,
      apiKey,
      headerName,
      headerValue,
      // 渠道可以单独启用/禁用，新建的缺省是启用；选择器和转发都只看这个开关。
      enabled: channel?.enabled !== false,
      models: validateModels(channel?.models ?? []),
    };
  });
};

/// 读取代理页设置。配置单独存放，升级和还原 Codex 配置都不会覆盖它。
export const readProxySettings = (configPath) => {
  if (!fs.existsSync(configPath)) return { host: "127.0.0.1", port: 47123 };
  const parsed = JSON.parse(fs.readFileSync(configPath, "utf8"));
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("代理配置必须是对象");
  }
  for (const key of Object.keys(parsed)) {
    if (!PROXY_CONFIG_KEYS.has(key)) throw new Error(`代理配置包含未知字段：${key}`);
  }
  const host = typeof parsed.host === "string" ? parsed.host.trim() : "";
  const port = Number(parsed.port);
  if (!IPV4_PATTERN.test(host)) {
    throw new Error("代理 IP 必须是合法的 IPv4 地址");
  }
  if (!Number.isInteger(port) || port < 1024 || port > 65535) {
    throw new Error("代理端口必须是 1024 到 65535 之间的整数");
  }
  return { host, port };
};

/// 校验代理页配置。端口占用不在这里拦截：启动或重启时占用会顺延，并把实际端口写回配置。
export const validateProxySettings = (value) => {
  const host = typeof value?.host === "string" ? value.host.trim() : "";
  const port = Number(value?.port);
  if (!IPV4_PATTERN.test(host)) {
    throw new Error("代理 IP 必须是合法的 IPv4 地址");
  }
  if (!Number.isInteger(port) || port < 1024 || port > 65535) {
    throw new Error("代理端口必须是 1024 到 65535 之间的整数");
  }
  return { host, port };
};

export const writeProxySettings = (configPath, value) => {
  const proxy = validateProxySettings(value);
  atomicWrite(configPath, `${JSON.stringify(proxy, null, 2)}\n`);
  return proxy;
};

export const readChannelState = (configPath) => {
  const parsed = JSON.parse(fs.readFileSync(configPath, "utf8"));
  const channels = validateChannels(parsed?.channels ?? []);
  const current = channels.some((channel) => channel.id === parsed?.current) ? parsed.current : null;
  return { channels, current };
};

export const writeChannelState = (configPath, state) => {
  const channels = validateChannels(state?.channels ?? []);
  const current = channels.some(((channel) => channel.id === state?.current)) ? state.current : null;
  atomicWrite(configPath, `${JSON.stringify({ channels, current }, null, 2)}\n`);
  return { channels, current };
};

export const tomlString = (value) => (/\\/.test(String(value))
  ? `'${String(value).replaceAll("'", "''")}'`
  : JSON.stringify(String(value)));

const unescapeBasic = (value) => value.replace(/\\(["\\ntr])/g,
  (_, char) => ({ '"': '"', "\\": "\\", n: "\n", t: "\t", r: "\r" }[char]));

/// 顶层键只在第一个表头之前生效，表里同名的键不算。
const topLevelHead = (text) => {
  const index = text.search(TABLE_START);
  return index < 0 ? text : text.slice(0, index);
};

/// 顶层键的整行（含行尾换行）。
const topLevelLinePattern = (name) => new RegExp(`^[ \\t]*${name}[ \\t]*=[^\\n]*\\n?`, "m");

/// 没有就补在最前面，有就按原位置替换。
const setTopLevelLine = (text, name, line) => {
  const head = topLevelHead(text);
  const pattern = topLevelLinePattern(name);
  const tail = text.slice(head.length);
  return pattern.test(head)
    ? `${head.replace(pattern, `${line}\n`)}${tail}`
    : `${line}\n${head.replace(/^\n+/, "")}${tail}`;
};

const removeTopLevelLine = (text, name) => {
  const head = topLevelHead(text);
  return `${head.replace(topLevelLinePattern(name), "")}${text.slice(head.length)}`;
};

/// 客户端自带的压缩提示是英文，压缩完接手的那一轮会顺着英文摘要继续用英文推理；换成「用用户当前使用的
/// 语言写摘要、并注明后续继续用该语言」的提示，压缩后仍按用户的语言走。
const COMPACT_PROMPT = "你正在进行上下文压缩检查点。请为接手这个任务的另一个 LLM 写一份交接摘要："
  + "用用户当前使用的语言写，并在摘要开头注明「后续回复与推理继续使用该语言」。";

/// 当前渠道模型都支持网页搜索，统一使用 live 实时抓取；第三方模型的推理是裸文本，
/// 不开这个桌面端看不到。
/// 这几个键都是全局的，启用时写入、还原时放回原值。
const GLOBAL_KEYS = [
  { name: "web_search", value: '"live"' },
  { name: "show_raw_agent_reasoning", value: "true" },
  { name: "compact_prompt", value: tomlString(COMPACT_PROMPT) },
];

/// 客户端把「当前默认模型」记在顶层 model 里。切换渠道后这个模型要是落不到新渠道的模型列表里，客户端的
/// 选择器就只能显示「自定义」；这种时候换成渠道里的第一个模型。原来那行照旧记进 globalKeys，还原时放回去。
export const channelDefaultModel = (text, channel, knownModels = null) => {
  const ids = channel.models.map((entry) => entry.id);
  if (!ids.length) return null;
  const current = modelFromToml(text);
  if (ids.includes(current)) return null;
  // 走本地转发时选择器里还有别的渠道的模型（`gpts-<渠道>/<模型>`）：那也是用户选好的，别改掉。
  return knownModels?.includes(current) ? null : ids[0];
};

const providerHeader = (id) => {
  const escaped = id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`^[ \\t]*\\[\\s*model_providers\\s*\\.\\s*(?:"${escaped}"|'${escaped}'|${escaped})\\s*\\][ \\t]*\\r?$`, "m");
};

const providerSpan = (text, id) => {
  const match = providerHeader(id).exec(text);
  if (!match) return null;
  const start = match.index;
  const rest = text.slice(start + match[0].length);
  const next = rest.search(/\n[ \t]*\[/);
  return { start, end: next < 0 ? text.length : start + match[0].length + next + 1 };
};

const parseValue = (raw) => {
  const value = raw.trim();
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    return unescapeBasic(value.slice(1, -1));
  }
  if (value.length >= 2 && value.startsWith("'") && value.endsWith("'")) {
    return value.slice(1, -1);
  }
  if (value === "true") return true;
  if (value === "false") return false;
  const inline = /^\{(.*)\}$/s.exec(value);
  if (inline) {
    const pairs = {};
    const pair = /(?:"((?:[^"\\]|\\.)*)"|'([^']*)')\s*=\s*(?:"((?:[^"\\]|\\.)*)"|'([^']*)')/g;
    let match = pair.exec(inline[1]);
    while (match) {
      pairs[unescapeBasic(match[1] ?? match[2])] = unescapeBasic(match[3] ?? match[4]);
      match = pair.exec(inline[1]);
    }
    return pairs;
  }
  return undefined;
};

export const modelProviderFromToml = (text) => {
  const match = MODEL_PROVIDER_LINE.exec(topLevelHead(text));
  if (!match) return null;
  return unescapeBasic(match[1] ?? match[2]);
};

export const modelFromToml = (text) => {
  const match = MODEL_LINE.exec(topLevelHead(text));
  if (!match) return null;
  return unescapeBasic(match[1] ?? match[2]);
};

export const readProviderTable = (text, id) => {
  const span = providerSpan(text, id);
  if (!span) return null;
  const table = {};
  for (const line of text.slice(span.start, span.end).split("\n").slice(1)) {
    const match = /^[ \t]*([A-Za-z0-9_-]+)[ \t]*=[ \t]*(.+?)[ \t]*$/.exec(line);
    if (!match) continue;
    const value = parseValue(match[2]);
    if (value !== undefined) table[match[1]] = value;
  }
  return table;
};

/// baseUrl 缺省就是渠道自己的地址；走本地转发时传转发端口，请求头改由转发层逐渠道补，
/// 写进 provider 段会让所有渠道共用同一份。
export const buildProviderBlock = (channel, id = channel.id, baseUrl = channel.baseUrl) => {
  const lines = [
    `[model_providers.${id}]`,
    `name = ${tomlString(channel.name || channel.id)}`,
    `base_url = ${tomlString(baseUrl)}`,
    'wire_api = "responses"',
    "requires_openai_auth = true",
  ];
  if (baseUrl === channel.baseUrl && channel.headerName && channel.headerValue) {
    lines.push(`http_headers = { ${tomlString(channel.headerName)} = ${tomlString(channel.headerValue)} }`);
  }
  return `${lines.join("\n")}\n`;
};

/// 上次启用渠道时写进 config.toml 的本地转发端口。
/// 插件的客户端只认配置里那个端口，重启后要优先沿用，不然它不会知道端口换了。
/// 渠道地址里的本地转发端口。只认 IPv4 回环：插件自己写的就是这个形状。
const localProxyPortOf = (baseUrl) => {
  const match = /^http:\/\/127\.0\.0\.1:(\d{1,5})(?=\/|$)/.exec(String(baseUrl ?? ""));
  if (!match) return 0;
  const port = Number(match[1]);
  return Number.isInteger(port) && port > 0 && port < 65536 ? port : 0;
};

/// 上次启用渠道时写进 config.toml 的转发端口。
///
/// 只认我们自己改写过的那个 provider 段。config.toml 里还可能有用户自己的本地服务
/// （Ollama 的 11434、LM Studio 的 1234），按全文取第一处 `127.0.0.1` 会认成我们的端口：
/// 要么客户端继续指着旧端口、要么转发服务把别人要用的端口占了。
export const recordedProxyPort = ({ userConfigPath, recordPath }) => {
  const id = readRecord(recordPath)?.appliedId;
  if (typeof id !== "string" || !ID_PATTERN.test(id)) return 0;
  try {
    return localProxyPortOf(readProviderTable(fs.readFileSync(userConfigPath, "utf8"), id)?.base_url);
  } catch {
    return 0;
  }
};

/// 上次写进 Codex 的本地转发地址。IPv4 代理页允许用户改监听地址，这里要和端口一起还原。
export const recordedProxyAddress = ({ userConfigPath, recordPath }) => {
  const id = readRecord(recordPath)?.appliedId;
  if (typeof id !== "string" || !ID_PATTERN.test(id)) return null;
  try {
    const value = readProviderTable(fs.readFileSync(userConfigPath, "utf8"), id)?.base_url;
    const match = /^http:\/\/((?:\d{1,3}\.){3}\d{1,3}):(\d{1,5})(?=\/|$)/.exec(String(value ?? ""));
    if (!match || !IPV4_PATTERN.test(match[1])) return null;
    const port = Number(match[2]);
    return Number.isInteger(port) && port >= 1024 && port <= 65535
      ? { host: match[1], port }
      : null;
  } catch {
    return null;
  }
};

const replaceProviderTable = (text, id, block) => {
  const span = providerSpan(text, id);
  if (!span) {
    const trimmed = text.replace(/\s+$/, "");
    return trimmed ? `${trimmed}\n\n${block}` : block;
  }
  return `${text.slice(0, span.start)}${block}${text.slice(span.end)}`;
};

export const upsertProviderTable = (text, channel, baseUrl = channel.baseUrl) =>
  replaceProviderTable(text, channel.id, buildProviderBlock(channel, channel.id, baseUrl));

export const removeProviderTable = (text, id) => {
  const span = providerSpan(text, id);
  if (!span) return text;
  const cut = `${text.slice(0, span.start)}${text.slice(span.end)}`;
  return span.end === text.length ? cut.replace(/\s+$/, "\n") : cut;
};

export const setModelProvider = (text, id) =>
  setTopLevelLine(text, "model_provider", `model_provider = ${tomlString(id)}`);

export const removeModelProvider = (text) => removeTopLevelLine(text, "model_provider");

const readAuthKey = (authPath) => {
  try {
    const data = JSON.parse(fs.readFileSync(authPath, "utf8"));
    return typeof data?.[AUTH_KEY] === "string" ? data[AUTH_KEY] : null;
  } catch {
    return null;
  }
};

const readRecord = (recordPath) => {
  try {
    const record = JSON.parse(fs.readFileSync(recordPath, "utf8"));
    return record && typeof record === "object" && !Array.isArray(record) ? record : null;
  } catch {
    return null;
  }
};

/// 每个回话会把创建时的 provider ID 记在自己身上，重开时只按这个 ID 去 config.toml 找表，
/// 不会回落到当前渠道。所以每次切换都要把当前渠道写进所有出现过的 ID（渠道列表 + 历史写入记录），
/// 否则旧回话要么继续指着旧地址（地址与全局密钥错配），要么因为表被删掉而打不开。
const providerIdsToRepoint = ({ channel, channelIds, record }) => {
  const candidates = [channel.id, ...channelIds, record.appliedId, record.modelProvider?.value,
    ...(record.tablesAdded ?? []), ...Object.keys(record.tablesOriginal ?? {})];
  const ids = [];
  for (const id of candidates) {
    if (typeof id !== "string" || !ID_PATTERN.test(id) || ids.includes(id)) continue;
    ids.push(id);
  }
  return ids;
};

/// 转发端口换了以后，把配置里我们写过的 provider 段重新指到新地址。
///
/// 客户端只认 config.toml 里的 `base_url`：转发服务换端口后不改这里，它的请求会一直发到
/// 没人监听的旧端口，直到用户手动点一次重启。只动 `base_url` 那一行——全局键、密钥和其它
/// provider 键都不碰，这是修地址，不是重新应用一次渠道。
export const repointProxyUrl = ({ userConfigPath, recordPath, baseUrl }) => {
  if (!baseUrl) return false;
  const record = readRecord(recordPath);
  if (!record) return false;
  let text = fs.readFileSync(userConfigPath, "utf8");
  let changed = false;
  for (const id of providerIdsToRepoint({ channel: { id: record.appliedId }, channelIds: [], record })) {
    const span = providerSpan(text, id);
    if (!span) continue;
    const before = text.slice(span.start, span.end);
    const after = before.replace(/^([ \t]*base_url[ \t]*=[ \t]*)["'][^"']*["']/m, `$1${tomlString(baseUrl)}`);
    if (after === before) continue;
    text = text.slice(0, span.start) + after + text.slice(span.end);
    changed = true;
  }
  if (changed) atomicWrite(userConfigPath, text);
  return changed;
};

/// 切换渠道：密钥进 auth.json，地址和 provider 段进 config.toml，原值记下来供还原。
export const applyChannelToCodex = ({
  channel, channelIds = [], authPath, userConfigPath, recordPath, proxyUrl = "", knownModels = null,
}) => {
  if (!channel.baseUrl) throw new Error(`渠道「${channel.name}」还没填地址`);
  const record = readRecord(recordPath) ?? { auth: null, modelProvider: null, tablesAdded: [] };
  if (!Array.isArray(record.tablesAdded)) record.tablesAdded = [];
  if (!record.tablesOriginal || typeof record.tablesOriginal !== "object") record.tablesOriginal = {};

  const previousAuth = channel.apiKey && fs.existsSync(authPath) ? fs.readFileSync(authPath, "utf8") : null;
  if (channel.apiKey && !record.auth) record.auth = { existed: previousAuth !== null, content: previousAuth };

  let text = fs.existsSync(userConfigPath) ? fs.readFileSync(userConfigPath, "utf8") : "";
  if (!record.modelProvider) {
    const head = topLevelHead(text);
    record.modelProvider = {
      existed: /^[ \t]*model_provider[ \t]*=/m.test(head),
      value: modelProviderFromToml(text),
    };
  }
  if (!record.globalKeys || typeof record.globalKeys !== "object") record.globalKeys = {};
  const defaultModel = channelDefaultModel(text, channel, knownModels);
  const globalKeys = defaultModel
    ? [...GLOBAL_KEYS, { name: "model", value: tomlString(defaultModel) }]
    : GLOBAL_KEYS;
  const prepend = [];
  for (const { name, value } of globalKeys) {
    const match = topLevelLinePattern(name).exec(topLevelHead(text));
    if (!(name in record.globalKeys)) {
      // 原来没有就记 null，还原时把这一行删掉，别凭空留一个用户没写过的键。
      record.globalKeys[name] = match ? match[0].replace(/\r?\n$/, "") : null;
    }
    if (match) text = setTopLevelLine(text, name, `${name} = ${value}`);
    else prepend.push(`${name} = ${value}`);
  }
  // 缺的键一起补在最前面，不然一个个插在开头会让它们在文件里倒过来。
  if (prepend.length) {
    const head = topLevelHead(text);
    text = `${prepend.join("\n")}\n${head.replace(/^\n+/, "")}${text.slice(head.length)}`;
  }
  for (const id of providerIdsToRepoint({ channel, channelIds, record })) {
    if (!record.tablesAdded.includes(id)) {
      const span = providerSpan(text, id);
      if (span) {
        // 用户自己的 provider 段（升级时导入的就是这种）先留一份原文，还原时原样放回去。
        if (!record.tablesOriginal[id]) record.tablesOriginal[id] = text.slice(span.start, span.end);
      } else {
        record.tablesAdded.push(id);
      }
    }
    text = replaceProviderTable(text, id, buildProviderBlock(channel, id, proxyUrl || channel.baseUrl));
  }
  record.appliedId = channel.id;
  // 备份先落盘再动 auth.json 和 config.toml：中间崩掉也还留得住还原信息。
  atomicWrite(recordPath, `${JSON.stringify(record, null, 2)}\n`);

  if (channel.apiKey) {
    let data = {};
    if (previousAuth) {
      try {
        const parsed = JSON.parse(previousAuth);
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) data = parsed;
      } catch {
        // auth.json 坏掉时按空对象重建，原文已存在 record 里可以还原。
      }
    }
    data[AUTH_KEY] = channel.apiKey;
    atomicWrite(authPath, `${JSON.stringify(data, null, 2)}\n`);
  }

  atomicWrite(userConfigPath, setModelProvider(text, channel.id));
  return { id: channel.id, baseUrl: channel.baseUrl, keyWritten: Boolean(channel.apiKey) };
};

/// 清空：把 config.toml 和 auth.json 恢复到插件第一次写入之前的样子。
export const restoreCodexConfig = ({ authPath, userConfigPath, recordPath }) => {
  const record = readRecord(recordPath);
  if (!record) return null;
  if (record.auth) {
    if (record.auth.existed) atomicWrite(authPath, record.auth.content);
    else fs.rmSync(authPath, { force: true });
  }
  if (fs.existsSync(userConfigPath)) {
    let text = fs.readFileSync(userConfigPath, "utf8");
    for (const id of record.tablesAdded ?? []) text = removeProviderTable(text, id);
    for (const [id, block] of Object.entries(record.tablesOriginal ?? {})) {
      // 只把插件现在还占着的那段放回原文；早就不在配置里的段（旧版本留下的备份）不要凭空补回来。
      if (providerSpan(text, id)) text = replaceProviderTable(text, id, block);
    }
    const provider = record.modelProvider;
    text = provider?.existed ? setModelProvider(text, provider.value) : removeModelProvider(text);
    for (const [name, original] of Object.entries(record.globalKeys ?? {})) {
      text = original ? setTopLevelLine(text, name, original) : removeTopLevelLine(text, name);
    }
    atomicWrite(userConfigPath, text);
  }
  fs.rmSync(recordPath, { force: true });
  return { restored: true, tablesRemoved: record.tablesAdded ?? [] };
};

/// 第一次升级：把现有的渠道（config.toml 里的 provider）、密钥和模型列表搬进 ~/.gptswitch。
export const importChannelsFromCodex = ({ userConfigPath, authPath, modelPaths = [] }) => {
  let models = [];
  for (const candidate of modelPaths) {
    try {
      models = validateModels(JSON.parse(fs.readFileSync(candidate, "utf8"))?.models ?? []);
      break;
    } catch {
      // 读不到或格式不对就跳过，继续试下一个。
    }
  }
  let text = "";
  try {
    text = fs.readFileSync(userConfigPath, "utf8");
  } catch {
    text = "";
  }
  const providerId = modelProviderFromToml(text);
  const table = providerId ? readProviderTable(text, providerId) : null;
  const apiKey = readAuthKey(authPath) ?? "";
  const header = table?.http_headers && typeof table.http_headers === "object"
    ? Object.entries(table.http_headers)[0]
    : null;
  if (!table && !models.length && !apiKey) return { channels: [], current: null };
  const id = providerId && ID_PATTERN.test(providerId) ? providerId : "default";
  return {
    channels: [{
      id,
      name: typeof table?.name === "string" && table.name.trim() ? table.name.trim() : id,
      baseUrl: typeof table?.base_url === "string" ? table.base_url.trim() : "",
      apiKey,
      headerName: header?.[0] ?? "",
      headerValue: header?.[1] ?? "",
      models,
    }],
    current: id,
  };
};

/// 老版本里改渠道 ID 会把 channels.json 的 current 弄丢（编辑不该动「使用中」）：config.toml 里那次切换还记得
/// 是谁写的（记录里的 appliedId），只要它还指着我们写进去的那段，就按 ID 或地址认回是哪条渠道。
const adoptRenamedCurrent = (state, options = {}) => {
  if (state.current || !state.channels.length || !options.userConfigPath || !options.recordPath) return null;
  const record = readRecord(options.recordPath);
  const applied = typeof record?.appliedId === "string" ? record.appliedId : "";
  if (!applied) return null;
  let text = "";
  try {
    text = fs.readFileSync(options.userConfigPath, "utf8");
  } catch {
    return null;
  }
  if (modelProviderFromToml(text) !== applied) return null;
  if (state.channels.some((channel) => channel.id === applied)) return applied;
  const baseUrl = readProviderTable(text, applied)?.base_url;
  const matches = typeof baseUrl === "string" && baseUrl.trim()
    ? state.channels.filter((channel) => channel.baseUrl === baseUrl.trim())
    : [];
  return matches.length === 1 ? matches[0].id : null;
};

/// 没有渠道配置时：先看能不能从现有 Codex 配置导入，导不出来就开机空列表。
export const loadChannelState = (configPath, importOptions) => {
  if (fs.existsSync(configPath)) {
    const state = readChannelState(configPath);
    const adopted = adoptRenamedCurrent(state, importOptions);
    return adopted ? writeChannelState(configPath, { channels: state.channels, current: adopted }) : state;
  }
  try {
    const imported = importChannelsFromCodex(importOptions);
    if (imported.channels.length) return writeChannelState(configPath, imported);
    return imported;
  } catch {
    // 现有 Codex 配置里有本插件收不下的值（超长的请求头等）时先当空列表用，别让面板打不开。
    return { channels: [], current: null };
  }
};

/// 面板送来的是输入框原文（可能带首尾空格），而落盘前会 trim 成合法的渠道 ID：
/// 这里按 trim 后的值比，改 ID 之后「运行中」那条才不会掉。
const keepCurrent = (channels, requested, previous) => {
  const find = (value) => channels.find((channel) => channel.id === (typeof value === "string" ? value.trim() : value));
  return find(requested)?.id ?? find(previous)?.id ?? null;
};

const positiveInt = (...candidates) => {
  for (const candidate of candidates) {
    if (typeof candidate === "number" && Number.isInteger(candidate) && candidate > 0) return candidate;
  }
  return undefined;
};

const firstText = (...candidates) => {
  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate.trim()) return candidate.trim();
  }
  return undefined;
};

/// 只有对象才是模型条目：数组里的 null 和 models 对象里的裸属性都不是。
const isListingEntry = (entry) => entry !== null && typeof entry === "object" && !Array.isArray(entry);

/// 端点公布的模型目录：标准 `data` 数组优先，部分网关改用富信息的 `models` 对象。
/// 对象里属性名才是请求要用的路由名，嵌套 id 只作兜底；条目不能用的行直接跳过。
const readModelListing = (body) => {
  const listing = body ?? {};
  let rows;
  if (Array.isArray(listing.data)) {
    rows = listing.data.filter(isListingEntry).map((entry) => ({ key: undefined, entry }));
  } else if (listing.models && typeof listing.models === "object" && !Array.isArray(listing.models)) {
    rows = Object.entries(listing.models)
      .filter(([, entry]) => isListingEntry(entry))
      .map(([key, entry]) => ({ key, entry }));
  } else {
    throw new Error("返回内容里既没有 data 数组也没有 models 对象");
  }
  const seen = new Set();
  const models = [];
  for (const { key, entry } of rows) {
    if (models.length >= MAX_DISCOVERED_MODELS) break;
    const id = firstText(key, entry.id);
    if (!id || id.length > MAX_LABEL_LENGTH || hasControlChars(id) || seen.has(id)) continue;
    seen.add(id);
    // 面板按同一套规则校验显示名，先筛掉存不进去的值，别让保存时才报错。端点没给名字就留空，
    // 空名字在保存时由 validateModels 统一落成模型 ID。
    const name = firstText(entry.name, entry.display_name, entry.displayName);
    const displayName = name && name.length <= MAX_LABEL_LENGTH && !hasControlChars(name) ? name : undefined;
    // 面板里的窗口单位是 k，端点给的是 token；1 到 10000k 之外的值按边界夹住。
    const tokens = positiveInt(entry.contextWindow, entry.context_window, entry.context_length,
      entry.max_input_tokens, entry.limit?.context);
    models.push({
      id,
      ...(displayName ? { displayName } : {}),
      ...(tokens ? { context: Math.min(10_000, Math.max(1, Math.round(tokens / 1000))) } : {}),
    });
  }
  return models;
};

/// 端点是自己填的地址：先看声明的长度，再按实际读到的字节数掐上限，别由着它把内存吃满。
const readBoundedText = async (response, url) => {
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > MAX_LISTING_BYTES) throw new Error(`${url} 返回的内容超过 8MB`);
  if (!response.body) return "";
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let text = "";
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_LISTING_BYTES) {
      await reader.cancel().catch(() => {});
      throw new Error(`${url} 返回的内容超过 8MB`);
    }
    text += decoder.decode(value, { stream: true });
  }
  return text + decoder.decode();
};

/// 问渠道端点要它公布的模型：OpenAI 兼容的 `GET {地址}/models`，密钥走 Bearer。
export const discoverChannelModels = async (request = {}) => {
  const baseUrl = String(request.baseUrl ?? "").trim();
  if (!baseUrl) throw new Error("请先填渠道地址，再获取可用模型");
  if (!/^https?:\/\//i.test(baseUrl)) throw new Error("渠道地址必须以 http:// 或 https:// 开头");
  const url = `${baseUrl.replace(/\/+$/, "")}/models`;
  const headers = { accept: "application/json" };
  const headerName = String(request.headerName ?? "").trim();
  if (headerName) headers[headerName] = String(request.headerValue ?? "");
  const apiKey = String(request.apiKey ?? "").trim();
  if (apiKey) headers.authorization = `Bearer ${apiKey}`;
  let response;
  try {
    response = await fetch(url, { headers, signal: AbortSignal.timeout(MODEL_LIST_TIMEOUT_MS) });
  } catch {
    throw new Error(`连不上 ${url}`);
  }
  if (!response.ok) {
    const hint = response.status === 401 || response.status === 403 ? "，检查 API 密钥" : "";
    throw new Error(`${url} 返回 ${response.status}${hint}`);
  }
  const text = await readBoundedText(response, url);
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    // New API 这类中转的模型接口在 /v1/models，只填站点根地址会拿回首页 HTML。
    const hint = /^\s*</.test(text) ? "，这个地址返回的是网页；中转站一般要带上 /v1" : "";
    throw new Error(`${url} 返回的不是 JSON${hint}`);
  }
  const models = readModelListing(body);
  if (models.length === 0) throw new Error("端点没有公布任何模型，请手动添加");
  return models;
};

/// 面板协议：load 读渠道和代理设置，save 只落盘，switch 落盘后写 Codex 配置并重启，
/// clear 把 Codex 侧还原（渠道列表保留）。
export const handlePanelRequest = async (request, {
  configPath, proxyConfigPath, importOptions, applyCodex, restoreCodex, applyCatalog, clearCatalog, restart,
}) => {
  let savedState = null;
  let cleared = false;
  let restored = false;
  try {
    if (request?.action === "load") {
      const state = loadChannelState(configPath, importOptions);
      return { ok: true, ...state, proxy: readProxySettings(proxyConfigPath) };
    }
    if (request?.action === "list-models") {
      return { ok: true, models: await discoverChannelModels(request) };
    }
    if (request?.action === "clear") {
      if (restoreCodex) {
        await restoreCodex();
        restored = true;
      }
      if (clearCatalog) await clearCatalog();
      cleared = true;
      let kept = { channels: [], current: null };
      try {
        const existing = readChannelState(configPath);
        kept = writeChannelState(configPath, { channels: existing.channels, current: null });
      } catch {
        // 还没有渠道文件时只清 Codex 侧。
      }
      if (restart) await restart();
      return { ok: true, cleared: true, restarted: true, channels: kept.channels, current: null };
    }
    if (request?.action !== "save" && request?.action !== "switch") throw new Error("无效的面板操作");
    if (typeof request.restart !== "boolean") throw new Error("无效的面板操作");
    if (request?.action === "save" && request?.scope === "proxy") {
      if (!proxyConfigPath) throw new Error("代理配置路径未初始化");
      const proxy = validateProxySettings(request.proxy);
      writeProxySettings(proxyConfigPath, proxy);
      // 保存只落盘；服务和 Codex 地址等右上角「重启 ChatGPT」时一起切换。
      return { ok: true, saved: true, proxy, restartNeeded: true };
    }
    const channels = validateChannels(request.channels ?? []);
    let previous = null;
    try {
      previous = readChannelState(configPath).current;
    } catch {
      previous = null;
    }
    let current = keepCurrent(channels, request.current, previous);
    const enabledChannels = channels.filter((channel) => channel.enabled !== false);
    // 当前这条被禁用或删掉时换成第一条启用的：留着它会让选择器一个裸模型名都没有，
    // 旧会话的裸名请求也会被转发层丢给别的渠道。本来就没有当前渠道（还没应用/刚还原）时不动。
    if (current && !enabledChannels.some((channel) => channel.id === current)) {
      current = enabledChannels[0]?.id ?? current;
    }
    if (request.action === "switch") {
      // 「重启」是把整份配置和全部启用渠道的模型重新写一遍，不针对某一条渠道：优先沿用当前这条，
      // 它被禁用了或者面板没给认得出的渠道时，换成第一条启用的。
      current = (enabledChannels.find((channel) => channel.id === current) ?? enabledChannels[0] ?? channels[0])?.id ?? null;
    }
    savedState = writeChannelState(configPath, { channels, current });
    if (request.action === "save") {
      return { ok: true, saved: true, channels: savedState.channels, current: savedState.current };
    }
    const active = savedState.channels.find((channel) => channel.id === savedState.current);
    // 代理配置与新渠道配置一起生效：先检查代理，再启动新服务，最后才写 Codex 地址。
    const proxy = request.action === "switch" && proxyConfigPath
      ? validateProxySettings(readProxySettings(proxyConfigPath))
      : null;
    if (active && applyCodex) await applyCodex(active, savedState.channels.map((item) => item.id));
    if (active && applyCatalog) await applyCatalog(active.models);
    if (request.restart && restart) await restart();
    return {
      ok: true, saved: true, restarted: request.restart,
      channels: savedState.channels, current: savedState.current, proxy,
    };
  } catch (error) {
    const prefix = restored ? "Codex 配置已还原，但清理或重启失败："
      : cleared ? "配置已清空，但重启失败："
        : savedState ? "配置已保存，但未能生效：" : "";
    return {
      ok: false,
      ...(savedState ? { saved: true, channels: savedState.channels, current: savedState.current } : {}),
      ...(cleared ? { cleared: true } : {}),
      error: `${prefix}${error.message}`,
    };
  }
};
