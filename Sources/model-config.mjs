import fs from "node:fs";
import path from "node:path";

export const DEFAULT_CONTEXT_K = 272;
const EFFECTIVE_CONTEXT_PERCENT = 95;
const INPUT_MODALITIES = ["text", "image"];
export const MAX_LABEL_LENGTH = 160;

const hasControlChars = (value) => /[\u0000-\u001f\u007f]/.test(value);

const parseContextK = (value, index) => {
  if (value == null || value === "") return DEFAULT_CONTEXT_K;
  const number = typeof value === "number" ? value : Number(String(value).trim());
  if (!Number.isInteger(number) || number < 1 || number > 10_000) {
    throw new Error(`第 ${index + 1} 行窗口必须是 1 到 10000 的整数（单位 k）`);
  }
  return number;
};

const parseDisplayName = (value, index) => {
  if (value == null) return "";
  if (typeof value !== "string") throw new Error(`第 ${index + 1} 行显示名称必须是文本`);
  const trimmed = value.trim();
  if (trimmed.length > MAX_LABEL_LENGTH || hasControlChars(trimmed)) {
    throw new Error(`第 ${index + 1} 行显示名称不能包含控制字符或超过 160 个字符`);
  }
  return trimmed;
};

/// Codex catalog 只认 text/image；不填时按 codex 自带模型的默认值给两者。
const parseModalities = (value, index) => {
  if (value == null) return [...INPUT_MODALITIES];
  if (!Array.isArray(value)) throw new Error(`第 ${index + 1} 行输入类型必须是列表`);
  const modalities = [...new Set(value.map((item) => (typeof item === "string" ? item.trim() : "")))];
  if (modalities.some((item) => !INPUT_MODALITIES.includes(item))) {
    throw new Error(`第 ${index + 1} 行输入类型只支持 text 和 image`);
  }
  return modalities;
};

export const validateModels = (models) => {
  if (!Array.isArray(models)) throw new Error("模型配置必须是列表");
  const ids = new Set();
  return models.map((model, index) => {
    const value = model?.id;
    if (typeof value !== "string" || !value.trim() || value.trim().length > MAX_LABEL_LENGTH
        || hasControlChars(value)) {
      throw new Error(`第 ${index + 1} 行模型 ID 不能为空、包含控制字符或超过 160 个字符`);
    }
    const id = value.trim();
    if (ids.has(id)) throw new Error(`第 ${index + 1} 行模型 ID 重复：${id}`);
    ids.add(id);
    return {
      id,
      displayName: parseDisplayName(model.displayName, index),
      context: parseContextK(model.context, index),
      inputModalities: parseModalities(model.inputModalities, index),
    };
  });
};

export const atomicWrite = (filePath, contents) => {
  fs.mkdirSync(path.dirname(filePath), { recursive: true, mode: 0o700 });
  const temporary = `${filePath}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(temporary, contents, { mode: 0o600 });
    fs.renameSync(temporary, filePath);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
};

const MINIMAL_MODEL = {
  slug: "",
  display_name: "",
  description: "",
  visibility: "list",
  supported_in_api: true,
  shell_type: "unified_exec",
  default_reasoning_level: "medium",
  supported_reasoning_levels: [],
};

const applyWindow = (entry, tokens) => {
  entry.context_window = tokens;
  entry.max_context_window = tokens;
  entry.effective_context_window_percent = EFFECTIVE_CONTEXT_PERCENT;
};

export const buildCatalog = (bundled, models) => {
  const base = Array.isArray(bundled?.models)
    ? bundled.models.map((entry) => JSON.parse(JSON.stringify(entry)))
    : [];
  const template = base.find((entry) => entry?.slug === "gpt-6-astra") || base[0] || MINIMAL_MODEL;
  const bySlug = new Map(base.map((entry) => [entry.slug, entry]));
  for (const model of models) {
    const tokens = model.context * 1000;
    // 直接调 buildCatalog 的老调用点可能只给了 id/context，这里补默认值。
    const modalities = Array.isArray(model.inputModalities) ? [...model.inputModalities] : [...INPUT_MODALITIES];
    const existing = bySlug.get(model.id);
    if (existing) {
      applyWindow(existing, tokens);
      if (model.displayName) existing.display_name = model.displayName;
      existing.input_modalities = modalities;
      existing.visibility = "list";
      continue;
    }
    const displayName = model.displayName || model.id;
    const entry = {
      ...JSON.parse(JSON.stringify(template)),
      slug: model.id,
      display_name: displayName,
      description: displayName,
      input_modalities: modalities,
      visibility: "list",
      auto_compact_token_limit: null,
      availability_nux: null,
      upgrade: null,
    };
    applyWindow(entry, tokens);
    base.push(entry);
    bySlug.set(model.id, entry);
  }
  return { models: base };
};

export const writeCatalog = (catalogPath, catalog) => {
  atomicWrite(catalogPath, `${JSON.stringify(catalog)}\n`);
};

/// TOML 里路径可能是基本字符串（"..."）或字面量字符串（'...'，Windows 路径用它避免反斜杠转义）。
const CATALOG_POINTER = /^[ \t]*model_catalog_json[ \t]*=[ \t]*(?:"([^"]*)"|'([^']*)')/m;

export const catalogPathFromToml = (text, home, codexHome) => {
  const match = text.match(CATALOG_POINTER);
  if (!match) return null;
  const raw = (match[1] ?? match[2]).replace(/^~(?=[\\/])/, home);
  return path.normalize(path.isAbsolute(raw) ? raw : path.resolve(codexHome, raw));
};

export const removeCatalogPointerLine = (text, catalogPath, home, codexHome) => {
  if (catalogPathFromToml(text, home, codexHome) !== catalogPath) return text;
  return text.replace(/^[ \t]*model_catalog_json[ \t]*=[ \t]*(?:"[^"]*"|'[^']*')[ \t]*\r?\n?/m, "");
};

export const catalogClearPlan = (record, catalogPath, defaultCatalogPath) => {
  const target = typeof record?.path === "string" ? record.path : catalogPath;
  const ownedByDefaultPath = target === defaultCatalogPath;
  const pointerAdded = record ? record.pointerAdded === true : ownedByDefaultPath;
  const fileCreated = record ? record.fileCreated === true : ownedByDefaultPath;
  return {
    path: target,
    removePointer: pointerAdded,
    deleteFile: pointerAdded && fileCreated,
    rewriteBundled: !(pointerAdded && fileCreated),
  };
};

export const readCatalogRecord = (recordPath) => {
  try {
    const record = JSON.parse(fs.readFileSync(recordPath, "utf8"));
    return typeof record?.path === "string" ? record : null;
  } catch {
    return null;
  }
};

export const writeCatalogRecord = (recordPath, { path: catalogPath, pointerAdded, fileCreated }) => {
  const previous = readCatalogRecord(recordPath);
  const record = previous?.path === catalogPath
    ? {
        path: catalogPath,
        pointerAdded: previous.pointerAdded === true || pointerAdded,
        fileCreated: previous.fileCreated === true || fileCreated,
      }
    : { path: catalogPath, pointerAdded, fileCreated };
  atomicWrite(recordPath, `${JSON.stringify(record, null, 2)}\n`);
  return record;
};

export const clearCatalogFiles = ({
  recordPath, userConfigPath, home, codexHome, catalogPath, defaultCatalogPath, readBundledCatalog,
}) => {
  const plan = catalogClearPlan(readCatalogRecord(recordPath), catalogPath, defaultCatalogPath);
  if (plan.removePointer && fs.existsSync(userConfigPath)) {
    const text = fs.readFileSync(userConfigPath, "utf8");
    const next = removeCatalogPointerLine(text, plan.path, home, codexHome);
    if (next !== text) atomicWrite(userConfigPath, next);
  }
  if (plan.deleteFile) {
    fs.rmSync(plan.path, { force: true });
  } else if (fs.existsSync(plan.path)) {
    writeCatalog(plan.path, buildCatalog(readBundledCatalog(), []));
  }
  fs.rmSync(recordPath, { force: true });
  return plan;
};
