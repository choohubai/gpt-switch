import http from "node:http";
import https from "node:https";
import net from "node:net";
import tls from "node:tls";

const CONNECT_TIMEOUT_MS = 30_000;
const MAX_REDIRECTS = 3;

/// 本机地址：代理通常代连不到本机，指向自己的还会成环，所以这类目标一律直连。
export const isLoopbackHost = (hostname) => {
  const host = String(hostname || "").replace(/^\[|\]$/g, "").toLowerCase();
  if (host === "localhost" || host.endsWith(".localhost")) return true;
  return host === "::1" || /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host);
};

/// 拼代理地址用的主机名：IPv6 在 URL 里带方括号，连的时候要去掉。
const bareHost = (hostname) => String(hostname || "").replace(/^\[|\]$/g, "");

/// 出站代理：没填就是直连。用户名密码单独保存，这里才拼成 Basic 头。
export const outboundProxyFrom = (settings) => {
  const value = typeof settings?.outboundProxy === "string" ? settings.outboundProxy.trim() : "";
  if (!value) return null;
  const url = new URL(value);
  const username = typeof settings?.outboundUsername === "string" ? settings.outboundUsername : "";
  const password = typeof settings?.outboundPassword === "string" ? settings.outboundPassword : "";
  return {
    host: bareHost(url.hostname),
    port: Number(url.port) || 80,
    // 凭据只进这个头，日志和错误信息里只出现 host:port。
    authorization: username ? `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}` : "",
  };
};

export const describeProxy = (proxy) => (proxy ? `${proxy.host}:${proxy.port}` : "直连");

/// 通过 HTTP 代理建隧道：代理只看到 host:port，TLS 仍在客户端和渠道之间端到端握手。
/// 证书始终按真实目标校验；IP 不发送 SNI，但仍须传 host，避免默认校验 localhost。
const openTunnel = (proxy, target, signal) => new Promise((resolve, reject) => {
  const port = Number(target.port) || 443;
  const authority = `${target.hostname.includes(":") ? `[${bareHost(target.hostname)}]` : target.hostname}:${port}`;
  const socket = net.connect(proxy.port, proxy.host);
  let settled = false;
  function failed(error) {
    if (settled) return;
    settled = true;
    signal?.removeEventListener("abort", onAbort);
    socket.destroy();
    reject(error);
  }
  // 调用方的超时只会取消请求，取消不到这条还没交出去的 socket，所以这里自己挂上信号。
  function onAbort() {
    failed(signal.reason ?? new Error("请求已取消"));
  }
  signal?.addEventListener("abort", onAbort, { once: true });
  socket.setTimeout(CONNECT_TIMEOUT_MS, () => failed(new Error(`连接代理 ${describeProxy(proxy)} 超时`)));
  socket.once("error", failed);
  const onSocketEnd = () => failed(new Error(`代理 ${describeProxy(proxy)} 在 CONNECT 响应完成前关闭了连接`));
  const onSocketClose = () => failed(new Error(`代理 ${describeProxy(proxy)} 在 CONNECT 响应完成前关闭了连接`));
  socket.once("end", onSocketEnd);
  socket.once("close", onSocketClose);
  socket.once("connect", () => {
    socket.write(`CONNECT ${authority} HTTP/1.1\r\nHost: ${authority}\r\n${
      proxy.authorization ? `Proxy-Authorization: ${proxy.authorization}\r\n` : ""}\r\n`);
    let head = "";
    const onData = (chunk) => {
      head += chunk.toString("latin1");
      const end = head.indexOf("\r\n\r\n");
      if (end < 0) {
        if (head.length > 8192) failed(new Error(`代理 ${describeProxy(proxy)} 返回了异常的 CONNECT 响应`));
        return;
      }
      socket.off("data", onData);
      socket.setTimeout(0);
      const status = Number(/^HTTP\/1\.[01] (\d{3})/.exec(head)?.[1]);
      if (status !== 200) {
        const hint = status === 407 ? "，检查用户名和密码" : "";
        failed(new Error(`代理 ${describeProxy(proxy)} 拒绝了 ${authority}（HTTP ${status || "?"}${hint}）`));
        return;
      }
      socket.off("end", onSocketEnd);
      socket.off("close", onSocketClose);
      const secure = tls.connect({
        socket,
        host: bareHost(target.hostname),
        servername: net.isIP(bareHost(target.hostname)) ? undefined : bareHost(target.hostname),
      });
      secure.once("error", failed);
      secure.once("close", () => {
        if (!settled) failed(new Error(`代理 ${describeProxy(proxy)} 在 TLS 握手完成前关闭了 ${authority} 的隧道`));
      });
      // CONNECT 通过后隧道已交给 TLS：握手也不该无限等下去。
      secure.setTimeout(CONNECT_TIMEOUT_MS, () => failed(new Error(`与 ${authority} 握手超时`)));
      secure.once("secureConnect", () => {
        settled = true;
        secure.setTimeout(0);
        socket.off("error", failed);
        signal?.removeEventListener("abort", onAbort);
        resolve(secure);
      });
    };
    socket.on("data", onData);
  });
});

/// 发往目标的请求：配了出站代理就走代理，本机目标始终直连。
/// https 目标先走 CONNECT 隧道再交给 https.request；http 目标按代理协议带完整 URL 发出。
export const openRequest = async (target, options, proxy, signal) => {
  const transport = target.protocol === "https:" ? https : http;
  if (!proxy || isLoopbackHost(target.hostname)) return transport.request(target, { ...options, signal });
  if (target.protocol === "http:") {
    return http.request({
      host: proxy.host,
      port: proxy.port,
      method: options.method,
      path: target.href,
      agent: false,
      signal,
      headers: {
        ...options.headers,
        host: target.host,
        ...(proxy.authorization ? { "proxy-authorization": proxy.authorization } : {}),
      },
    });
  }
  if (target.protocol !== "https:") throw new Error(`不支持的渠道协议：${target.protocol}`);
  // 先把隧道握完再发请求：请求一建立就握着真 socket，超时才能真的把它掐掉。
  const secure = await openTunnel(proxy, target, signal);
  const agent = new https.Agent({ keepAlive: false });
  agent.createConnection = () => secure;
  return https.request(target, { ...options, agent, signal });
};

const tooLarge = (url, maxBytes) => new Error(`${url} 返回的内容超过 ${Math.round(maxBytes / 1048576)}MB`);

/// 一次性请求：读完整份响应体。用于检查更新、模型目录这类小请求，不参与转发流量。
/// 重定向地址解析失败也交回调用方处理，不能从响应事件里抛出而结束整个进程。
/// 每跳只分配剩余时间，建隧道、重定向和读取响应体共用调用方的总超时预算。
export const requestText = async (url, {
  method = "GET",
  headers = {},
  timeoutMs = 5000,
  maxBytes = 8 * 1024 * 1024,
  proxy = null,
  redirects = MAX_REDIRECTS,
} = {}) => {
  const target = new URL(url);
  const deadline = performance.now() + timeoutMs;
  const timeoutError = new Error(`请求 ${url} 超时`);
  if (timeoutMs <= 0) throw timeoutError;
  const controller = new AbortController();
  let request = null;
  const timer = setTimeout(() => {
    controller.abort(timeoutError);
    request?.destroy(timeoutError);
  }, timeoutMs);
  try {
    request = await openRequest(target, { method, headers }, proxy, controller.signal);
  } catch (error) {
    clearTimeout(timer);
    throw error;
  }
  return new Promise((resolve, reject) => {
    const settle = (done, value) => {
      clearTimeout(timer);
      done(value);
    };
    request.on("error", (error) => settle(reject, controller.signal.aborted ? timeoutError : error));
    request.on("response", (response) => {
      const status = response.statusCode || 0;
      if (redirects > 0 && [301, 302, 303, 307, 308].includes(status) && response.headers.location) {
        let next;
        try {
          next = new URL(response.headers.location, url);
        } catch (error) {
          response.destroy();
          settle(reject, error);
          return;
        }
        response.resume();
        // 跳到别的站点就不再带凭据：渠道密钥和自定义头不能跟着重定向跑到别的域。
        const forwarded = next.origin === target.origin
          ? headers
          : Object.fromEntries(Object.entries(headers)
            .filter(([name]) => ["accept", "user-agent"].includes(name.toLowerCase())));
        settle(resolve, requestText(next.href, {
          method: status === 303 ? "GET" : method,
          headers: forwarded, timeoutMs: deadline - performance.now(), maxBytes, proxy, redirects: redirects - 1,
        }));
        return;
      }
      if (Number(response.headers["content-length"]) > maxBytes) {
        response.resume();
        request.destroy();
        settle(reject, tooLarge(url, maxBytes));
        return;
      }
      const chunks = [];
      let total = 0;
      response.on("data", (chunk) => {
        total += chunk.length;
        if (total > maxBytes) {
          request.destroy(tooLarge(url, maxBytes));
          return;
        }
        chunks.push(chunk);
      });
      response.on("error", (error) => settle(reject, error));
      response.on("end", () => settle(resolve, {
        status,
        ok: status >= 200 && status < 300,
        headers: response.headers,
        text: Buffer.concat(chunks).toString("utf8"),
      }));
    });
    request.end();
  });
};
