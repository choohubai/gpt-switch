import fs from "node:fs";
import { atomicWrite, validateModels } from "./model-config.mjs";

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
const MODEL_PROVIDER_ANY_LINE = /^[ \t]*model_provider[ \t]*=[^\n]*\n?/m;
const AUTH_KEY = "OPENAI_API_KEY";

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
      models: validateModels(channel?.models ?? []),
    };
  });
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

export const buildProviderBlock = (channel) => {
  const lines = [
    `[model_providers.${channel.id}]`,
    `name = ${tomlString(channel.name || channel.id)}`,
    `base_url = ${tomlString(channel.baseUrl)}`,
    'wire_api = "responses"',
    "requires_openai_auth = true",
  ];
  if (channel.headerName && channel.headerValue) {
    lines.push(`http_headers = { ${tomlString(channel.headerName)} = ${tomlString(channel.headerValue)} }`);
  }
  return `${lines.join("\n")}\n`;
};

const replaceProviderTable = (text, id, block) => {
  const span = providerSpan(text, id);
  if (!span) {
    const trimmed = text.replace(/\s+$/, "");
    return trimmed ? `${trimmed}\n\n${block}` : block;
  }
  return `${text.slice(0, span.start)}${block}${text.slice(span.end)}`;
};

export const upsertProviderTable = (text, channel) =>
  replaceProviderTable(text, channel.id, buildProviderBlock(channel));

export const removeProviderTable = (text, id) => {
  const span = providerSpan(text, id);
  if (!span) return text;
  const cut = `${text.slice(0, span.start)}${text.slice(span.end)}`;
  return span.end === text.length ? cut.replace(/\s+$/, "\n") : cut;
};

export const setModelProvider = (text, id) => {
  const head = topLevelHead(text);
  const tail = text.slice(head.length);
  const line = `model_provider = ${tomlString(id)}\n`;
  if (/^[ \t]*model_provider[ \t]*=/m.test(head)) {
    return `${head.replace(MODEL_PROVIDER_ANY_LINE, line)}${tail}`;
  }
  return `${line}${head.replace(/^\n+/, "")}${tail}`;
};

export const removeModelProvider = (text) => {
  const head = topLevelHead(text);
  return `${head.replace(MODEL_PROVIDER_ANY_LINE, "")}${text.slice(head.length)}`;
};

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

/// 切换渠道：密钥进 auth.json，地址和 provider 段进 config.toml，原值记下来供还原。
export const applyChannelToCodex = ({ channel, authPath, userConfigPath, recordPath }) => {
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
  // Provider ID 改名后把上一次切换写进去的那段删掉，避免 config.toml 里留两份。
  if (record.appliedId && record.appliedId !== channel.id && record.tablesAdded.includes(record.appliedId)) {
    text = removeProviderTable(text, record.appliedId);
    record.tablesAdded = record.tablesAdded.filter((id) => id !== record.appliedId);
  }
  record.appliedId = channel.id;
  const span = providerSpan(text, channel.id);
  if (span) {
    // 用户自己的 provider 段（升级时导入的就是这种）先留一份原文，还原时原样放回去。
    if (!record.tablesOriginal[channel.id]) record.tablesOriginal[channel.id] = text.slice(span.start, span.end);
  } else if (!record.tablesAdded.includes(channel.id)) {
    record.tablesAdded.push(channel.id);
  }
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

  atomicWrite(userConfigPath, setModelProvider(upsertProviderTable(text, channel), channel.id));
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
      text = replaceProviderTable(text, id, block);
    }
    const provider = record.modelProvider;
    text = provider?.existed ? setModelProvider(text, provider.value) : removeModelProvider(text);
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

/// 没有渠道配置时：先看能不能从现有 Codex 配置导入，导不出来就开机空列表。
export const loadChannelState = (configPath, importOptions) => {
  if (fs.existsSync(configPath)) return readChannelState(configPath);
  try {
    const imported = importChannelsFromCodex(importOptions);
    if (imported.channels.length) return writeChannelState(configPath, imported);
    return imported;
  } catch {
    // 现有 Codex 配置里有本插件收不下的值（超长的请求头等）时先当空列表用，别让面板打不开。
    return { channels: [], current: null };
  }
};

const keepCurrent = (channels, requested, previous) => {
  if (channels.some((channel) => channel.id === requested)) return requested;
  if (channels.some((channel) => channel.id === previous)) return previous;
  return null;
};

/// 面板协议：load 读渠道，save 只落盘，switch 落盘后写 Codex 配置并重启，
/// clear 把 Codex 侧还原（渠道列表保留）。
export const handlePanelRequest = async (request, {
  configPath, importOptions, applyCodex, restoreCodex, applyCatalog, clearCatalog, restart,
}) => {
  let savedState = null;
  let cleared = false;
  let restored = false;
  try {
    if (request?.action === "load") {
      return { ok: true, ...loadChannelState(configPath, importOptions) };
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
      if (restart) await restart([]);
      return { ok: true, cleared: true, restarted: true, channels: kept.channels, current: null };
    }
    if (request?.action !== "save" && request?.action !== "switch") throw new Error("无效的面板操作");
    if (typeof request.restart !== "boolean") throw new Error("无效的面板操作");
    const channels = validateChannels(request.channels ?? []);
    let previous = null;
    try {
      previous = readChannelState(configPath).current;
    } catch {
      previous = null;
    }
    let current = keepCurrent(channels, request.current, previous);
    if (request.action === "switch") {
      if (!channels.some((channel) => channel.id === request.current)) throw new Error("请选择要切换的渠道");
      current = request.current;
    }
    savedState = writeChannelState(configPath, { channels, current });
    if (request.action === "save") {
      return { ok: true, saved: true, channels: savedState.channels, current: savedState.current };
    }
    const active = savedState.channels.find((channel) => channel.id === savedState.current);
    if (applyCodex) await applyCodex(active);
    if (applyCatalog) await applyCatalog(active.models);
    if (request.restart && restart) await restart(active.models);
    return {
      ok: true, saved: true, restarted: request.restart,
      channels: savedState.channels, current: savedState.current,
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
