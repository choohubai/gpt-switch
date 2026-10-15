import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";

/// 分组归属那一段是纯函数，只有渠道名清单和默认分组名是注入器塞进去的占位符。
/// 这里把同一段源码抽出来直接执行，测的是真正跑到客户端里的那份代码。
const GROUPING_START = "// ---- 分组归属（tests/injection-grouping.test.mjs";
const GROUPING_END = "// ---- 分组归属结束 ----";

const loadGrouping = (channelNames, currentName = "ChooHub", bootModels = []) => {
  const source = fs.readFileSync(new URL("../Sources/injection.js", import.meta.url), "utf8");
  const start = source.indexOf(GROUPING_START);
  assert.notEqual(start, -1, "注入模板里找不到「分组归属」段的起点，测试要跟着改");
  const end = source.indexOf(GROUPING_END, start);
  assert.notEqual(end, -1, "注入模板里找不到「分组归属」段的终点，测试要跟着改");
  const block = source.slice(start, end);
  // 渠道名清单读的是 state 上的可变字段（热推送会换掉它），这里照注入后的初始状态摆一份。
  const factory = new Function("KNOWN_GROUP_NAMES", "DEFAULT_GROUP_NAME", "BOOT_MODELS", "state",
    `${block}\nreturn { splitPickerLabel, defaultPickerGroupName, pickerRowGroup, stripRowMarks, setPickerGroupNames };`);
  return factory(channelNames, currentName, bootModels,
    { groupName: currentName, groupNames: channelNames });
};

test("只有后缀命中已知渠道名才算分组", () => {
  const { splitPickerLabel } = loadGrouping(["ChooHub", "feiyu"]);
  assert.deepEqual(splitPickerLabel("glm-5.3（feiyu）"), { name: "glm-5.3", group: "feiyu" });
  assert.deepEqual(splitPickerLabel("kimi-k2 (feiyu)"), { name: "kimi-k2", group: "feiyu" }, "半角括号也认");
  assert.deepEqual(splitPickerLabel("glm-5.3"), { name: "glm-5.3", group: "" }, "裸名归默认分组");
  assert.deepEqual(splitPickerLabel("GLM-4.6 (Thinking)"),
    { name: "GLM-4.6 (Thinking)", group: "" }, "模型名自带的括号不能被当成渠道名");
  assert.deepEqual(splitPickerLabel("deepseek（已下线）"),
    { name: "deepseek（已下线）", group: "" }, "后缀不是渠道名就整段当名字");
});

test("后缀的大小写和空格跟渠道名有出入时归到同一个表头", () => {
  const { splitPickerLabel, defaultPickerGroupName } = loadGrouping(["Choo Hub"], "Choo Hub");
  assert.deepEqual(splitPickerLabel("glm-5.3（choo  hub）"), { name: "glm-5.3", group: "Choo Hub" });
  assert.equal(defaultPickerGroupName(), "Choo Hub");
});

test("注入器没给渠道名时用兜底表头名，注入器没给默认分组名时也一样", () => {
  const { splitPickerLabel, defaultPickerGroupName } = loadGrouping([], "");
  assert.equal(defaultPickerGroupName(), "当前渠道");
  assert.deepEqual(splitPickerLabel("glm-5.3（feiyu）"),
    { name: "glm-5.3（feiyu）", group: "" }, "清单是空的时候不认任何后缀");
});

test("只有注入出去的模型才归渠道，客户端自己的行不归任何渠道", () => {
  const bootModels = [
    { id: "grok-4.7", displayName: "grok-4.7" },
    { id: "gpts-feiyu/glm-5.3", displayName: "glm-5.3（feiyu）" },
  ];
  const { pickerRowGroup } = loadGrouping(["ChooHub", "feiyu"], "ChooHub", bootModels);
  assert.equal(pickerRowGroup("grok-4.7"), "ChooHub", "当前渠道的裸名行归当前渠道");
  assert.equal(pickerRowGroup("glm-5.3（feiyu）"), "feiyu");
  assert.equal(pickerRowGroup("默认推荐模型集"), "", "客户端自己的行不能被算进任何渠道");
  assert.equal(pickerRowGroup("GPT-6-Sol"), "", "内置模型同理");
  assert.equal(pickerRowGroup("grok-4.7（feiyu）"), "feiyu", "同名模型带着渠道后缀时按后缀算");
});

test("行尾的选中勾不算模型名的一部分", () => {
  const bootModels = [
    { id: "glm-5.3", displayName: "glm-5.3" },
    { id: "gpts-feiyu/deepseek-flash", displayName: "deepseek-flash（feiyu）" },
  ];
  const { pickerRowGroup, stripRowMarks } = loadGrouping(["ChooHub", "feiyu"], "ChooHub", bootModels);
  assert.equal(stripRowMarks("glm-5.3 ✓"), "glm-5.3");
  assert.equal(pickerRowGroup(stripRowMarks("glm-5.3 ✓")), "ChooHub", "选中的当前渠道模型不能被当成别人的行");
  assert.equal(pickerRowGroup(stripRowMarks("deepseek-flash（feiyu） ✓")), "feiyu",
    "选中的其它渠道模型要留在自己那一组，不能掉进默认分组");
  assert.equal(pickerRowGroup(stripRowMarks("默认推荐模型集 ✓")), "", "客户端的行剥掉勾之后仍然不是我们的");
});

test("面板保存后热推送新渠道名，新渠道的模型当场就归到自己那一组", () => {
  const bootModels = [
    { id: "glm-5.3", displayName: "glm-5.3（ChooHub）" },
    { id: "gpts-feiyu/glm-5.3", displayName: "glm-5.3（feiyu）" },
  ];
  const { pickerRowGroup, setPickerGroupNames } = loadGrouping(["ChooHub", "feiyu"], "ChooHub", bootModels);
  // 刚加了一条渠道，面板保存后注入器热推送：只换模型列表、不换渠道名清单时，这一行认不出后缀，
  // 会被 hideForeignPickerRows 当成外来行藏掉。
  assert.equal(pickerRowGroup("glm-5.3（newch）"), "", "清单还没更新时认不出新渠道");
  setPickerGroupNames("ChooHub", ["ChooHub", "feiyu", "newch"]);
  assert.equal(pickerRowGroup("glm-5.3（newch）"), "newch", "清单更新后新渠道的模型要归到自己那一组");
  assert.equal(pickerRowGroup("glm-5.3（feiyu）"), "feiyu", "老渠道不受影响");
});
