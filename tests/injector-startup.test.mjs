import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { appearanceNativeMode } from "../Sources/appearance-config.mjs";

const injectorSource = fs.readFileSync(
  new URL("../Sources/injector.mjs", import.meta.url),
  "utf8",
);
const injectionSource = fs.readFileSync(
  new URL("../Sources/injection.js", import.meta.url),
  "utf8",
);

const loadCDPSession = () => {
  const start = injectorSource.indexOf("class CDPSession {");
  const end = injectorSource.indexOf("\n}\n\nconst writeFileAtomic", start) + 2;
  assert.notEqual(start, -1, "注入器里找不到 CDP 会话");
  assert.notEqual(end, 1, "注入器里找不到 CDP 会话的终点");
  const binding = injectorSource.match(
    /const NATIVE_APPEARANCE_BINDING = "([^"]+)";/,
  )?.[1];
  assert.ok(binding, "注入器里找不到原生外观广播 binding");
  return new Function(
    "crypto", "WebSocket", "appearanceNativeMode", "NATIVE_APPEARANCE_BINDING", `
    ${injectorSource.slice(start, end)}
    return CDPSession;
  `)(crypto, WebSocket, appearanceNativeMode, binding);
};

test("原生明暗模式通过 ChatGPT 设置桥在主题注入前生效", async () => {
  const CDPSession = loadCDPSession();
  const requests = [];
  const session = new CDPSession({ type: "page", url: "app://-/index.html", title: "ChatGPT" });
  session.command = async (method, params) => {
    requests.push({ method, params });
    return { result: { value: { success: true, mode: params.expression.includes('"dark"') ? "dark" : "light" } } };
  };

  assert.equal(await session.setNativeAppearanceTheme("dark"), "dark");
  assert.equal(await session.setNativeAppearanceTheme("wind"), "light");
  assert.ok(requests.every(({ method }) => method === "Runtime.evaluate"));
  assert.ok(requests.every(({ params }) => params.awaitPromise === true));
  assert.match(requests[0].params.expression, /vscode:\/\/codex\/set-setting/);
  assert.match(requests[0].params.expression, /key: "appearanceTheme"/);
  assert.match(requests[0].params.expression, /value: "dark"/);
  assert.match(requests[1].params.expression, /value: "light"/);
});

test("处理原生模式广播前会从 bridge 重新读取当前值", async () => {
  const CDPSession = loadCDPSession();
  const session = new CDPSession({ type: "page", url: "app://-/index.html", title: "ChatGPT" });
  session.command = async (method, params) => {
    assert.equal(method, "Runtime.evaluate");
    assert.match(params.expression, /getSystemThemeVariant/);
    return { result: { value: "light" } };
  };

  assert.equal(await session.getNativeAppearanceMode(), "light");
});

test("Codex 原生模式广播会暂停 GPT Switch 覆盖并同步面板", () => {
  assert.match(injectionSource, /const VERSION = "0\.1\.32";/);
  assert.match(injectionSource, /subscribeToSystemThemeVariant/);
  assert.match(injectionSource, /__gptSwitchNativeAppearanceChanged/);
  const nativeHandlerStart = injectorSource.indexOf("const handleNativeAppearanceChange");
  const nativeHandlerEnd = injectorSource.indexOf("\n  const injectTargets", nativeHandlerStart);
  assert.notEqual(nativeHandlerStart, -1);
  assert.notEqual(nativeHandlerEnd, -1);
  const nativeHandler = injectorSource.slice(nativeHandlerStart, nativeHandlerEnd);
  assert.match(nativeHandler, /consumeProgrammaticNativeAppearance\(actualMode\)/,
    "程序性设置原生模式时必须只消费预期广播");
  assert.match(nativeHandler, /writeNativeAppearanceOverride/);
  assert.match(nativeHandler, /applyAppearanceTheme/);
  assert.match(nativeHandler, /notifyAppearancePanel/);
  assert.match(injectorSource, /expiresAt: Date\.now\(\) \+ 6000/);
  assert.match(injectorSource, /expected\.mode !== mode/,
    "抑制窗口不能吞掉另一种真实原生模式变化");
  assert.match(injectorSource, /onBindingError: \(error\) => log\("appearance_binding_failed"/,
    "CDP binding 注册失败必须留下可诊断日志");
  const applyIndex = nativeHandler.indexOf(
    "await applyAppearanceTheme(activeSessions, next)",
  );
  const persistIndex = nativeHandler.indexOf("writeNativeAppearanceOverride");
  assert.notEqual(applyIndex, -1);
  assert.notEqual(persistIndex, -1);
  assert.ok(applyIndex < persistIndex, "必须先成功撤下覆盖再持久化跟随原生状态");
  const sessionRegisterIndex = injectorSource.indexOf("sessions.set(target.id, session);");
  const sessionInjectIndex = injectorSource.indexOf(
    "session.inject(injectionSource)", sessionRegisterIndex,
  );
  assert.notEqual(sessionRegisterIndex, -1);
  assert.notEqual(sessionInjectIndex, -1);
  assert.ok(sessionRegisterIndex < sessionInjectIndex,
    "必须先登记会话，首个原生模式 binding 才不会被丢弃");
});

const loadProgrammaticAppearanceGuard = () => {
  const start = injectorSource.indexOf("  let programmaticNativeAppearance = null;");
  const end = injectorSource.indexOf("\n  const isDesktopRendererTarget", start);
  assert.notEqual(start, -1, "注入器里找不到原生模式预期状态");
  assert.notEqual(end, -1, "注入器里找不到原生模式预期状态的终点");
  return new Function(
    "appearanceNativeMode", "Date",
    `${injectorSource.slice(start, end)}
    return {
      expectProgrammaticNativeAppearance,
      consumeProgrammaticNativeAppearance,
    };`,
  );
};

test("程序性原生模式广播只消费一次，另一模式会立即解除旧预期", () => {
  const guard = loadProgrammaticAppearanceGuard()(
    (theme) => (theme === "dark" ? "dark" : "light"),
    Date,
  );
  guard.expectProgrammaticNativeAppearance("dark");
  assert.equal(guard.consumeProgrammaticNativeAppearance("light"), false);
  assert.equal(guard.consumeProgrammaticNativeAppearance("dark"), false,
    "用户先切换另一模式后，旧程序性预期不能吞掉随后的真实深色广播");

  guard.expectProgrammaticNativeAppearance("dark");
  assert.equal(guard.consumeProgrammaticNativeAppearance("dark"), true);
  assert.equal(guard.consumeProgrammaticNativeAppearance("dark"), false,
    "匹配到程序性广播后必须立即清空预期");
});

test("慢广播和多个窗口的程序性模式事件不会被误判为用户切换", () => {
  let now = 0;
  class FakeDate extends Date {
    static now() { return now; }
  }
  const guard = loadProgrammaticAppearanceGuard()(
    (theme) => (theme === "dark" ? "dark" : "light"),
    FakeDate,
  );

  guard.expectProgrammaticNativeAppearance("dark");
  now = 1300;
  assert.equal(guard.consumeProgrammaticNativeAppearance("dark"), true,
    "原生设置请求允许等待 5 秒，程序性广播不能只保留 1.2 秒");

  guard.expectProgrammaticNativeAppearance("dark", 2);
  assert.equal(guard.consumeProgrammaticNativeAppearance("dark"), true);
  assert.equal(guard.consumeProgrammaticNativeAppearance("dark"), true);
  assert.equal(guard.consumeProgrammaticNativeAppearance("dark"), false,
    "按活动窗口数消费完后必须清空预期");
});

const loadNativeAppearanceHandler = () => {
  const start = injectorSource.indexOf("  const handleNativeAppearanceChange =");
  const end = injectorSource.indexOf("\n\n  /**\n   * 串行同步 CDP 目标", start);
  assert.notEqual(start, -1, "注入器里找不到原生模式广播处理器");
  assert.notEqual(end, -1, "注入器里找不到原生模式广播处理器的终点");
  return new Function(
    "queueHotRefresh", "targetSync", "sessions", "currentNativeAppearanceMode",
    "consumeProgrammaticNativeAppearance", "readAppearanceState", "APPEARANCE_CONFIG",
    "applyAppearanceTheme", "writeNativeAppearanceOverride", "setAppearanceRuntimeState",
    "notifyAppearancePanel", "log",
    `${injectorSource.slice(start, end)}
    return handleNativeAppearanceChange;`,
  );
};

test("迟到的程序性深色回声不能覆盖用户随后选择的浅色", async () => {
  const sessions = new Map([["main", {
    target: { type: "page", url: "app://-/index.html", id: "main" },
    closed: false,
  }]]);
  let currentMode = "dark";
  let firstProgrammaticEcho = true;
  let saved = { theme: "ripple", followNative: false, nativeMode: "light" };
  const writes = [];
  const staleEvents = [];
  const handle = loadNativeAppearanceHandler()(
    (operation) => Promise.resolve().then(operation),
    Promise.resolve(),
    sessions,
    async () => currentMode,
    (mode) => {
      if (mode === "dark" && firstProgrammaticEcho) {
        firstProgrammaticEcho = false;
        return true;
      }
      return false;
    },
    () => saved,
    "/appearance.json",
    async () => true,
    (configPath, mode) => {
      assert.equal(configPath, "/appearance.json");
      writes.push(mode);
      saved = { theme: mode, followNative: true, nativeMode: mode };
      return saved;
    },
    () => {},
    () => {},
    (event, detail) => {
      if (event === "appearance_native_event_stale") staleEvents.push(detail);
    },
  );

  await handle({ mode: "dark" });
  currentMode = "light";
  await handle({ mode: "light" });
  await handle({ mode: "dark" });

  assert.deepEqual(writes, ["light"]);
  assert.deepEqual(staleEvents, [{ reported: "dark", actual: "light" }]);
  assert.equal(saved.theme, "light");
  assert.equal(saved.nativeMode, "light");
});

test("配置写入失败且运行时回滚也失败时重新绑定旧运行态", async () => {
  const sessions = new Map([["main", {
    target: { type: "page", url: "app://-/index.html", id: "main" },
    closed: false,
  }]]);
  const previous = { theme: "ripple", followNative: false, nativeMode: "light" };
  const restored = [];
  const logged = [];
  let applyCount = 0;
  const handle = loadNativeAppearanceHandler()(
    (operation) => Promise.resolve().then(operation),
    Promise.resolve(),
    sessions,
    async () => "dark",
    () => false,
    () => previous,
    "/appearance.json",
    async () => {
      applyCount += 1;
      if (applyCount === 1) return true;
      throw new Error("all renderers unavailable");
    },
    () => { throw new Error("disk full"); },
    (state) => restored.push(state),
    () => {},
    (event) => logged.push(event),
  );

  await handle({ mode: "dark" });
  assert.deepEqual(restored, [previous]);
  assert.ok(logged.includes("appearance_native_rollback_failed"));
});

test("原生模式订阅回调从 bridge 重新取值，不依赖回调参数", () => {
  const start = injectionSource.indexOf("  const subscribeNativeAppearance = () => {");
  const end = injectionSource.indexOf("\n  };", start) + 4;
  assert.notEqual(start, -1);
  assert.ok(end >= 4);
  let currentMode = "light";
  let listener = null;
  let unsubscribed = false;
  const notifications = [];
  const state = {
    appearance: { colorScheme: "light" },
    unsubscribeNativeAppearance: null,
  };
  const fakeWindow = {
    electronBridge: {
      getSystemThemeVariant: () => currentMode,
      subscribeToSystemThemeVariant: (callback) => {
        listener = callback;
        return () => { unsubscribed = true; };
      },
    },
    __gptSwitchNativeAppearanceChanged: (payload) => notifications.push(JSON.parse(payload)),
  };
  const subscribe = new Function(
    "state", "window", "NATIVE_APPEARANCE_BINDING",
    `${injectionSource.slice(start, end)}
    return subscribeNativeAppearance;`,
  )(state, fakeWindow, "__gptSwitchNativeAppearanceChanged");

  subscribe();
  currentMode = "dark";
  listener(undefined);
  listener("light");
  assert.deepEqual(notifications, [{ mode: "dark" }]);
  assert.equal(typeof state.unsubscribeNativeAppearance, "function");
  state.unsubscribeNativeAppearance();
  assert.equal(unsubscribed, true);
});

test("注入器用页面暴露的刷新入口确认注入仍在工作", () => {
  assert.match(injectionSource, /state\.refresh = refreshOnce;/,
    "页面必须给注入器暴露一次完整刷新入口");
  assert.match(injectorSource, /typeof runtime\.refresh !== "function"/,
    "注入器必须检查刷新入口，不能只判断全局对象存在");
});

/// 抽出真实的目标同步逻辑，用假 CDP 会话复现页面重载或页面刷新循环失效。
const loadInjectTargets = () => {
  const start = injectorSource.indexOf("  let injectionGeneration = 0;");
  const end = injectorSource.indexOf("\n  const restart =", start);
  assert.notEqual(start, -1, "注入器里找不到目标同步逻辑");
  assert.notEqual(end, -1, "注入器里找不到目标同步逻辑的终点");
  return new Function(
    "sessions", "source", "CDPSession", "log", "handleNativeAppearanceChange",
    "expectProgrammaticNativeAppearance", "syncNativeAppearanceMode",
    `${injectorSource.slice(start, end)}
    return {
      injectTargets,
      advanceGeneration() { injectionGeneration += 1; },
      setSource(next) { source = next; },
    };`,
  );
};

test("冷启动在主题注入前同步原生明暗模式", async () => {
  const calls = [];
  const sessions = new Map();
  class FakeCDPSession {
    constructor(target) {
      this.target = target;
      this.closed = false;
    }

    async connect() {}

    async inject(source) {
      calls.push({ step: "inject", source });
      return { installed: true };
    }

    close() {
      this.closed = true;
    }
  }
  const controls = loadInjectTargets()(
    sessions,
    "injection-source",
    FakeCDPSession,
    () => {},
    () => {},
    (theme) => calls.push({ step: "expect", theme }),
    async (activeSessions, theme) => {
      calls.push({ step: "native", theme, count: activeSessions.length });
      return theme;
    },
  );
  const target = { id: "main", title: "ChatGPT", url: "app://-/index.html" };

  await controls.injectTargets([target], { nativeAppearanceTheme: "dark" });
  assert.deepEqual(calls, [
    { step: "native", theme: "dark", count: 1 },
    { step: "inject", source: "injection-source" },
  ]);
});

test("页面运行时失效后，即使 targetId 不变也会重新注入", async () => {
  const sessions = new Map();
  const events = [];
  const created = [];
  class FakeCDPSession {
    constructor(target) {
      this.target = target;
      this.closed = false;
      this.runtimePresent = false;
      this.probeError = null;
      this.refreshCalls = 0;
      this.injectCount = 0;
      created.push(this);
    }

    async connect() {}

    async command(method, params) {
      assert.equal(method, "Runtime.evaluate");
      if (this.probeError) throw this.probeError;
      const runtime = this.runtimePresent ? {
        disposed: false,
        refresh: () => {
          this.refreshCalls += 1;
          if (this.refreshError) throw this.refreshError;
        },
      } : null;
      const value = new Function("window", `return ${params.expression}`)({
        __GPT_SWITCH__: runtime,
      });
      return { result: { value } };
    }

    async inject(source) {
      assert.equal(source, "injection-source");
      this.injectCount += 1;
      this.runtimePresent = true;
      return { installed: true };
    }

    close() {
      this.closed = true;
    }
  }

  const { injectTargets } = loadInjectTargets()(
    sessions,
    "injection-source",
    FakeCDPSession,
    (event, detail) => events.push({ event, detail }),
    () => {},
    () => {},
    async () => {},
  );
  const target = { id: "same-renderer", title: "ChatGPT", url: "app://-/index.html" };

  await injectTargets([target]);
  assert.equal(created.length, 1);
  assert.equal(created[0].injectCount, 1);
  const refreshCallsBeforeFailure = created[0].refreshCalls;

  created[0].refreshError = new Error("group refresh failed");
  await Promise.all([injectTargets([target]), injectTargets([target])]);
  assert.equal(created[0].refreshCalls, refreshCallsBeforeFailure + 1,
    "对象还在时必须先尝试页面内刷新");
  assert.equal(created.length, 2, "页面刷新失败后要重建会话");
  assert.equal(created[0].closed, true);
  assert.equal(created[1].injectCount, 1);
  assert.equal(sessions.get(target.id), created[1]);
  assert.equal(events.filter((item) => item.event === "target_injection_lost").length, 1);
  assert.equal(events.at(-1).detail.recovered, true);

  const refreshCallsBeforeHealthCheck = created[1].refreshCalls;
  await injectTargets([target]);
  assert.equal(created.length, 2, "运行时仍在时不能重复注入");
  assert.equal(created[1].refreshCalls, refreshCallsBeforeHealthCheck + 1,
    "后续同步要继续触发页面内刷新");
});

test("外观热应用始终排入同一队列，热刷新不使用冷启动长等待", () => {
  const appearanceStart = injectorSource.indexOf(
    'if (request?.action === "save" && request?.scope === "appearance")',
  );
  const channelRequestStart = injectorSource.indexOf("const answer = await handlePanelRequest", appearanceStart);
  assert.notEqual(appearanceStart, -1);
  assert.notEqual(channelRequestStart, -1);
  const appearanceBranch = injectorSource.slice(appearanceStart, channelRequestStart);
  assert.match(appearanceBranch, /await queueHotRefresh\(/,
    "外观保存必须等同一热刷新队列真正完成");
  assert.doesNotMatch(appearanceBranch, /if \(port \|\| sessions\.size > 0\)/,
    "后台 restart 暂清 port/sessions 时不能绕过热刷新队列");
  assert.match(appearanceBranch, /restartRequired:\s*!applied/,
    "主题已保存但未热应用时要明确要求重启");
  assert.doesNotMatch(appearanceBranch, /热应用失败/,
    "可恢复的未生效状态不能作为红色错误文案返回");
  const nativeSyncIndex = appearanceBranch.indexOf("await syncNativeAppearanceMode(");
  const applyIndex = appearanceBranch.indexOf(
    "return await applyAppearanceTheme(activeSessions",
  );
  assert.notEqual(nativeSyncIndex, -1, "切换主题时必须先同步 ChatGPT 原生明暗模式");
  assert.ok(nativeSyncIndex < applyIndex, "原生明暗模式生效后才能注入 GPT Switch 主题");
  assert.match(appearanceBranch,
    /expectProgrammaticNativeAppearance\(theme, activeSessions\.length\)/,
    "程序性原生模式广播必须按活动窗口数匹配");
  assert.match(injectorSource, /waitForTargets\(nextPort, existingPort \? 2000 : 30_000\)/,
    "现有端口热刷新不能沿用冷启动的 30 秒等待");
  const restartStart = injectorSource.indexOf("const restart = async");
  const restartEnd = injectorSource.indexOf("const logProviderMismatch", restartStart);
  const restartSource = injectorSource.slice(restartStart, restartEnd);
  assert.match(restartSource, /const appearanceState = readAppearanceState\(APPEARANCE_CONFIG\)/);
  assert.match(restartSource,
    /injectTargets\(targets, existingPort \? \{\} : \{\s*nativeAppearanceTheme: appearanceState\.followNative \? null : appearanceState\.theme,/,
    "冷启动必须在注入主题前对齐已保存主题对应的原生模式");
});

const loadApplyAppearanceTheme = () => {
  const start = injectorSource.indexOf("  let hotRefreshQueue = Promise.resolve();");
  const end = injectorSource.indexOf("\n  /// 面板保持打开时", start);
  assert.notEqual(start, -1, "注入器里找不到外观热应用逻辑");
  assert.notEqual(end, -1, "注入器里找不到外观热应用逻辑的终点");
  return new Function(
    "sessions", "visiblePickerState", "pickerModelsFromState", "pickerGroupNameFromState",
    "pickerChannelNamesFromState", "appearanceRuntimeTheme", "APPEARANCE_RESOURCE_DIR",
    "buildInjectionSource", "log",
    `${injectorSource.slice(start, end)}
    return {
      applyAppearanceTheme,
      currentSource: () => source,
    };`,
  );
};

test("原生模式撤覆盖时部分窗口失败仍更新运行态并回收失败会话", async () => {
  const sessions = new Map();
  const events = [];
  const alive = {
    target: { id: "main" },
    close() { throw new Error("成功会话不应关闭"); },
    async inject(source) {
      assert.equal(source, "next-source");
      return { installed: true };
    },
  };
  const failed = {
    target: { id: "stale" },
    closed: false,
    async inject() { throw new Error("renderer navigated"); },
    close() { this.closed = true; },
  };
  sessions.set(alive.target.id, alive);
  sessions.set(failed.target.id, failed);
  const controls = loadApplyAppearanceTheme()(
    sessions,
    () => ({ current: "relay" }),
    () => [{ id: "model" }],
    () => "relay",
    () => ["relay"],
    () => ({ id: "light" }),
    "/appearance",
    () => "next-source",
    (event, detail) => events.push({ event, detail }),
  );

  assert.equal(await controls.applyAppearanceTheme(
    [alive, failed],
    { theme: "light", followNative: true },
  ), true);
  assert.equal(controls.currentSource(), "next-source");
  assert.equal(sessions.has("main"), true);
  assert.equal(sessions.has("stale"), false);
  assert.equal(failed.closed, true);
  assert.equal(events[0].event, "appearance_apply_partial");
});

test("restart 清空会话期间完成的旧注入不能回填，最终必须使用新 source", async () => {
  const sessions = new Map();
  const events = [];
  const created = [];
  let releaseFirstInjection;
  let markFirstInjectionStarted;
  const firstInjectionStarted = new Promise((resolve) => { markFirstInjectionStarted = resolve; });
  const firstInjectionGate = new Promise((resolve) => { releaseFirstInjection = resolve; });

  class DeferredCDPSession {
    constructor(target) {
      this.target = target;
      this.closed = false;
      this.injectCount = 0;
      this.injectedSources = [];
      created.push(this);
    }

    async connect() {}

    async command() {
      return { result: { value: false } };
    }

    async inject(source) {
      this.injectCount += 1;
      this.injectedSources.push(source);
      if (created.length === 1) {
        markFirstInjectionStarted();
        await firstInjectionGate;
      }
      return { installed: true };
    }

    close() {
      this.closed = true;
    }
  }

  const controls = loadInjectTargets()(
    sessions,
    "old-source",
    DeferredCDPSession,
    (event, detail) => events.push({ event, detail }),
    () => {},
    () => {},
    async () => {},
  );
  const target = { id: "same-renderer", title: "ChatGPT", url: "app://-/index.html" };

  const staleRun = controls.injectTargets([target]);
  await firstInjectionStarted;
  // 模拟 restart 发生在旧会话已连接但尚未回填 Map 的窗口。
  controls.advanceGeneration();
  controls.setSource("new-source");
  sessions.clear();
  releaseFirstInjection();
  await staleRun;

  assert.equal(sessions.size, 0, "过期注入不能写回会话表");
  assert.equal(created[0].closed, true, "过期注入必须关闭刚建立的会话");
  assert.equal(events.filter((item) => item.event === "target_injection_stale").length, 1);

  await controls.injectTargets([target]);
  assert.equal(created.length, 2);
  assert.deepEqual(created[1].injectedSources, ["new-source"]);
  assert.equal(sessions.get(target.id), created[1]);
});

// Intercept process launches in a child so regression checks cannot touch ChatGPT.
const preload = `
  import os from "node:os";
  import fs from "node:fs";
  import childProcess from "node:child_process";
  import { syncBuiltinESMExports } from "node:module";
  os.homedir = () => process.env.CUSTOM_MODELS_TEST_DIR;
  const existsSync = fs.existsSync;
  fs.existsSync = (value) => /GPTSwitchStatusMenu$|MenuBarIcon\.png$/.test(String(value))
    ? false : existsSync(value);
  childProcess.spawnSync = (file, args) => {
    console.log(JSON.stringify({ file, args }));
    return { status: Number(process.env.CUSTOM_MODELS_TEST_APP_STATUS), stdout: "", stderr: "" };
  };
  childProcess.spawn = (file) => { throw new Error("Unexpected process launch: " + file); };
  syncBuiltinESMExports();
`;

// 这条断言依赖 macOS 的配置目录和 osascript 通知，Windows 走的是另一套实现。
test("startup does not launch, restart, or activate ChatGPT", {
  skip: process.platform === "darwin" ? false : "只在 macOS 上检查",
}, (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "custom-models-startup-"));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const support = path.join(directory, "Library", "Application Support", "GPTSwitch");
  fs.mkdirSync(support, { recursive: true });
  const config = path.join(support, "models.json");
  const lock = path.join(support, "launcher.lock");
  const app = path.join(directory, "ChatGPT.app");
  fs.mkdirSync(app);

  for (const scenario of ["running", "stopped", "empty", "duplicate"]) {
    const contents = JSON.stringify({ models: scenario === "empty" ? [] : [{ id: "test-model" }] });
    fs.writeFileSync(config, contents);
    if (scenario === "duplicate") fs.writeFileSync(lock, String(process.pid));
    const result = spawnSync(process.execPath, [
      "--import", "data:text/javascript," + encodeURIComponent(preload),
      fileURLToPath(new URL("../Sources/injector.mjs", import.meta.url)), "--once", "--app", app,
    ], {
      encoding: "utf8", timeout: 5000,
      env: { ...process.env, CUSTOM_MODELS_TEST_DIR: directory,
        CUSTOM_MODELS_TEST_APP_STATUS: scenario === "stopped" ? "1" : "0" },
    });
    assert.equal(result.status, 0, `${scenario}: ${result.stderr}`);
    const calls = result.stdout.trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
    if (scenario === "duplicate") {
      assert.equal(calls.length, 1);
      assert.equal(calls[0].file, "/usr/bin/osascript");
      assert.match(calls[0].args[1], /^display notification /);
      assert.equal(fs.readFileSync(lock, "utf8"), String(process.pid));
    } else {
      assert.deepEqual(calls, [], scenario);
      assert.equal(fs.existsSync(lock), false);
    }
    assert.equal(fs.readFileSync(config, "utf8"), contents);
  }
});
