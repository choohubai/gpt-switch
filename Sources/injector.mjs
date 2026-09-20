import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import {
  loadModels, handlePanelRequest, buildCatalog, writeCatalog,
  catalogPathFromToml, writeCatalogRecord, clearCatalogFiles,
} from "./model-config.mjs";

const VERSION = "0.1.30";
const REPOSITORY = "choohubai/gpt-switch";
const APP_TITLE = "GPT Switch";
const HOME = os.homedir();
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const SUPPORT_DIR = path.join(HOME, "Library", "Application Support", "GPTSwitch");
const LEGACY_SUPPORT_DIR = path.join(HOME, "Library", "Application Support", "CodexModelUnlocker");
const STATE_PATH = path.join(SUPPORT_DIR, "state.json");
const LOCK_PATH = path.join(SUPPORT_DIR, "launcher.lock");
const LOG_PATH = path.join(HOME, "Library", "Logs", "GPTSwitch.log");
const MODEL_CONFIG = path.join(SUPPORT_DIR, "models.json");
const DEFAULT_MODELS = path.join(SCRIPT_DIR, "models.json");
const STATUS_MENU_PATH = path.join(SCRIPT_DIR, "GPTSwitchStatusMenu");
const STATUS_ICON_PATH = path.join(SCRIPT_DIR, "MenuBarIcon.png");
const BUNDLE_ID = "com.openai.codex";
let statusMenuProcess = null;

fs.mkdirSync(SUPPORT_DIR, { recursive: true, mode: 0o700 });
fs.mkdirSync(path.dirname(LOG_PATH), { recursive: true });

const args = process.argv.slice(2);
const optionValue = (name) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : null;
};
const hasOption = (name) => args.includes(name);
const attachPort = Number(optionValue("--attach-port") || 0);
const runOnce = hasOption("--once");
const noDialog = hasOption("--no-dialog");
const requestedAppPath = optionValue("--app");

const log = (message, detail = null) => {
  const suffix = detail == null
    ? ""
    : ` ${typeof detail === "string" ? detail : JSON.stringify(detail)}`;
  const line = `${new Date().toISOString()} ${message}${suffix}`;
  fs.appendFileSync(LOG_PATH, `${line}\n`, { mode: 0o600 });
  if (hasOption("--verbose")) process.stderr.write(`${line}\n`);
};

const runAppleScript = (script) => spawnSync(
  "/usr/bin/osascript",
  ["-e", script],
  { encoding: "utf8" },
);

/// Carry the model list over from the previous CodexModelUnlocker config directory.
const migrateLegacyConfig = () => {
  try {
    if (fs.existsSync(MODEL_CONFIG)) return;
    const legacy = path.join(LEGACY_SUPPORT_DIR, "models.json");
    if (!fs.existsSync(legacy)) return;
    fs.mkdirSync(SUPPORT_DIR, { recursive: true, mode: 0o700 });
    fs.copyFileSync(legacy, MODEL_CONFIG);
    log("config_migrated", { from: legacy, to: MODEL_CONFIG });
  } catch (error) {
    log("config_migration_failed", String(error?.message || error));
  }
};

migrateLegacyConfig();

const quoteAppleScript = (value) => String(value)
  .replaceAll("\\", "\\\\")
  .replaceAll("\"", "\\\"")
  .replaceAll("\n", " ");

const notify = (message) => {
  if (noDialog) return;
  runAppleScript(`display notification "${quoteAppleScript(message)}" with title "${APP_TITLE}"`);
};

const showError = (message) => {
  log("error", message);
  if (noDialog) return;
  runAppleScript(`display alert "${APP_TITLE}" message "${quoteAppleScript(message)}" as critical`);
};

const startStatusMenu = (onRequest) => {
  if (statusMenuProcess || !fs.existsSync(STATUS_MENU_PATH) || !fs.existsSync(STATUS_ICON_PATH)) return;
  try {
    statusMenuProcess = spawn(
      STATUS_MENU_PATH,
      ["--parent-pid", String(process.pid), "--icon-path", STATUS_ICON_PATH],
      { stdio: ["pipe", "pipe", "pipe"] },
    );
    const child = statusMenuProcess;
    child.stdin.on("error", (error) => log("panel_pipe_failed", error.message));
    child.stderr.on("data", (data) => log("panel_stderr", String(data).trim()));
    const lines = createInterface({ input: child.stdout });
    lines.on("line", (line) => {
      try {
        const request = JSON.parse(line);
        onRequest(request, (result) => {
          if (!child.stdin.destroyed) child.stdin.write(`${JSON.stringify(result)}\n`);
        });
      } catch (error) {
        log("panel_request_failed", error.message);
      }
    });
    child.once("exit", () => {
      lines.close();
      if (statusMenuProcess === child) statusMenuProcess = null;
    });
    statusMenuProcess.once("error", (error) => {
      log("status_menu_failed", String(error?.message || error));
      statusMenuProcess = null;
    });
    statusMenuProcess.unref();
  } catch (error) {
    log("status_menu_failed", String(error?.message || error));
    statusMenuProcess = null;
  }
};

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

const processIsAlive = (pid) => {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

const acquireLock = () => {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const descriptor = fs.openSync(LOCK_PATH, "wx", 0o600);
      fs.writeFileSync(descriptor, String(process.pid));
      fs.closeSync(descriptor);
      return true;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      const pid = Number(fs.readFileSync(LOCK_PATH, "utf8").trim());
      if (processIsAlive(pid)) return false;
      fs.rmSync(LOCK_PATH, { force: true });
    }
  }
  return false;
};

const releaseLock = () => {
  try {
    const pid = Number(fs.readFileSync(LOCK_PATH, "utf8").trim());
    if (pid === process.pid) fs.rmSync(LOCK_PATH, { force: true });
  } catch {
    // The lock may already be gone during shutdown.
  }
};

const candidateApps = [
  requestedAppPath,
  "/Applications/ChatGPT.app",
  "/Applications/Codex.app",
  path.join(HOME, "Applications", "ChatGPT.app"),
  path.join(HOME, "Applications", "Codex.app"),
].filter(Boolean);

const findApp = () => candidateApps.find((candidate) => fs.existsSync(candidate));

const appIsRunning = (appPath) => {
  const pattern = `${appPath}/Contents/MacOS/`;
  return spawnSync("/usr/bin/pgrep", ["-f", pattern]).status === 0;
};

const quitApp = async (appPath) => {
  runAppleScript(`tell application id "${BUNDLE_ID}" to quit`);
  const deadline = Date.now() + 12_000;
  while (Date.now() < deadline) {
    if (!appIsRunning(appPath)) return true;
    await sleep(250);
  }
  return false;
};

const getFreePort = () => new Promise((resolve, reject) => {
  const server = net.createServer();
  server.unref();
  server.once("error", reject);
  server.listen({ host: "127.0.0.1", port: 0 }, () => {
    const address = server.address();
    const port = typeof address === "object" && address ? address.port : 0;
    server.close((error) => (error ? reject(error) : resolve(port)));
  });
});

const bundleExecutable = (appPath) => {
  const infoPath = path.join(appPath, "Contents", "Info.plist");
  let declared = "";
  try {
    const result = spawnSync(
      "/usr/bin/plutil",
      ["-extract", "CFBundleExecutable", "raw", "-o", "-", infoPath],
      { encoding: "utf8" },
    );
    declared = result.status === 0 ? result.stdout.trim() : "";
  } catch {
    // Fall back to the app name when plutil is unavailable or Info.plist is invalid.
  }
  const appName = path.basename(appPath, ".app");
  const names = [declared, appName, "ChatGPT", "Codex"].filter((name, index, all) => (
    name && !name.includes("/") && all.indexOf(name) === index
  ));
  const executable = names
    .map((name) => path.join(appPath, "Contents", "MacOS", name))
    .find((candidate) => fs.existsSync(candidate));
  if (!executable) throw new Error(`未找到应用可执行文件：${path.join(appPath, "Contents", "MacOS")}`);
  return executable;
};

const launchApp = (appPath, port) => new Promise((resolve, reject) => {
  let executable;
  try {
    executable = bundleExecutable(appPath);
  } catch (error) {
    reject(error);
    return;
  }
  const child = spawn(
    executable,
    [
      `--remote-debugging-port=${port}`,
      "--remote-debugging-address=127.0.0.1",
    ],
    { detached: true, stdio: "ignore" },
  );
  child.once("error", (error) => {
    log("app_launch_failed", { executable, error: String(error?.message || error) });
    reject(new Error(`启动应用失败：${String(error?.message || error)}`));
  });
  child.once("spawn", () => {
    child.unref();
    resolve();
  });
});

const buildInjectionSource = (models) => {
  const template = fs.readFileSync(path.join(SCRIPT_DIR, "injection.js"), "utf8");
  const marker = "const BOOT_MODELS = [];";
  if (!template.includes(marker)) throw new Error("Injection template marker is missing");
  return template.replace(marker, `const BOOT_MODELS = ${JSON.stringify(models)};`);
};

const fetchJson = async (url, timeoutMs = 1500, headers = null) => {
  const response = await fetch(url, {
    signal: AbortSignal.timeout(timeoutMs),
    ...(headers ? { headers } : {}),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status} for ${url}`);
  return response.json();
};

const parseVersion = (value) => String(value || "")
  .replace(/^v/, "")
  .split(".")
  .map((part) => Number.parseInt(part, 10) || 0);

const compareVersions = (left, right) => {
  const a = parseVersion(left);
  const b = parseVersion(right);
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    const difference = (a[index] || 0) - (b[index] || 0);
    if (difference !== 0) return difference;
  }
  return 0;
};

const checkForUpdate = async () => {
  try {
    const release = await fetchJson(
      `https://api.github.com/repos/${REPOSITORY}/releases/latest`,
      5000,
      { "User-Agent": "gpt-switch", Accept: "application/vnd.github+json" },
    );
    const latest = String(release?.tag_name || "").replace(/^v/, "");
    if (!latest) throw new Error("发布信息缺少版本号");
    const newer = compareVersions(latest, VERSION) > 0;
    log("update_checked", { current: VERSION, latest, newer });
    return {
      ok: true,
      version: VERSION,
      latest,
      url: String(release?.html_url || ""),
      newer,
    };
  } catch (error) {
    return { ok: false, version: VERSION, error: `检查更新失败：${String(error?.message || error)}` };
  }
};

const fetchTargets = async (port) => {
  const targets = await fetchJson(`http://127.0.0.1:${port}/json/list`);
  if (!Array.isArray(targets)) return [];
  return targets.filter((target) => (
    ["page", "webview"].includes(target.type)
    && typeof target.webSocketDebuggerUrl === "string"
    && !String(target.url || "").startsWith("devtools://")
    && !String(target.url || "").includes("avatar-overlay")
  ));
};

class CDPSession {
  constructor(target) {
    this.target = target;
    this.nextId = 1;
    this.pending = new Map();
    this.closed = false;
    this.scriptIdentifier = null;
  }

  async connect() {
    this.socket = new WebSocket(this.target.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("CDP WebSocket connection timed out")), 5000);
      this.socket.addEventListener("open", () => {
        clearTimeout(timer);
        resolve();
      }, { once: true });
      this.socket.addEventListener("error", () => {
        clearTimeout(timer);
        reject(new Error("CDP WebSocket connection failed"));
      }, { once: true });
    });

    this.socket.addEventListener("message", (event) => {
      let message;
      try {
        message = JSON.parse(String(event.data));
      } catch {
        return;
      }
      if (message.id == null) return;
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message || "CDP command failed"));
      else pending.resolve(message.result || {});
    });

    this.socket.addEventListener("close", () => {
      this.closed = true;
      for (const pending of this.pending.values()) {
        pending.reject(new Error("CDP WebSocket closed"));
      }
      this.pending.clear();
    });

    await this.command("Page.enable");
  }

  command(method, params = {}) {
    if (this.closed || this.socket?.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error("CDP session is not connected"));
    }
    const id = this.nextId;
    this.nextId += 1;

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP command timed out: ${method}`));
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
    if (this.scriptIdentifier) {
      await this.command("Page.removeScriptToEvaluateOnNewDocument", {
        identifier: this.scriptIdentifier,
      }).catch(() => {});
    }
    const registered = await this.command("Page.addScriptToEvaluateOnNewDocument", {
      source,
      runImmediately: true,
    });
    this.scriptIdentifier = registered.identifier || null;

    const evaluated = await this.command("Runtime.evaluate", {
      expression: source,
      returnByValue: true,
      awaitPromise: false,
      allowUnsafeEvalBlockedByCSP: true,
    });
    if (evaluated.exceptionDetails) {
      const description = evaluated.exceptionDetails.exception?.description
        || evaluated.exceptionDetails.text
        || "Injection evaluation failed";
      throw new Error(description);
    }
    return evaluated.result?.value || null;
  }

  close() {
    this.closed = true;
    try {
      this.socket?.close();
    } catch {
      // Ignore close errors during shutdown.
    }
  }
}

const writeFileAtomic = (filePath, contents) => {
  const temporary = `${filePath}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(temporary, contents, { mode: 0o600 });
    fs.renameSync(temporary, filePath);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
};

const writeState = (state) => {
  writeFileAtomic(STATE_PATH, `${JSON.stringify(state, null, 2)}\n`);
};

const cleanupState = () => {
  try {
    const state = JSON.parse(fs.readFileSync(STATE_PATH, "utf8"));
    if (state.pid === process.pid) fs.rmSync(STATE_PATH, { force: true });
  } catch {
    // State is optional during partial startup.
  }
};

const waitForTargets = async (port, timeoutMs = 30_000) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const targets = await fetchTargets(port);
      if (targets.length > 0) return targets;
    } catch {
      // The DevTools endpoint is expected to be unavailable during startup.
    }
    await sleep(250);
  }
  throw new Error("Timed out waiting for the Codex renderer");
};

const CODEX_HOME = path.join(HOME, ".codex");
const USER_CONFIG = path.join(CODEX_HOME, "config.toml");
const DEFAULT_CATALOG_PATH = path.join(CODEX_HOME, "model_catalog.json");
const CATALOG_RECORD = path.join(SUPPORT_DIR, "catalog.json");

const readBundledCatalog = (appPath) => {
  const binary = path.join(appPath, "Contents", "Resources", "codex");
  if (!fs.existsSync(binary)) throw new Error("未找到 Codex 可执行文件，无法读取官方模型目录");
  const result = spawnSync(binary, ["debug", "models", "--bundled"], {
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    timeout: 20_000,
  });
  if (result.status !== 0) {
    throw new Error(`读取官方模型目录失败：${(result.stderr || result.stdout || "").trim() || result.status}`);
  }
  const text = result.stdout || "";
  const start = text.indexOf("{");
  if (start < 0) throw new Error("官方模型目录不是 JSON");
  const parsed = JSON.parse(text.slice(start));
  if (!Array.isArray(parsed?.models)) throw new Error("官方模型目录缺少 models");
  return parsed;
};

const ensureCatalogPointer = (catalogPath) => {
  if (!fs.existsSync(USER_CONFIG)) return false;
  const text = fs.readFileSync(USER_CONFIG, "utf8");
  if (/^[ \t]*model_catalog_json[ \t]*=/m.test(text)) return false;
  const line = `model_catalog_json = ${JSON.stringify(catalogPath)}\n`;
  const table = text.search(/^[ \t]*\[/m);
  const next = table < 0 ? `${text.replace(/\s*$/, "")}\n${line}` : `${text.slice(0, table)}${line}${text.slice(table)}`;
  writeFileAtomic(USER_CONFIG, next);
  return true;
};

const resolveCatalogPath = () => {
  if (!fs.existsSync(USER_CONFIG)) return DEFAULT_CATALOG_PATH;
  return catalogPathFromToml(fs.readFileSync(USER_CONFIG, "utf8"), HOME, CODEX_HOME) || DEFAULT_CATALOG_PATH;
};

const clearCatalog = (appPath) => {
  if (!appPath) throw new Error("未找到 ChatGPT.app 或 Codex.app");
  const plan = clearCatalogFiles({
    recordPath: CATALOG_RECORD,
    userConfigPath: USER_CONFIG,
    home: HOME,
    codexHome: CODEX_HOME,
    catalogPath: resolveCatalogPath(),
    defaultCatalogPath: DEFAULT_CATALOG_PATH,
    readBundledCatalog: () => readBundledCatalog(appPath),
  });
  log("catalog_cleared", plan);
};

const main = async () => {
  if (!acquireLock()) {
    notify("模型解锁已在运行");
    return;
  }

  const appPath = findApp();
  const requests = [];
  startStatusMenu((request, reply) => requests.push({ request, reply }));
  const sessions = new Map();
  let models = [];
  let port = 0;
  let source = "";
  let appMissingSince = null;

  const injectTargets = async (targets) => {
    const activeIds = new Set(targets.map((target) => target.id));
    for (const [id, session] of sessions) {
      if (!activeIds.has(id) || session.closed) {
        session.close();
        sessions.delete(id);
      }
    }

    if (models.length === 0) return;
    for (const target of targets) {
      if (sessions.has(target.id)) continue;
      const session = new CDPSession(target);
      try {
        await session.connect();
        const result = await session.inject(source);
        sessions.set(target.id, session);
        log("target_injected", {
          targetId: target.id,
          title: target.title,
          url: target.url,
          result,
        });
      } catch (error) {
        session.close();
        log("target_injection_failed", { targetId: target.id, error: String(error?.message || error) });
      }
    }
  };

  const restart = async (nextModels, existingPort = 0) => {
    if (!existingPort) {
      if (!appPath) throw new Error("未找到 ChatGPT.app 或 Codex.app");
      if (appIsRunning(appPath) && !await quitApp(appPath)) {
        throw new Error("ChatGPT 未能正常退出；请稍后重试");
      }
    }
    for (const session of sessions.values()) session.close();
    sessions.clear();
    port = 0;
    appMissingSince = null;
    models = nextModels;
    source = models.length ? buildInjectionSource(models) : "";
    const nextPort = existingPort || await getFreePort();
    if (!existingPort) await launchApp(appPath, nextPort);
    const targets = await waitForTargets(nextPort);
    port = nextPort;
    await injectTargets(targets);
    if (models.length > 0 && sessions.size === 0) throw new Error("模型注入失败，请重试并检查插件日志");
    log("launcher_started", { version: VERSION, appPath, port, models });
    writeState({ pid: process.pid, version: VERSION, appPath, port, models, startedAt: Date.now() });
  };

  if (attachPort) {
    try {
      await restart(loadModels(MODEL_CONFIG, DEFAULT_MODELS), attachPort);
    } catch (error) {
      if (!statusMenuProcess || runOnce) throw error;
      showError(error.message);
    }
  }

  while (true) {
    const pending = requests.shift();
    if (pending) {
      const result = pending.request.action === "check-update"
        ? await checkForUpdate()
        : { ...await handlePanelRequest(pending.request, {
            configPath: MODEL_CONFIG, defaultPath: DEFAULT_MODELS, restart,
            applyCatalog: async (nextModels) => {
              if (!appPath) throw new Error("未找到 ChatGPT.app 或 Codex.app");
              const dest = resolveCatalogPath();
              const fileCreated = !fs.existsSync(dest);
              writeCatalog(dest, buildCatalog(readBundledCatalog(appPath), nextModels));
              const pointerAdded = ensureCatalogPointer(dest) || dest === DEFAULT_CATALOG_PATH;
              writeCatalogRecord(CATALOG_RECORD, {
                path: dest,
                pointerAdded,
                fileCreated: fileCreated || dest === DEFAULT_CATALOG_PATH,
              });
              log("catalog_written", { path: dest, models: nextModels.map((model) => model.id) });
            },
            clearCatalog: () => clearCatalog(appPath),
          }), version: VERSION };
      if (!result.ok) log("panel_action_failed", result.error);
      pending.reply(result);
    }

    if (port) {
      try {
        await injectTargets(await fetchTargets(port));
      } catch (error) {
        if (runOnce) throw error;
      }
    }
    if (runOnce) break;

    if (port && !attachPort && appPath && !appIsRunning(appPath)) {
      appMissingSince ??= Date.now();
      if (Date.now() - appMissingSince > 5000) {
        port = 0;
        for (const session of sessions.values()) session.close();
        sessions.clear();
        cleanupState();
      }
    } else {
      appMissingSince = null;
    }

    if (!port && !statusMenuProcess) break;
    await sleep(250);
  }

  for (const session of sessions.values()) session.close();
  log("launcher_stopped");
};

let shuttingDown = false;
const shutdown = () => {
  if (shuttingDown) return;
  shuttingDown = true;
  try { statusMenuProcess?.kill("SIGTERM"); } catch {}
  statusMenuProcess = null;
  cleanupState();
  releaseLock();
};

process.on("SIGINT", () => {
  shutdown();
  process.exit(0);
});
process.on("SIGTERM", () => {
  shutdown();
  process.exit(0);
});
process.on("exit", shutdown);

try {
  await main();
} catch (error) {
  showError(String(error?.message || error));
  process.exitCode = 1;
} finally {
  shutdown();
}
