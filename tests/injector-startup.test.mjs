import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

// Intercept process launches in a child so regression checks cannot touch ChatGPT.
const preload = `
  import os from "node:os";
  import fs from "node:fs";
  import childProcess from "node:child_process";
  import { syncBuiltinESMExports } from "node:module";
  os.homedir = () => process.env.CUSTOM_MODELS_TEST_DIR;
  const existsSync = fs.existsSync;
  fs.existsSync = (value) => /GPTSwitchStatusMenu$|MenuBarIcon\.png$/.test(String(value))
    ? false : existsSync(value);
  childProcess.spawnSync = (file, args) => {
    console.log(JSON.stringify({ file, args }));
    return { status: Number(process.env.CUSTOM_MODELS_TEST_APP_STATUS), stdout: "", stderr: "" };
  };
  childProcess.spawn = (file) => { throw new Error("Unexpected process launch: " + file); };
  syncBuiltinESMExports();
`;

// 这条断言依赖 macOS 的配置目录和 osascript 通知，Windows 走的是另一套实现。
test("startup does not launch, restart, or activate ChatGPT", {
  skip: process.platform === "darwin" ? false : "只在 macOS 上检查",
}, (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "custom-models-startup-"));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const support = path.join(directory, "Library", "Application Support", "GPTSwitch");
  fs.mkdirSync(support, { recursive: true });
  const config = path.join(support, "models.json");
  const lock = path.join(support, "launcher.lock");
  const app = path.join(directory, "ChatGPT.app");
  fs.mkdirSync(app);

  for (const scenario of ["running", "stopped", "empty", "duplicate"]) {
    const contents = JSON.stringify({ models: scenario === "empty" ? [] : [{ id: "test-model" }] });
    fs.writeFileSync(config, contents);
    if (scenario === "duplicate") fs.writeFileSync(lock, String(process.pid));
    const result = spawnSync(process.execPath, [
      "--import", "data:text/javascript," + encodeURIComponent(preload),
      fileURLToPath(new URL("../Sources/injector.mjs", import.meta.url)), "--once", "--app", app,
    ], {
      encoding: "utf8", timeout: 5000,
      env: { ...process.env, CUSTOM_MODELS_TEST_DIR: directory,
        CUSTOM_MODELS_TEST_APP_STATUS: scenario === "stopped" ? "1" : "0" },
    });
    assert.equal(result.status, 0, `${scenario}: ${result.stderr}`);
    const calls = result.stdout.trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
    if (scenario === "duplicate") {
      assert.equal(calls.length, 1);
      assert.equal(calls[0].file, "/usr/bin/osascript");
      assert.match(calls[0].args[1], /^display notification /);
      assert.equal(fs.readFileSync(lock, "utf8"), String(process.pid));
    } else {
      assert.deepEqual(calls, [], scenario);
      assert.equal(fs.existsSync(lock), false);
    }
    assert.equal(fs.readFileSync(config, "utf8"), contents);
  }
});
