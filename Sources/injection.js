(() => {
  "use strict";

  const BOOT_MODELS = [];
  const DEFAULT_GROUP_NAME = "";
  const KNOWN_GROUP_NAMES = [];
  const MODEL_ID_PREFIX = "";
  /// 注入模板自己的版本：模板改动（插的 DOM 形状变了）就抬一格，
  /// 已经开着的客户端会拆掉上一份重建，不至于把旧节点留在页面上。
  const VERSION = "0.1.28";
  const GLOBAL_KEY = "__GPT_SWITCH__";
  const STATSIG_MODEL_CONFIG = "107580212";
  const modelListRequestIds = new Set();
  const appServerModulePromises = new Map();
  const appServerModuleFailures = new Map();
  const APP_SERVER_RETRY_COOLDOWN_MS = 3000;

  const normalizeModel = (value) => {
    const id = typeof value === "string" ? value : value?.id || value?.model || value?.slug;
    if (typeof id !== "string" || !id.trim()) return null;
    const modalities = typeof value === "object" && Array.isArray(value.inputModalities)
      ? value.inputModalities.filter((item) => item === "text" || item === "image")
      : [];
    return {
      id: id.trim(),
      displayName: typeof value === "object" && typeof value.displayName === "string" && value.displayName.trim()
        ? value.displayName.trim()
        : id.trim(),
      inputModalities: modalities.length ? modalities : ["text", "image"],
    };
  };
  const uniqueModels = (values) => {
    const models = new Map();
    for (const value of values) {
      const model = normalizeModel(value);
      if (model) models.set(model.id, model);
    }
    return [...models.values()];
  };
  const modelIds = (models) => models.map((model) => model.id);

  /// 我们从选择器里撤下来的模型 id：渠道被禁用/删除后模型目录里还留着旧条目，得藏掉。
  const droppedModelIds = new Set();

  if (window[GLOBAL_KEY] && window[GLOBAL_KEY].version !== VERSION) {
    try { window[GLOBAL_KEY].dispose?.(); } catch (error) { /* stale state is best-effort cleanup */ }
  }
  if (window[GLOBAL_KEY]?.version === VERSION) {
    window[GLOBAL_KEY].update(BOOT_MODELS, DEFAULT_GROUP_NAME, KNOWN_GROUP_NAMES);
    return {
      installed: true,
      reused: true,
      models: window[GLOBAL_KEY].models,
      version: VERSION,
    };
  }

  const initialModels = uniqueModels(BOOT_MODELS);
  const state = {
    version: VERSION,
    models: initialModels,
    /// 分组用的渠道名清单。热推送时会被换成新的那份，所以不能直接读注入时的常量。
    groupName: DEFAULT_GROUP_NAME,
    groupNames: KNOWN_GROUP_NAMES,
    refreshTimer: null,
    refreshUntil: 0,
    interval: null,
    observer: null,
    domReadyListener: null,
    responsePatch: null,
    dispatchPatch: null,
    statsigPatches: [],
    appServerPatches: [],
    disposed: false,
  };

  const modelDescriptor = (model) => ({
    id: model.id,
    model: model.id,
    slug: model.id,
    name: model.id,
    displayName: model.displayName,
    display_name: model.displayName,
    description: "Custom relay model",
    hidden: false,
    isDefault: false,
    defaultReasoningEffort: "high",
    supportedReasoningEfforts: [
      { reasoningEffort: "none", description: "Disable reasoning" },
      { reasoningEffort: "low", description: "Light reasoning" },
      { reasoningEffort: "medium", description: "Balanced reasoning" },
      { reasoningEffort: "high", description: "Deep reasoning" },
      { reasoningEffort: "xhigh", description: "Extra high reasoning" },
    ],
    inputModalities: model.inputModalities,
    supportsPersonality: false,
    additionalSpeedTiers: [],
    serviceTiers: [],
    defaultServiceTier: null,
    upgrade: null,
    upgradeInfo: null,
    availabilityNux: null,
    modelSpecialty: null,
    multiAgentVersion: "v2",
  });

  const patchStatsigConfig = (config) => {
    const value = config?.value;
    if (!value || typeof value !== "object") return config;

    const available = Array.isArray(value.available_models)
      ? [...value.available_models]
      : [];
    let changed = false;
    for (const name of modelIds(state.models)) {
      if (!available.includes(name)) {
        available.push(name);
        changed = true;
      }
    }
    if (!changed) return config;

    const nextValue = {
      ...value,
      available_models: available,
    };
    try {
      config.value = nextValue;
      return config;
    } catch {
      return { ...config, value: nextValue };
    }
  };

  const modelArrayLooksPatchable = (value, allowEmpty = false) => (
    Array.isArray(value)
    && (allowEmpty || value.length > 0)
    && value.every((item) => item && typeof item === "object"
      && typeof item.model === "string")
  );

  const patchModelArray = (list, allowEmpty = false) => {
    if (!modelArrayLooksPatchable(list, allowEmpty)) return false;
    let changed = false;
    const existing = new Map(list.map((item) => [item.model, item]));
    const customItems = [];
    for (const model of state.models) {
      const item = existing.get(model.id);
      if (item) {
        if (item.hidden !== false) { item.hidden = false; changed = true; }
        if (item.displayName !== model.displayName) { item.displayName = model.displayName; changed = true; }
        if (item.display_name !== model.displayName) { item.display_name = model.displayName; changed = true; }
        customItems.push(item);
      } else {
        customItems.push(modelDescriptor(model));
      }
    }
    // 列表补丁是增量式的：撤下来的模型（渠道被禁用/删除）在模型目录里还留着旧条目，这里藏掉。
    // 带我们前缀的条目一定是自己写进去的，所以不用等一次热推就能认出来。
    const wanted = new Set(modelIds(state.models));
    for (const item of list) {
      const id = String(item.model || "");
      if (wanted.has(id)) continue;
      if (!droppedModelIds.has(id) && !(MODEL_ID_PREFIX && id.startsWith(MODEL_ID_PREFIX))) continue;
      if (item.hidden !== true) { item.hidden = true; changed = true; }
    }
    const expectedPrefix = customItems.map((item) => item.model);
    const hasExpectedPrefix = expectedPrefix.every((id, index) => (
      list[index]?.model === id
    ));
    if (!hasExpectedPrefix) {
      const customIds = new Set(expectedPrefix);
      for (let index = list.length - 1; index >= 0; index -= 1) {
        if (customIds.has(list[index]?.model)) list.splice(index, 1);
      }
      list.unshift(...customItems);
      changed = true;
    }
    return changed;
  };

  const patchModelNames = (list) => {
    if (!Array.isArray(list) || !list.every((item) => typeof item === "string")) return false;
    let changed = false;
    for (const name of modelIds(state.models)) {
      if (!list.includes(name)) { list.push(name); changed = true; }
    }
    return changed;
  };

  const patchModelContainer = (value) => {
    if (!value || typeof value !== "object") return false;
    let changed = false;
    const patch = (list, allowEmpty = false) => {
      if (patchModelArray(list, allowEmpty)) changed = true;
    };
    const allowEmptyModels = ["defaultModel", "default_model", "availableModels", "available_models"]
      .some((key) => key in value);
    patch(value.models, allowEmptyModels);
    if (patchModelNames(value.models)) changed = true;
    patch(value.data);
    patch(value.result);
    patch(value.result?.data);
    patch(value.result?.models);
    const names = modelIds(state.models);
    for (const key of ["availableModels", "available_models"]) {
      if (Array.isArray(value[key])) {
        for (const name of names) {
          if (!value[key].includes(name)) { value[key].push(name); changed = true; }
        }
      }
    }
    for (const key of ["hiddenModels", "hidden_models"]) {
      if (!Array.isArray(value[key])) continue;
      const filtered = value[key].filter((name) => !names.includes(name));
      if (filtered.length !== value[key].length) { value[key] = filtered; changed = true; }
    }
    return changed;
  };

  const patchModelPayload = (value, allowEmpty = true) => (
    Array.isArray(value) ? patchModelArray(value, allowEmpty) : patchModelContainer(value)
  );

  // The model picker gets its data from the app-server query, not fetch().
  // Assets can carry a cache-busting query string, and the optional module is
  // sometimes only referenced by a loaded application bundle.
  const assetUrls = () => [...new Set([
    ...[...document.scripts || []].map((script) => script.src),
    ...Array.from(document.querySelectorAll?.("link[href]") || []).map((link) => link.href),
    ...performance.getEntriesByType("resource").map((entry) => entry.name),
  ].filter((url) => {
    if (!url || typeof url !== "string" || !url.includes("/assets/")) return false;
    return url.split(/[?#]/, 1)[0].endsWith(".js");
  }))];

  const appAssetUrl = (namePart) => assetUrls().find((url) => url.includes(namePart)) || "";

  const APP_SERVER_ASSET_PARTS = ["app-server-manager-signals-", "use-host-config-"];
  let appAssetTextScanPromise = null;
  let appAssetTextScanAt = 0;
  const resolveAssetReference = (reference, source) => {
    const sourceUrl = new URL(source);
    if (reference.startsWith("./assets/") && sourceUrl.pathname.includes("/assets/")) {
      const assetsRoot = sourceUrl.pathname.slice(0, sourceUrl.pathname.lastIndexOf("/assets/") + 1);
      const baseUrl = new URL(sourceUrl.href);
      baseUrl.pathname = assetsRoot;
      baseUrl.search = "";
      baseUrl.hash = "";
      return new URL(reference.slice(2), baseUrl).href;
    }
    return new URL(reference, sourceUrl).href;
  };
  const scanAppAssetScriptText = async () => {
    const found = new Map();
    const candidates = assetUrls().sort((left, right) => {
      const score = (url) => /app-initial|app-main|page-|chatg|signals|server-manager/i.test(url) ? 0 : 1;
      return score(left) - score(right) || right.length - left.length;
    }).slice(0, 16);
    for (const source of candidates) {
      try {
        const response = await fetch(source);
        if (!response.ok) continue;
        const text = await response.text();
        for (const namePart of APP_SERVER_ASSET_PARTS) {
          if (found.has(namePart)) continue;
          const escaped = namePart.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
          const patterns = [
            new RegExp(`["'](\\./(?:assets/)?${escaped}[^"']+\\.js(?:[?#][^"']*)?)["']`),
            new RegExp(`["'](\\.?/assets/${escaped}[^"']+\\.js(?:[?#][^"']*)?)["']`),
            new RegExp(`["']([^"']*/assets/${escaped}[^"']+\\.js(?:[?#][^"']*)?)["']`),
          ];
          for (const pattern of patterns) {
            const match = text.match(pattern);
            if (match) {
              found.set(namePart, resolveAssetReference(match[1], source));
              break;
            }
          }
        }
      } catch {
        // A stale or cross-origin resource must not break the main renderer.
      }
    }
    return found;
  };

  const appAssetUrlFromScriptText = async (namePart) => {
    if (!appAssetTextScanPromise || Date.now() - appAssetTextScanAt >= APP_SERVER_RETRY_COOLDOWN_MS) {
      appAssetTextScanAt = Date.now();
      appAssetTextScanPromise = scanAppAssetScriptText().catch(() => new Map());
    }
    const found = await appAssetTextScanPromise;
    return found.get(namePart) || "";
  };

  const appServerFallbackAssetUrls = () => assetUrls()
    .filter((url) => /use-host-config|app-server-manager-signals|app-initial|app-main|page-|chatg|signals|server-manager|gwqc41kz|c1urrgy0|hsvsqcnf/i.test(url))
    .sort((left, right) => {
      const score = (url) => {
        if (/use-host-config/i.test(url)) return 0;
        if (/app-server-manager-signals/i.test(url)) return 1;
        if (/gwqc41kz|c1urrgy0|hsvsqcnf/i.test(url)) return 2;
        if (/app-initial.*app-main/i.test(url)) return 3;
        if (/app-main/i.test(url)) return 4;
        return 5;
      };
      return score(left) - score(right) || right.length - left.length;
    }).slice(0, 16);

  const loadAppModule = async (namePart) => {
    const failure = appServerModuleFailures.get(namePart);
    if (failure && Date.now() - failure.at < APP_SERVER_RETRY_COOLDOWN_MS) throw failure.error;
    if (!appServerModulePromises.has(namePart)) {
      const promise = Promise.resolve().then(async () => {
        const directUrl = appAssetUrl(namePart) || await appAssetUrlFromScriptText(namePart);
        if (!directUrl) throw new Error(`未找到内部模块: ${namePart}`);
        return import(directUrl);
      }).then((module) => {
        appServerModuleFailures.delete(namePart);
        return module;
      }).catch((error) => {
        appServerModulePromises.delete(namePart);
        appServerModuleFailures.set(namePart, { at: Date.now(), error });
        throw error;
      });
      appServerModulePromises.set(namePart, promise);
    }
    return appServerModulePromises.get(namePart);
  };

  const collectAppServerCandidates = (module) => {
    const candidates = [];
    const seen = new Set();
    const push = (value) => {
      if (!value || typeof value !== "object" || seen.has(value)) return;
      seen.add(value);
      candidates.push(value);
    };
    for (const value of Object.values(module || {})) {
      push(value);
      if (!value || typeof value !== "object") continue;
      if (typeof value.get === "function") {
        try { push(value.get()); } catch {}
        try { push(value.get("local")); } catch {}
      }
      try { for (const nested of Object.values(value).slice(0, 100)) push(nested); } catch {}
    }
    return candidates;
  };

  const loadAppServerModules = async () => {
    const modules = [];
    const seen = new Set();
    const push = (module) => {
      if (!module || typeof module !== "object" || seen.has(module)) return;
      seen.add(module);
      modules.push(module);
    };
    try { push(await loadAppModule("app-server-manager-signals-")); } catch {}
    try { push(await loadAppModule("use-host-config-")); } catch {}
    for (const url of appServerFallbackAssetUrls()) {
      try { push(await import(url)); } catch {}
    }
    return modules;
  };

  const appServerMethod = (method, params) => (
    method === "send-cli-request-for-host" && params?.method
      ? String(params.method)
      : String(method || "")
  );

  const APP_SERVER_MODEL_METHODS = new Set(["model/list", "list-models-for-host"]);
  const patchAppServerResult = (method, result) => {
    if (!APP_SERVER_MODEL_METHODS.has(method)) return result;
    patchModelPayload(result);
    if (result && typeof result === "object" && Array.isArray(result.data)) {
      patchModelArray(result.data, true);
    }
    return result;
  };

  const patchAppServerClient = (client) => {
    if (!client || typeof client.sendRequest !== "function") return false;
    if (client.__gptSwitchPatched === VERSION) return true;
    const previousOriginal = client.__gptSwitchOriginal;
    if (previousOriginal && client.__gptSwitchPatched !== VERSION) {
      try { client.sendRequest = previousOriginal; } catch {}
    }
    const original = previousOriginal || client.sendRequest.bind(client);
    client.__gptSwitchOriginal = original;
    const wrapper = async (method, params, options) => {
      const result = await original(method, params, options);
      return patchAppServerResult(appServerMethod(String(method || ""), params), result);
    };
    client.sendRequest = wrapper;
    client.__gptSwitchPatched = VERSION;
    client.__gptSwitchWrapper = wrapper;
    state.appServerPatches.push({ client, original, wrapper });
    return true;
  };

  let appServerPatchPromise = null;
  const installAppServerPatch = () => {
    if (state.disposed || appServerPatchPromise) return;
    appServerPatchPromise = loadAppServerModules().then((modules) => {
      if (state.disposed) return;
      for (const module of modules) {
        for (const candidate of collectAppServerCandidates(module)) {
          patchAppServerClient(candidate);
        }
      }
    }).catch(() => {}).finally(() => {
      appServerPatchPromise = null;
    });
  };

  const installModelResponsePatch = () => {
    const previous = window.__gptSwitchResponsePatch;
    if (previous?.version === VERSION) return;
    previous?.dispose?.();
    const originalJson = Response.prototype.json;
    if (typeof originalJson !== "function") return;
    const wrapper = async function (...args) {
      const payload = await originalJson.apply(this, args);
      const url = String(this.url || "");
      if (/\/models(?:\/|\?|$)|model\/list|list-models-for-host/i.test(url)) patchModelPayload(payload);
      return payload;
    };
    const record = {
      version: VERSION,
      original: originalJson,
      wrapper,
      dispose: () => {
        if (Response.prototype.json === wrapper) Response.prototype.json = originalJson;
      },
    };
    Response.prototype.json = wrapper;
    window.__gptSwitchResponsePatch = record;
    state.responsePatch = record;
  };

  const patchMcpModelResponse = (data) => {
    if (data?.type !== "mcp-response") return false;
    const message = data.message || data.response;
    const requestId = message?.id != null ? String(message.id) : "";
    if (!modelListRequestIds.has(requestId)) return false;
    modelListRequestIds.delete(requestId);
    let changed = false;
    for (const value of [message?.result, message?.result?.data, message?.result?.models]) {
      if (patchModelPayload(value)) changed = true;
    }
    return changed;
  };

  const installModelListMessagePatch = () => {
    const previous = window.__gptSwitchMessagePatch;
    if (previous?.version === VERSION) return;
    previous?.dispose?.();
    const originalDispatchEvent = window.dispatchEvent;
    const dispatchWrapper = function (event) {
      try {
        const request = event?.detail?.request;
        if (event?.type === "codex-message-from-view"
          && event.detail?.type === "mcp-request" && request?.method === "model/list") {
          request.params = { ...(request.params || {}), includeHidden: true };
          if (request.id != null) modelListRequestIds.add(String(request.id));
        }
        if (event?.type === "message") patchMcpModelResponse(event.data);
      } catch {
        // A failed model-list patch must not break the renderer.
      }
      return Reflect.apply(originalDispatchEvent, window, [event]);
    };
    const messageListener = (event) => {
      try { patchMcpModelResponse(event.data); } catch { /* Best effort. */ }
    };
    window.dispatchEvent = dispatchWrapper;
    window.addEventListener("message", messageListener, true);
    const record = {
      version: VERSION,
      original: originalDispatchEvent,
      wrapper: dispatchWrapper,
      listener: messageListener,
      dispose: () => {
        window.removeEventListener("message", messageListener, true);
        if (window.dispatchEvent === dispatchWrapper) window.dispatchEvent = originalDispatchEvent;
      },
    };
    window.__gptSwitchMessagePatch = record;
    state.dispatchPatch = record;
  };

  const statsigClients = () => {
    const root = window.__STATSIG__ || globalThis.__STATSIG__;
    if (!root || typeof root !== "object") return [];
    const clients = [
      root.firstInstance,
      typeof root.instance === "function" ? root.instance() : null,
    ];
    if (root.instances && typeof root.instances === "object") {
      clients.push(...Object.values(root.instances));
    }
    return clients.filter((client, index, all) => (
      client && typeof client === "object" && all.indexOf(client) === index
    ));
  };

  const patchStatsig = () => {
    let patched = false;
    for (const client of statsigClients()) {
      if (typeof client.getDynamicConfig !== "function") continue;
      if (client.__gptSwitchPatched !== VERSION) {
        const previousOriginal = client.__gptSwitchOriginal;
        if (previousOriginal) {
          try { client.getDynamicConfig = previousOriginal; } catch {}
        }
        const original = previousOriginal || client.getDynamicConfig.bind(client);
        const wrapper = (name, options) => {
          const config = original(name, options);
          return String(name) === STATSIG_MODEL_CONFIG
            ? patchStatsigConfig(config)
            : config;
        };
        client.getDynamicConfig = wrapper;
        client.__gptSwitchOriginal = original;
        client.__gptSwitchWrapper = wrapper;
        client.__gptSwitchPatched = VERSION;
        state.statsigPatches.push({ client, original, wrapper });
        patched = true;
      }
      try {
        patchStatsigConfig(client.getDynamicConfig(STATSIG_MODEL_CONFIG, {
          disableExposureLog: true,
        }));
      } catch {
        // Statsig clients that reject the read are skipped.
      }
    }
    return patched;
  };

  // ---- 模型选择器分组折叠（纯渲染层 DOM 补丁） ----
  //
  // 聚合渠道下原生选择器是一维列表：非默认渠道的模型只能靠展示名尾部的 `（渠道名）`
  // 标归属，几十个模型平铺下来很难找。这里按渠道把行分组，在每组第一行前插一个可点
  // 表头，折叠时只给该组行加类隐藏，行的点击与键盘选中仍然完全交给原生逻辑。
  // 一个分组都没有时只还原补丁、藏掉外来行，不插表头。

  /** 自己插入的节点标记；刷新逻辑靠它把自己产生的 DOM 变化排除在外。 */
  const MODEL_GROUP_EXT = "model-picker-groups";
  const MODEL_GROUP_STYLE_ID = "gpt-switch-model-group-style";
  const MODEL_GROUP_ROW_CLASS = "gpt-switch-group-row";
  const MODEL_GROUP_HIDDEN_CLASS = "gpt-switch-group-hidden";
  /** 不是我们注入的行（客户端内置模型、默认推荐模型集、渠道禁用后残留的旧条目）：藏掉。 */
  const MODEL_GROUP_FOREIGN_CLASS = "gpt-switch-group-foreign";
  const MODEL_GROUP_NATIVE_LABEL_CLASS = "gpt-switch-group-native-label";
  const MODEL_GROUP_OWN_LABEL_CLASS = "gpt-switch-group-own-label";
  const MODEL_GROUP_ROW_GROUP_ATTR = "data-gptswitch-group";
  const MODEL_GROUP_HEADER_GROUP_ATTR = "data-gptswitch-group-header";
  /** 列表 DOM 变化后的合并重扫延迟。 */
  const MODEL_GROUP_RESCAN_DELAY_MS = 60;

  const modelGroupState = {
    /** 上一次补丁的内容指纹，用来跳过多余重建。 */
    signature: "",
    /** 已折叠的分组名：只活在本次会话里，重开菜单不重置。 */
    collapsed: new Set(),
    observer: null,
    observedList: null,
    rescanTimer: null,
  };

  // ---- 分组归属（tests/injection-grouping.test.mjs 会抽出这一段直接执行，改签名要同步改测试）----

  /** 注入器没给出当前渠道名时的兜底分组名，免得表头只剩一个数量徽标。 */
  const MODEL_GROUP_FALLBACK_NAME = "当前渠道";

  const normalizeGroupText = (value) => String(value || "").replace(/\s+/g, " ").trim();

  /**
   * 去掉行尾的选中标记。
   *
   * 客户端把当前选中项的勾画在行文本里（`glm-5.3 ✓`），不剥掉就会认不出这是不是我们的模型。
   */
  const stripRowMarks = (value) => normalizeGroupText(value).replace(/[\s✓✔√]+$/u, "");

  /** 比较用的键：忽略大小写与空白。 */
  const groupLookupKey = (value) => normalizeGroupText(value).replace(/\s+/g, "").toLowerCase();

  /** 默认分组名：注入器给的是当前生效渠道名。 */
  const defaultPickerGroupName = () => normalizeGroupText(state.groupName) || MODEL_GROUP_FALLBACK_NAME;

  /**
   * 后台注入的渠道名清单。
   *
   * 只有后缀命中了它才算渠道：模型自己的显示名也可能以括号结尾（`GLM-4.6 (Thinking)`），
   * 不查清单就会把这种模型名截断、还凭空分出一组。
   */
  let knownGroupNames = null;
  const knownGroupName = (group) => {
    if (!knownGroupNames) {
      knownGroupNames = new Map();
      for (const name of Array.isArray(state.groupNames) ? state.groupNames : []) {
        const key = groupLookupKey(name);
        if (key && !knownGroupNames.has(key)) knownGroupNames.set(key, normalizeGroupText(name));
      }
    }
    // 命中的话返回注入清单里那个写法：后缀大小写、空格和渠道名有出入时也只会有一个表头。
    return knownGroupNames.get(groupLookupKey(group)) || "";
  };

  /** 热推送换渠道名清单：换完把缓存清掉，下次访问按新清单重建。 */
  const setPickerGroupNames = (groupName, groupNames) => {
    if (typeof groupName === "string") state.groupName = groupName;
    if (Array.isArray(groupNames)) {
      state.groupNames = groupNames;
      knownGroupNames = null;
    }
  };

  /** 拆 `glm-5.3（feiyu）`；拆不出渠道名时 `group` 为空。 */
  const splitPickerLabel = (text) => {
    const value = normalizeGroupText(text);
    const match = value.match(/^(.*\S)\s*[（(]\s*([^（()）]{1,64})\s*[)）]$/u);
    if (!match) return { name: value, group: "" };
    const name = match[1].trim();
    const group = name ? knownGroupName(match[2].trim()) : "";
    if (!group) return { name: value, group: "" };
    return { name, group };
  };

  /** 这一行是不是我们注入出去的模型。客户端的「默认推荐模型集」等自己的行不在里面。 */
  let bootModelLabels = null;
  const isBootModelLabel = (text) => {
    if (!bootModelLabels) {
      bootModelLabels = new Set();
      for (const model of Array.isArray(BOOT_MODELS) ? BOOT_MODELS : []) {
        // 显示名和 id 都收进来：客户端某天把行文本换成 id 时，这些行仍然算我们的。
        for (const label of [model?.displayName, model?.id]) {
          const key = groupLookupKey(label);
          if (key) bootModelLabels.add(key);
        }
      }
    }
    return bootModelLabels.has(groupLookupKey(text));
  };

  /** 行文本归到哪个渠道；不是我们的模型就返回空串，那一行保持原生样子。 */
  const pickerRowGroup = (text, parsed = splitPickerLabel(text)) => (
    parsed.group || (isBootModelLabel(text) ? defaultPickerGroupName() : "")
  );

  // ---- 分组归属结束 ----

  /**
   * 原生面板根节点。
   *
   * 菜单关闭后节点会从文档里摘除，`isConnected` 天然就是「开着/关着」的判据；
   * 宫格视图没有折叠的意义，直接跳过。
   */
  const modelPickerPanel = () => {
    for (const panel of document.querySelectorAll("[data-model-picker-view]")) {
      if (panel.getAttribute("data-model-picker-view") === "grid") continue;
      if (!panel.isConnected) continue;
      if (!panel.querySelector('[class*="_ModelList_"]')) continue;
      return panel;
    }
    return null;
  };

  /** 自己插入的节点（含其后代）：刷新逻辑要跳过它们，否则会自己喂自己。 */
  const isOwnGroupNode = (node) => (
    node?.nodeType === Node.ELEMENT_NODE
    && (node.hasAttribute("data-gptswitch-ext") || !!node.closest?.("[data-gptswitch-ext]"))
  );

  /**
   * 行的原生文本。
   *
   * 打过补丁的行直接读被隐藏的原生标签；没打补丁时遍历文本节点并跳过自己插入的
   * 节点 —— React 只重建部分子节点时，把自己的裸名标签算进来会把模型名拼错。
   */
  const pickerRowNativeText = (content) => {
    const native = content.querySelector(`.${MODEL_GROUP_NATIVE_LABEL_CLASS}`);
    if (native) return normalizeGroupText(native.textContent);
    let text = "";
    const walk = (node) => {
      for (const child of node.childNodes) {
        if (child.nodeType === Node.ELEMENT_NODE) {
          if (child.hasAttribute("data-gptswitch-ext")) continue;
          walk(child);
        } else if (child.nodeType === Node.TEXT_NODE) {
          text += child.nodeValue;
        }
      }
    };
    walk(content);
    return normalizeGroupText(text);
  };

  /**
   * 扫描列表里的模型行并按渠道分组。
   *
   * 归属只看行文本尾部的 `（渠道名）`，其余行必须是注入出去的模型才归当前渠道；客户端的
   * 自己的行（「默认推荐模型集」、内置模型）不归任何渠道，保持原生样子。
   * 不做「按模型名记住上次归属」：同名模型可能同时存在于两个渠道，那样会把当前渠道的
   * 裸名行挂到别的渠道表头下面。
   */
  const collectPickerGroups = (list) => {
    const groups = new Map();
    for (const row of list.querySelectorAll('[role="menuitemradio"]')) {
      const content = row.querySelector("[data-menu-row-content]") || row;
      const nativeText = pickerRowNativeText(content);
      if (!nativeText) continue;
      const cleanText = stripRowMarks(nativeText);
      const parsed = splitPickerLabel(cleanText);
      const name = pickerRowGroup(cleanText, parsed);
      if (!name) continue;
      let group = groups.get(name);
      if (!group) {
        group = { name, rows: [] };
        groups.set(name, group);
      }
      group.rows.push({ row, content, nativeText, label: parsed.name || nativeText });
    }
    return [...groups.values()];
  };

  const pickerGroupsSignature = (groups) => groups
    .map((group) => `${group.name}:${group.rows.map((item) => item.nativeText).join("|")}`)
    .join("||");

  const cssEscapeValue = (value) => (
    typeof CSS !== "undefined" && typeof CSS.escape === "function"
      ? CSS.escape(value)
      : String(value).replace(/["\\]/g, "\\$&")
  );

  /** 表头是否还在原位：React 做一次重渲染就可能顺手回收它们。 */
  const pickerGroupHeadersIntact = (list, groups) => (
    groups.every((group) => {
      const header = list.querySelector(`[${MODEL_GROUP_HEADER_GROUP_ATTR}="${cssEscapeValue(group.name)}"]`);
      const first = group.rows[0]?.row;
      return !!header && !!first && header.nextElementSibling === first;
    })
  );

  /** 建表头：箭头 + 组名 + 数量徽标，点击只切换折叠状态。 */
  const createPickerGroupHeader = (group) => {
    const header = document.createElement("button");
    header.type = "button";
    header.className = "gpt-switch-group-header";
    header.setAttribute("data-gptswitch-ext", MODEL_GROUP_EXT);
    header.setAttribute(MODEL_GROUP_HEADER_GROUP_ATTR, group.name);
    header.setAttribute("aria-expanded", "true");
    const chevron = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    chevron.setAttribute("viewBox", "0 0 12 12");
    chevron.setAttribute("aria-hidden", "true");
    chevron.setAttribute("class", "gpt-switch-group-chevron");
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", "M4 2.5 8 6 4 9.5");
    path.setAttribute("fill", "none");
    path.setAttribute("stroke", "currentColor");
    path.setAttribute("stroke-width", "1.4");
    path.setAttribute("stroke-linecap", "round");
    path.setAttribute("stroke-linejoin", "round");
    chevron.appendChild(path);
    const title = document.createElement("span");
    title.className = "gpt-switch-group-title";
    title.textContent = group.name;
    const count = document.createElement("span");
    count.className = "gpt-switch-group-count";
    count.textContent = String(group.rows.length);
    header.append(chevron, title, count);
    header.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      togglePickerGroup(group.name);
    });
    // 指针事件冒到菜单外会把菜单关掉；行由原生自己拦，这里是我们的节点。
    header.addEventListener("pointerdown", (event) => event.stopPropagation());
    header.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") event.stopPropagation();
    });
    return header;
  };

  /** 用裸模型名顶替 `模型名（渠道名）`：原生标签隐藏并退出无障碍树。 */
  const installPickerRowLabel = (item) => {
    // 原生标签优先按类名找；React 重建过节点时按文本找回来。
    const native = item.content.querySelector(`.${MODEL_GROUP_NATIVE_LABEL_CLASS}`)
      || findRowLabelElement(item.content, stripRowMarks(item.nativeText))
      || findRowLabelElement(item.content, item.nativeText);
    const own = item.content.querySelector(`.${MODEL_GROUP_OWN_LABEL_CLASS}`);
    if (own) {
      if (own.textContent !== item.label) own.textContent = item.label;
    } else if (native?.parentElement) {
      const label = document.createElement("span");
      label.className = MODEL_GROUP_OWN_LABEL_CLASS;
      label.setAttribute("data-gptswitch-ext", MODEL_GROUP_EXT);
      label.textContent = item.label;
      native.parentElement.insertBefore(label, native);
    } else {
      // 找不到承载文本的元素就保持原样：宁可留着原生后缀，也不把行改成空白。
      return;
    }
    if (!native) return;
    native.classList.add(MODEL_GROUP_NATIVE_LABEL_CLASS);
    native.setAttribute("aria-hidden", "true");
  };

  /** 文本完整落在哪个元素上：取最深的那个（不把行内容容器自己算进来）。 */
  const findRowLabelElement = (content, text) => {
    let found = null;
    const walk = (node) => {
      for (const child of node.children) {
        if (isOwnGroupNode(child)) continue;
        if (normalizeGroupText(child.textContent) !== text) continue;
        found = child;
        walk(child);
      }
    };
    walk(content);
    return found;
  };

  const restorePickerRow = (row) => {
    const content = row.querySelector("[data-menu-row-content]") || row;
    content.querySelector(`.${MODEL_GROUP_OWN_LABEL_CLASS}`)?.remove();
    const native = content.querySelector(`.${MODEL_GROUP_NATIVE_LABEL_CLASS}`);
    if (native) {
      native.classList.remove(MODEL_GROUP_NATIVE_LABEL_CLASS);
      native.removeAttribute("aria-hidden");
    }
    row.classList.remove(MODEL_GROUP_ROW_CLASS, MODEL_GROUP_HIDDEN_CLASS);
    row.removeAttribute(MODEL_GROUP_ROW_GROUP_ATTR);
  };

  const clearPickerOwnNodes = (scope) => {
    for (const node of scope.querySelectorAll(`[data-gptswitch-ext="${MODEL_GROUP_EXT}"]`)) {
      if (node.id === MODEL_GROUP_STYLE_ID) continue;
      node.remove();
    }
  };

  /** 还原成原生列表：行恢复原样，自己插的节点摘干净。 */
  const resetPickerGroups = (scope) => {
    modelGroupState.signature = "";
    for (const row of scope.querySelectorAll(`.${MODEL_GROUP_ROW_CLASS}`)) restorePickerRow(row);
    for (const row of scope.querySelectorAll(`.${MODEL_GROUP_FOREIGN_CLASS}`)) {
      row.classList.remove(MODEL_GROUP_FOREIGN_CLASS);
    }
    clearPickerOwnNodes(scope);
  };

  /**
   * 不在我们注入清单里的行全部藏掉。
   *
   * 选择器只该有插件里配置的渠道模型：客户端内置模型、默认推荐模型集对第三方渠道没有意义，
   * 渠道被禁用后模型目录里残留的旧条目（模型目录只在「重启」时重写）也一并挡住。
   */
  const hideForeignPickerRows = (list, groups) => {
    const ours = new Set(groups.flatMap((group) => group.rows.map((item) => item.row)));
    for (const row of list.querySelectorAll('[role="menuitemradio"]')) {
      row.classList.toggle(MODEL_GROUP_FOREIGN_CLASS, !ours.has(row));
    }
  };

  /** 同步折叠状态：行只加/去类，不增删原生节点，React 的对账不受影响。 */
  const applyPickerGroups = (list, groups) => {
    for (const group of groups) {
      // 只剩一个分组时不沿用折叠状态：禁用掉另一条渠道后整份列表会只剩一个表头，
      // 看着像模型全没了。单分组也没有别的组需要折叠开。
      const collapsed = groups.length > 1 && modelGroupState.collapsed.has(group.name);
      for (const item of group.rows) {
        item.row.classList.add(MODEL_GROUP_ROW_CLASS);
        item.row.classList.toggle(MODEL_GROUP_HIDDEN_CLASS, collapsed);
        item.row.setAttribute(MODEL_GROUP_ROW_GROUP_ATTR, group.name);
        installPickerRowLabel(item);
      }
      const header = list.querySelector(`[${MODEL_GROUP_HEADER_GROUP_ATTR}="${cssEscapeValue(group.name)}"]`);
      if (!header) continue;
      header.setAttribute("aria-expanded", collapsed ? "false" : "true");
      header.classList.toggle("gpt-switch-group-header-collapsed", collapsed);
      const count = header.querySelector(".gpt-switch-group-count");
      const total = String(group.rows.length);
      if (count && count.textContent !== total) count.textContent = total;
      header.setAttribute(
        "aria-label",
        `${group.name}，${total} 个模型，${collapsed ? "已折叠" : "已展开"}`,
      );
    }
  };

  const insertPickerGroupNodes = (list, groups) => {
    for (const group of groups) {
      const first = group.rows[0]?.row;
      const parent = first?.parentElement;
      if (!parent) continue;
      parent.insertBefore(createPickerGroupHeader(group), first);
    }
  };

  const installPickerGroupStyle = () => {
    if (document.getElementById(MODEL_GROUP_STYLE_ID)) return;
    const style = document.createElement("style");
    style.id = MODEL_GROUP_STYLE_ID;
    style.setAttribute("data-gptswitch-ext", MODEL_GROUP_EXT);
    style.textContent = `
      .gpt-switch-group-header{display:flex;align-items:center;gap:6px;width:100%;box-sizing:border-box;margin:2px 0 0;padding:4px 8px;border:0;border-radius:8px;background:none;color:var(--color-token-text-secondary,#6f6f7a);font:inherit;font-size:11px;line-height:16px;font-weight:600;text-align:left;cursor:pointer;appearance:none;user-select:none}
      .gpt-switch-group-header:hover{background:var(--color-token-bg-secondary,rgba(127,127,127,.14))}
      .gpt-switch-group-header:focus-visible{outline:1px solid currentColor;outline-offset:1px}
      .gpt-switch-group-chevron{flex:none;width:12px;height:12px;opacity:.75;transform:rotate(90deg);transition:transform .15s ease}
      .gpt-switch-group-header-collapsed .gpt-switch-group-chevron{transform:rotate(0deg)}
      .gpt-switch-group-title{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .gpt-switch-group-count{flex:none;margin-left:auto;padding:0 6px;border-radius:999px;background:var(--color-token-bg-secondary,rgba(127,127,127,.14));color:var(--color-token-text-secondary,#6f6f7a);font-size:10px;font-weight:500}
      [role="menuitemradio"].${MODEL_GROUP_HIDDEN_CLASS}{display:none!important}
      [role="menuitemradio"].${MODEL_GROUP_FOREIGN_CLASS}{display:none!important}
      .${MODEL_GROUP_NATIVE_LABEL_CLASS}{display:none!important}
      .${MODEL_GROUP_OWN_LABEL_CLASS}{min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    `;
    document.head?.appendChild(style);
  };

  const togglePickerGroup = (name) => {
    if (modelGroupState.collapsed.has(name)) modelGroupState.collapsed.delete(name);
    else modelGroupState.collapsed.add(name);
    syncModelPickerGroups();
  };

  const detachPickerGroupObserver = () => {
    modelGroupState.observer?.disconnect();
    modelGroupState.observer = null;
    modelGroupState.observedList = null;
  };

  const schedulePickerGroupRescan = () => {
    if (modelGroupState.rescanTimer != null) return;
    modelGroupState.rescanTimer = window.setTimeout(() => {
      modelGroupState.rescanTimer = null;
      try {
        syncModelPickerGroups();
      } catch {
        // 分组补丁失败不影响原生选择器。
      }
    }, MODEL_GROUP_RESCAN_DELAY_MS);
  };

  /**
   * 只看列表自身的变化，菜单关着时不挂着观察器。
   *
   * 自己插入的表头/标签会触发观察器，这里靠标记属性跳过，避免自己喂自己
   * （早期没有排除时表头会一闪一闪）。
   */
  const observePickerGroupList = (list) => {
    if (modelGroupState.observedList === list) return;
    detachPickerGroupObserver();
    modelGroupState.observedList = list;
    modelGroupState.observer = new MutationObserver((records) => {
      const changed = records.some((record) => (
        [...record.addedNodes, ...record.removedNodes].some((node) => !isOwnGroupNode(node))
      ));
      if (changed) schedulePickerGroupRescan();
    });
    modelGroupState.observer.observe(list, { childList: true, subtree: true });
  };

  const syncModelPickerGroups = () => {
    if (state.disposed) return;
    const panel = modelPickerPanel();
    if (!panel) {
      detachPickerGroupObserver();
      modelGroupState.signature = "";
      return;
    }
    const list = panel.querySelector('[class*="_ModelList_"]');
    if (!list) return;
    const groups = collectPickerGroups(list);
    installPickerGroupStyle();
    observePickerGroupList(list);
    // 一个分组都没有时没得插表头，把之前可能打上的补丁还原掉；但还是只留我们注入的模型。
    // 只剩一个渠道也照样插表头，显示方式跟多渠道一致。
    if (!groups.length) {
      resetPickerGroups(panel);
      hideForeignPickerRows(list, groups);
      return;
    }
    const signature = pickerGroupsSignature(groups);
    if (signature === modelGroupState.signature && pickerGroupHeadersIntact(list, groups)) {
      applyPickerGroups(list, groups);
      hideForeignPickerRows(list, groups);
      return;
    }
    resetPickerGroups(panel);
    // 指纹要写在还原之后：resetPickerGroups 会把它清空，先写就等于每轮都走全量重建。
    modelGroupState.signature = signature;
    insertPickerGroupNodes(list, groups);
    applyPickerGroups(list, groups);
    hideForeignPickerRows(list, groups);
  };

  const disposePickerGroups = () => {
    if (modelGroupState.rescanTimer != null) window.clearTimeout(modelGroupState.rescanTimer);
    modelGroupState.rescanTimer = null;
    detachPickerGroupObserver();
    resetPickerGroups(document);
    document.getElementById(MODEL_GROUP_STYLE_ID)?.remove();
  };

  const refreshOnce = () => {
    patchStatsig();
    installAppServerPatch();
    syncModelPickerGroups();
  };

  const refreshBurst = (durationMs = 3000) => {
    state.refreshUntil = Math.max(state.refreshUntil, Date.now() + durationMs);
    if (state.refreshTimer) return;

    const tick = () => {
      state.refreshTimer = null;
      try {
        refreshOnce();
      } catch {
        // Refreshing patches is best effort.
      }
      if (Date.now() < state.refreshUntil) {
        state.refreshTimer = window.setTimeout(tick, 120);
      }
    };
    tick();
  };

  /**
   * 面板保存后的热推送。
   *
   * 渠道名清单必须跟着一起来：只换模型列表的话，新增或改名的渠道，它的模型后缀认不出来，
   * 会被 hideForeignPickerRows 当成外来行藏掉——用户以为没加进去，其实要等一次重启。
   */
  state.update = (models, groupName, groupNames) => {
    if (state.disposed) return state.models;
    setPickerGroupNames(groupName, groupNames);
    const next = uniqueModels(models);
    const nextIds = new Set(modelIds(next));
    for (const model of state.models) {
      if (!nextIds.has(model.id)) droppedModelIds.add(model.id);
    }
    for (const id of nextIds) droppedModelIds.delete(id);
    state.models = next;
    refreshBurst(3500);
    return state.models;
  };
  state.dispose = () => {
    if (state.disposed) return;
    state.disposed = true;
    if (state.interval != null) window.clearInterval(state.interval);
    if (state.refreshTimer != null) window.clearTimeout(state.refreshTimer);
    state.interval = null;
    state.refreshTimer = null;
    state.observer?.disconnect?.();
    state.observer = null;
    disposePickerGroups();
    if (state.domReadyListener) {
      document.removeEventListener("DOMContentLoaded", state.domReadyListener);
      state.domReadyListener = null;
    }
    const responsePatch = state.responsePatch;
    if (responsePatch && Response.prototype.json === responsePatch.wrapper) {
      Response.prototype.json = responsePatch.original;
    }
    if (window.__gptSwitchResponsePatch === responsePatch) {
      delete window.__gptSwitchResponsePatch;
    }
    const dispatchPatch = state.dispatchPatch;
    dispatchPatch?.dispose?.();
    if (window.__gptSwitchMessagePatch === dispatchPatch) {
      delete window.__gptSwitchMessagePatch;
    }
    for (const { client, original, wrapper } of state.statsigPatches) {
      if (client.getDynamicConfig === wrapper) client.getDynamicConfig = original;
      if (client.__gptSwitchWrapper === wrapper) delete client.__gptSwitchWrapper;
      if (client.__gptSwitchOriginal === original) delete client.__gptSwitchOriginal;
      if (client.__gptSwitchPatched === VERSION) delete client.__gptSwitchPatched;
    }
    for (const { client, original, wrapper } of state.appServerPatches) {
      if (client.sendRequest === wrapper) client.sendRequest = original;
      if (client.__gptSwitchWrapper === wrapper) delete client.__gptSwitchWrapper;
      if (client.__gptSwitchOriginal === original) delete client.__gptSwitchOriginal;
      if (client.__gptSwitchPatched === VERSION) delete client.__gptSwitchPatched;
    }
    state.statsigPatches.length = 0;
    state.appServerPatches.length = 0;
    modelListRequestIds.clear();
    appServerModulePromises.clear();
    appServerModuleFailures.clear();
    appAssetTextScanPromise = null;
    if (window[GLOBAL_KEY] === state) delete window[GLOBAL_KEY];
  };

  window[GLOBAL_KEY] = state;
  installModelResponsePatch();
  installModelListMessagePatch();
  installAppServerPatch();

  const startObserver = () => {
    if (!document.documentElement || state.observer) return;
    state.observer = new MutationObserver((mutations) => {
      const shouldRefresh = mutations.some((mutation) => (
        [...mutation.addedNodes].some((node) => (
          // 自己插入的分组表头/标签不算菜单变化，否则会自己喂自己。
          !isOwnGroupNode(node)
          && node?.nodeType === Node.ELEMENT_NODE
          && (
            node.matches?.("[role='menu'], [role='dialog'], [role='listbox'], [data-radix-popper-content-wrapper]")
            || node.querySelector?.("[role='menu'], [role='dialog'], [role='listbox'], [data-radix-popper-content-wrapper]")
          )
        ))
      ));
      if (shouldRefresh) refreshBurst();
    });
    state.observer.observe(document.documentElement, { childList: true, subtree: true });
  };

  startObserver();
  if (!state.observer) {
    state.domReadyListener = startObserver;
    document.addEventListener("DOMContentLoaded", state.domReadyListener, { once: true });
  }
  state.interval = window.setInterval(refreshOnce, 1000);
  refreshBurst(5000);

  return {
    installed: true,
    reused: false,
    models: state.models.map((model) => ({ ...model })),
    version: VERSION,
  };
})();
