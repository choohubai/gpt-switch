#!/usr/bin/env node
// 一次性探针：连到已经带 --remote-debugging-port 启动的客户端，注入真实的 injection.js，
// 用来确认这台机器上的客户端能不能被注入、模型菜单能不能出模型。
//
//   node Scripts/cdp-probe.mjs --port 9222 --models grok-4.6,glm-5.3
//
// Windows 上先手动启动客户端，例如：
//   & "$env:LOCALAPPDATA\Programs\ChatGPT\ChatGPT.exe" --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const INJECTION_PATH = path.join(SCRIPT_DIR, "..", "Sources", "injection.js");

const args = process.argv.slice(2);
const optionValue = (name) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : null;
};

const port = Number(optionValue("--port") || 9222);
const models = (optionValue("--models") || "grok-4.6")
  .split(",")
  .map((id) => id.trim())
  .filter(Boolean)
  .map((id) => ({ id, displayName: id }));

if (typeof WebSocket !== "function") {
  console.error(`需要 Node.js 22 或更高版本（内置 WebSocket），当前是 ${process.version}`);
  process.exit(1);
}

const buildSource = () => {
  const template = fs.readFileSync(INJECTION_PATH, "utf8");
  const marker = "const BOOT_MODELS = [];";
  if (!template.includes(marker)) throw new Error("injection.js 缺少 BOOT_MODELS 标记");
  return template.replace(marker, `const BOOT_MODELS = ${JSON.stringify(models)};`);
};

class Session {
  constructor(target) {
    this.target = target;
    this.nextId = 1;
    this.pending = new Map();
    this.closed = false;
  }

  async connect() {
    this.socket = new WebSocket(this.target.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("WebSocket 连接超时")), 5000);
      this.socket.addEventListener("open", () => {
        clearTimeout(timer);
        resolve();
      }, { once: true });
      this.socket.addEventListener("error", () => {
        clearTimeout(timer);
        reject(new Error("WebSocket 连接失败"));
      }, { once: true });
    });
    this.socket.addEventListener("message", (event) => {
      let message;
      try {
        message = JSON.parse(String(event.data));
      } catch {
        return;
      }
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message || "CDP 命令失败"));
      else pending.resolve(message.result || {});
    });
    this.socket.addEventListener("close", () => {
      this.closed = true;
      for (const pending of this.pending.values()) pending.reject(new Error("CDP 连接已关闭"));
      this.pending.clear();
    });
  }

  command(method, params = {}) {
    if (this.closed || this.socket?.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error("CDP 未连接"));
    }
    const id = this.nextId;
    this.nextId += 1;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP 命令超时：${method}`));
      }, 7000);
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
      });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  async inject(source) {
    await this.command("Page.enable").catch(() => {});
    await this.command("Page.addScriptToEvaluateOnNewDocument", { source, runImmediately: true });
    const evaluated = await this.command("Runtime.evaluate", {
      expression: source,
      returnByValue: true,
      awaitPromise: false,
      allowUnsafeEvalBlockedByCSP: true,
    });
    if (evaluated.exceptionDetails) {
      throw new Error(evaluated.exceptionDetails.exception?.description
        || evaluated.exceptionDetails.text
        || "注入执行失败");
    }
    return evaluated.result?.value || null;
  }

  close() {
    this.closed = true;
    try { this.socket?.close(); } catch { /* 关掉就行 */ }
  }
}

const targets = await (async () => {
  try {
    const response = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(3000) });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.json();
  } catch (error) {
    console.error(`连不上 127.0.0.1:${port}/json/list —— ${error.message}`);
    console.error("确认客户端是带 --remote-debugging-port 启动的，端口号一致。");
    process.exit(2);
  }
})();

console.log(`端口 ${port} 上有 ${targets.length} 个 target：`);
for (const target of targets) {
  console.log(`  - ${target.type} | ${target.title} | ${target.url}`);
}

const pages = targets.filter((target) => (
  ["page", "webview"].includes(target.type)
  && typeof target.webSocketDebuggerUrl === "string"
  && !String(target.url || "").startsWith("devtools://")
));

if (pages.length === 0) {
  console.error("没有可注入的 page/webview target：客户端可能不是 Electron，或调试端口没生效。");
  process.exit(3);
}

const source = buildSource();
let injected = 0;
for (const target of pages) {
  const session = new Session(target);
  try {
    await session.connect();
    const result = await session.inject(source);
    injected += 1;
    console.log(`✔ ${target.title} → ${JSON.stringify(result)}`);
  } catch (error) {
    console.log(`✖ ${target.title} → ${error.message}`);
  } finally {
    session.close();
  }
}

if (injected === 0) {
  console.error("所有 target 都注入失败，把上面的报错发出来。");
  process.exit(4);
}

console.log(`
注入完成。现在打开模型菜单，看有没有：${models.map((model) => model.id).join(", ")}`);
console.log("没出现就说明这个客户端和 macOS 版结构不同，需要再查它自己的模型列表来源。");

