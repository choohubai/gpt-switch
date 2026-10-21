import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import {
  inspectInstructionsInCodex, loadInstructionsTemplate, readInstructionsEnabled, readInstructionsState,
  saveInstructionsToCodex,
} from "../Sources/agents-config.mjs";

const sandbox = (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "gpt-switch-agents-"));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return directory;
};

test("没有保存内容时使用插件模板，不读取用户现有 AGENTS.md", (context) => {
  const codexHome = sandbox(context);
  const userPath = path.join(codexHome, "AGENTS.md");
  fs.writeFileSync(userPath, "用户私有规则\n");
  const state = readInstructionsState(path.join(codexHome, "agents.json"));
  assert.equal(state.content, loadInstructionsTemplate());
  assert.doesNotMatch(state.content, /用户私有规则/);
  assert.equal(state.source, "plugin");
  assert.equal(fs.readFileSync(userPath, "utf8"), "用户私有规则\n");
});

test("应用路径包含空格时仍能读取模板", () => {
  assert.match(loadInstructionsTemplate(), /## 一、任务开始前：读取基线/);
});

test("保存可编辑内容到插件标记段，用户原有 AGENTS.md 正文保留", (context) => {
  const codexHome = sandbox(context);
  const statePath = path.join(codexHome, "agents.json");
  const userPath = path.join(codexHome, "AGENTS.md");
  fs.writeFileSync(userPath, "用户私有规则\n");
  const result = saveInstructionsToCodex({
    codexHome, statePath, enabled: true, content: "# 用户编辑后的指令\n",
  });
  assert.equal(result.path, userPath);
  assert.equal(result.keptUserFile, true);
  const merged = fs.readFileSync(userPath, "utf8");
  assert.match(merged, /<!-- GPTSWITCH_AGENTS_START -->/);
  assert.match(merged, /# 用户编辑后的指令/);
  assert.doesNotMatch(merged, /请遵循以下全局工作方式/);
  assert.match(merged, /用户私有规则\n$/);
  assert.equal(fs.readFileSync(result.backupPath, "utf8"), "用户私有规则\n");
  assert.deepEqual(readInstructionsState(statePath), {
    content: "# 用户编辑后的指令\n",
    enabled: true,
    source: "user",
  });
});

test("再次保存更新同一个插件块，不重复追加内容", (context) => {
  const codexHome = sandbox(context);
  const statePath = path.join(codexHome, "agents.json");
  const userPath = path.join(codexHome, "AGENTS.md");
  fs.writeFileSync(userPath, "用户正文\n");
  saveInstructionsToCodex({ codexHome, statePath, enabled: true, content: "第一版\n" });
  saveInstructionsToCodex({ codexHome, statePath, enabled: true, content: "第二版\n" });
  const merged = fs.readFileSync(userPath, "utf8");
  assert.equal(merged.match(/<!-- GPTSWITCH_AGENTS_START -->/g)?.length, 1);
  assert.equal(merged.match(/<!-- GPTSWITCH_AGENTS_END -->/g)?.length, 1);
  assert.doesNotMatch(merged, /第一版/);
  assert.match(merged, /第二版/);
  assert.match(merged, /用户正文\n$/);
});

test("重复启用和停用不会删除用户正文开头的空行", (context) => {
  const codexHome = sandbox(context);
  const statePath = path.join(codexHome, "agents.json");
  const userPath = path.join(codexHome, "AGENTS.md");
  fs.writeFileSync(userPath, "\n\n用户正文\n");
  saveInstructionsToCodex({ codexHome, statePath, enabled: true, content: "可编辑内容\n" });
  saveInstructionsToCodex({ codexHome, statePath, enabled: true, content: "可编辑内容\n" });
  saveInstructionsToCodex({ codexHome, statePath, enabled: false });
  assert.equal(fs.readFileSync(userPath, "utf8"), "\n\n用户正文\n");
});

test("停用只移除插件标记块，用户正文和备份保留", (context) => {
  const codexHome = sandbox(context);
  const statePath = path.join(codexHome, "agents.json");
  const userPath = path.join(codexHome, "AGENTS.md");
  fs.writeFileSync(userPath, "用户正文\n");
  saveInstructionsToCodex({ codexHome, statePath, enabled: true, content: "可编辑内容\n" });
  assert.equal(readInstructionsEnabled(statePath), true);
  const result = saveInstructionsToCodex({ codexHome, statePath, enabled: false });
  assert.equal(result.enabled, false);
  assert.equal(readInstructionsEnabled(statePath), false);
  assert.equal(fs.readFileSync(userPath, "utf8"), "用户正文\n");
  assert.ok(result.backupPath);
  assert.equal(readInstructionsState(statePath).content, "可编辑内容\n",
    "停用后仍要保留用户编辑的草稿");
});

test("默认禁用，状态存在插件配置里而不是从用户 AGENTS.md 推断", (context) => {
  const codexHome = sandbox(context);
  const statePath = path.join(codexHome, "agents.json");
  fs.writeFileSync(path.join(codexHome, "AGENTS.md"), "用户自己的规则\n");
  assert.equal(readInstructionsEnabled(statePath), false);
});

test("旧版只含开关的状态文件继续加载内置模板", (context) => {
  const codexHome = sandbox(context);
  const statePath = path.join(codexHome, "agents.json");
  fs.writeFileSync(statePath, '{"enabled":true}\n');
  assert.deepEqual(readInstructionsState(statePath), {
    content: loadInstructionsTemplate(),
    enabled: true,
    source: "plugin",
  });
});

test("从 AGENTS.md 标记段恢复实际生效内容和开关", (context) => {
  const codexHome = sandbox(context);
  const statePath = path.join(codexHome, "agents.json");
  saveInstructionsToCodex({ codexHome, statePath, enabled: true, content: "# 实际生效内容\n" });
  const inspected = inspectInstructionsInCodex({ codexHome });
  assert.equal(inspected.enabled, true);
  assert.equal(inspected.content, "# 实际生效内容\n");
  assert.equal(inspected.error, undefined);
});

test("重复或残缺标记段拒绝写入，停用不会留下第二份有效内容", (context) => {
  const codexHome = sandbox(context);
  const statePath = path.join(codexHome, "agents.json");
  const userPath = path.join(codexHome, "AGENTS.md");
  const block = "<!-- GPTSWITCH_AGENTS_START -->\n插件内容\n<!-- GPTSWITCH_AGENTS_END -->\n";
  fs.writeFileSync(userPath, `${block}${block}`);
  assert.throws(
    () => saveInstructionsToCodex({ codexHome, statePath, enabled: false }),
    /插件标记段重复或不完整/);
  assert.equal(fs.readFileSync(userPath, "utf8"), `${block}${block}`);

  fs.writeFileSync(userPath, "<!-- GPTSWITCH_AGENTS_START -->\n残缺内容\n");
  assert.throws(
    () => saveInstructionsToCodex({ codexHome, statePath, enabled: true, content: "新内容\n" }),
    /插件标记段重复或不完整/);
});

test("首次创建 AGENTS.md 不制造空备份，并拒绝把插件标记写进正文", (context) => {
  const codexHome = sandbox(context);
  const statePath = path.join(codexHome, "agents.json");
  const created = saveInstructionsToCodex({
    codexHome, statePath, enabled: true, content: "首次内容\n",
  });
  assert.equal(created.backupPath, "");
  assert.equal(created.keptUserFile, false);
  assert.throws(() => saveInstructionsToCodex({
    codexHome,
    statePath,
    enabled: true,
    content: "<!-- GPTSWITCH_AGENTS_START -->\n内嵌标记\n",
  }), /不能包含 GPT Switch 的插件标记/);
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
  saveInstructionsToCodex({ codexHome, statePath, enabled: true, content: "链接里的插件内容\n" });
  assert.equal(fs.lstatSync(userPath).isSymbolicLink(), true);
  assert.match(fs.readFileSync(targetPath, "utf8"), /链接里的插件内容/);
  saveInstructionsToCodex({ codexHome, statePath, enabled: false });
  assert.equal(fs.lstatSync(userPath).isSymbolicLink(), true);
  assert.equal(fs.readFileSync(targetPath, "utf8"), "链接目标里的用户正文\n");
});
