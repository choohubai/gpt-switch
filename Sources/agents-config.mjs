import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { atomicWrite } from "./model-config.mjs";

const TEMPLATE_PATH = path.join(path.dirname(fileURLToPath(import.meta.url)), "AGENTS.template.md");

/// 面板首次使用插件内模板作为默认值，不把用户现有 AGENTS.md 混进编辑器内容。
export const loadInstructionsTemplate = () => fs.readFileSync(TEMPLATE_PATH, "utf8");

const PLUGIN_START = "<!-- GPTSWITCH_AGENTS_START -->";
const PLUGIN_END = "<!-- GPTSWITCH_AGENTS_END -->";
const PLUGIN_PATTERN =
  /<!-- GPTSWITCH_AGENTS_START -->\r?\n([\s\S]*?)<!-- GPTSWITCH_AGENTS_END -->(?:\r?\n)?/;
const STATE_KEYS = new Set(["enabled", "content"]);

const instructionsBlock = (content) => `${PLUGIN_START}\n${content}${PLUGIN_END}\n`;

/// 返回唯一的插件段；重复或残缺失配的标记会拒绝操作，避免停用后仍有插件内容生效。
const findPluginBlock = (content) => {
  const starts = content.split(PLUGIN_START).length - 1;
  const ends = content.split(PLUGIN_END).length - 1;
  if (starts === 0 && ends === 0) return null;
  if (starts !== 1 || ends !== 1) {
    throw new Error("AGENTS.md 的插件标记段重复或不完整，请先修复 GPTSWITCH_AGENTS 标记");
  }
  const match = PLUGIN_PATTERN.exec(content);
  if (!match) throw new Error("AGENTS.md 的插件标记段顺序不完整，请先修复 GPTSWITCH_AGENTS 标记");
  return match;
};

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

/// 读取面板保存的内容和开关；旧版只有 enabled 时继续使用当前内置模板作为默认值。
export const readInstructionsState = (statePath) => {
  const template = loadInstructionsTemplate();
  if (!fs.existsSync(statePath)) {
    return { content: template, enabled: false, source: "plugin" };
  }
  const parsed = JSON.parse(fs.readFileSync(statePath, "utf8"));
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("公共指令状态必须是对象");
  }
  for (const key of Object.keys(parsed)) {
    if (!STATE_KEYS.has(key)) throw new Error(`公共指令状态包含未知字段：${key}`);
  }
  if (typeof parsed.enabled !== "boolean") throw new Error("公共指令状态缺少布尔值 enabled");
  if (parsed.content !== undefined && typeof parsed.content !== "string") {
    throw new Error("公共指令状态里的 content 必须是文本");
  }
  return {
    content: parsed.content ?? template,
    enabled: parsed.enabled,
    source: parsed.content === undefined ? "plugin" : "user",
  };
};

/// 兼容只关心开关的调用方；内容仍由 readInstructionsState 返回。
export const readInstructionsEnabled = (statePath) => readInstructionsState(statePath).enabled;

/// 从 AGENTS.md 的标记段读取实际生效状态，用来发现状态文件损坏或跨文件写入中断。
export const inspectInstructionsInCodex = ({ codexHome }) => {
  const agentsPath = path.join(codexHome, "AGENTS.md");
  const targetPath = instructionsTargetPath(agentsPath);
  if (!fs.existsSync(targetPath)) {
    return { content: loadInstructionsTemplate(), enabled: false, source: "plugin", path: agentsPath };
  }
  const current = fs.readFileSync(targetPath, "utf8");
  try {
    const block = findPluginBlock(current);
    return block
      ? { content: block[1], enabled: true, source: "user", path: agentsPath }
      : { content: loadInstructionsTemplate(), enabled: false, source: "plugin", path: agentsPath };
  } catch (error) {
    return {
      content: loadInstructionsTemplate(),
      enabled: true,
      source: "plugin",
      path: agentsPath,
      error: error.message,
    };
  }
};

/// 原子写入规范化状态；状态文件损坏但 AGENTS.md 可读时由面板加载流程自动修复。
export const writeInstructionsState = (statePath, state) => {
  atomicWrite(statePath, `${JSON.stringify({
    enabled: state.enabled,
    content: state.content,
  }, null, 2)}\n`);
};

/// 把插件段插在用户正文前；同一 Codex 全局层里 override 优先，因此不生成 override。
const mergeInstructions = (userContent, content) => {
  const block = instructionsBlock(content);
  const existing = findPluginBlock(userContent);
  if (existing) {
    const before = userContent.slice(0, existing.index);
    const after = userContent.slice(existing.index + existing[0].length);
    return `${before}${block}${after}`;
  }
  const bom = userContent.startsWith("\uFEFF") ? "\uFEFF" : "";
  const body = userContent.slice(bom.length);
  return body ? `${bom}${block}${body}` : `${bom}${block}`;
};

/// 保存可编辑内容到用户 AGENTS.md 的独立标记段；用户原有正文原样保留。
export const saveInstructionsToCodex = ({ codexHome, statePath, enabled, content }) => {
  if (typeof enabled !== "boolean") throw new Error("公共指令启用状态必须是布尔值");
  let nextContent = content;
  if (nextContent === undefined) {
    try {
      nextContent = readInstructionsState(statePath).content;
    } catch {
      nextContent = loadInstructionsTemplate();
    }
  }
  if (typeof nextContent !== "string") throw new Error("公共指令内容必须是文本");
  if (nextContent.includes(PLUGIN_START) || nextContent.includes(PLUGIN_END)) {
    throw new Error("公共指令内容不能包含 GPT Switch 的插件标记");
  }
  const agentsPath = path.join(codexHome, "AGENTS.md");
  const targetPath = instructionsTargetPath(agentsPath);
  const previous = fs.existsSync(targetPath) ? fs.readFileSync(targetPath, "utf8") : "";
  const pluginBlock = findPluginBlock(previous);
  const next = enabled
    ? mergeInstructions(previous, nextContent)
    : (pluginBlock
      ? `${previous.slice(0, pluginBlock.index)}${previous.slice(pluginBlock.index + pluginBlock[0].length)}`
      : previous);
  let backupPath = "";
  if (previous !== next) {
    if (previous) {
      const stamp = new Date().toISOString().replace(/[:.]/g, "-");
      backupPath = `${agentsPath}.${stamp}.bak`;
      atomicWrite(backupPath, previous);
    }
    atomicWrite(targetPath, next);
  }
  try {
    writeInstructionsState(statePath, { enabled, content: nextContent });
  } catch (error) {
    // 开关状态写不进去时把 AGENTS.md 恢复到操作前，避免界面与文件各说一套。
    if (previous !== next && fs.existsSync(targetPath) && fs.readFileSync(targetPath, "utf8") === next) {
      atomicWrite(targetPath, previous);
    }
    throw error;
  }
  return {
    content: nextContent,
    source: "user",
    enabled,
    path: agentsPath,
    backupPath,
    keptUserFile: Boolean(previous),
  };
};

