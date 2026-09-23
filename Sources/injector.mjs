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
  loadModels, handlePanelRequest, buildCatalog, writeCatalog,
  catalogPathFromToml, writeCatalogRecord, clearCatalogFiles,
} from "./model-config.mjs";

const VERSION = "0.1.32";
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
const MODEL_CONFIG = path.join(SUPPORT_DIR, "models.json");
const DEFAULT_MODELS = path.join(SCRIPT_DIR, "models.json");
const STATUS_MENU_PATH = path.join(SCRIPT_DIR, "GPTSwitchStatusMenu");
const STATUS_ICON_PATH = path.join(SCRIPT_DIR, "MenuBarIcon.png");
const WINDOWS_PANEL_PATH = path.join(SCRIPT_DIR, "StatusMenu.ps1");
const WINDOWS_PANEL_ICON = path.join(SCRIPT_DIR, "AppIcon.ico");
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
  if (!IS_MACOS) return;
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

/// Windows 没有 osascript，用系统消息框提示启动期错误。
const windowsMessageBox = (message, icon = "Error") => {
  const script = "Add-Type -AssemblyName PresentationFramework;"
    + ` [System.Windows.MessageBox]::Show(${quotePowerShell(message)}, `
    + `${quotePowerShell(APP_TITLE)}, 'OK', ${quotePowerShell(icon)}) | Out-Null`;
  runPowerShell(script, 120_000);
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

/// Windows 面板是 PowerShell + WPF 写的桌面窗口，等价于 macOS 的菜单栏面板。
const startWindowsPanel = (onRequest) => {
  if (statusMenuProcess || !fs.existsSync(WINDOWS_PANEL_PATH)) return;
  const panelArgs = [
    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
    "-File", WINDOWS_PANEL_PATH,
    "-ParentPid", String(process.pid),
  ];
  if (fs.existsSync(WINDOWS_PANEL_ICON)) panelArgs.push("-IconPath", WINDOWS_PANEL_ICON);
  try {
    statusMenuProcess = spawn(
      "powershell.exe",
      panelArgs,
      { stdio: ["pipe", "pipe", "pipe"], windowsHide: true },
    );
    attachPanelProcess(statusMenuProcess, onRequest);
  } catch (error) {
    log("panel_failed", String(error?.message || error));
    statusMenuProcess = null;
  }
};

const startPanel = IS_WINDOWS ? startWindowsPanel : startStatusMenu;

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

const findMacApp = () => candidateApps.find((candidate) => fs.existsSync(candidate));

const macAppIsRunning = (appPath) => {
  const pattern = `${appPath}/Contents/MacOS/`;
  return spawnSync("/usr/bin/pgrep", ["-f", pattern]).status === 0;
};

const macQuitApp = async (appPath) => {
  runAppleScript(`tell application id "${BUNDLE_ID}" to quit`);
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
let windowsActivationId = null;

const quotePowerShell = (value) => `'${String(value).replaceAll("'", "''")}'`;

const runPowerShell = (script, timeoutMs = 30_000) => spawnSync(
  "powershell.exe",
  ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script],
  { encoding: "utf8", timeout: timeoutMs, windowsHide: true },
);

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

const windowsProcessPaths = (script) => String(runPowerShell(script).stdout || "")
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter(Boolean);

/// 正在运行的客户端：主进程是 ChatGPT.exe；Codex.exe 只在确认是桌面端安装时才认，
/// 否则会把 codex CLI 当成客户端。
const windowsRunningApp = () => {
  const paths = windowsProcessPaths(
    "Get-CimInstance Win32_Process -Filter \"Name='ChatGPT.exe' or Name='Codex.exe'\""
    + " | Select-Object -ExpandProperty ExecutablePath",
  );
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

/// 商店版（MSIX）：目录不能直接执行，只能用应用激活 API 带参数拉起。
const windowsPackagedApp = () => {
  const line = firstLine(runPowerShell(
    "$package = Get-AppxPackage OpenAI.Codex;"
    + " if ($package) {"
    + " $application = (Get-AppxPackageManifest $package).Package.Applications.Application | Select-Object -First 1;"
    + " \"$($package.InstallLocation)|$($package.PackageFamilyName)!$($application.Id)|$($application.Executable)\" }",
  ).stdout);
  const [installLocation, activationId, executable] = line.split("|");
  if (!installLocation || !activationId || !executable) return null;
  windowsActivationId = activationId;
  const candidate = path.join(installLocation, ...executable.split("/"));
  if (!fs.existsSync(candidate)) return null;
  let modified = 0;
  try { modified = fs.statSync(installLocation).mtimeMs; } catch { /* 读不到时间就当最旧 */ }
  return { path: candidate, modified };
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
const windowsClientPids = (appPath) => windowsProcessPaths(
  `Get-CimInstance Win32_Process -Filter "Name=${quotePowerShell(path.basename(appPath))}"`
  + ` | Where-Object { $_.ExecutablePath -eq ${quotePowerShell(appPath)} }`
  + " | Select-Object -ExpandProperty ProcessId",
).map(Number).filter((value) => Number.isInteger(value) && value > 0);

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

const WINDOWS_ACTIVATION_TYPE = `
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IApplicationActivationManager {
    int ActivateApplication([In] string appUserModelId, [In] string arguments, [In] int options, [Out] out uint processId);
    int ActivateForFile([In] string appUserModelId, [In] object itemArray, [In] string verb, [Out] out uint processId);
    int ActivateForProtocol([In] string appUserModelId, [In] object itemArray, [Out] out uint processId);
}
[ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
public class ApplicationActivationManager { }
public static class GPTSwitchActivation {
    public static uint Activate(string appUserModelId, string arguments) {
        var manager = (IApplicationActivationManager)new ApplicationActivationManager();
        uint processId;
        int hr = manager.ActivateApplication(appUserModelId, arguments, 0, out processId);
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        return processId;
    }
}
'@
`;

const windowsDebugArguments = (port) => `--remote-debugging-port=${port} --remote-debugging-address=127.0.0.1`;

const windowsActivateApp = (appPath, port) => {
  // 发现阶段可能走的是“正在运行的客户端”这条路，激活 ID 需要在这里补齐。
  if (!windowsActivationId) windowsPackagedApp();
  if (!windowsActivationId) throw new Error("未找到商店版客户端的激活信息，请改用官方独立安装版");
  const script = "$ErrorActionPreference = \"Stop\"\n"
    + WINDOWS_ACTIVATION_TYPE
    + `\n[GPTSwitchActivation]::Activate(${quotePowerShell(windowsActivationId)}, `
    + `${quotePowerShell(windowsDebugArguments(port))}) | Out-Null\n`;
  const result = runPowerShell(script, 90_000);
  if (result.status !== 0) {
    throw new Error(`启动客户端失败：${firstLine(result.stderr) || firstLine(result.stdout) || result.status}`);
  }
  log("app_activated", { activationId: windowsActivationId, port });
};

const windowsSpawnApp = (appPath, port) => new Promise((resolve, reject) => {
  const child = spawn(
    appPath,
    [`--remote-debugging-port=${port}`, "--remote-debugging-address=127.0.0.1"],
    { detached: true, stdio: "ignore", windowsHide: false },
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
    windowsActivateApp(appPath, port);
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

const readBundledCatalog = (appPath) => {
  if (IS_WINDOWS) {
    const binary = windowsCodexBinary(appPath);
    if (!binary) throw new Error("未找到 Codex 可执行文件，无法读取官方模型目录");
    return readCodexCatalog(binary);
  }
  const binary = path.join(appPath, "Contents", "Resources", "codex");
  if (!fs.existsSync(binary)) throw new Error("未找到 Codex 可执行文件，无法读取官方模型目录");
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

  // 客户端定位要跑 PowerShell（约 1~2 秒），所以懒执行：面板先出来，
  // 只有真的要读写模型目录或重启客户端时才去找。
  let appPath;
  const clientPath = () => (appPath ??= findApp());
  const requests = [];
  startPanel((request, reply) => requests.push({ request, reply }));
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
    let target = appPath;
    if (!existingPort) {
      target = clientPath();
      if (!target) throw appMissing();
      if (appIsRunning(target, true) && !await quitApp(target)) {
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
    if (!existingPort) await launchApp(target, nextPort);
    const targets = await waitForTargets(nextPort);
    port = nextPort;
    await injectTargets(targets);
    if (models.length > 0 && sessions.size === 0) throw new Error("模型注入失败，请重试并检查插件日志");
    log("launcher_started", { version: VERSION, appPath: target, port, models });
    writeState({ pid: process.pid, version: VERSION, appPath: target, port, models, startedAt: Date.now() });
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
    return { ...await handlePanelRequest(request, {
      configPath: MODEL_CONFIG, defaultPath: DEFAULT_MODELS, restart,
      applyCatalog: async (nextModels) => {
        const target = clientPath();
        if (!target) throw appMissing();
        const dest = resolveCatalogPath();
        const fileCreated = !fs.existsSync(dest);
        writeCatalog(dest, buildCatalog(readBundledCatalog(target), nextModels));
        const pointerAdded = ensureCatalogPointer(dest) || dest === DEFAULT_CATALOG_PATH;
        writeCatalogRecord(CATALOG_RECORD, {
          path: dest,
          pointerAdded,
          fileCreated: fileCreated || dest === DEFAULT_CATALOG_PATH,
        });
        log("catalog_written", { path: dest, models: nextModels.map((model) => model.id) });
      },
      clearCatalog: () => clearCatalog(clientPath()),
    }), version: VERSION };
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
      const result = await dispatchRequest(pending.request);
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
