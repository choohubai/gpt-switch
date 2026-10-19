import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";

/// 选择器列表补丁里「哪些行算我们的渠道模型」这一段，用假的行对象直接执行真实源码。
/// 客户端自带的模型必须被藏起来，选中项行尾的勾不能把行认成别人的。
const BLOCK_START = "  const MODEL_GROUP_EXT = ";
const BLOCK_END = "  const pickerGroupsSignature = ";

const loadBlock = ({ bootModels, groupNames, currentName }) => {
  const source = fs.readFileSync(new URL("../Sources/injection.js", import.meta.url), "utf8");
  const start = source.indexOf(BLOCK_START);
  assert.notEqual(start, -1, "注入模板里找不到分组补丁段的起点，测试要跟着改");
  const end = source.indexOf(BLOCK_END, start);
  assert.notEqual(end, -1, "注入模板里找不到分组补丁段的终点，测试要跟着改");
  const factory = new Function(
    "BOOT_MODELS", "KNOWN_GROUP_NAMES", "DEFAULT_GROUP_NAME", "state", "Node", "document", "window", "MutationObserver", "CSS",
    `${source.slice(start, end)}\nreturn { modelPickerPanel, collectPickerGroups };`,
  );
  let panels = [];
  const document = {
    querySelectorAll: (selector) => (
      selector === '[class*="_ModelPickerDropdownContent_"]'
        ? panels.filter((panel) => panel.dropdown)
        : panels
    ),
  };
  const loaded = factory(bootModels, groupNames, currentName,
    { groupName: currentName, groupNames }, { ELEMENT_NODE: 1, TEXT_NODE: 3 }, document);
  loaded.setPanels = (next) => { panels = next; };
  return loaded;
};

/// 只带一个文本节点的行，够 pickerRowNativeText 走「没打过补丁」的那条路。
const row = (label, role = "menuitemradio") => ({
  nodeType: 1,
  role,
  label,
  attrs: {},
  children: [],
  childNodes: [{ nodeType: 3, nodeValue: label }],
  querySelector: () => null,
  setAttribute(name, value) { this.attrs[name] = value; },
});

const list = (rows) => ({
  isConnected: true,
  closest: () => null,
  querySelectorAll: (selector) => selector === '[role="menuitemradio"]'
    ? rows.filter((item) => item.role === "menuitemradio")
    : selector === '[role^="menuitem"]' ? rows : [],
  querySelector: (selector) => selector === '[role="menuitemradio"]'
    ? rows.find((item) => item.role === "menuitemradio") || null
    : null,
});

/// 复现 React 菜单行所在的滚动容器：分组的表头应跟着行插在这里。
const rowList = (rows) => {
  const container = {
    parentElement: null,
    querySelectorAll: (selector) => selector === '[role="menuitemradio"]' ? rows : [],
    querySelector: () => null,
  };
  for (const item of rows) item.parentElement = container;
  return container;
};

test("模型选择器能被弹层或 menu 语义结构定位", () => {
  const { modelPickerPanel, setPanels } = loadBlock({
    bootModels: [
      { id: "grok-4.7", displayName: "grok-4.7" },
      { id: "glm-5.3", displayName: "glm-5.3" },
      { id: "gpts-feiyu/deepseek-flash", displayName: "deepseek-flash（feiyu）" },
    ],
    groupNames: ["ChooHub", "feiyu"],
    currentName: "ChooHub",
  });
  const rows = [
    row("默认"),
    row("grok-4.7"),
    row("glm-5.3"),
    row("deepseek-flash（feiyu）"),
  ];
  const menu = list(rows);
  menu.dropdown = true;
  menu.querySelectorAll = ((original) => (selector) => (
    selector === '[role="menu"]' ? [menu] : original(selector)
  ))(menu.querySelectorAll);
  setPanels([menu]);
  assert.equal(modelPickerPanel(), menu);
});

test("带 hash class 的模型行仍按渠道归组", () => {
  const { collectPickerGroups } = loadBlock({
    bootModels: [
      { id: "grok-4.7", displayName: "grok-4.7" },
      { id: "glm-5.3", displayName: "glm-5.3" },
      { id: "gpts-feiyu/deepseek-flash", displayName: "deepseek-flash（feiyu）" },
    ],
    groupNames: ["ChooHub", "feiyu"],
    currentName: "ChooHub",
  });
  const rows = [
    "默认推荐模型集 ✓",
    "grok-4.7",
    "glm-5.3 ✓",
    "GPT-6-Sol",
    "deepseek-flash（feiyu）",
  ].map((label) => row(label));
  const groups = collectPickerGroups(rowList(rows));
  assert.deepEqual(groups.map((group) => [group.name, group.rows.length]),
    [["ChooHub", 2], ["feiyu", 1]], "分组只数我们注入的模型，表头计数才不会虚高");
});
