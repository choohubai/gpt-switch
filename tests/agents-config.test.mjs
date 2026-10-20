import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import {
  loadInstructionsTemplate, readInstructionsEnabled, saveInstructionsToCodex,
} from "../Sources/agents-config.mjs";

const sandbox = (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "gpt-switch-agents-"));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return directory;
};

test("加载固定插件模板，不读取用户现有 AGENTS.md", (context) => {
  const codexHome = sandbox(context);
  const userPath = path.join(codexHome, "AGENTS.md");
  fs.writeFileSync(userPath, "用户私有规则\n");
  const template = loadInstructionsTemplate();
  assert.match(template, /请遵循以下全局工作方式/);
  assert.doesNotMatch(template, /用户私有规则/);
  assert.equal(fs.readFileSync(userPath, "utf8"), "用户私有规则\n");
});

test("应用路径包含空格时仍能读取模板", () => {
  assert.match(loadInstructionsTemplate(), /## 一、任务开始前：读取基线/);
});

test("保存只替换插件标记段，用户原有 AGENTS.md 正文保留", (context) => {
  const codexHome = sandbox(context);
  const statePath = path.join(codexHome, "agents.json");
  const userPath = path.join(codexHome, "AGENTS.md");
  fs.writeFileSync(userPath, "用户私有规则\n");
  const result = saveInstructionsToCodex({ codexHome, statePath, enabled: true });
  assert.equal(result.path, userPath);
  assert.equal(result.keptUserFile, true);
  const merged = fs.readFileSync(userPath, "utf8");
  assert.match(merged, /<!-- GPTSWITCH_AGENTS_START -->/);
  assert.match(merged, /请遵循以下全局工作方式/);
  assert.match(merged, /用户私有规则\n$/);
  assert.equal(fs.readFileSync(result.backupPath, "utf8"), "用户私有规则\n");
});

test("再次保存只替换插件块，不重复追加模板", (context) => {
  const codexHome = sandbox(context);
  const statePath = path.join(codexHome, "agents.json");
  const userPath = path.join(codexHome, "AGENTS.md");
  fs.writeFileSync(userPath, "用户正文\n");
  saveInstructionsToCodex({ codexHome, statePath, enabled: true });
  saveInstructionsToCodex({ codexHome, statePath, enabled: true });
  const merged = fs.readFileSync(userPath, "utf8");
  assert.equal(merged.match(/<!-- GPTSWITCH_AGENTS_START -->/g)?.length, 1);
  assert.equal(merged.match(/<!-- GPTSWITCH_AGENTS_END -->/g)?.length, 1);
  assert.match(merged, /用户正文\n$/);
});

test("重复启用和停用不会删除用户正文开头的空行", (context) => {
  const codexHome = sandbox(context);
  const statePath = path.join(codexHome, "agents.json");
  const userPath = path.join(codexHome, "AGENTS.md");
  fs.writeFileSync(userPath, "\n\n用户正文\n");
  saveInstructionsToCodex({ codexHome, statePath, enabled: true });
  saveInstructionsToCodex({ codexHome, statePath, enabled: true });
  saveInstructionsToCodex({ codexHome, statePath, enabled: false });
  assert.equal(fs.readFileSync(userPath, "utf8"), "\n\n用户正文\n");
});

test("停用只移除插件标记块，用户正文和备份保留", (context) => {
  const codexHome = sandbox(context);
  const statePath = path.join(codexHome, "agents.json");
  const userPath = path.join(codexHome, "AGENTS.md");
  fs.writeFileSync(userPath, "用户正文\n");
  saveInstructionsToCodex({ codexHome, statePath, enabled: true });
  assert.equal(readInstructionsEnabled(statePath), true);
  const result = saveInstructionsToCodex({ codexHome, statePath, enabled: false });
  assert.equal(result.enabled, false);
  assert.equal(readInstructionsEnabled(statePath), false);
  assert.equal(fs.readFileSync(userPath, "utf8"), "用户正文\n");
  assert.ok(result.backupPath);
});

test("默认禁用，状态存在插件配置里而不是从用户 AGENTS.md 推断", (context) => {
  const codexHome = sandbox(context);
  const statePath = path.join(codexHome, "agents.json");
  fs.writeFileSync(path.join(codexHome, "AGENTS.md"), "用户自己的规则\n");
  assert.equal(readInstructionsEnabled(statePath), false);
});

test("禁用且用户文件里没有插件段时不改写 AGENTS.md", (context) => {
  const codexHome = sandbox(context);
  const statePath = path.join(codexHome, "agents.json");
  const userPath = path.join(codexHome, "AGENTS.md");
  const original = "\n用户保留开头的空行\n";
  fs.writeFileSync(userPath, original);
  const result = saveInstructionsToCodex({ codexHome, statePath, enabled: false });
  assert.equal(fs.readFileSync(userPath, "utf8"), original);
  assert.equal(result.backupPath, "");
  assert.equal(readInstructionsEnabled(statePath), false);
});

test("AGENTS.md 是符号链接时保留链接并更新目标文件", (context) => {
  const codexHome = sandbox(context);
  const targetPath = path.join(codexHome, "dotfiles-agents.md");
  const userPath = path.join(codexHome, "AGENTS.md");
  const statePath = path.join(codexHome, "agents.json");
  fs.writeFileSync(targetPath, "链接目标里的用户正文\n");
  fs.symlinkSync(targetPath, userPath);
  saveInstructionsToCodex({ codexHome, statePath, enabled: true });
  assert.equal(fs.lstatSync(userPath).isSymbolicLink(), true);
  assert.match(fs.readFileSync(targetPath, "utf8"), /请遵循以下全局工作方式/);
  saveInstructionsToCodex({ codexHome, statePath, enabled: false });
  assert.equal(fs.lstatSync(userPath).isSymbolicLink(), true);
  assert.equal(fs.readFileSync(targetPath, "utf8"), "链接目标里的用户正文\n");
});
