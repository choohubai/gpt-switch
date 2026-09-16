(() => {
  "use strict";

  const BOOT_MODELS = [];
  const VERSION = "0.1.27";
  const GLOBAL_KEY = "__GPT_SWITCH__";
  const STATSIG_MODEL_CONFIG = "107580212";
  const modelListRequestIds = new Set();
  const appServerModulePromises = new Map();
  const appServerModuleFailures = new Map();
  const APP_SERVER_RETRY_COOLDOWN_MS = 3000;

  const normalizeModel = (value) => {
    const id = typeof value === "string" ? value : value?.id || value?.model || value?.slug;
    if (typeof id !== "string" || !id.trim()) return null;
    return {
      id: id.trim(),
      displayName: typeof value === "object" && typeof value.displayName === "string" && value.displayName.trim()
        ? value.displayName.trim()
        : id.trim(),
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

  if (window[GLOBAL_KEY] && window[GLOBAL_KEY].version !== VERSION) {
    try { window[GLOBAL_KEY].dispose?.(); } catch (error) { /* stale state is best-effort cleanup */ }
  }
  if (window[GLOBAL_KEY]?.version === VERSION) {
    window[GLOBAL_KEY].update(BOOT_MODELS);
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
    inputModalities: ["text", "image"],
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

  const refreshOnce = () => {
    patchStatsig();
    installAppServerPatch();
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

  state.update = (models) => {
    if (state.disposed) return state.models;
    state.models = uniqueModels(models);
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
          node?.nodeType === Node.ELEMENT_NODE
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
