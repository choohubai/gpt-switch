import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { atomicWrite } from "./model-config.mjs";

const TEMPLATE_PATH = path.join(path.dirname(fileURLToPath(import.meta.url)), "AGENTS.template.md");

/// 面板只读插件内固定模板，绝不把用户现有 AGENTS.md 作为编辑器输入。
export const loadInstructionsTemplate = () => fs.readFileSync(TEMPLATE_PATH, "utf8");

const PLUGIN_START = "<!-- GPTSWITCH_AGENTS_START -->";
const PLUGIN_END = "<!-- GPTSWITCH_AGENTS_END -->";
const PLUGIN_PATTERN = /<!-- GPTSWITCH_AGENTS_START -->[\s\S]*?<!-- GPTSWITCH_AGENTS_END -->(?:\r?\n)?/;
const STATE_KEYS = new Set(["enabled"]);

const templateBlock = () => `${PLUGIN_START}\n${loadInstructionsTemplate()}${PLUGIN_END}\n`;

/// 保留用户把 AGENTS.md 指向 dotfiles 的符号链接；失效链接直接报错，避免被原子写替换成普通文件。
const instructionsTargetPath = (agentsPath) => {
  let stat;
  try {
    stat = fs.lstatSync(agentsPath);
  } catch (error) {
    if (error.code === "ENOENT") return agentsPath;
    throw error;
  }
  if (!stat.isSymbolicLink()) return agentsPath;
  try {
    return fs.realpathSync(agentsPath);
  } catch (error) {
    if (error.code === "ENOENT") throw new Error("AGENTS.md 是失效的符号链接，请先修复链接");
    throw error;
  }
};

/// 读取插件自己的开关状态；面板加载时不会因此读取用户 AGENTS.md。
export const readInstructionsEnabled = (statePath) => {
  if (!fs.existsSync(statePath)) return false;
  const parsed = JSON.parse(fs.readFileSync(statePath, "utf8"));
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("公共指令状态必须是对象");
  }
  for (const key of Object.keys(parsed)) {
    if (!STATE_KEYS.has(key)) throw new Error(`公共指令状态包含未知字段：${key}`);
  }
  if (typeof parsed.enabled !== "boolean") throw new Error("公共指令状态缺少布尔值 enabled");
  return parsed.enabled;
};

const writeInstructionsEnabled = (statePath, enabled) => {
  atomicWrite(statePath, `${JSON.stringify({ enabled }, null, 2)}\n`);
};

/// 把插件段插在用户正文前；同一 Codex 全局层里 override 优先，因此不生成 override。
const mergeInstructions = (userContent) => {
  const block = templateBlock();
  const existing = PLUGIN_PATTERN.exec(userContent);
  if (existing) {
    const before = userContent.slice(0, existing.index);
    const after = userContent.slice(existing.index + existing[0].length);
    return `${before}${block}${after}`;
  }
  const bom = userContent.startsWith("\uFEFF") ? "\uFEFF" : "";
  const body = userContent.slice(bom.length);
  return body ? `${bom}${block}${body}` : `${bom}${block}`;
};

/// 保存插件模板到用户 AGENTS.md 的独立标记段；用户原有正文原样保留。
export const saveInstructionsToCodex = ({ codexHome, statePath, enabled }) => {
  const agentsPath = path.join(codexHome, "AGENTS.md");
  const targetPath = instructionsTargetPath(agentsPath);
  const content = loadInstructionsTemplate();
  const previous = fs.existsSync(targetPath) ? fs.readFileSync(targetPath, "utf8") : "";
  const pluginBlock = PLUGIN_PATTERN.exec(previous);
  const next = enabled
    ? mergeInstructions(previous)
    : (pluginBlock
      ? `${previous.slice(0, pluginBlock.index)}${previous.slice(pluginBlock.index + pluginBlock[0].length)}`
      : previous);
  let backupPath = "";
  if (previous !== next) {
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    backupPath = `${agentsPath}.${stamp}.bak`;
    atomicWrite(backupPath, previous);
    atomicWrite(targetPath, next);
  }
  try {
    writeInstructionsEnabled(statePath, enabled);
  } catch (error) {
    // 开关状态写不进去时把 AGENTS.md 恢复到操作前，避免界面与文件各说一套。
    if (previous !== next && fs.existsSync(targetPath) && fs.readFileSync(targetPath, "utf8") === next) {
      atomicWrite(targetPath, previous);
    }
    throw error;
  }
  return { content, source: "plugin", enabled, path: agentsPath, backupPath, keptUserFile: Boolean(previous) };
};

