import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import {
  buildCatalog, validateModels, writeCatalog,
  catalogPathFromToml, removeCatalogPointerLine, catalogClearPlan, readCatalogRecord, writeCatalogRecord,
  clearCatalogFiles,
} from "../Sources/model-config.mjs";

const defaults = [{ id: "gpt-6-astra", displayName: "", context: 272, inputModalities: ["text", "image"] }];

test("model validation accepts IDs with default context and rejects invalid rows", () => {
  assert.deepEqual(validateModels([{ id: " alias-id " }]),
    [{ id: "alias-id", displayName: "alias-id", context: 272, inputModalities: ["text", "image"], webSearch: false }],
    "没填显示名就存模型 ID");
  assert.equal(validateModels([{ id: "deepseek-v4.1-flash" }])[0].webSearch, true,
    "白名单内的模型默认勾选");
  assert.equal(validateModels([{ id: "GPT-6-Astra" }])[0].webSearch, true,
    "白名单匹配不区分大小写");
  assert.equal(validateModels([{ id: "glm-5.3" }])[0].webSearch, false,
    "白名单外的模型默认不勾");
  assert.equal(validateModels([{ id: "deepseek-v4.1-flash", webSearch: false }])[0].webSearch, false,
    "用户显式取消后不能被前缀规则勾回去");
  assert.equal(validateModels([{ id: "GPT-6-Astra", webSearch: true }])[0].webSearch, true,
    "显式开启的模型不能被归一成关闭");
  assert.deepEqual(validateModels([{ id: "alias-id", displayName: " 旧名称 " }]),
    [{ id: "alias-id", displayName: "旧名称", context: 272, inputModalities: ["text", "image"], webSearch: false }]);
  assert.deepEqual(validateModels([{ id: "x", context: " 1000 " }]),
    [{ id: "x", displayName: "x", context: 1000, inputModalities: ["text", "image"], webSearch: false }]);
  assert.deepEqual(validateModels([{ id: "x", inputModalities: ["image"] }]),
    [{ id: "x", displayName: "x", context: 272, inputModalities: ["image"], webSearch: false }]);
  assert.equal(validateModels([{ id: "x", webSearch: true }])[0].webSearch, true,
    "模型卡片勾了网页搜索才打开");
  // 勾了两次的输入类型去重，顺序按面板勾选顺序。
  assert.deepEqual(validateModels([{ id: "x", inputModalities: ["text", "text"] }])
    .at(0).inputModalities, ["text"]);
  for (const invalid of [null, {}, [null], [{}], [{ id: 123 }], [{ id: "" }], [{ id: "   " }],
    [{ id: "a\nb" }], [{ id: "x".repeat(161) }],
    [defaults[0], { ...defaults[0], id: " gpt-6-astra " }],
    [{ id: "x", context: 0 }], [{ id: "x", context: 1.5 }], [{ id: "x", context: 10001 }],
    [{ id: "x", context: "abc" }]]) {
    assert.throws(() => validateModels(invalid));
  }
  for (const invalid of [[{ id: "x", displayName: 1 }], [{ id: "x", displayName: "a".repeat(161) }],
    [{ id: "x", inputModalities: "text" }], [{ id: "x", inputModalities: ["audio"] }]]) {
    assert.throws(() => validateModels(invalid));
  }
  assert.deepEqual(validateModels([]), []);
});

test("catalog overlay keeps bundled models and applies k windows", () => {
  const bundled = { models: [{
    slug: "gpt-6-astra",
    display_name: "GPT-6-Astra",
    context_window: 272000,
    max_context_window: 872000,
    effective_context_window_percent: 95,
    visibility: "list",
    use_responses_lite: true,
    shell_type: "unified_exec",
    extra: "keep",
  }] };
  const catalog = buildCatalog(bundled, [
    { id: "gpt-6-astra", displayName: "", context: 272, inputModalities: ["text", "image"] },
    { id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", context: 1000, inputModalities: ["text"] },
  ]);
  assert.equal(catalog.models.length, 2);
  assert.equal(catalog.models[0].supports_search_tool, true, "内置同名模型也要按当前选择覆盖搜索能力");
  assert.equal(catalog.models[1].slug, "deepseek-v4-pro");
  assert.equal(catalog.models[1].display_name, "DeepSeek V4 Pro");
  assert.equal(catalog.models[1].description, "DeepSeek V4 Pro");
  assert.deepEqual(catalog.models[1].input_modalities, ["text"]);
  assert.equal(catalog.models[1].context_window, 1_000_000);
  assert.equal(catalog.models[1].max_context_window, 1_000_000);
  assert.equal(catalog.models[1].effective_context_window_percent, 95);
  assert.equal(catalog.models[1].extra, "keep");
  // 渠道模型要按第三方端点声明：Responses Lite 上游不认，模型就会把工具调用当文本吐出来。
  assert.equal(catalog.models[1].use_responses_lite, false);
  assert.equal(catalog.models[1].tool_mode, null);
  assert.equal(catalog.models[1].shell_type, "shell_command");
  assert.equal(catalog.models[1].web_search_tool_type, "text");
  assert.equal(catalog.models[1].supports_search_tool, true, "deepseek 前缀默认打开网页搜索");
  assert.equal(catalog.models[1].web_search_tool_type, "text");
  assert.equal(catalog.models[1].supports_parallel_tool_calls, true);
  assert.deepEqual(catalog.models[1].service_tiers, []);
  assert.deepEqual(buildCatalog(bundled, []).models, bundled.models);
});

test("catalog keeps the bundled display name and applies panel display names", () => {
  const bundled = { models: [{ slug: "gpt-6-astra", display_name: "GPT-6-Astra", context_window: 272000 }] };
  const renamed = buildCatalog(bundled, [
    { id: "gpt-6-astra", displayName: "Astra 官方", context: 272, inputModalities: ["text", "image"] },
  ]);
  assert.equal(renamed.models[0].display_name, "Astra 官方");
  const kept = buildCatalog(bundled, [
    { id: "gpt-6-astra", displayName: "", context: 272, inputModalities: ["text", "image"] },
  ]);
  assert.equal(kept.models[0].display_name, "GPT-6-Astra", "直接把空名字交给 buildCatalog 时保留官方名字");
  // 面板链路先过 validateModels：留空会落成模型 ID，重名时以面板的为准。
  const chained = buildCatalog(bundled, validateModels([{ id: "gpt-6-astra" }]));
  assert.equal(chained.models[0].display_name, "gpt-6-astra");
});

test("catalog enables search only for models that opt in", () => {
  const catalog = buildCatalog({ models: [{ slug: "gpt-6-astra", supports_search_tool: true }] }, [
    { id: "deepseek-v4.1-flash", displayName: "DeepSeek", context: 1000, inputModalities: ["text"] },
    { id: "glm-5.3", displayName: "GLM", context: 200, inputModalities: ["text"], webSearch: false },
    { id: "gpt-6-astra-private", displayName: "GPT private", context: 200, inputModalities: ["text"] },
  ]);
  assert.equal(catalog.models[1].supports_search_tool, true, "DeepSeek 勾选后要写进目录");
  assert.equal(catalog.models[2].supports_search_tool, false, "GLM 不勾时不能被模板带着打开");
  assert.equal(catalog.models[3].supports_search_tool, true, "白名单内的 gpt 模型默认打开");
});

test("catalog cleanup only touches the plugin-managed catalog", () => {
  const home = "/Users/example";
  const codexHome = path.join(home, ".codex");
  const defaultPath = path.join(codexHome, "model_catalog.json");
  const text = 'model = "gpt-6-astra"\nmodel_catalog_json = "~/.codex/model_catalog.json"\n\n[features]\n';
  assert.equal(catalogPathFromToml(text, home, codexHome), defaultPath);
  const removed = removeCatalogPointerLine(text, defaultPath, home, codexHome);
  assert.equal(removed.includes("model_catalog_json"), false);
  assert.equal(removed.includes('model = "gpt-6-astra"'), true);
  assert.equal(removed.includes("[features]"), true);
  assert.equal(removeCatalogPointerLine(text, path.join(codexHome, "other.json"), home, codexHome), text);
  assert.deepEqual(
    catalogClearPlan({ path: defaultPath, pointerAdded: true, fileCreated: true }, defaultPath, defaultPath),
    { path: defaultPath, removePointer: true, deleteFile: true, rewriteBundled: false });
  assert.deepEqual(
    catalogClearPlan({ path: "/tmp/user-catalog.json", pointerAdded: false, fileCreated: false },
      "/tmp/user-catalog.json", defaultPath),
    { path: "/tmp/user-catalog.json", removePointer: false, deleteFile: false, rewriteBundled: true });
  assert.deepEqual(
    catalogClearPlan(null, defaultPath, defaultPath),
    { path: defaultPath, removePointer: true, deleteFile: true, rewriteBundled: false });
  assert.deepEqual(
    catalogClearPlan(null, "/tmp/user-catalog.json", defaultPath),
    { path: "/tmp/user-catalog.json", removePointer: false, deleteFile: false, rewriteBundled: true });
});

test("catalog ownership record keeps the first flags for the same path", (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "custom-models-test-"));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const recordPath = path.join(directory, "catalog.json");
  assert.equal(readCatalogRecord(recordPath), null);
  writeCatalogRecord(recordPath, { path: "/tmp/catalog.json", pointerAdded: true, fileCreated: true });
  writeCatalogRecord(recordPath, { path: "/tmp/catalog.json", pointerAdded: false, fileCreated: false });
  assert.deepEqual(readCatalogRecord(recordPath),
    { path: "/tmp/catalog.json", pointerAdded: true, fileCreated: true });
  writeCatalogRecord(recordPath, { path: "/tmp/other.json", pointerAdded: false, fileCreated: false });
  assert.deepEqual(readCatalogRecord(recordPath),
    { path: "/tmp/other.json", pointerAdded: false, fileCreated: false });
});

test("clearCatalogFiles removes plugin-created files and keeps user-owned catalogs", (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "custom-models-test-"));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const codexHome = path.join(directory, ".codex");
  const userConfigPath = path.join(codexHome, "config.toml");
  const defaultCatalogPath = path.join(codexHome, "model_catalog.json");
  const recordPath = path.join(directory, "support", "catalog.json");
  const bundled = { models: [{ slug: "gpt-6-astra", context_window: 272000 }] };
  const readBundledCatalog = () => bundled;
  fs.mkdirSync(codexHome, { recursive: true });

  fs.writeFileSync(userConfigPath, 'model = "gpt-6-astra"\nmodel_catalog_json = "~/.codex/model_catalog.json"\n');
  writeCatalog(defaultCatalogPath, buildCatalog(bundled, [{ id: "relay-alias", context: 512 }]));
  writeCatalogRecord(recordPath, { path: defaultCatalogPath, pointerAdded: true, fileCreated: true });
  const created = clearCatalogFiles({
    recordPath, userConfigPath, home: directory, codexHome,
    catalogPath: defaultCatalogPath, defaultCatalogPath, readBundledCatalog,
  });
  assert.deepEqual(created,
    { path: defaultCatalogPath, removePointer: true, deleteFile: true, rewriteBundled: false });
  assert.equal(fs.existsSync(defaultCatalogPath), false);
  assert.equal(fs.existsSync(recordPath), false);
  assert.equal(fs.readFileSync(userConfigPath, "utf8"), 'model = "gpt-6-astra"\n');

  const userCatalogPath = path.join(directory, "user-catalog.json");
  fs.writeFileSync(userConfigPath, `model_catalog_json = "${userCatalogPath}"\n`);
  writeCatalog(userCatalogPath, buildCatalog(bundled, [{ id: "relay-alias", context: 512 }]));
  writeCatalogRecord(recordPath, { path: userCatalogPath, pointerAdded: false, fileCreated: false });
  const kept = clearCatalogFiles({
    recordPath, userConfigPath, home: directory, codexHome,
    catalogPath: userCatalogPath, defaultCatalogPath, readBundledCatalog,
  });
  assert.deepEqual(kept,
    { path: userCatalogPath, removePointer: false, deleteFile: false, rewriteBundled: true });
  assert.equal(fs.existsSync(userCatalogPath), true);
  assert.deepEqual(JSON.parse(fs.readFileSync(userCatalogPath, "utf8")).models, bundled.models);
  assert.equal(fs.readFileSync(userConfigPath, "utf8"), `model_catalog_json = "${userCatalogPath}"\n`);
});
