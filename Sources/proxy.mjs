import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import { atomicWrite } from "./model-config.mjs";
import {
  writeProxySettings, recordedProxyAddress, repointProxyUrl,
} from "./channel-config.mjs";

/// 模型 id 里带上渠道身份：客户端只会把 id 原样发回来，转发层据此把请求送回原来那家。
/// 渠道 id 只允许字母数字和 -_，不需要转义。
export const MODEL_PREFIX = "gpts-";

export const proxyModelId = (channelId, upstreamModel) => `${MODEL_PREFIX}${channelId}/${upstreamModel}`;

export const parseProxyModelId = (model) => {
  if (typeof model !== "string" || !model.startsWith(MODEL_PREFIX)) return null;
  const rest = model.slice(MODEL_PREFIX.length);
  const slash = rest.indexOf("/");
  if (slash <= 0 || slash === rest.length - 1) return null;
  return { channelId: rest.slice(0, slash), upstreamModel: rest.slice(slash + 1) };
};

/// 选择器和模型目录里要出现的全部模型。
///
/// ID：当前渠道保持裸名（老会话的裸名请求、自动压缩带的模型名、`config.toml` 顶层的 `model`
/// 都归它），其他渠道带 `gpts-<渠道>/<模型>` 前缀，请求靠它转回原来那家。
///
/// 显示名：每个渠道都带「（渠道）」，当前渠道也一样——客户端把模型目录里的显示名原样贴到
/// 输入框上，只给非当前渠道加后缀，就会出现同一个模型换个渠道选、有时候带名字有时候不带。
/// 后缀只给分组表头认归属，选择器列表里那一行会换成裸名。
export const pickerModelsFromState = (state) => {
  const channels = Array.isArray(state?.channels) ? state.channels : [];
  return channels.filter(isEnabled).flatMap((channel) => {
    const label = channel?.name || channel?.id || "";
    const isCurrent = channel?.id === state?.current;
    return (channel?.models ?? []).map((model) => ({
      context: model.context,
      inputModalities: model.inputModalities,
      id: isCurrent ? model.id : proxyModelId(channel.id, model.id),
      displayName: label ? `${model.displayName || model.id}（${label}）` : (model.displayName || model.id),
    }));
  });
};

/// 当前渠道的名字：裸名行（老会话/自动压缩里的模型名）兜底归给它。
export const pickerGroupNameFromState = (state) => {
  const current = (Array.isArray(state?.channels) ? state.channels : [])
    .find((channel) => channel?.id === state?.current);
  return current ? current.name || current.id : "";
};

/// 选择器分组表头会用到的全部渠道名。客户端那边只能从展示名尾部的 `（渠道名）` 认归属，
/// 把这份清单一起注入进去，才不至于把「GLM-4.6 (Thinking)」这种自带括号的模型名认成渠道。
export const pickerChannelNamesFromState = (state) => {
  const names = [];
  for (const channel of (Array.isArray(state?.channels) ? state.channels : []).filter(isEnabled)) {
    const name = channel?.name || channel?.id;
    if (typeof name === "string" && name && !names.includes(name)) names.push(name);
  }
  return names;
};

/// 渠道自己的启用开关：只有面板里填了 enabled: false 才算禁用。
const isEnabled = (channel) => channel?.enabled !== false;

/// 这次请求该转给哪个渠道。带前缀的按前缀精确归因；裸名（老会话、自动压缩带的模型名）
/// 交给当前渠道，按请求里的 id 原样转发，不改派到别的渠道。
export const resolveRoute = (model, state) => {
  const channels = Array.isArray(state?.channels) ? state.channels : [];
  const parsed = parseProxyModelId(model);
  if (parsed) {
    const channel = channels.find((item) => item?.id === parsed.channelId);
    if (!channel) {
      return { error: `模型「${model}」所属的渠道「${parsed.channelId}」已经不存在，请到面板里重新选一个模型` };
    }
    if (!isEnabled(channel)) {
      return { error: `渠道「${channel.name || channel.id}」已经禁用，请到面板里启用它再选这个模型` };
    }
    if (!channel.baseUrl) {
      return { error: `渠道「${channel.name || channel.id}」没有填 API 地址，请到面板里补上` };
    }
    return { channel, upstreamModel: parsed.upstreamModel };
  }
  const usable = channels.filter(isEnabled);
  const fallback = usable.find((item) => item?.id === state?.current) || usable[0];
  if (!fallback) return { error: "面板里还没有启用的渠道" };
  if (!fallback.baseUrl) {
    return { error: `渠道「${fallback.name || fallback.id}」没有填 API 地址，请到面板里补上` };
  }
  return { channel: fallback, upstreamModel: model };
};

/// 客户端拿到的 base_url 是 http://127.0.0.1:<port>/v1，所以这里收到的是 /v1/responses 这类路径；
/// 渠道地址自带 /v1（或 /api-proxy/v1）之类的段，拼的时候把前导 /v1 去掉再接到渠道地址后面。
export const upstreamUrl = (baseUrl, requestUrl) => {
  let base;
  try {
    base = new URL(baseUrl);
  } catch {
    return null;
  }
  let incoming;
  try {
    // 只拿它当解析相对路径的底座，不会真的连过去。
    incoming = new URL(requestUrl || "/", "http://127.0.0.1");
  } catch {
    return null;
  }
  const tail = incoming.pathname.replace(/^\/v1(?=\/|$)/, "");
  const basePath = base.pathname.replace(/\/+$/, "");
  return new URL(`${basePath}${tail.startsWith("/") ? tail : `/${tail}`}${incoming.search}`, base);
};

/// 转发用的请求头：客户端带来的 authorization 一律丢掉，换成这个渠道自己的密钥；
/// 渠道配了自定义请求头的话，客户端那份同名头也先删掉再写，免得两份打架。
export const buildUpstreamHeaders = (incoming, channel) => {
  const headers = {};
  const customName = channel.headerName ? String(channel.headerName).toLowerCase() : "";
  for (const [name, value] of Object.entries(incoming || {})) {
    if (value === undefined) continue;
    const key = name.toLowerCase();
    // transfer-encoding 必须跟着 content-length 一起丢：两个头同时出现是非法请求，上游会直接回 400。
    if (key === "host" || key === "authorization" || key === "content-length" || key === "connection"
      || key === "transfer-encoding") continue;
    if (customName && key === customName) continue;
    headers[name] = value;
  }
  if (channel.apiKey) headers.authorization = `Bearer ${channel.apiKey}`;
  if (channel.headerName && channel.headerValue) headers[channel.headerName] = channel.headerValue;
  return headers;
};

const RESPONSE_HEADERS_TO_DROP = new Set(["connection", "transfer-encoding", "keep-alive", "content-length"]);

const sendError = (res, status, message) => {
  const body = JSON.stringify({ error: { message, type: "gpt_switch_proxy_error" } });
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "content-length": Buffer.byteLength(body) });
  res.end(body);
};

const readBody = (req) => new Promise((resolve, reject) => {
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => resolve(Buffer.concat(chunks)));
  req.on("error", reject);
});

/// 本地转发服务：客户端所有模型流量都进这里，按模型 id 选渠道再原样透传（含流式响应）。
export const createProxyServer = ({ loadState, log = () => {}, name = "proxy" }) => {
  const server = http.createServer(async (req, res) => {
    let raw;
    try {
      raw = await readBody(req);
    } catch (error) {
      sendError(res, 400, `读取请求失败：${String(error?.message || error)}`);
      return;
    }
    let body = null;
    if (raw.length) {
      try {
        body = JSON.parse(raw.toString("utf8"));
      } catch {
        body = null;
      }
    }
    const model = typeof body?.model === "string" ? body.model.trim() : "";
    let state;
    try {
      state = loadState();
    } catch (error) {
      // 渠道文件坏掉时只让这一个请求失败：抛出去会变成未处理的 rejection，把整个插件进程带走。
      log("proxy_state_failed", { path: req.url, error: String(error?.message || error) });
      sendError(res, 503, `读不到渠道列表：${String(error?.message || error)}。请到面板里检查渠道配置`);
      return;
    }
    const route = resolveRoute(model, state);
    if (route.error) {
      log("proxy_rejected", { path: req.url, model, error: route.error });
      sendError(res, 400, route.error);
      return;
    }
    const target = upstreamUrl(route.channel.baseUrl, req.url);
    if (!target) {
      log("proxy_rejected", { path: req.url, model, error: "渠道地址不合法" });
      sendError(res, 400, `渠道「${route.channel.name || route.channel.id}」的地址不是合法的 http(s) 地址`);
      return;
    }
    let payload = raw;
    if (body && model && route.upstreamModel !== model) {
      body.model = route.upstreamModel;
      payload = Buffer.from(JSON.stringify(body));
    }
    const headers = buildUpstreamHeaders(req.headers, route.channel);
    headers["content-length"] = String(payload.length);
    const transport = target.protocol === "https:" ? https : http;
    const upstream = transport.request(target, { method: req.method, headers }, (upstreamRes) => {
      const outHeaders = {};
      for (const [key, value] of Object.entries(upstreamRes.headers)) {
        if (value === undefined || RESPONSE_HEADERS_TO_DROP.has(key.toLowerCase())) continue;
        outHeaders[key] = value;
      }
      res.writeHead(upstreamRes.statusCode || 502, outHeaders);
      upstreamRes.pipe(res);
    });
    upstream.on("error", (error) => {
      log("proxy_upstream_failed", {
        path: req.url, model, channel: route.channel.id, target: target.origin, error: String(error?.message || error),
      });
      if (!res.headersSent) sendError(res, 502, `连不上渠道「${route.channel.name || route.channel.id}」：${String(error?.message || error)}`);
      else res.destroy();
    });
    res.on("close", () => upstream.destroy());
    log("proxy_routed", { path: req.url, model, channel: route.channel.id, upstream: route.upstreamModel, target: target.origin });
    upstream.end(payload);
  });
  server.on("error", (error) => log("proxy_failed", String(error?.message || error)));
  return server;
};

export const DEFAULT_PROXY_PORT = Number(process.env.GPT_SWITCH_PROXY_PORT) || 47123;
export const DEFAULT_PROXY_HOST = "127.0.0.1";
export const MAX_PROXY_PORT = 65535;

export const proxyBaseUrl = (port, host = DEFAULT_PROXY_HOST) => `http://${host}:${port}/v1`;

/// 代理切换和 ChatGPT 重启绑定：新服务先就绪，客户端重启成功后才释放旧服务。
/// 地址或重启失败时恢复旧文件，避免留下指向未启动代理的半成品。
export const switchProxyAndRestart = async ({
  settings, currentServer, currentHost, currentPort, restartClient,
  updateCodex = async () => false,
  loadState = () => ({ channels: [], current: null }),
  log = () => {}, proxyConfigPath, userConfigPath, recordPath,
}) => {
  if (settings.host === currentHost && settings.port === currentPort) {
    await restartClient();
    return {
      server: currentServer, host: currentHost, port: currentPort, repointed: false,
      previousHost: currentHost, previousPort: currentPort,
    };
  }
  const configExisted = fs.existsSync(proxyConfigPath);
  const configText = configExisted ? fs.readFileSync(proxyConfigPath, "utf8") : null;
  const codexExisted = fs.existsSync(userConfigPath);
  const codexText = codexExisted ? fs.readFileSync(userConfigPath, "utf8") : null;
  const started = await startProxy({ loadState, log, host: settings.host, port: settings.port });
  try {
    const actual = { host: started.host, port: started.port };
    if (started.port !== settings.port) writeProxySettings(proxyConfigPath, actual);
    const repointed = recordedProxyAddress({ userConfigPath, recordPath })
      ? repointProxyUrl({ userConfigPath, recordPath, baseUrl: started.baseUrl })
      : false;
    await updateCodex(started.baseUrl);
    await restartClient();
    await closeProxyServer(currentServer);
    log("proxy_switched", { ...actual, repointed });
    return {
      server: started.server, host: actual.host, port: actual.port, repointed,
      previousHost: currentHost, previousPort: currentPort,
    };
  } catch (error) {
    try { started.server.close(); } catch {}
    try {
      if (configExisted) atomicWrite(proxyConfigPath, configText);
      else fs.rmSync(proxyConfigPath, { force: true });
      if (codexExisted && codexText !== null) atomicWrite(userConfigPath, codexText);
      else if (!codexExisted) fs.rmSync(userConfigPath, { force: true });
    } catch (restoreError) {
      log("proxy_switch_rollback_failed", String(restoreError?.message || restoreError));
    }
    throw error;
  }
};

/// 等待旧代理真正释放端口；重启后的客户端不会因为换端口而撞上旧监听。
const closeProxyServer = (server) => new Promise((resolve) => {
  if (!server) {
    resolve();
    return;
  }
  server.close(() => resolve());
});

/// 代理会把渠道密钥替换进请求；默认只监听回环地址，用户明确改成局域网 IP 时自行承担暴露风险。
/// 面板先校验配置，这里只负责在指定地址上启动监听。

/// 指定端口被占用时向后找可用端口；调用方要把实际端口写回配置，Codex 才能继续对上。
export const startProxy = ({
  loadState, log, host = DEFAULT_PROXY_HOST, port = DEFAULT_PROXY_PORT, attempts = 10,
}) => new Promise((resolve, reject) => {
  const tryListen = (candidate, remaining) => {
    const server = createProxyServer({ loadState, log });
    server.once("error", (error) => {
      if (error?.code === "EADDRINUSE" && candidate < MAX_PROXY_PORT && remaining > 0) {
        tryListen(candidate + 1, remaining - 1);
      } else {
        reject(error);
      }
    });
    server.listen(candidate, host, () => {
      const address = server.address();
      const actualPort = typeof address === "object" && address ? address.port : candidate;
      const actualHost = typeof address === "object" && address ? address.address : host;
      log("proxy_started", { host: actualHost, port: actualPort });
      resolve({
        server, host: actualHost, port: actualPort,
        baseUrl: proxyBaseUrl(actualPort, actualHost),
        requestedPort: port,
      });
    });
  };
  tryListen(port, attempts);
});

const readChannelsFile = (filePath) => {
  const parsed = JSON.parse(fs.readFileSync(filePath, "utf8"));
  return { channels: parsed?.channels ?? [], current: parsed?.current ?? null };
};

const isMain = process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href;
if (isMain) {
  const option = (flag, fallback) => {
    const index = process.argv.indexOf(flag);
    return index >= 0 ? process.argv[index + 1] : fallback;
  };
  const statePath = option("--state", `${process.env.HOME}/.gptswitch/channels.json`);
  const host = option("--host", DEFAULT_PROXY_HOST);
  const port = Number(option("--port", DEFAULT_PROXY_PORT));
  const started = await startProxy({
    loadState: () => readChannelsFile(statePath),
    log: (message, detail) => process.stderr.write(`${message} ${detail ? JSON.stringify(detail) : ""}\n`),
    host,
    port,
  });
  process.stderr.write(`proxy listening on ${started.baseUrl}\n`);
}
