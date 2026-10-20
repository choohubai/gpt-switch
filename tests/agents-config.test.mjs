import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { loadPublicInstructions, savePublicInstructions } from "../Sources/agents-config.mjs";

const sandbox = (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "gpt-switch-agents-"));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return {
    codexHome: directory,
    agentsPath: path.join(directory, "AGENTS.md"),
    storePath: path.join(directory, "gptswitch-agents.json"),
  };
};

test("公共指令首次加载当前 AGENTS.md，启用前创建独立备份", (context) => {
  const paths = sandbox(context);
  fs.writeFileSync(paths.agentsPath, "原始公共指令\n");
  const loaded = loadPublicInstructions(paths.agentsPath);
  assert.equal(loaded.content, "原始公共指令\n");
  assert.equal(loaded.enabled, false);

  const saved = savePublicInstructions(paths.agentsPath, loaded, { content: "新的公共指令\n", enabled: true });
  assert.equal(fs.readFileSync(paths.agentsPath, "utf8"), "新的公共指令\n");
  assert.ok(saved.backupPath);
  assert.equal(fs.readFileSync(saved.backupPath, "utf8"), "原始公共指令\n");

  const reopened = loadPublicInstructions(paths.agentsPath);
  assert.equal(reopened.content, "新的公共指令\n");
  assert.equal(reopened.enabled, true);
});

test("关闭只停止同步并保留当前文件，再次启用会重新备份", (context) => {
  const paths = sandbox(context);
  const initial = loadPublicInstructions(paths.agentsPath);
  const enabled = savePublicInstructions(paths.agentsPath, initial, { content: "第一次\n", enabled: true });
  assert.equal(enabled.backupPath, null, "原本没有文件时不制造空备份");
  const disabled = savePublicInstructions(paths.agentsPath, loadPublicInstructions(paths.agentsPath),
    { content: "草稿\n", enabled: false });
  assert.equal(fs.readFileSync(paths.agentsPath, "utf8"), "第一次\n");
  assert.equal(disabled.enabled, false);
  const enabledAgain = savePublicInstructions(paths.agentsPath, loadPublicInstructions(paths.agentsPath),
    { content: "第二次\n", enabled: true });
  assert.ok(enabledAgain.backupPath);
  assert.equal(fs.readFileSync(enabledAgain.backupPath, "utf8"), "第一次\n");
  assert.equal(fs.readFileSync(paths.agentsPath, "utf8"), "第二次\n");
});

test("启用时更新内容同步写 AGENTS.md，不改渠道和 Codex 配置", (context) => {
  const paths = sandbox(context);
  fs.writeFileSync(paths.agentsPath, "原内容\n");
  const enabled = savePublicInstructions(paths.agentsPath, loadPublicInstructions(paths.agentsPath),
    { content: "更新内容\n", enabled: true });
  assert.equal(fs.readFileSync(paths.agentsPath, "utf8"), "更新内容\n");
  assert.equal(JSON.parse(fs.readFileSync(paths.storePath, "utf8")).content, "更新内容\n");
  assert.equal(fs.readdirSync(paths.codexHome).filter((name) => name.endsWith(".bak")).length, 1);
  assert.ok(enabled.backupPath);
});

test("AGENTS.md 写入失败时不提交草稿，也不会留下假备份", (context) => {
  const paths = sandbox(context);
  const initial = loadPublicInstructions(paths.agentsPath);
  fs.mkdirSync(paths.agentsPath);
  assert.throws(() => savePublicInstructions(paths.agentsPath, initial, {
    content: "不会落盘\n", enabled: true,
  }));
  assert.equal(fs.existsSync(paths.storePath), false);
  assert.equal(fs.readdirSync(paths.codexHome).filter((name) => name.endsWith(".bak")).length, 0);
});
