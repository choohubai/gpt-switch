import assert from "node:assert/strict";
import { execFile, execFileSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import tls from "node:tls";
import { test } from "node:test";
import { promisify } from "node:util";
import { isLoopbackHost, outboundProxyFrom, requestText } from "../Sources/outbound.mjs";

const basic = (user, password) => `Basic ${Buffer.from(`${user}:${password}`).toString("base64")}`;
const runNode = promisify(execFile);

/// 隔离进程退出和 TLS 信任配置，断言请求失败不会杀掉调用进程。
const requestInChild = async (url, options = {}, env = {}) => {
  const { stdout } = await runNode(process.execPath, ["--input-type=module", "-e", `
    import { requestText } from ${JSON.stringify(new URL("../Sources/outbound.mjs", import.meta.url).href)};
    try {
      const response = await requestText(${JSON.stringify(url)}, ${JSON.stringify(options)});
      console.log(JSON.stringify({ status: response.status, text: response.text }));
    } catch (error) {
      console.log(JSON.stringify({ error: error.code ?? error.message }));
    }
  `], { env: { ...process.env, ...env }, timeout: 5000 });
  return JSON.parse(stdout);
};

test("outbound settings turn into a proxy target only when a URL is set", () => {
  assert.equal(outboundProxyFrom({}), null, "没填地址就是直连");
  assert.equal(outboundProxyFrom({ outboundProxy: "  " }), null);
  assert.deepEqual(
    outboundProxyFrom({ outboundProxy: "http://127.0.0.1:7897", outboundUsername: "u", outboundPassword: "p" }),
    { host: "127.0.0.1", port: 7897, authorization: basic("u", "p") },
  );
  assert.equal(
    outboundProxyFrom({ outboundProxy: "http://127.0.0.1:7897" }).authorization,
    "",
    "没填用户名就不带认证头",
  );
});

test("loopback targets stay direct so they never loop through the proxy", () => {
  for (const host of ["127.0.0.1", "127.1.2.3", "localhost", "app.localhost", "::1", "[::1]"]) {
    assert.equal(isLoopbackHost(host), true, `${host} 应当算本机`);
  }
  for (const host of ["relay.test", "10.0.0.1", "192.168.1.20"]) {
    assert.equal(isLoopbackHost(host), false, `${host} 不该算本机`);
  }
});

test("http requests reach the proxy in absolute form with credentials and original headers", async (context) => {
  const seen = [];
  const proxy = http.createServer((req, res) => {
    seen.push({ url: req.url, headers: req.headers });
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ models: [] }));
  });
  await new Promise((resolve) => proxy.listen(0, "127.0.0.1", resolve));
  context.after(() => proxy.close());

  const response = await requestText("http://relay.test/v1/models?client_version=1", {
    headers: { authorization: "Bearer sk-x" },
    proxy: outboundProxyFrom({
      outboundProxy: `http://127.0.0.1:${proxy.address().port}`,
      outboundUsername: "u",
      outboundPassword: "p",
    }),
  });
  assert.equal(response.status, 200);
  assert.deepEqual(JSON.parse(response.text), { models: [] });
  assert.equal(seen[0].url, "http://relay.test/v1/models?client_version=1", "http 目标按代理协议带完整 URL");
  assert.equal(seen[0].headers["proxy-authorization"], basic("u", "p"));
  assert.equal(seen[0].headers.authorization, "Bearer sk-x", "渠道密钥照常发给目标");
});

test("loopback endpoints are not sent through the proxy", async (context) => {
  let hits = 0;
  const proxy = http.createServer((req, res) => {
    hits += 1;
    res.end("proxy");
  });
  const origin = http.createServer((req, res) => res.end("origin"));
  await new Promise((resolve) => proxy.listen(0, "127.0.0.1", resolve));
  await new Promise((resolve) => origin.listen(0, "127.0.0.1", resolve));
  context.after(() => proxy.close());
  context.after(() => origin.close());

  const response = await requestText(`http://127.0.0.1:${origin.address().port}/`, {
    proxy: outboundProxyFrom({ outboundProxy: `http://127.0.0.1:${proxy.address().port}` }),
  });
  assert.equal(response.text, "origin");
  assert.equal(hits, 0, "本机目标必须直连");
});

test("https tunnels verify the target identity and still authenticate", async (context) => {
  for (const fixture of [
    { name: "DNS", host: "relay.test", san: "DNS:relay.test", authority: "relay.test:443" },
    { name: "IPv4", host: "198.51.100.7", san: "IP:198.51.100.7", authority: "198.51.100.7:443" },
    { name: "IPv6", host: "[2001:db8::7]", san: "IP:2001:db8::7", authority: "[2001:db8::7]:443" },
    {
      name: "wrong IP identity", host: "198.51.100.7", san: "DNS:localhost",
      authority: "198.51.100.7:443", error: "ERR_TLS_CERT_ALTNAME_INVALID",
    },
  ]) {
    await context.test(fixture.name, async (context) => {
      const directory = fs.mkdtempSync(path.join(os.tmpdir(), "gpt-switch-tunnel-"));
      context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
      const keyPath = path.join(directory, "key.pem");
      const certPath = path.join(directory, "cert.pem");
      execFileSync("openssl", [
        "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        "-subj", "/CN=review", "-addext", `subjectAltName=${fixture.san}`,
        "-keyout", keyPath, "-out", certPath,
      ], { stdio: "ignore" });

      const secure = tls.createServer({
        key: fs.readFileSync(keyPath),
        cert: fs.readFileSync(certPath),
      }, (socket) => socket.end("HTTP/1.1 200 OK\r\ncontent-length: 8\r\n\r\ntunneled"));

      const seen = [];
      const proxy = http.createServer();
      proxy.on("connect", (req, socket) => {
        seen.push({ url: req.url, headers: req.headers });
        socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
        // CONNECT 之后的两端本来就是一条裸 TCP 通道，把这条 socket 直接交给 TLS 层。
        secure.emit("connection", socket);
      });
      await new Promise((resolve) => proxy.listen(0, "127.0.0.1", resolve));
      context.after(() => proxy.close());
      context.after(() => secure.close());

      // 子进程只信任本例证书，仍须校验它是否属于请求的目标。
      const result = await requestInChild(`https://${fixture.host}/v1/responses`, {
        headers: { authorization: "Bearer sk-x" },
        proxy: outboundProxyFrom({
          outboundProxy: `http://127.0.0.1:${proxy.address().port}`,
          outboundUsername: "u",
          outboundPassword: "p",
        }),
      }, { NODE_EXTRA_CA_CERTS: certPath, NODE_TLS_REJECT_UNAUTHORIZED: "1" });
      if (fixture.error) {
        assert.equal(result.error, fixture.error);
      } else {
        assert.deepEqual(result, { status: 200, text: "tunneled" });
      }
      assert.equal(seen[0].url, fixture.authority, "隧道只向代理暴露 host:port");
      assert.equal(seen[0].headers["proxy-authorization"], basic("u", "p"));
    });
  }
});

test("a proxy that refuses the tunnel reports why without leaking the password", async (context) => {
  const proxy = http.createServer();
  proxy.on("connect", (req, socket) => {
    socket.end("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n");
  });
  const origin = http.createServer((req, res) => res.end("不该走到这里"));
  await new Promise((resolve) => proxy.listen(0, "127.0.0.1", resolve));
  context.after(() => proxy.close());
  context.after(() => origin.close());

  await assert.rejects(requestText("https://relay.test/v1", {
    proxy: outboundProxyFrom({
      outboundProxy: `http://127.0.0.1:${proxy.address().port}`,
      outboundUsername: "u",
      outboundPassword: "s3cret",
    }),
  }), (error) => {
    assert.match(error.message, /HTTP 407，检查用户名和密码/);
    assert.doesNotMatch(error.message, /s3cret/, "错误信息里不能出现密码");
    return true;
  });
});

test("a cross-site redirect drops the channel key", async (context) => {
  let received = "";
  const target = http.createServer((req, res) => {
    received = req.headers.authorization ?? "";
    res.end("ok");
  });
  await new Promise((resolve) => target.listen(0, "127.0.0.1", resolve));
  context.after(() => target.close());
  const redirector = http.createServer((req, res) => {
    // localhost 和 127.0.0.1 是不同站点：重定向后原站的密钥不能跟过去。
    res.writeHead(302, { location: `http://localhost:${target.address().port}/next` });
    res.end();
  });
  await new Promise((resolve) => redirector.listen(0, "127.0.0.1", resolve));
  context.after(() => redirector.close());

  const response = await requestText(`http://127.0.0.1:${redirector.address().port}/start`, {
    headers: { authorization: "Bearer sk-x", accept: "application/json" },
  });
  assert.equal(response.text, "ok");
  assert.equal(received, "", "换站点后不能再带渠道密钥");
});

test("an invalid redirect rejects the request without terminating its caller", async (context) => {
  const origin = http.createServer((req, res) => {
    res.writeHead(302, { location: "http://[" });
    res.end();
  });
  await new Promise((resolve) => origin.listen(0, "127.0.0.1", resolve));
  context.after(() => origin.close());

  const result = await requestInChild(`http://127.0.0.1:${origin.address().port}/`);
  assert.equal(result.error, "ERR_INVALID_URL");
});

test("redirects and the final response share one timeout budget", async (context) => {
  const origin = http.createServer((req, res) => {
    const hop = Number(req.url.slice(1));
    const timer = setTimeout(() => {
      if (hop < 3) res.writeHead(302, { location: `/${hop + 1}` });
      res.end(hop < 3 ? "" : "too late");
    }, 80);
    res.on("close", () => clearTimeout(timer));
  });
  await new Promise((resolve) => origin.listen(0, "127.0.0.1", resolve));
  context.after(() => origin.close());

  await assert.rejects(requestText(`http://127.0.0.1:${origin.address().port}/0`, {
    timeoutMs: 200,
  }), /超时/);
});

test("a tunnel that goes silent still times out", async (context) => {
  const proxy = http.createServer();
  proxy.on("connect", (req, socket) => {
    // 回了 200 就不再发 TLS 数据：客户端不能一直等下去。
    socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
  });
  await new Promise((resolve) => proxy.listen(0, "127.0.0.1", resolve));
  context.after(() => proxy.close());

  const started = Date.now();
  await assert.rejects(requestText("https://relay.test/v1", {
    timeoutMs: 300,
    proxy: outboundProxyFrom({ outboundProxy: `http://127.0.0.1:${proxy.address().port}` }),
  }), /超时/);
  assert.ok(Date.now() - started < 3_000, "超时要自己收口，不能等隧道兜底");
});
