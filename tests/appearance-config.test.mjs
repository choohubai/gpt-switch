import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import {
  APPEARANCE_THEMES,
  appearanceNativeMode,
  appearancePanelState,
  appearanceRuntimeTheme,
  normalizeAppearanceTheme,
  readAppearanceState,
  readAppearanceTheme,
  writeNativeAppearanceOverride,
  writeAppearanceTheme,
} from "../Sources/appearance-config.mjs";

const resourceDirectory = fileURLToPath(new URL("../Resources/Appearance/", import.meta.url));

test("appearance catalog keeps one valid preview and runtime background per theme", () => {
  assert.deepEqual(APPEARANCE_THEMES.map((theme) => theme.id), [
    "light", "dark", "wind", "qq", "peace", "journey", "ripple", "buddy",
  ]);
  for (const theme of APPEARANCE_THEMES) {
    assert.ok(fs.statSync(path.join(resourceDirectory, theme.previewFile)).size > 0);
    if (theme.backgroundFile) {
      assert.ok(fs.statSync(path.join(resourceDirectory, theme.backgroundFile)).size > 0);
    }
  }
  const wind = appearanceRuntimeTheme("wind", resourceDirectory);
  assert.equal(wind.id, "wind");
  assert.match(wind.imageUrl, /^data:image\/png;base64,/);
  assert.equal(appearanceNativeMode("dark"), "dark");
  for (const theme of APPEARANCE_THEMES.filter(({ id }) => id !== "dark")) {
    assert.equal(appearanceNativeMode(theme.id), "light");
  }
  assert.equal(appearanceNativeMode("unknown"), "light");
});

test("appearance does not paint ChatGPT's bottom scroll fade", () => {
  const injection = fs.readFileSync(
    fileURLToPath(new URL("../Sources/injection.js", import.meta.url)),
    "utf8");
  assert.match(injection, /--color-surface:transparent;/);
  assert.doesNotMatch(injection, /--color-surface:\$\{theme\.surface\};/);
  assert.match(injection, /border-radius:22px!important;/);
});

test("appearance persistence validates theme ids and returns panel paths", (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "gpt-switch-appearance-"));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const configPath = path.join(directory, ".gptswitch", "appearance.json");

  assert.equal(readAppearanceTheme(configPath), "light");
  assert.deepEqual(readAppearanceState(configPath), {
    theme: "light", followNative: false, nativeMode: "light",
  });
  assert.equal(writeAppearanceTheme(configPath, "wind"), "wind");
  assert.equal(readAppearanceTheme(configPath), "wind");
  assert.deepEqual(writeNativeAppearanceOverride(configPath, "dark"), {
    theme: "dark", followNative: true, nativeMode: "dark",
  });
  const followed = readAppearanceState(configPath);
  assert.equal(followed.theme, "dark");
  assert.equal(followed.followNative, true);
  assert.equal(followed.nativeMode, "dark");
  assert.equal(appearanceRuntimeTheme(followed, resourceDirectory), null);
  writeAppearanceTheme(configPath, "wind");
  assert.equal(readAppearanceState(configPath).followNative, false);
  assert.equal(normalizeAppearanceTheme("not-a-theme"), "light");

  fs.writeFileSync(configPath, "{broken");
  assert.equal(readAppearanceTheme(configPath), "light");
  fs.writeFileSync(configPath, JSON.stringify({ theme: "ripple" }));
  const panel = appearancePanelState(configPath, resourceDirectory);
  assert.equal(panel.theme, "ripple");
  assert.equal(panel.themes.length, APPEARANCE_THEMES.length);
  assert.ok(panel.themes.every((theme) => path.isAbsolute(theme.previewPath)));
  assert.equal(panel.themes.find((theme) => theme.id === "ripple").coverPath,
    path.join(resourceDirectory, "ripple-bg.png"));
  assert.equal(panel.themes.find((theme) => theme.id === "dark").cardBackground, "#303030");
  assert.equal(panel.followNative, false);
});

test("appearance persistence keeps the previous theme when atomic replace fails", (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "gpt-switch-appearance-atomic-"));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const configPath = path.join(directory, ".gptswitch", "appearance.json");
  writeAppearanceTheme(configPath, "wind");
  const previous = fs.readFileSync(configPath, "utf8");
  const renameSync = fs.renameSync;
  fs.renameSync = () => { throw new Error("simulated rename failure"); };
  try {
    assert.throws(() => writeAppearanceTheme(configPath, "dark"), /simulated rename failure/);
  } finally {
    fs.renameSync = renameSync;
  }

  assert.equal(fs.readFileSync(configPath, "utf8"), previous);
  assert.equal(readAppearanceTheme(configPath), "wind");
  assert.equal(fs.existsSync(`${configPath}.${process.pid}.tmp`), false);
});
