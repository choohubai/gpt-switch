import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";

/// 选择器列表补丁里「哪些行算我们的渠道模型」这一段，用假的行对象直接执行真实源码。
/// 客户端自带的模型必须被藏起来，选中项行尾的勾不能把行认成别人的。
const BLOCK_START = "  const MODEL_GROUP_EXT = ";
const BLOCK_END = "  const insertPickerGroupNodes = ";

const loadBlock = ({ bootModels, groupNames, currentName }) => {
  const source = fs.readFileSync(new URL("../Sources/injection.js", import.meta.url), "utf8");
  const start = source.indexOf(BLOCK_START);
  assert.notEqual(start, -1, "注入模板里找不到分组补丁段的起点，测试要跟着改");
  const end = source.indexOf(BLOCK_END, start);
  assert.notEqual(end, -1, "注入模板里找不到分组补丁段的终点，测试要跟着改");
  const factory = new Function(
    "BOOT_MODELS", "KNOWN_GROUP_NAMES", "DEFAULT_GROUP_NAME", "state", "Node", "document", "window", "MutationObserver", "CSS",
    `${source.slice(start, end)}\nreturn { collectPickerGroups, hideForeignPickerRows, applyPickerGroups, modelGroupState };`,
  );
  return factory(bootModels, groupNames, currentName,
    { groupName: currentName, groupNames }, { ELEMENT_NODE: 1, TEXT_NODE: 3 });
};

const classList = () => {
  const names = new Set();
  return {
    names,
    add: (...items) => items.forEach((item) => names.add(item)),
    remove: (...items) => items.forEach((item) => names.delete(item)),
    contains: (item) => names.has(item),
    toggle: (item, force) => {
      const on = force === undefined ? !names.has(item) : force;
      if (on) names.add(item);
      else names.delete(item);
      return on;
    },
  };
};

/// 只带一个文本节点的行，够 pickerRowNativeText 走「没打过补丁」的那条路。
const row = (label) => ({
  nodeType: 1,
  label,
  classes: classList(),
  classList: null,
  attrs: {},
  children: [],
  childNodes: [{ nodeType: 3, nodeValue: label }],
  querySelector: () => null,
  setAttribute(name, value) { this.attrs[name] = value; },
});

/// applyPickerGroups 只碰行上的类和表头节点的属性/文本。
const fakeHeader = () => {
  const count = { textContent: "0" };
  const classes = classList();
  return {
    attrs: {},
    classes,
    classList: classes,
    setAttribute(name, value) { this.attrs[name] = value; },
    querySelector: () => count,
  };
};

const makeRows = (labels) => {
  const rows = labels.map(row);
  // hideForeignPickerRows 只看 classList，把上面那个记录用的对象挂上就行。
  for (const item of rows) item.classList = item.classes;
  return rows;
};

const foreignLabels = (rows) => rows.filter((item) => item.classes.contains("gpt-switch-group-foreign")).map((item) => item.label);

test("客户端自带的模型被藏起来，只剩插件配置的渠道模型", () => {
  const { collectPickerGroups, hideForeignPickerRows } = loadBlock({
    bootModels: [
      { id: "grok-4.7", displayName: "grok-4.7" },
      { id: "glm-5.3", displayName: "glm-5.3" },
      { id: "gpts-feiyu/deepseek-flash", displayName: "deepseek-flash（feiyu）" },
    ],
    groupNames: ["ChooHub", "feiyu"],
    currentName: "ChooHub",
  });
  const rows = makeRows([
    "默认推荐模型集 ✓",
    "grok-4.7",
    "glm-5.3 ✓",
    "GPT-6-Sol",
    "deepseek-flash（feiyu）",
  ]);
  const list = { querySelectorAll: () => rows };

  const groups = collectPickerGroups(list);
  assert.deepEqual(groups.map((group) => [group.name, group.rows.length]),
    [["ChooHub", 2], ["feiyu", 1]], "分组只数我们注入的模型，表头计数才不会虚高");

  hideForeignPickerRows(list, groups);
  assert.deepEqual(foreignLabels(rows), ["默认推荐模型集 ✓", "GPT-6-Sol"]);
  // 再跑一次不能把我们的行也藏了（菜单开着时每 120ms 会重扫一次）。
  hideForeignPickerRows(list, groups);
  assert.deepEqual(foreignLabels(rows), ["默认推荐模型集 ✓", "GPT-6-Sol"]);
});

test("一个渠道的模型也不多藏东西", () => {
  const { collectPickerGroups, hideForeignPickerRows } = loadBlock({
    bootModels: [{ id: "glm-5.3", displayName: "glm-5.3" }],
    groupNames: ["ChooHub"],
    currentName: "ChooHub",
  });
  const rows = makeRows(["glm-5.3", "GPT-6-Luna", "Codex Auto Review"]);
  const list = { querySelectorAll: () => rows };
  const groups = collectPickerGroups(list);
  hideForeignPickerRows(list, groups);
  assert.deepEqual(groups.map((group) => group.name), ["ChooHub"]);
  assert.deepEqual(foreignLabels(rows), ["GPT-6-Luna", "Codex Auto Review"]);
});

/// 折叠状态是会话级的 Set，禁用掉另一条渠道后只剩一个分组：这时候不能再按折叠态藏行，
/// 否则整份列表只剩一个表头，看着像模型全没了。
test("只剩一个分组时不再沿用折叠状态，模型行照样显示", () => {
  const { applyPickerGroups, modelGroupState } = loadBlock({
    bootModels: [{ id: "glm-5.3", displayName: "glm-5.3" }],
    groupNames: ["ChooHub"],
    currentName: "ChooHub",
  });
  const items = ["glm-5.3", "grok-4.7"].map((label) => {
    const item = row(label);
    item.classList = item.classes;
    return { row: item, content: item, label };
  });
  const list = { querySelector: fakeHeader };

  modelGroupState.collapsed.add("ChooHub");
  applyPickerGroups(list, [{ name: "ChooHub", rows: items }]);
  for (const item of items) {
    assert(!item.row.classes.contains("gpt-switch-group-hidden"), "单分组不能沿用折叠态把行藏掉");
    assert(item.row.classes.contains("gpt-switch-group-row"), "行仍然要按渠道打上分组标记");
  }

  // 两个分组时折叠照旧生效：只有被折叠那组的行藏起来。
  const other = row("deepseek-flash（feiyu）");
  other.classList = other.classes;
  applyPickerGroups(list, [
    { name: "ChooHub", rows: items },
    { name: "feiyu", rows: [{ row: other, content: other, label: "deepseek-flash" }] },
  ]);
  for (const item of items) {
    assert(item.row.classes.contains("gpt-switch-group-hidden"), "多分组时折叠仍然要藏行");
  }
  assert(!other.classes.contains("gpt-switch-group-hidden"), "没折叠的那组不受影响");
});
