import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
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
    [{
      id: "alias-id", displayName: "alias-id", context: 272, inputModalities: ["text", "image"],
    }],
    "没填显示名就存模型 ID");
  assert.deepEqual(validateModels([{ id: "x", webSearch: true }]),
    [{
      id: "x", displayName: "x", context: 272, inputModalities: ["text", "image"],
    }],
    "按模型配置网页搜索作废后，旧配置里的 webSearch 字段在保存时被丢掉");
  assert.deepEqual(validateModels([{ id: "alias-id", displayName: " 旧名称 " }]),
    [{
      id: "alias-id", displayName: "旧名称", context: 272, inputModalities: ["text", "image"],
    }]);
  assert.deepEqual(validateModels([{ id: "x", context: " 1000 " }]),
    [{
      id: "x", displayName: "x", context: 1000, inputModalities: ["text", "image"],
    }]);
  assert.deepEqual(validateModels([{ id: "x", inputModalities: ["image"] }]),
    [{
      id: "x", displayName: "x", context: 272, inputModalities: ["image"],
    }]);
  assert.deepEqual(validateModels([{
    id: "verified", supportsSearchTool: true, supportsParallelToolCalls: true,
  }])[0], {
    id: "verified", displayName: "verified", context: 272, inputModalities: ["text", "image"],
  });
  assert.equal("supportsParallelToolCalls" in validateModels([{
    id: "legacy", supportsParallelToolCalls: true,
  }])[0], false, "旧配置里的 Agent 工具能力字段保存时被丢掉");
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
    apply_patch_tool_type: "freeform",
    experimental_supported_tools: ["send_user_message_async", "clock"],
    extra: "keep",
  }] };
  const catalog = buildCatalog(bundled, [
    {
      id: "gpt-6-astra", displayName: "", context: 272, inputModalities: ["text", "image"],
    },
    {
      id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", context: 1000, inputModalities: ["text"],
    },
  ]);
  assert.equal(catalog.models.length, 2);
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
  assert.equal("supports_search_tool" in catalog.models[1], false, "搜索由 Agent 声明");
  assert.equal("web_search_tool_type" in catalog.models[1], false);
  assert.equal("supports_parallel_tool_calls" in catalog.models[1], false, "并行工具由 Agent 声明");
  assert.equal("apply_patch_tool_type" in catalog.models[1], false);
  assert.deepEqual(catalog.models[1].experimental_supported_tools, [],
    "当前客户端的目录 schema 要求这个字段，空列表表示不声明实验工具");
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

test("catalog omits Agent tool capabilities", () => {
  const catalog = buildCatalog({ models: [{
    slug: "gpt-6-astra",
    apply_patch_tool_type: "freeform",
    experimental_supported_tools: ["send_user_message_async", "clock"],
    supports_search_tool: false,
  }] }, [
    {
      id: "deepseek-v4.1-flash", displayName: "DeepSeek", context: 1000, inputModalities: ["text"],
    },
    {
      id: "glm-5.3", displayName: "GLM", context: 200, inputModalities: ["text"],
    },
    {
      id: "gpt-6-astra-private", displayName: "GPT private", context: 200, inputModalities: ["text"],
    },
  ]);
  assert.equal("supports_search_tool" in catalog.models[1], false);
  assert.equal("supports_parallel_tool_calls" in catalog.models[1], false);
  assert.equal("supports_search_tool" in catalog.models[2], false);
  assert.equal("supports_parallel_tool_calls" in catalog.models[2], false);
  assert.equal("supports_search_tool" in catalog.models[3], false);
  assert.equal("web_search_tool_type" in catalog.models[3], false, "新模型不能从模板继承搜索声明");
  assert.equal("supports_parallel_tool_calls" in catalog.models[3], false);
  assert.equal("apply_patch_tool_type" in catalog.models[3], false);
  assert.deepEqual(catalog.models[3].experimental_supported_tools, []);

  const sameSlug = buildCatalog({ models: [{
    slug: "gpt-6-astra",
    apply_patch_tool_type: "freeform",
    experimental_supported_tools: ["send_user_message_async", "clock"],
    supports_search_tool: false,
    web_search_tool_type: "text",
    supports_parallel_tool_calls: true,
  }] },
    validateModels([{ id: "gpt-6-astra" }]));
  assert.equal("supports_search_tool" in sameSlug.models[0], false);
  assert.equal("web_search_tool_type" in sameSlug.models[0], false);
  assert.equal("supports_parallel_tool_calls" in sameSlug.models[0], false,
    "同 slug 也不能保留模型级的并行工具声明");
  assert.equal("apply_patch_tool_type" in sameSlug.models[0], false);
  assert.deepEqual(sameSlug.models[0].experimental_supported_tools, [],
    "客户端要求这个字段必填，空列表表示没有实验工具声明");
});

test("generated catalog is accepted by the installed Codex parser", (context) => {
  const candidates = process.platform === "darwin"
    ? [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
      ]
    : [];
  const binary = candidates.find((candidate) => fs.existsSync(candidate));
  if (!binary) {
    context.skip("本机没有可执行的 Codex 客户端");
    return;
  }
  const bundled = spawnSync(binary, ["debug", "models", "--bundled"], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  assert.equal(bundled.status, 0, bundled.stderr);
  const bundledCatalog = JSON.parse(bundled.stdout.slice(bundled.stdout.indexOf("{")));
  const catalogPath = path.join(
    fs.mkdtempSync(path.join(os.tmpdir(), "gpt-switch-catalog-contract-")),
    "catalog.json",
  );
  context.after(() => fs.rmSync(path.dirname(catalogPath), { recursive: true, force: true }));
  writeCatalog(catalogPath, buildCatalog(bundledCatalog, [
    { id: "third-party-test", displayName: "Test", context: 128, inputModalities: ["text"] },
    { id: "gpt-6-astra", displayName: "Astra", context: 128, inputModalities: ["text"] },
  ]));
  const parsed = spawnSync(binary, [
    "-c", `model_catalog_json="${catalogPath}"`,
    "debug", "models",
  ], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  assert.equal(parsed.status, 0, parsed.stderr);
  assert.equal(JSON.parse(parsed.stdout).models.some((model) => model.slug === "third-party-test"), true);
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
