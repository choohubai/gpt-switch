import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import {
  buildCatalog, writeCatalog,
  catalogPathFromToml, writeCatalogRecord, clearCatalogFiles,
} from "./model-config.mjs";
import {
  loadChannelState, handlePanelRequest, applyChannelToCodex, restoreCodexConfig,
  modelProviderFromToml, modelFromToml, channelDefaultModel, recordedProxyAddress,
  repointProxyUrl,
  readProxySettings, writeProxySettings,
} from "./channel-config.mjs";
import {
  startProxy, proxyBaseUrl, switchProxyAndRestart, pickerModelsFromState, pickerGroupNameFromState,
  pickerChannelNamesFromState, DEFAULT_PROXY_PORT, DEFAULT_PROXY_HOST, MODEL_PREFIX,
} from "./proxy.mjs";
import { isLoopbackHost, outboundProxyFrom, requestText } from "./outbound.mjs";
import {
  appearanceNativeMode, appearancePanelState, appearanceRuntimeTheme,
  readAppearanceState, writeAppearanceTheme, writeNativeAppearanceOverride,
} from "./appearance-config.mjs";

const VERSION = "0.1.60";
const REPOSITORY = "choohubai/gpt-switch";
const APP_TITLE = "GPT Switch";
const IS_WINDOWS = process.platform === "win32";
const IS_MACOS = process.platform === "darwin";
const HOME = os.homedir();
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const LOCAL_APP_DATA = process.env.LOCALAPPDATA || path.join(HOME, "AppData", "Local");
const SUPPORT_DIR = IS_WINDOWS
  ? path.join(LOCAL_APP_DATA, "GPTSwitch")
  : path.join(HOME, "Library", "Application Support", "GPTSwitch");
const LEGACY_SUPPORT_DIR = path.join(HOME, "Library", "Application Support", "CodexModelUnlocker");
const STATE_PATH = path.join(SUPPORT_DIR, "state.json");
const LOCK_PATH = path.join(SUPPORT_DIR, "launcher.lock");
const LOG_PATH = IS_WINDOWS
  ? path.join(SUPPORT_DIR, "GPTSwitch.log")
  : path.join(HOME, "Library", "Logs", "GPTSwitch.log");
/// 0.1.x 早期版本把模型列表存在这里，首次升级时读它导入成第一个渠道。
const LEGACY_MODELS = path.join(SUPPORT_DIR, "models.json");
const STATUS_MENU_PATH = path.join(SCRIPT_DIR, "GPTSwitchStatusMenu");
const STATUS_ICON_PATH = path.join(SCRIPT_DIR, "MenuBarIcon.png");
const WINDOWS_PANEL_PATH = path.join(SCRIPT_DIR, "StatusMenu.ps1");
const WINDOWS_PANEL_ICON = path.join(SCRIPT_DIR, "AppIcon.ico");
const WINDOWS_LAUNCHER_PATH = path.join(SCRIPT_DIR, "GPT Switch.exe");
const APPEARANCE_RESOURCE_DIR = fs.existsSync(path.join(SCRIPT_DIR, "Appearance"))
  ? path.join(SCRIPT_DIR, "Appearance")
  : path.join(SCRIPT_DIR, "..", "Resources", "Appearance");
const NATIVE_APPEARANCE_BINDING = "__gptSwitchNativeAppearanceChanged";
let statusMenuProcess = null;
let proxyServer = null;
let proxyHost = "";
let proxyPort = 0;
/// 客户端 config.toml 里 provider 的 base_url 会写成它；代理没起来时留空，退回直连。
const proxyUrl = () => (proxyPort ? proxyBaseUrl(proxyPort, proxyHost) : "");

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

const quoteAppleScript = (value) => String(value)
  .replaceAll("\\", "\\\\")
  .replaceAll("\"", "\\\"")
  .replaceAll("\n", " ");

const runWindowsLauncher = (arguments_, timeoutMs = 30_000) => {
  const result = spawnSync(
    WINDOWS_LAUNCHER_PATH,
    arguments_,
    { encoding: "utf8", timeout: timeoutMs, windowsHide: true },
  );
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(firstLine(result.stderr) || firstLine(result.stdout) || "Windows helper failed");
  }
  return result;
};

/// Windows 没有 osascript，用系统消息框提示启动期错误。
const windowsMessageBox = (message, icon = "Error") => {
  runWindowsLauncher(["--message", icon, String(message)], 120_000);
};

const notify = (message) => {
  if (noDialog || IS_WINDOWS) return;
  runAppleScript(`display notification "${quoteAppleScript(message)}" with title "${APP_TITLE}"`);
};

const showError = (message) => {
  log("error", message);
  if (noDialog) return;
  if (IS_WINDOWS) {
    try {
      windowsMessageBox(message);
    } catch (error) {
      log("dialog_failed", String(error?.message || error));
    }
    return;
  }
  runAppleScript(`display alert "${APP_TITLE}" message "${quoteAppleScript(message)}" as critical`);
};

/// 面板子进程与注入器之间用同一套协议：面板往 stdout 写请求，注入器往 stdin 写响应。
const attachPanelProcess = (child, onRequest) => {
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
  child.once("error", (error) => {
    log("panel_failed", String(error?.message || error));
    if (statusMenuProcess === child) statusMenuProcess = null;
  });
  child.unref();
};

const startStatusMenu = (onRequest) => {
  if (statusMenuProcess || !fs.existsSync(STATUS_MENU_PATH) || !fs.existsSync(STATUS_ICON_PATH)) return;
  try {
    statusMenuProcess = spawn(
      STATUS_MENU_PATH,
      ["--parent-pid", String(process.pid), "--icon-path", STATUS_ICON_PATH],
      { stdio: ["pipe", "pipe", "pipe"] },
    );
    attachPanelProcess(statusMenuProcess, onRequest);
  } catch (error) {
    log("panel_failed", String(error?.message || error));
    statusMenuProcess = null;
  }
};

/// 既有 WPF 面板由原生 GPT Switch.exe 在自身进程内承载，不再启动 powershell.exe。
const startWindowsPanel = (onRequest) => {
  if (statusMenuProcess
    || !fs.existsSync(WINDOWS_LAUNCHER_PATH)
    || !fs.existsSync(WINDOWS_PANEL_PATH)) return;
  const panelArgs = [
    "--panel", "--parent-pid", String(process.pid),
  ];
  if (fs.existsSync(WINDOWS_PANEL_ICON)) panelArgs.push("--icon-path", WINDOWS_PANEL_ICON);
  try {
    statusMenuProcess = spawn(
      WINDOWS_LAUNCHER_PATH,
      panelArgs,
      { cwd: SCRIPT_DIR, stdio: ["pipe", "pipe", "pipe"], windowsHide: true },
    );
    attachPanelProcess(statusMenuProcess, onRequest);
  } catch (error) {
    log("panel_failed", String(error?.message || error));
    statusMenuProcess = null;
  }
};

const startPanel = IS_WINDOWS ? startWindowsPanel : startStatusMenu;

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

/// 主循环的节奏（事件通道不可用时的兜底轮询间隔）：CDP 目标轮询和客户端存活检查
/// 都按它走。原来 250ms 一轮，每轮 ping 一次调试端口、fork 一次 pgrep，
/// 4Hz 的唤醒让这个后台进程一直出不了空闲状态；1 秒一轮便宜得多。
const POLL_INTERVAL_MS = 1000;

/// 浏览器级事件连不上时的兜底轮询间隔：Target 事件漏掉也会在 5 秒内自愈。
const TARGET_BACKSTOP_MS = 5000;

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

const findMacApp = () => candidateApps.find((candidate) => fs.existsSync(candidate));

const macAppIsRunning = (appPath) => {
  const pattern = `${appPath}/Contents/MacOS/`;
  return spawnSync("/usr/bin/pgrep", ["-f", pattern]).status === 0;
};

const bundleIdentifier = (appPath) => {
  const infoPath = path.join(appPath, "Contents", "Info.plist");
  let identifier = "";
  try {
    const result = spawnSync(
      "/usr/bin/plutil",
      ["-extract", "CFBundleIdentifier", "raw", "-o", "-", infoPath],
      { encoding: "utf8" },
    );
    identifier = result.status === 0 ? result.stdout.trim() : "";
  } catch {
    // Fall through to the explicit error below.
  }
  if (!identifier || !/^[A-Za-z0-9.-]+$/.test(identifier)) {
    throw new Error(`应用缺少合法的 CFBundleIdentifier：${infoPath}`);
  }
  return identifier;
};

const macQuitApp = async (appPath) => {
  const identifier = bundleIdentifier(appPath);
  const result = runAppleScript(`tell application id "${identifier}" to quit`);
  if (result.status !== 0) {
    throw new Error(firstLine(result.stderr) || `无法退出应用：${identifier}`);
  }
  const deadline = Date.now() + 12_000;
  while (Date.now() < deadline) {
    if (!macAppIsRunning(appPath)) return true;
    await sleep(250);
  }
  return false;
};

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

// ---- Windows：客户端是 exe，商店版装在 WindowsApps 下，独立版装在 %LOCALAPPDATA%\Programs ----

const WINDOWS_CLIENT_NAMES = ["ChatGPT.exe", "Codex.exe"];
const WINDOWS_PROGRAMS_DIR = path.join(LOCAL_APP_DATA, "Programs");
const WINDOWS_CODEX_BIN_DIR = path.join(LOCAL_APP_DATA, "OpenAI", "Codex", "bin");
const WINDOWS_PACKAGED_CLIENT = /[\\/]WindowsApps[\\/]/i;

const firstLine = (value) => String(value || "")
  .split(/\r?\n/)
  .map((line) => line.trim())
  .find(Boolean) || "";

/// 桌面端安装目录里有 resources\app.asar；同名的 codex CLI 没有。
const windowsIsDesktopInstall = (executable) => {
  try {
    return fs.existsSync(path.join(path.dirname(executable), "resources", "app.asar"));
  } catch {
    return false;
  }
};

const windowsLauncherLines = (arguments_) => {
  const result = runWindowsLauncher(arguments_);
  return String(result.stdout || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
};

/// 正在运行的客户端：主进程是 ChatGPT.exe；Codex.exe 只在确认是桌面端安装时才认，
/// 否则会把 codex CLI 当成客户端。
const windowsRunningApp = () => {
  const paths = windowsLauncherLines(["--running-client-paths"]);
  const desktop = paths.find((candidate) => /[\\/]ChatGPT\.exe$/i.test(candidate));
  if (desktop && fs.existsSync(desktop)) return desktop;
  const codex = paths.find((candidate) => /[\\/]Codex\.exe$/i.test(candidate)
    && windowsIsDesktopInstall(candidate));
  return codex && fs.existsSync(codex) ? codex : null;
};

/// 独立安装版：%LOCALAPPDATA%\Programs 下按修改时间取最新的一份，可以直接带参数启动。
const windowsStandaloneApp = () => {
  let newest = null;
  try {
    for (const entry of fs.readdirSync(WINDOWS_PROGRAMS_DIR, { withFileTypes: true })) {
      if (!entry.isDirectory() || !/^(codex|chatgpt)/i.test(entry.name)) continue;
      const directory = path.join(WINDOWS_PROGRAMS_DIR, entry.name);
      const executable = WINDOWS_CLIENT_NAMES
        .map((name) => path.join(directory, name))
        .find((candidate) => fs.existsSync(candidate));
      if (!executable) continue;
      let modified = 0;
      try { modified = fs.statSync(directory).mtimeMs; } catch { /* 读不到时间就当最旧 */ }
      if (!newest || modified > newest.modified) newest = { path: executable, modified };
    }
  } catch {
    // 没有 Programs 目录说明客户端不是独立安装版。
  }
  return newest;
};

/// 商店版（MSIX）：目录不能直接执行，通过系统执行别名带参数拉起。
const windowsPackagedApp = () => {
  const line = firstLine(windowsLauncherLines(["--packaged-app"]).join("\n"));
  const [installLocation, activationId, executable, alias] = line.split("|");
  if (!installLocation || !activationId || !executable) return null;
  const candidate = path.join(installLocation, ...executable.split("/"));
  if (!fs.existsSync(candidate)) return null;
  let modified = 0;
  try { modified = fs.statSync(installLocation).mtimeMs; } catch { /* 读不到时间就当最旧 */ }
  const launcher = alias
    ? path.join(LOCAL_APP_DATA, "Microsoft", "WindowsApps", alias)
    : null;
  return { path: candidate, modified, launcher };
};

/// 正在运行的客户端优先（它就是用户实际在用的版本）；都没在跑就比安装时间，
/// 避免挑到 %LOCALAPPDATA%\Programs 里遗留的旧版本副本。
const findWindowsApp = () => {
  if (requestedAppPath && fs.existsSync(requestedAppPath)) return requestedAppPath;
  const running = windowsRunningApp();
  if (running) return running;
  const candidates = [windowsStandaloneApp(), windowsPackagedApp()].filter(Boolean);
  candidates.sort((left, right) => right.modified - left.modified);
  return candidates[0]?.path;
};

const findApp = IS_WINDOWS ? findWindowsApp : findMacApp;

let windowsRunningCheckedAt = 0;
let windowsRunningValue = false;

const windowsAppIsRunning = (appPath, force = false) => {
  const now = Date.now();
  if (!force && now - windowsRunningCheckedAt < 2000) return windowsRunningValue;
  const image = path.basename(appPath);
  const result = spawnSync("tasklist.exe", ["/FI", `IMAGENAME eq ${image}`, "/NH"], {
    encoding: "utf8", timeout: 8000, windowsHide: true,
  });
  windowsRunningValue = new RegExp(`\\b${image.replaceAll(".", "\\.")}\\b`, "i").test(result.stdout || "");
  windowsRunningCheckedAt = now;
  return windowsRunningValue;
};

const appIsRunning = IS_WINDOWS
  ? (appPath, force) => windowsAppIsRunning(appPath, force)
  : macAppIsRunning;

/// 只取这个客户端自己的进程：桌面端和 codex CLI 可能同名（Codex.exe / codex.exe），
/// 按 taskkill /IM 会连 CLI 一起杀掉。
const windowsClientPids = (appPath) => windowsLauncherLines(["--client-pids", appPath])
  .map(Number)
  .filter((value) => Number.isInteger(value) && value > 0);

/// 等这个客户端退出。先用便宜的 tasklist 判断同名进程；同名进程还在时才精确核对路径，
/// 免得把 codex CLI 当成客户端一直等下去。
const windowsWaitForClientExit = async (appPath, timeoutMs) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!windowsAppIsRunning(appPath, true)) return true;
    if (windowsClientPids(appPath).length === 0) return true;
    await sleep(250);
  }
  return false;
};

const windowsQuitApp = async (appPath) => {
  const taskkill = (extra = []) => {
    const pids = windowsClientPids(appPath);
    if (pids.length === 0) return;
    spawnSync(
      "taskkill.exe",
      [...pids.flatMap((pid) => ["/PID", String(pid)]), "/T", ...extra],
      { timeout: 12_000, windowsHide: true },
    );
  };

  // 先温和关闭（taskkill 不带 /F 会发 WM_CLOSE），12 秒不退再强杀。
  taskkill();
  if (await windowsWaitForClientExit(appPath, 12_000)) return true;
  taskkill(["/F"]);
  return windowsWaitForClientExit(appPath, 6000);
};

const quitApp = IS_WINDOWS ? windowsQuitApp : macQuitApp;

const windowsSpawnApp = (appPath, port) => new Promise((resolve, reject) => {
  const child = spawn(
    appPath,
    [`--remote-debugging-port=${port}`, "--remote-debugging-address=127.0.0.1"],
    { detached: true, stdio: "ignore", windowsHide: true },
  );
  child.once("error", (error) => {
    log("app_launch_failed", { executable: appPath, error: String(error?.message || error) });
    reject(new Error(`启动客户端失败：${String(error?.message || error)}`));
  });
  child.once("spawn", () => {
    child.unref();
    resolve();
  });
});

const launchApp = async (appPath, port) => {
  if (!IS_WINDOWS) {
    const executable = bundleExecutable(appPath);
    await new Promise((resolve, reject) => {
      const child = spawn(
        executable,
        [`--remote-debugging-port=${port}`, "--remote-debugging-address=127.0.0.1"],
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
    return;
  }
  if (WINDOWS_PACKAGED_CLIENT.test(appPath)) {
    const packaged = windowsPackagedApp();
    if (!packaged || packaged.path !== appPath) {
      throw new Error("商店版客户端安装信息已变化，请重试");
    }
    if (!packaged.launcher || !fs.existsSync(packaged.launcher)) {
      throw new Error("商店版客户端没有可用的执行别名，请在 Windows 设置中启用 chatgpt-desktop.exe");
    }
    await windowsSpawnApp(packaged.launcher, port);
    return;
  }
  await windowsSpawnApp(appPath, port);
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

const buildInjectionSource = (models, groupName = "", groupNames = [], appearance = null) => {
  const template = fs.readFileSync(path.join(SCRIPT_DIR, "injection.js"), "utf8");
  const modelMarker = "const BOOT_MODELS = [];";
  const groupMarker = 'const DEFAULT_GROUP_NAME = "";';
  const groupNamesMarker = "const KNOWN_GROUP_NAMES = [];";
  const prefixMarker = 'const MODEL_ID_PREFIX = "";';
  const appearanceMarker = "const BOOT_APPEARANCE = null;";
  if (!template.includes(modelMarker)) throw new Error("Injection template marker is missing");
  if (!template.includes(groupMarker)) throw new Error("Injection group marker is missing");
  if (!template.includes(groupNamesMarker)) throw new Error("Injection group names marker is missing");
  if (!template.includes(prefixMarker)) throw new Error("Injection model prefix marker is missing");
  if (!template.includes(appearanceMarker)) throw new Error("Injection appearance marker is missing");
  // 用函数式替换：模型名和渠道名是用户内容，直接当替换串时 `$&` 这类片段会被当成替换模式。
  return template
    .replace(modelMarker, () => `const BOOT_MODELS = ${JSON.stringify(models)};`)
    .replace(groupMarker, () => `const DEFAULT_GROUP_NAME = ${JSON.stringify(groupName)};`)
    .replace(groupNamesMarker, () => `const KNOWN_GROUP_NAMES = ${JSON.stringify(groupNames)};`)
    .replace(prefixMarker, () => `const MODEL_ID_PREFIX = ${JSON.stringify(MODEL_PREFIX)};`)
    .replace(appearanceMarker, () => `const BOOT_APPEARANCE = ${JSON.stringify(appearance)};`);
};

/// 插件自己发出的请求：检查更新走全局出站代理，CDP 这类本机地址直连。
const fetchJson = async (url, timeoutMs = 1500, headers = null) => {
  const target = new URL(url);
  const proxy = isLoopbackHost(target.hostname)
    ? null
    : outboundProxyFrom(readProxySettings(PROXY_CONFIG));
  const response = await requestText(url, { headers: headers ?? {}, timeoutMs, proxy });
  if (!response.ok) throw new Error(`HTTP ${response.status} for ${url}`);
  return JSON.parse(response.text);
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

/// 浏览器级的 CDP 长连接，只用来听「有新页面了」这类事件。
/// 有了它就不必每秒去问一次 /json/list：新窗口一出现就能立刻注入，
/// 平时进程完全睡着。
class BrowserWatch {
  constructor(port, onChange) {
    this.port = port;
    this.onChange = onChange;
    this.socket = null;
    this.closed = false;
  }

  get active() {
    return !this.closed && this.socket?.readyState === WebSocket.OPEN;
  }

  async connect() {
    const version = await fetchJson(`http://127.0.0.1:${this.port}/json/version`);
    const url = version?.webSocketDebuggerUrl;
    if (typeof url !== "string" || !url) throw new Error("调试端口没有提供 WebSocket 地址");
    this.socket = new WebSocket(url);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.close();
        reject(new Error("CDP browser connection timed out"));
      }, 5000);
      this.socket.addEventListener("open", () => {
        clearTimeout(timer);
        resolve();
      }, { once: true });
      this.socket.addEventListener("error", () => {
        clearTimeout(timer);
        // 连失败的 socket 要扔掉，不然它晚一点连上会让 active 变成 true，
        // 但那时已经没人发 setDiscoverTargets，事件永远不会来。
        this.close();
        reject(new Error("CDP browser connection failed"));
      }, { once: true });
    });
    this.socket.addEventListener("message", (event) => {
      let message;
      try {
        message = JSON.parse(String(event.data));
      } catch {
        return;
      }
      // targetCreated / targetDestroyed / targetInfoChanged 都算变化。
      if (typeof message.method === "string" && message.method.startsWith("Target.")) this.onChange();
    });
    this.socket.addEventListener("close", () => {
      this.closed = true;
      // 客户端退出时这条连接会断，当成一次变化去复查。
      this.onChange();
    });
    this.socket.send(JSON.stringify({ id: 1, method: "Target.setDiscoverTargets", params: { discover: true } }));
    return true;
  }

  close() {
    this.closed = true;
    try { this.socket?.close(); } catch { /* 已经断了就算了 */ }
    this.socket = null;
  }
}

class CDPSession {
  constructor(target, { onNativeAppearanceChange = null, onBindingError = null } = {}) {
    this.target = target;
    this.onNativeAppearanceChange = onNativeAppearanceChange;
    this.onBindingError = onBindingError;
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
      if (message.id == null) {
        if (
          message.method === "Runtime.bindingCalled"
          && message.params?.name === NATIVE_APPEARANCE_BINDING
          && this.onNativeAppearanceChange
        ) {
          try {
            this.onNativeAppearanceChange(JSON.parse(message.params.payload));
          } catch {
            // 广播负载异常不能打断后续 CDP 命令。
          }
        }
        return;
      }
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
    try {
      await this.command("Runtime.enable");
      await this.command("Runtime.addBinding", { name: NATIVE_APPEARANCE_BINDING });
    } catch (error) {
      this.onBindingError?.(error);
    }
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

  /// 通过主窗口的 Electron bridge 热更新 ChatGPT 原生明暗模式，并等待设置落盘响应。
  async setNativeAppearanceTheme(themeId) {
    const mode = appearanceNativeMode(themeId);
    const requestId = `gpt-switch-native-theme-${crypto.randomUUID()}`;
    const expression = `(async () => {
      const requestId = ${JSON.stringify(requestId)};
      const bridge = window.electronBridge;
      if (typeof bridge?.sendMessageFromView !== "function") {
        throw new Error("ChatGPT 原生外观设置接口不可用");
      }
      let cleanup = () => {};
      const responsePromise = new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          cleanup();
          reject(new Error("ChatGPT 原生外观设置超时"));
        }, 5000);
        const listener = (event) => {
          const response = event.data;
          if (response?.type !== "fetch-response" || response?.requestId !== requestId) return;
          cleanup();
          if (response.responseType !== "success") {
            reject(new Error(response.error || "ChatGPT 原生外观设置失败"));
            return;
          }
          resolve(response);
        };
        cleanup = () => {
          clearTimeout(timeout);
          window.removeEventListener("message", listener);
        };
        window.addEventListener("message", listener);
      });
      try {
        await bridge.sendMessageFromView({
          type: "fetch",
          requestId,
          url: "vscode://codex/set-setting",
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ key: "appearanceTheme", value: ${JSON.stringify(mode)} }),
          responsePriority: "normal",
        });
      } catch (error) {
        cleanup();
        throw error;
      }
      const response = await responsePromise;
      const result = response.bodyJsonString ? JSON.parse(response.bodyJsonString) : null;
      if (result?.success !== true) throw new Error("ChatGPT 原生外观设置未生效");
      return { success: true, mode: ${JSON.stringify(mode)} };
    })()`;
    const evaluated = await this.command("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
      allowUnsafeEvalBlockedByCSP: true,
    });
    if (evaluated.exceptionDetails) {
      const description = evaluated.exceptionDetails.exception?.description
        || evaluated.exceptionDetails.text
        || "ChatGPT 原生外观设置失败";
      throw new Error(description);
    }
    if (evaluated.result?.value?.success !== true) {
      throw new Error("ChatGPT 原生外观设置未生效");
    }
    return mode;
  }

  /// 读取桥接层当前真实模式；排队较久的广播必须用它剔除其他窗口迟到的旧回声。
  async getNativeAppearanceMode() {
    const evaluated = await this.command("Runtime.evaluate", {
      expression: `(() => {
        const mode = window.electronBridge?.getSystemThemeVariant?.();
        return mode === "dark" || mode === "light" ? mode : null;
      })()`,
      returnByValue: true,
    });
    const mode = evaluated?.result?.value;
    return mode === "dark" || mode === "light" ? mode : null;
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
const AUTH_PATH = path.join(CODEX_HOME, "auth.json");
const DEFAULT_CATALOG_PATH = path.join(CODEX_HOME, "model_catalog.json");
const CATALOG_RECORD = path.join(SUPPORT_DIR, "catalog.json");
const CHANNELS_CONFIG = path.join(HOME, ".gptswitch", "channels.json");
const CODEX_RECORD = path.join(HOME, ".gptswitch", "codex.json");
const PROXY_CONFIG = path.join(HOME, ".gptswitch", "proxy.json");
const AGENTS_STATE = path.join(HOME, ".gptswitch", "agents.json");
const APPEARANCE_CONFIG = path.join(HOME, ".gptswitch", "appearance.json");

/// 渠道配置不存在时按这个顺序找老配置导入：本插件旧目录、更早的 CodexModelUnlocker 目录。
const channelImportOptions = () => ({
  userConfigPath: USER_CONFIG,
  authPath: AUTH_PATH,
  recordPath: CODEX_RECORD,
  modelPaths: [LEGACY_MODELS, path.join(LEGACY_SUPPORT_DIR, "models.json")],
});

const pickerState = () => loadChannelState(CHANNELS_CONFIG, channelImportOptions());
/// 选择器和模型目录里该出现哪些渠道。转发服务没起来时只能直连，带 `gpts-` 前缀的模型上游不认，
/// 所以那种情况退回只留当前渠道。
const visiblePickerState = () => {
  const state = pickerState();
  if (proxyPort) return state;
  return { ...state, channels: state.channels.filter((channel) => channel.id === state.current) };
};

const pickerModels = () => {
  const state = visiblePickerState();
  return state.current ? pickerModelsFromState(state) : [];
};

const readCodexCatalog = (binary) => {
  const result = spawnSync(binary, ["debug", "models", "--bundled"], {
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    timeout: 30_000,
    windowsHide: true,
  });
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || "").trim()
      || result.error?.message
      || result.status;
    throw new Error(`读取官方模型目录失败：${detail}`);
  }
  const text = result.stdout || "";
  const start = text.indexOf("{");
  if (start < 0) throw new Error("官方模型目录不是 JSON");
  const parsed = JSON.parse(text.slice(start));
  if (!Array.isArray(parsed?.models)) throw new Error("官方模型目录缺少 models");
  return parsed;
};

/// 商店版客户端自带的 codex 存在但不能执行，只能用客户端按用户安装的 codex 运行时；
/// 独立安装版则用它自己那份，保证读到的官方模型目录和客户端一致。
const windowsCodexBinary = (appPath) => {
  const candidates = [];
  if (!WINDOWS_PACKAGED_CLIENT.test(appPath)) {
    // 新版客户端把 codex 挪进了 codex-cli/bin，旧版放在 resources 根下。
    candidates.push(path.join(path.dirname(appPath), "resources", "codex-cli", "bin", "codex.exe"));
    candidates.push(path.join(path.dirname(appPath), "resources", "codex.exe"));
  }
  try {
    const directories = fs.readdirSync(WINDOWS_CODEX_BIN_DIR, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => {
        const directory = path.join(WINDOWS_CODEX_BIN_DIR, entry.name);
        let modified = 0;
        try { modified = fs.statSync(directory).mtimeMs; } catch { /* 读不到时间就排最后 */ }
        return { directory, modified };
      })
      .sort((left, right) => right.modified - left.modified);
    for (const { directory } of directories) candidates.push(path.join(directory, "codex.exe"));
  } catch {
    // 客户端没有安装按用户的 codex 运行时。
  }
  return candidates.find((candidate) => fs.existsSync(candidate)) || null;
};

/// 新版客户端把 codex 挪进了 codex-cli/bin（codex-package.json 里的 entrypoint 就是它），旧版直接放在 Resources 下。
const macCodexBinary = (appPath) => [
  path.join(appPath, "Contents", "Resources", "codex-cli", "bin", "codex"),
  path.join(appPath, "Contents", "Resources", "codex"),
].find((candidate) => fs.existsSync(candidate)) || null;

/// Codex 模型目录协议只接受 major.minor.patch；桌面端自带版本可能带 prerelease 后缀。
const readCodexClientVersion = (binary) => {
  const result = spawnSync(binary, ["--version"], {
    encoding: "utf8",
    maxBuffer: 1024 * 1024,
    timeout: 10_000,
    windowsHide: true,
  });
  if (result.status !== 0) return "";
  return /(\d+\.\d+\.\d+)/.exec(result.stdout || "")?.[1] || "";
};

const readBundledCatalog = (appPath) => {
  if (IS_WINDOWS) {
    const binary = windowsCodexBinary(appPath);
    if (!binary) throw new Error("未找到 ChatGPT 自带的模型目录工具，无法读取官方模型目录");
    return readCodexCatalog(binary);
  }
  const binary = macCodexBinary(appPath);
  if (!binary) throw new Error("未找到 ChatGPT 自带的模型目录工具，无法读取官方模型目录");
  return readCodexCatalog(binary);
};

/// Windows 路径含反斜杠，写进 TOML 基本字符串会被当成非法转义，所以用字面量字符串。
const tomlString = (value) => (/\\/.test(value)
  ? `'${value.replaceAll("'", "''")}'`
  : JSON.stringify(value));

const ensureCatalogPointer = (catalogPath) => {
  if (!fs.existsSync(USER_CONFIG)) return false;
  const text = fs.readFileSync(USER_CONFIG, "utf8");
  if (/^[ \t]*model_catalog_json[ \t]*=/m.test(text)) return false;
  const line = `model_catalog_json = ${tomlString(catalogPath)}\n`;
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
  if (!appPath) throw appMissing();
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

const appMissing = () => new Error(IS_WINDOWS
  ? "未找到 ChatGPT/Codex 客户端，请先安装桌面端"
  : "未找到 ChatGPT.app 或 Codex.app");

const main = async () => {
  if (typeof WebSocket !== "function") {
    // Windows 上可能回退到 PATH 里的旧 node，早点给出能看懂的提示。
    throw new Error(`需要 Node.js 22 或更高版本（内置 WebSocket），当前是 ${process.version}`);
  }
  if (!acquireLock()) {
    notify("模型解锁已在运行");
    return;
  }

  // 本地转发端口：客户端只连它，由它按模型 id 把请求送回所属渠道，切渠道不用重启客户端。
  // --once 是给检查用的单次模式，起了服务就退不出去，所以只在常驻模式启动。
  if (!runOnce) {
    try {
      // 代理页的设置是唯一来源；旧安装还没有这份文件时，先沿用 config.toml 里写过的端口。
      // 启动阶段可能同时弹出面板，代理配置和渠道列表都先读好再拉起面板，避免 load 抢跑。
      if (!fs.existsSync(PROXY_CONFIG)) {
        const recorded = recordedProxyAddress({ userConfigPath: USER_CONFIG, recordPath: CODEX_RECORD });
        writeProxySettings(PROXY_CONFIG, recorded || {
          host: DEFAULT_PROXY_HOST, port: DEFAULT_PROXY_PORT,
        });
      }
      const settings = readProxySettings(PROXY_CONFIG);
      // 先读取当前配置，让它和代理配置一样在面板启动前完成；之后请求仍然实时读文件，
      // 保存渠道后不需要重启注入器。
      loadChannelState(CHANNELS_CONFIG, channelImportOptions());
      const loadState = () => loadChannelState(CHANNELS_CONFIG, channelImportOptions());
      const started = await startProxy({
        loadState,
        loadProxy: () => readProxySettings(PROXY_CONFIG),
        log,
        host: settings.host,
        port: settings.port,
      });
      proxyServer = started.server;
      proxyHost = started.host;
      proxyPort = started.port;
      let configChanged = false;
      if (started.port !== settings.port) {
        // 占用的端口自动顺延后写回配置，面板刷新时会看到真正在用的端口。
        writeProxySettings(PROXY_CONFIG, { ...settings, host: started.host, port: started.port });
        configChanged = true;
      }
      const recorded = recordedProxyAddress({ userConfigPath: USER_CONFIG, recordPath: CODEX_RECORD });
      const actual = { host: started.host, port: started.port };
      if (recorded && (recorded.host !== actual.host || recorded.port !== actual.port)) {
        // 端口顺延或监听地址变化后，把客户端配置里我们写过的 provider 地址一并修好。
        const repaired = repointProxyUrl({
          userConfigPath: USER_CONFIG, recordPath: CODEX_RECORD, baseUrl: proxyBaseUrl(actual.port, actual.host),
        });
        log("proxy_address_changed", { recorded, actual, repaired });
      }
      if (configChanged) log("proxy_config_updated", { host: started.host, port: started.port });
    } catch (error) {
      // 起不来就退回直连：applyCodex 拿不到转发地址时会写渠道自己的 base_url。
      log("proxy_failed", String(error?.message || error));
      proxyServer = null;
      proxyHost = "";
      proxyPort = 0;
    }
  }

  // 客户端定位可能要跑 PowerShell（约 1~2 秒）：面板先出来，常驻监听随后查找。
  let appPath;
  const clientPath = (refresh = false) => {
    if (refresh || !appPath || !fs.existsSync(appPath)) appPath = findApp();
    return appPath;
  };
  const requests = [];
  // 面板请求一到就立刻结束这一轮等待，别让「保存」白等一整个轮询周期。
  let wakePolling = null;
  const waitPolling = (milliseconds) => new Promise((resolve) => {
    const timer = setTimeout(() => {
      wakePolling = null;
      resolve();
    }, milliseconds);
    wakePolling = () => {
      clearTimeout(timer);
      wakePolling = null;
      resolve();
    };
  });
  startPanel((request, reply) => {
    // 首次读取面板只碰本地文件；客户端恢复最长会等待渲染器，不能把这次读取一起卡住。
    if (request?.action === "load") {
      dispatchRequest(request)
        .then(reply)
        .catch((error) => {
          log("panel_action_failed", String(error?.message || error));
          reply({ ok: false, version: VERSION, error: String(error?.message || error) });
        });
      return;
    }
    requests.push({ request, reply });
    if (wakePolling) wakePolling();
  });
  // CDP 目标变化由 BrowserWatch 推过来，平时完全不用醒；事件漏了还有兜底轮询。
  let browserWatch = null;
  let targetsDirty = true;
  let targetEventRevision = 0;
  let lastTargetPoll = 0;
  const markTargetsDirty = () => {
    targetEventRevision += 1;
    targetsDirty = true;
    if (wakePolling) wakePolling();
  };
  const sessions = new Map();
  let programmaticNativeAppearance = null;
  let programmaticNativeAppearanceTimer = null;
  const clearProgrammaticNativeAppearance = () => {
    programmaticNativeAppearance = null;
    if (programmaticNativeAppearanceTimer) clearTimeout(programmaticNativeAppearanceTimer);
    programmaticNativeAppearanceTimer = null;
  };
  /// 程序性 set-setting 也会广播；按窗口数只吞掉这次操作产生的匹配事件，用户改另一模式仍会生效。
  const expectProgrammaticNativeAppearance = (theme, expectedCount = 1) => {
    const mode = appearanceNativeMode(theme);
    programmaticNativeAppearance = {
      mode,
      remaining: Math.max(1, expectedCount),
      expiresAt: Date.now() + 6000,
    };
    if (programmaticNativeAppearanceTimer) clearTimeout(programmaticNativeAppearanceTimer);
    programmaticNativeAppearanceTimer = setTimeout(() => {
      programmaticNativeAppearance = null;
      programmaticNativeAppearanceTimer = null;
    }, 6500);
    programmaticNativeAppearanceTimer.unref?.();
    return mode;
  };
  const consumeProgrammaticNativeAppearance = (mode) => {
    const expected = programmaticNativeAppearance;
    if (!expected || Date.now() >= expected.expiresAt) {
      clearProgrammaticNativeAppearance();
      return false;
    }
    if (expected.mode !== mode) {
      clearProgrammaticNativeAppearance();
      return false;
    }
    expected.remaining -= 1;
    if (expected.remaining <= 0) clearProgrammaticNativeAppearance();
    return true;
  };
  const isDesktopRendererTarget = (target) => (
    target?.type === "page"
    && String(target.url || "").startsWith("app://-/index.html")
    && !String(target.url || "").includes("avatar-overlay")
  );
  const currentNativeAppearanceMode = async (activeSessions) => {
    let lastError = null;
    for (const session of activeSessions) {
      if (!isDesktopRendererTarget(session.target)) continue;
      try {
        const mode = await session.getNativeAppearanceMode();
        if (mode) return mode;
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError || new Error("未读到 ChatGPT 当前原生外观");
  };
  /**
   * 原生明暗模式需要先于主题样式生效；多个 target 中只有主窗口提供 Electron bridge，
   * 因此按顺序重试，任一主窗口成功即可。
   */
  const syncNativeAppearanceMode = async (activeSessions, theme) => {
    let lastError = null;
    for (const session of activeSessions) {
      if (!isDesktopRendererTarget(session.target)) continue;
      try {
        return await session.setNativeAppearanceTheme(theme);
      } catch (error) {
        lastError = error;
        log("appearance_native_sync_failed", {
          targetId: session.target?.id,
          error: String(error?.message || error),
        });
      }
    }
    throw lastError || new Error("未找到可设置 ChatGPT 原生外观的主窗口");
  };
  let hotRefreshQueue = Promise.resolve();
  const queueHotRefresh = (operation) => {
    const next = hotRefreshQueue.catch(() => {}).then(operation);
    hotRefreshQueue = next.catch(() => {});
    return next;
  };
  let models = [];
  let port = 0;
  let source = "";
  let appMissingSince = null;
  let clientConnectionLostSince = 0;
  let lastClientRunning = false;
  let nextClientRestartAt = 0;
  let clientRestartBackoffMs = 5000;
  /// 按外观状态重建模型与主题 source；注入失败时不会提前覆盖当前运行态。
  const buildAppearanceRuntime = (appearanceState) => {
    const state = visiblePickerState();
    const nextModels = state.current ? pickerModelsFromState(state) : [];
    const appearance = appearanceRuntimeTheme(appearanceState, APPEARANCE_RESOURCE_DIR);
    const nextSource = buildInjectionSource(
      nextModels,
      pickerGroupNameFromState(state),
      pickerChannelNamesFromState(state),
      appearance,
    );
    return { nextModels, nextSource };
  };
  /// 回滚时窗口已全部失联也必须把后续自愈目标切回磁盘中的旧主题。
  const setAppearanceRuntimeState = (appearanceState) => {
    const next = buildAppearanceRuntime(appearanceState);
    models = next.nextModels;
    source = next.nextSource;
    return next;
  };
  /**
   * 把当前文件中的主题推给所有活动窗口；原生外观广播和面板选择共用这条链路。
   */
  const applyAppearanceTheme = async (activeSessions, appearanceState) => {
    const { nextModels, nextSource } = buildAppearanceRuntime(appearanceState);
    const results = await Promise.allSettled(
      activeSessions.map((session) => session.inject(nextSource)),
    );
    const failures = [];
    results.forEach((result, index) => {
      if (result.status === "fulfilled") return;
      const session = activeSessions[index];
      failures.push({
        targetId: session.target?.id,
        error: String(result.reason?.message || result.reason),
      });
      session.close();
      if (sessions.get(session.target?.id) === session) sessions.delete(session.target?.id);
    });
    if (failures.length === results.length) {
      throw new Error(`主题未应用到任何 ChatGPT 窗口：${failures[0]?.error || "未知错误"}`);
    }
    if (failures.length > 0) log("appearance_apply_partial", { failures });
    models = nextModels;
    source = nextSource;
    return true;
  };

  /// 面板保持打开时也同步卡片和“跟随原生”状态，避免选择仍停在已失效的主题上。
  const notifyAppearancePanel = () => {
    if (!statusMenuProcess || statusMenuProcess.stdin.destroyed) return;
    const payload = {
      event: "appearance-updated",
      version: VERSION,
      appearance: appearancePanelState(APPEARANCE_CONFIG, APPEARANCE_RESOURCE_DIR),
    };
    try {
      statusMenuProcess.stdin.write(`${JSON.stringify(payload)}\n`);
    } catch (error) {
      log("appearance_panel_sync_failed", String(error?.message || error));
    }
  };

  /**
   * Codex 原生模式广播是用户主动设置的最终来源：暂停覆盖并持久化，
   * 用户之后点击任一主题卡片时再由 writeAppearanceTheme 重新启用。
   */
  const handleNativeAppearanceChange = (change) => {
    const mode = change?.mode;
    if (mode !== "dark" && mode !== "light") return;
    return queueHotRefresh(async () => {
      // 首次注入时 binding 可能先到；等这轮 target 同步结束，避免同会话并发替换脚本。
      await targetSync;
      const activeSessions = [...sessions.values()].filter((session) => !session.closed);
      if (activeSessions.length === 0) return false;
      let actualMode = mode;
      try {
        actualMode = await currentNativeAppearanceMode(activeSessions);
      } catch (error) {
        log("appearance_native_mode_read_failed", String(error?.message || error));
      }
      if (actualMode !== mode) {
        log("appearance_native_event_stale", { reported: mode, actual: actualMode });
        return false;
      }
      if (consumeProgrammaticNativeAppearance(actualMode)) return false;
      const previous = readAppearanceState(APPEARANCE_CONFIG);
      if (previous.followNative && previous.nativeMode === actualMode) return false;
      const next = {
        ...previous,
        theme: actualMode,
        followNative: true,
        nativeMode: actualMode,
      };
      // 先确认运行时能撤下覆盖，再持久化；写盘失败则恢复上一份运行时主题。
      await applyAppearanceTheme(activeSessions, next);
      try {
        writeNativeAppearanceOverride(APPEARANCE_CONFIG, actualMode);
      } catch (error) {
        await applyAppearanceTheme(activeSessions, previous).catch((rollbackError) => {
          log("appearance_native_rollback_failed", String(rollbackError?.message || rollbackError));
          setAppearanceRuntimeState(previous);
        });
        throw error;
      }
      notifyAppearancePanel();
      log("appearance_follow_native", { mode: actualMode });
      return true;
    }).catch((error) => log("appearance_native_override_failed", String(error?.message || error)));
  };

  /**
   * 串行同步 CDP 目标；主循环和异步 restart 会交错调用，必须避免同一 target 竞争覆盖会话。
   * 页面重载后 targetId 可能不变，已有会话还要确认注入运行时仍在。
   */
  let injectionGeneration = 0;
  let targetSync = Promise.resolve();
  const injectTargets = (targets, { nativeAppearanceTheme = null } = {}) => {
    const run = targetSync.then(async () => {
      const generation = injectionGeneration;
      const injectionSource = source;
      const stale = () => generation !== injectionGeneration;
      let nativeAppearanceSynced = nativeAppearanceTheme == null;
      const activeIds = new Set(targets.map((target) => target.id));
      for (const [id, session] of sessions) {
        if (!activeIds.has(id) || session.closed) {
          session.close();
          sessions.delete(id);
        }
      }

      if (!injectionSource || stale()) return;
      for (const target of targets) {
        const existing = sessions.get(target.id);
        let recovered = false;
        if (existing) {
          let runtimePresent = false;
          try {
            const inspected = await existing.command("Runtime.evaluate", {
              // 全局对象存在不代表页面刷新循环还活着；顺手触发一次刷新，
              // 这样 React 重渲染撤掉分组节点或注入器自愈失败时也能恢复。
              expression: `(() => {
                const runtime = window.__GPT_SWITCH__;
                if (!runtime || runtime.disposed || typeof runtime.refresh !== "function") return false;
                runtime.refresh();
                return true;
              })()`,
              returnByValue: true,
            });
            runtimePresent = inspected?.result?.value === true;
          } catch {
            // 页面正在导航时执行上下文可能暂时不可用，按丢失处理并重新建连。
          }
          if (stale()) return;
          if (runtimePresent) continue;

          existing.close();
          sessions.delete(target.id);
          recovered = true;
          log("target_injection_lost", {
            targetId: target.id,
            title: target.title,
            url: target.url,
          });
        }
        const session = new CDPSession(target, {
          onNativeAppearanceChange: handleNativeAppearanceChange,
          onBindingError: (error) => log("appearance_binding_failed", {
            targetId: target.id,
            error: String(error?.message || error),
          }),
        });
        try {
          await session.connect();
          if (stale()) {
            session.close();
            return;
          }
          // 注入脚本可能马上上报原生模式不匹配；先登记会话，避免首条 binding 丢失。
          sessions.set(target.id, session);
          if (!nativeAppearanceSynced) {
            try {
              await syncNativeAppearanceMode([session], nativeAppearanceTheme);
              nativeAppearanceSynced = true;
            } catch (error) {
              if (sessions.get(target.id) === session) sessions.delete(target.id);
              session.close();
              log("target_native_sync_failed", {
                targetId: target.id,
                error: String(error?.message || error),
              });
              continue;
            }
          }
          const result = await session.inject(injectionSource);
          if (stale()) {
            if (sessions.get(target.id) === session) sessions.delete(target.id);
            session.close();
            log("target_injection_stale", {
              targetId: target.id,
              title: target.title,
              url: target.url,
            });
            return;
          }
          log("target_injected", {
            targetId: target.id,
            title: target.title,
            url: target.url,
            result,
            recovered,
          });
        } catch (error) {
          if (sessions.get(target.id) === session) sessions.delete(target.id);
          session.close();
          log("target_injection_failed", { targetId: target.id, error: String(error?.message || error) });
        }
      }
    });
    targetSync = run.catch(() => {});
    return run;
  };

  const restart = async (existingPort = 0) => {
    let target = appPath;
    if (!existingPort) {
      // Windows 商店更新会更换安装路径；先重新定位，才能退出真正运行的客户端。
      target = clientPath(IS_WINDOWS);
      if (!target) throw appMissing();
      if (appIsRunning(target, true) && !await quitApp(target)) {
        throw new Error("ChatGPT 未能正常退出；请稍后重试");
      }
    }
    injectionGeneration += 1;
    for (const session of sessions.values()) session.close();
    sessions.clear();
    port = 0;
    appMissingSince = null;
    clientConnectionLostSince = 0;
    // 选择器里要出现的是全部启用渠道的模型（见 pickerModels）；没有当前渠道说明刚「还原」，
    // 那就一个都别注入。面板送回的那份模型列表只用来落盘，不决定注入内容。
    const state = visiblePickerState();
    models = state.current ? pickerModelsFromState(state) : [];
    const appearanceState = readAppearanceState(APPEARANCE_CONFIG);
    const appearance = appearanceRuntimeTheme(appearanceState, APPEARANCE_RESOURCE_DIR);
    source = buildInjectionSource(
      models,
      pickerGroupNameFromState(state),
      pickerChannelNamesFromState(state),
      appearance,
    );
    const nextPort = existingPort || await getFreePort();
    if (!existingPort) await launchApp(target, nextPort);
    const eventRevision = targetEventRevision;
    // 现有端口只是热刷新，页面短暂重载时最多等 2 秒；冷启动才允许等渲染进程完整起来。
    const targets = await waitForTargets(nextPort, existingPort ? 2000 : 30_000);
    port = nextPort;
    // 端口确认可用后再连事件通道；刚启动时连不上会一直退回轮询。
    browserWatch?.close();
    browserWatch = new BrowserWatch(nextPort, markTargetsDirty);
    // 连不上不影响功能：没有事件就退回轮询。
    browserWatch.connect().catch((error) => log("browser_watch_failed", String(error?.message || error)));
    await injectTargets(targets, existingPort ? {} : {
      nativeAppearanceTheme: appearanceState.followNative ? null : appearanceState.theme,
    });
    // 等待期间出现的新 target 不在这份快照里，必须保留事件唤醒立即补扫。
    targetsDirty = targetEventRevision !== eventRevision;
    lastTargetPoll = Date.now();
    if (source && sessions.size === 0) throw new Error("插件注入失败，请重试并检查插件日志");
    nextClientRestartAt = 0;
    clientRestartBackoffMs = 5000;
    log("launcher_started", {
      version: VERSION, appPath: target, port, models, appearance: appearance?.id,
    });
    writeState({ pid: process.pid, version: VERSION, appPath: target, port, models, startedAt: Date.now() });
  };

  const applyCodexForChannel = (channel, channelIds, baseUrl = proxyUrl()) => applyChannelToCodex({
    channel, channelIds, authPath: AUTH_PATH, userConfigPath: USER_CONFIG, recordPath: CODEX_RECORD,
    proxyUrl: baseUrl, knownModels: pickerModels().map((model) => model.id),
  });

  const applySavedCatalog = async () => {
    const target = clientPath();
    if (!target) throw appMissing();
    const dest = resolveCatalogPath();
    const catalogExisted = fs.existsSync(dest);
    const originalContent = catalogExisted ? fs.readFileSync(dest, "utf8") : null;
    const catalogModels = pickerModels();
    writeCatalog(dest, buildCatalog(readBundledCatalog(target), catalogModels));
    const pointerAdded = ensureCatalogPointer(dest) || dest === DEFAULT_CATALOG_PATH;
    writeCatalogRecord(CATALOG_RECORD, {
      path: dest,
      pointerAdded,
      fileCreated: !catalogExisted,
      originalContent,
    });
    log("catalog_written", { path: dest, models: catalogModels.map((model) => model.id) });
  };

  const applySavedChannelState = async () => {
    const state = loadChannelState(CHANNELS_CONFIG, channelImportOptions());
    const active = state.channels.find((channel) => channel.id === state.current);
    if (!active) return false;
    applyCodexForChannel(active, state.channels.map((channel) => channel.id));
    await applySavedCatalog();
    return true;
  };

  /// 用户手动关闭客户端后旧 CDP 端口已经失效；应用再次出现时带调试参数重新接管。
  const disconnectClientForRestart = (reason, detail = null) => {
    clientConnectionLostSince = 0;
    appMissingSince = null;
    if (!port) return;
    const lostPort = port;
    port = 0;
    browserWatch?.close();
    browserWatch = null;
    for (const session of sessions.values()) session.close();
    sessions.clear();
    cleanupState();
    log(reason, { port: lostPort, ...(detail || {}) });
  };

  const recoverClientAfterManualRestart = async () => {
    if (attachPort) return false;
    try {
      appPath ??= clientPath();
      const clientRunning = Boolean(appPath && appIsRunning(appPath));
      if (!clientRunning) {
        // 进程监听始终继续；GPT 没运行时清掉重启节流，下次出现立即接管。
        lastClientRunning = false;
        nextClientRestartAt = 0;
        clientRestartBackoffMs = 5000;
        return false;
      }
      if (!lastClientRunning) {
        lastClientRunning = true;
        nextClientRestartAt = 0;
        clientRestartBackoffMs = 5000;
      }
      if (Date.now() < nextClientRestartAt) return false;
      await applySavedChannelState();
      const restarted = await queueHotRefresh(async () => {
        if (port) return false;
        await restart();
        return true;
      });
      if (!restarted) return false;
      nextClientRestartAt = 0;
      clientRestartBackoffMs = 5000;
      log("manual_restart_recovered", { appPath });
      return true;
    } catch (error) {
      nextClientRestartAt = Date.now() + clientRestartBackoffMs;
      clientRestartBackoffMs = Math.min(clientRestartBackoffMs * 2, 60_000);
      log("manual_restart_recovery_failed", String(error?.message || error));
      return false;
    }
  };

  /// 客户端启动后还会再写一次 config.toml（本机实测比写入晚 8 秒）。这里只比对、只记日志，
  /// 用来确认「切换看着成功、请求却还走旧地址」和「刚对齐的 model 又被盖回去」到底是不是它干的。
  const logProviderMismatch = () => {
    const state = loadChannelState(CHANNELS_CONFIG, channelImportOptions());
    const active = state.channels.find((channel) => channel.id === state.current);
    if (!active) return;
    let text = null;
    try {
      text = fs.readFileSync(USER_CONFIG, "utf8");
    } catch {
      return;
    }
    const provider = modelProviderFromToml(text);
    if (provider !== active.id) log("codex_config_mismatch", { expected: active.id, found: provider });
    // 和 applyCodex 用同一份「认识的模型」：用户选的是别的渠道的模型（gpts- 前缀）时不该当成被盖回去。
    const expectedModel = channelDefaultModel(text, active, pickerModels().map((model) => model.id));
    if (expectedModel) {
      log("codex_config_model_mismatch", { expected: expectedModel, found: modelFromToml(text) });
    }
  };

  const dispatchRequest = async (request) => {
    if (request?.action === "quit") {
      // Windows 托盘菜单的“退出”走这里；macOS 面板是直接结束父进程。
      log("panel_quit");
      setTimeout(() => {
        shutdown();
        process.exit(0);
      }, 0);
      return { ok: true, quitting: true, version: VERSION };
    }
    if (request?.action === "check-update") return checkForUpdate();
    if (request?.action === "save" && request?.scope === "appearance") {
      try {
        const theme = writeAppearanceTheme(APPEARANCE_CONFIG, request.theme);
        let applied = false;
        try {
          applied = await queueHotRefresh(async () => {
            const activeSessions = [...sessions.values()].filter((session) => !session.closed);
            if (activeSessions.length === 0) return false;
            expectProgrammaticNativeAppearance(theme, activeSessions.length);
            await syncNativeAppearanceMode(activeSessions, theme);
            return await applyAppearanceTheme(activeSessions, readAppearanceState(APPEARANCE_CONFIG));
          });
        } catch (error) {
          // 配置已经落盘；热应用异常只记录原因，面板统一提示重启后可生效。
          log("appearance_refresh_failed", String(error?.message || error));
        }
        return {
          ok: true,
          saved: true,
          version: VERSION,
          applied,
          restartRequired: !applied,
          appearance: appearancePanelState(APPEARANCE_CONFIG, APPEARANCE_RESOURCE_DIR),
          theme,
        };
      } catch (error) {
        return {
          ok: false,
          version: VERSION,
          error: `保存外观主题失败：${String(error?.message || error)}`,
        };
      }
    }
    const answer = await handlePanelRequest(request, {
      configPath: CHANNELS_CONFIG,
      proxyConfigPath: PROXY_CONFIG,
      codexHome: CODEX_HOME,
      agentsStatePath: AGENTS_STATE,
      importOptions: channelImportOptions(),
      codexClientVersion: () => {
        try {
          const target = clientPath();
          const binary = IS_WINDOWS ? windowsCodexBinary(target) : macCodexBinary(target);
          return binary ? readCodexClientVersion(binary) : "";
        } catch {
          return "";
        }
      },
      restart: async () => {
        // 配置里的目标地址若被其他进程占用，startProxy 会顺延；候选服务必须先启动再切客户端。
        const settings = readProxySettings(PROXY_CONFIG);
        const switched = await switchProxyAndRestart({
          settings,
          currentServer: proxyServer,
          currentHost: proxyHost,
          currentPort: proxyPort,
          restartClient: () => restart(),
          // 渠道写入在 restart 之前执行，这里用候选地址覆盖刚写进去的旧地址。
          updateCodex: async (baseUrl) => {
            const state = loadChannelState(CHANNELS_CONFIG, channelImportOptions());
            const active = state.channels.find((channel) => channel.id === state.current);
            if (!active) return false;
            applyCodexForChannel(active, state.channels.map((channel) => channel.id), baseUrl);
            return true;
          },
          loadState: () => loadChannelState(CHANNELS_CONFIG, channelImportOptions()),
          // 换端口后新起的服务还要接着用同一个出站代理，否则重启一次就静默直连。
          loadProxy: () => readProxySettings(PROXY_CONFIG),
          log,
          proxyConfigPath: PROXY_CONFIG,
          userConfigPath: USER_CONFIG,
          recordPath: CODEX_RECORD,
        });
        proxyServer = switched.server;
        proxyHost = switched.host;
        proxyPort = switched.port;
      },
      applyCodex: applyCodexForChannel,
      restoreCodex: () => restoreCodexConfig({
        authPath: AUTH_PATH, userConfigPath: USER_CONFIG, recordPath: CODEX_RECORD,
      }),
      applyCatalog: applySavedCatalog,
      clearCatalog: () => clearCatalog(clientPath()),
    });
    if (request?.action === "load" && answer?.ok) {
      answer.appearance = appearancePanelState(APPEARANCE_CONFIG, APPEARANCE_RESOURCE_DIR);
    }
    // 等客户端把自己的那份配置写完（实测启动后约 8 秒）再看一眼，只记录不修改。
    if (request?.action === "switch" && answer?.restarted) setTimeout(logProviderMismatch, 12_000).unref();
    // 面板刚改过渠道（含单独启用/禁用）：把新的模型列表推给已经打开的客户端，不用重启它。
    // 不能 await：客户端没在跑时 waitForTargets 要等满 30 秒，面板会一直转圈。
    if (request?.action === "save" && request.scope !== "proxy" && request.scope !== "agents" && answer?.ok && port) {
      queueHotRefresh(() => {
        // restart 会先清空 port；给主循环留出正常的重连窗口，避免误排第二次重启。
        nextClientRestartAt = Date.now() + 5000;
        return restart(port);
      })
        .catch((error) => log("panel_refresh_failed", String(error?.message || error)));
    }
    return { ...answer, version: VERSION };
  };

  if (attachPort) {
    try {
      await restart(attachPort);
    } catch (error) {
      if (!statusMenuProcess || runOnce) throw error;
      showError(error.message);
    }
  }

  while (true) {
    const pending = requests.shift();
    if (pending) {
      const result = await dispatchRequest(pending.request);
      if (!result.ok) log("panel_action_failed", result.error);
      pending.reply(result);
    }

    if (port) {
      const backstop = browserWatch?.active ? TARGET_BACKSTOP_MS : POLL_INTERVAL_MS;
      if (targetsDirty || Date.now() - lastTargetPoll >= backstop) {
        targetsDirty = false;
        lastTargetPoll = Date.now();
        try {
          await injectTargets(await fetchTargets(port));
          clientConnectionLostSince = 0;
        } catch (error) {
          if (runOnce) throw error;
          clientConnectionLostSince ||= Date.now();
          if (!attachPort && Date.now() - clientConnectionLostSince >= 5000
              && appPath && appIsRunning(appPath, true)) {
            disconnectClientForRestart("client_connection_lost", {
              error: String(error?.message || error),
            });
          }
        }
      }
    }
    if (runOnce) break;

    if (port && !attachPort && appPath && !appIsRunning(appPath)) {
      appMissingSince ??= Date.now();
      if (Date.now() - appMissingSince > 5000) {
        disconnectClientForRestart("client_closed");
      }
    } else {
      appMissingSince = null;
    }

    if (!port && !statusMenuProcess) break;
    if (!port) await recoverClientAfterManualRestart();
    await waitPolling(browserWatch?.active ? TARGET_BACKSTOP_MS : POLL_INTERVAL_MS);
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
  try { proxyServer?.close(); } catch { /* 已经关了就算了 */ }
  proxyServer = null;
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
