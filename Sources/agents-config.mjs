import fs from "node:fs";
import path from "node:path";
import { atomicWrite } from "./model-config.mjs";

// shortcut: 公共指令只支持单个 ~/.codex/AGENTS.md，项目级 AGENTS.md 各自管理；需求扩展到多级目录时再改。
const timestamp = () => new Date().toISOString().replace(/[:.]/g, "-");

/// 读取公共指令草稿。首次加载时把当前 AGENTS.md 原样作为初始内容，供用户直接编辑。
export const loadPublicInstructions = (agentsPath) => {
  const storePath = path.join(path.dirname(agentsPath), "gptswitch-agents.json");
  try {
    const saved = JSON.parse(fs.readFileSync(storePath, "utf8"));
    if (typeof saved?.content !== "string" || typeof saved?.enabled !== "boolean") {
      throw new Error("公共指令配置缺少 content 或 enabled");
    }
    return { content: saved.content, enabled: saved.enabled, backupPath: null };
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  let content = "";
  try {
    content = fs.readFileSync(agentsPath, "utf8");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  return { content, enabled: false, backupPath: null };
};

const writePublicInstructions = (agentsPath, state) => {
  atomicWrite(path.join(path.dirname(agentsPath), "gptswitch-agents.json"), `${JSON.stringify({
    enabled: state.enabled,
    content: state.content,
  }, null, 2)}\n`);
};

/// 每次从关闭切到开启都备份当时的 AGENTS.md；同一次启用期间不会覆盖首次备份。
export const savePublicInstructions = (agentsPath, state, patch) => {
  if (typeof patch?.content !== "string") throw new Error("公共指令内容必须是文本");
  if (typeof patch?.enabled !== "boolean") throw new Error("公共指令启用状态必须是布尔值");
  const next = { ...state, content: patch.content, enabled: patch.enabled };
  let backupPath = null;
  let backup = null;
  if (!state.enabled && next.enabled) {
    try {
      const original = fs.readFileSync(agentsPath, "utf8");
      backupPath = `${agentsPath}.${timestamp()}.bak`;
      backup = { path: backupPath, content: original };
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  }
  if (next.enabled) atomicWrite(agentsPath, next.content);
  if (backup) atomicWrite(backup.path, backup.content);
  writePublicInstructions(agentsPath, next);
  return { ...next, backupPath };
};

