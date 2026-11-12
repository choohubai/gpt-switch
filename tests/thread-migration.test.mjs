import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { migrateThreadProviders, restoreThreadProviders } from "../Sources/thread-migration.mjs";

/// 用独立 Codex 数据目录覆盖活动、归档及无文件索引，正文包含附件和工具记录。
const fixture = (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "gpts-thread-migration-"));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const codexHome = path.join(directory, "codex");
  const backupDir = path.join(directory, "backups");
  fs.mkdirSync(codexHome);
  const state = new DatabaseSync(path.join(codexHome, "state_9.sqlite"));
  state.exec("CREATE TABLE threads(id TEXT PRIMARY KEY, model_provider TEXT, rollout_path TEXT, archived INTEGER)");
  const history = new DatabaseSync(path.join(codexHome, "thread_history_3.sqlite"));
  history.exec(`
    CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, rollout_byte_offset INTEGER, rollout_end_byte_offset INTEGER, PRIMARY KEY(thread_id,turn_id));
    CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY, next_rollout_byte_offset INTEGER, next_rollout_ordinal INTEGER);
    CREATE TABLE thread_items(thread_id TEXT, item_json TEXT);
  `);
  context.after(() => { state.close(); history.close(); });
  const entries = [];
  for (const [id, provider, archived] of [["a", "x", false], ["b", "unrelated-provider", true], ["c", "openai", false]]) {
    const folder = path.join(codexHome, archived ? "archived_sessions" : "sessions/2026/11/12");
    fs.mkdirSync(folder, { recursive: true });
    const file = path.join(folder, `rollout-${id}.jsonl`);
    const header = JSON.stringify({ type: "session_meta", payload: { id, model_provider: provider, base_instructions: "保持完整" } }) + "\n";
    const body = JSON.stringify({ type: "response_item", payload: { text: "完整历史", image: "附件引用", tool: { output: "工具结果" } } }) + "\n";
    fs.writeFileSync(file, header + body);
    state.prepare("INSERT INTO threads VALUES(?,?,?,?)").run(id, provider, file, Number(archived));
    history.prepare("INSERT INTO thread_turns VALUES(?,?,?,?)").run(id, "turn", Buffer.byteLength(header), Buffer.byteLength(header + body));
    history.prepare("INSERT INTO thread_history_projection_state VALUES(?,?,?)").run(id, Buffer.byteLength(header + body), 2);
    history.prepare("INSERT INTO thread_items VALUES(?,?)").run(id, body);
    entries.push({ id, provider, file, header, body });
  }
  state.prepare("INSERT INTO threads VALUES(?,?,?,?)").run("index-only", "other", "", 0);
  return { codexHome, backupDir, state, history, entries, assertIdle: () => {} };
};

test("all active and archived conversations migrate with content and byte indexes intact", async (context) => {
  const files = fixture(context);
  const before = files.history.prepare("SELECT * FROM thread_items").all();
  const result = await migrateThreadProviders({ ...files, providerId: "stable-provider" });
  assert.equal(result.files, 3);
  assert.equal(result.threads, 4);
  for (const entry of files.entries) {
    const contents = fs.readFileSync(entry.file, "utf8");
    const newline = contents.indexOf("\n");
    assert.equal(JSON.parse(contents.slice(0, newline)).payload.model_provider, "stable-provider");
    assert.equal(contents.slice(newline + 1), entry.body);
    const offsets = files.history.prepare("SELECT * FROM thread_turns WHERE thread_id=?").get(entry.id);
    const bytes = fs.readFileSync(entry.file);
    assert.equal(bytes.subarray(offsets.rollout_byte_offset, offsets.rollout_end_byte_offset).toString(), entry.body);
    assert.equal(files.history.prepare("SELECT next_rollout_byte_offset FROM thread_history_projection_state WHERE thread_id=?").get(entry.id).next_rollout_byte_offset, bytes.length);
  }
  assert.deepEqual(files.history.prepare("SELECT * FROM thread_items").all(), before);
  assert.ok(files.state.prepare("SELECT model_provider FROM threads").all().every(row => row.model_provider === "stable-provider"));
  assert.ok(fs.readdirSync(files.backupDir).length > 0);
  assert.deepEqual(await migrateThreadProviders({ ...files, providerId: "stable-provider" }), { files: 0, threads: 0 });
});

test("restoring identities preserves messages appended after migration", async (context) => {
  const files = fixture(context);
  await migrateThreadProviders({ ...files, providerId: "stable-provider" });
  const extra = '{"type":"response_item","payload":{"text":"迁移后的新消息"}}\n';
  for (const entry of files.entries) fs.appendFileSync(entry.file, extra);
  await restoreThreadProviders(files);
  for (const entry of files.entries) {
    assert.equal(fs.readFileSync(entry.file, "utf8"), entry.header + entry.body + extra);
    assert.equal(files.state.prepare("SELECT model_provider FROM threads WHERE id=?").get(entry.id).model_provider, entry.provider);
  }
  assert.equal(files.state.prepare("SELECT model_provider FROM threads WHERE id='index-only'").get().model_provider, "other");
});

test("an active client prevents migration before any history or index changes", async (context) => {
  const files = fixture(context);
  await assert.rejects(migrateThreadProviders({
    ...files, providerId: "stable-provider", assertIdle: () => { throw Error("client is running"); },
  }), /client is running/);
  for (const entry of files.entries) assert.equal(fs.readFileSync(entry.file, "utf8"), entry.header + entry.body);
  assert.equal(files.state.prepare("SELECT model_provider FROM threads WHERE id='a'").get().model_provider, "x");
});

test("a write failure rolls back previously migrated files and database indexes", async (context) => {
  const files = fixture(context);
  const rename = fs.renameSync;
  fs.renameSync = (from, to) => {
    if (to === files.entries[1].file && String(from).endsWith(".gpts-migrating")) throw Error("simulated write failure");
    return rename(from, to);
  };
  try {
    await assert.rejects(migrateThreadProviders({ ...files, providerId: "stable-provider" }), /simulated write failure/);
  } finally {
    fs.renameSync = rename;
  }
  for (const entry of files.entries) assert.equal(fs.readFileSync(entry.file, "utf8"), entry.header + entry.body);
  assert.equal(files.state.prepare("SELECT model_provider FROM threads WHERE id='a'").get().model_provider, "x");
});

test("restoring also gives new conversations the restored default provider", async (context) => {
  const files = fixture(context);
  await migrateThreadProviders({ ...files, providerId: "stable-provider" });
  const file = path.join(files.codexHome, "sessions", "new.jsonl");
  const body = '{"type":"response_item","payload":{"text":"新聊天完整正文"}}\n';
  fs.writeFileSync(file, '{"type":"session_meta","payload":{"id":"new","model_provider":"stable-provider"}}\n' + body);
  files.state.prepare("INSERT INTO threads VALUES(?,?,?,?)").run("new", "stable-provider", file, 0);
  await migrateThreadProviders({ ...files, providerId: "stable-provider" });
  await restoreThreadProviders({ ...files, fallbackProviderId: "openai" });
  const [header, ...rest] = fs.readFileSync(file, "utf8").split("\n");
  assert.equal(JSON.parse(header).payload.model_provider, "openai");
  assert.equal(rest.join("\n"), body);
  assert.equal(files.state.prepare("SELECT model_provider FROM threads WHERE id='new'").get().model_provider, "openai");
});

test("a concurrent append during replacement is retained and migration stops", async (context) => {
  const files = fixture(context);
  const file = files.entries[0].file;
  const extra = '{"type":"response_item","payload":{"text":"并发追加"}}\n';
  const rename = fs.renameSync;
  let appended = false;
  fs.renameSync = (from, to) => {
    if (to === file && String(from).endsWith(".gpts-migrating") && !appended) {
      appended = true;
      fs.appendFileSync(file, extra);
    }
    return rename(from, to);
  };
  try {
    await assert.rejects(migrateThreadProviders({ ...files, providerId: "stable-provider" }), /聊天文件已变化/);
  } finally {
    fs.renameSync = rename;
  }
  assert.equal(fs.readFileSync(file, "utf8"), files.entries[0].header + files.entries[0].body + extra);
  assert.equal(files.state.prepare("SELECT model_provider FROM threads WHERE id='a'").get().model_provider, "x");
});

test("pending recovery rejects a reused database rowid instead of restoring another thread", async (context) => {
  const files = fixture(context);
  const migrationModule = new URL("../Sources/thread-migration.mjs", import.meta.url).href;
  const code = `
    import fs from "node:fs";
    import { migrateThreadProviders } from ${JSON.stringify(migrationModule)};
    const rename = fs.renameSync;
    fs.renameSync = (from, to) => {
      rename(from, to);
      if (to === process.argv[3]) process.exit(77);
    };
    await migrateThreadProviders({
      codexHome: process.argv[1], backupDir: process.argv[2], providerId: "stable-provider", assertIdle() {},
    });
  `;
  const child = spawnSync(process.execPath, ["--input-type=module", "-e", code,
    files.codexHome, files.backupDir, files.entries[0].file], { encoding: "utf8" });
  assert.equal(child.status, 77, child.stderr);
  const rowid = files.state.prepare("SELECT rowid FROM threads WHERE id='a'").get().rowid;
  files.state.prepare("DELETE FROM threads WHERE id='a'").run();
  files.state.prepare("INSERT INTO threads(rowid,id,model_provider,rollout_path,archived) VALUES(?,?,?,?,0)")
    .run(rowid, "replacement", "stable-provider", "");
  await assert.rejects(migrateThreadProviders({ ...files, providerId: "stable-provider" }), /聊天索引已变化/);
  assert.equal(files.state.prepare("SELECT model_provider FROM threads WHERE id='replacement'").get().model_provider, "stable-provider");
});

test("an interrupted committed migration recovers its journal and remains reversible", async (context) => {
  const files = fixture(context);
  const migrationModule = new URL("../Sources/thread-migration.mjs", import.meta.url).href;
  const code = `
    import fs from "node:fs";
    import { migrateThreadProviders } from ${JSON.stringify(migrationModule)};
    const remove = fs.rmSync;
    fs.rmSync = (file, ...args) => {
      if (file === process.argv[2] + "/pending.json") process.exit(77);
      return remove(file, ...args);
    };
    await migrateThreadProviders({
      codexHome: process.argv[1], backupDir: process.argv[2], providerId: "stable-provider", assertIdle() {},
    });
  `;
  const child = spawnSync(process.execPath, ["--input-type=module", "-e", code,
    files.codexHome, files.backupDir], { encoding: "utf8" });
  assert.equal(child.status, 77, child.stderr);
  await migrateThreadProviders({ ...files, providerId: "stable-provider" });
  assert.equal(fs.existsSync(path.join(files.backupDir, "pending.json")), false);
  await restoreThreadProviders(files);
  for (const entry of files.entries) {
    assert.equal(fs.readFileSync(entry.file, "utf8"), entry.header + entry.body);
    const offset = files.history.prepare("SELECT rollout_byte_offset FROM thread_turns WHERE thread_id=?").get(entry.id).rollout_byte_offset;
    assert.equal(offset, Buffer.byteLength(entry.header));
  }
});

test("the original inode remains recoverable even if a stale writer appends after migration", async (context) => {
  const files = fixture(context);
  const file = files.entries[0].file;
  const writer = fs.openSync(file, "a");
  const extra = '{"type":"response_item","payload":{"text":"旧写入者的晚到消息"}}\n';
  try {
    await migrateThreadProviders({ ...files, providerId: "stable-provider" });
    fs.writeSync(writer, extra);
    const snapshots = fs.readdirSync(files.backupDir, { recursive: true })
      .map((name) => path.join(files.backupDir, name))
      .filter((name) => fs.statSync(name).isFile());
    assert.ok(snapshots.some((name) => fs.readFileSync(name, "utf8") === files.entries[0].header + files.entries[0].body + extra),
      "完整原 inode 必须留在备份中，不能删除仍可能被旧写入者持有的唯一副本");
  } finally {
    fs.closeSync(writer);
  }
});
