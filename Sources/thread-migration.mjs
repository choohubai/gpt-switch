import fs from "node:fs";
import path from "node:path";
import { atomicWrite } from "./model-config.mjs";

/// 只读取聊天首行，避免把完整对话加载到内存。
const readHeader = (file) => {
  const fd = fs.openSync(file, "r");
  const chunks = [];
  try {
    const buffer = Buffer.alloc(16 * 1024);
    let offset = 0;
    for (;;) {
      const length = fs.readSync(fd, buffer, 0, buffer.length, offset);
      if (!length) break;
      const newline = buffer.subarray(0, length).indexOf(10);
      chunks.push(Buffer.from(buffer.subarray(0, newline < 0 ? length : newline + 1)));
      if (newline >= 0) break;
      offset += length;
    }
    return Buffer.concat(chunks).toString("utf8");
  } finally {
    fs.closeSync(fd);
  }
};

/// 逐块复制正文并保留原 inode；检测到并发写入时放回原文件，禁止丢弃追加消息。
const replaceHeader = (file, before, after, backup) => {
  if (readHeader(file) !== before) throw new Error(`聊天文件已变化，已停止迁移：${file}`);
  const temporary = `${file}.gpts-migrating`;
  const preserved = `${file}.gpts-original`;
  const source = fs.openSync(file, "r");
  let target;
  let replaced = false;
  let linked = false;
  let saved = preserved;
  try {
    fs.linkSync(file, preserved);
    linked = true;
    const snapshot = fs.fstatSync(source, { bigint: true });
    const unchanged = (stat) => ["dev", "ino", "size", "mtimeNs"].every((key) => stat[key] === snapshot[key]);
    if (!unchanged(fs.statSync(file, { bigint: true }))) throw new Error(`聊天文件已变化，已停止迁移：${file}`);
    target = fs.openSync(temporary, "wx", fs.statSync(file).mode & 0o777);
    fs.writeFileSync(target, after);
    const buffer = Buffer.alloc(1024 * 1024);
    let offset = Buffer.byteLength(before);
    for (;;) {
      const length = fs.readSync(source, buffer, 0, buffer.length, offset);
      if (!length) break;
      fs.writeFileSync(target, buffer.subarray(0, length));
      offset += length;
    }
    fs.fsyncSync(target);
    fs.closeSync(target);
    target = undefined;
    if (!unchanged(fs.fstatSync(source, { bigint: true })) || !unchanged(fs.statSync(file, { bigint: true }))) {
      throw new Error(`聊天文件已变化，已停止迁移：${file}`);
    }
    fs.renameSync(temporary, file);
    replaced = true;
    if (!unchanged(fs.fstatSync(source, { bigint: true }))) throw new Error(`聊天文件已变化，已停止迁移：${file}`);
    fs.renameSync(preserved, backup);
    saved = backup;
    if (!unchanged(fs.fstatSync(source, { bigint: true }))) throw new Error(`聊天文件已变化，已停止迁移：${file}`);
  } catch (error) {
    if (replaced) {
      fs.linkSync(saved, temporary);
      fs.renameSync(temporary, file);
      replaced = false;
    }
    throw error;
  } finally {
    if (target !== undefined) fs.closeSync(target);
    fs.closeSync(source);
    fs.rmSync(temporary, { force: true });
    if (linked && !replaced) fs.rmSync(preserved, { force: true });
  }
};

/// 枚举活动和归档聊天；迁移不按原供应商筛选。
const rolloutFiles = (directory) => {
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(directory, entry.name);
    return entry.isDirectory() ? rolloutFiles(file) : entry.isFile() && entry.name.endsWith(".jsonl") ? [file] : [];
  });
};

const quote = (name) => `"${name.replaceAll('"', '""')}"`;

/// 生成提供商及字节位置的变更计划；保留精确前后值以恢复中断的迁移。
const databaseChanges = (DatabaseSync, codexHome, files, providerId, identities = null, rememberThread = null, fallbackFrom = null) => {
  const plans = [];
  const byId = new Map(files.map((file) => [file.id, file]));
  for (const name of fs.readdirSync(codexHome).filter((name) => /^(state|thread_history)_\d+\.sqlite$/.test(name)).sort()) {
    const database = new DatabaseSync(path.join(codexHome, name), { readOnly: true });
    const changes = [];
    try {
      const tables = database.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map((row) => row.name);
      if (tables.includes("threads")) {
        for (const row of database.prepare("SELECT rowid AS migration_rowid,id,model_provider FROM threads").all()) {
          rememberThread?.(name, row);
          const key = `${name}:${row.id}`;
          const wanted = identities
            ? identities.has(key) ? identities.get(key) : row.model_provider === fallbackFrom ? providerId : undefined
            : providerId;
          if (wanted === undefined || row.model_provider === wanted) continue;
          changes.push({
            table: "threads", rowid: row.migration_rowid, id: row.id, identity: { id: row.id },
            before: { model_provider: row.model_provider }, after: { model_provider: wanted },
          });
        }
      }
      for (const table of ["thread_turns", "thread_history_projection_state"]) {
        if (!tables.includes(table)) continue;
        const schema = database.prepare(`PRAGMA table_info(${quote(table)})`).all();
        const columns = schema.map((row) => row.name).filter((name) => name.endsWith("byte_offset"));
        const keys = schema.filter((row) => row.pk || row.name === "thread_id").map((row) => row.name);
        if (!columns.length) continue;
        const select = database.prepare(`SELECT rowid AS migration_rowid,${[...keys, ...columns].map(quote).join(",")} FROM ${quote(table)} WHERE thread_id=?`);
        for (const [id, file] of byId) {
          const beforeLength = Buffer.byteLength(file.before);
          const delta = Buffer.byteLength(file.after) - beforeLength;
          if (!delta) continue;
          for (const row of select.all(id)) {
            const before = {}, after = {};
            for (const column of columns) {
              if (row[column] < beforeLength || row[column] == null) continue;
              before[column] = row[column];
              after[column] = row[column] + delta;
            }
            if (Object.keys(before).length) changes.push({
              table, rowid: row.migration_rowid, identity: Object.fromEntries(keys.map((key) => [key, row[key]])), before, after,
            });
          }
        }
      }
    } finally {
      database.close();
    }
    if (changes.length) plans.push({ name, changes });
  }
  return plans;
};

/// 在事务中核对快照后更新索引；恢复时接受已经回滚的行，拒绝覆盖并发变化。
const updateDatabases = (database, plans, restore) => {
  for (let index = 0; index < plans.length; index += 1) {
    for (const change of plans[index].changes) {
      const table = `${quote(`db${index}`)}.${quote(change.table)}`;
      const expected = restore ? change.after : change.before;
      const wanted = restore ? change.before : change.after;
      const columns = Object.keys(wanted);
      const identity = change.identity;
      const row = database.prepare(`SELECT * FROM ${table} WHERE rowid=?`).get(change.rowid);
      if (!identity || !row || Object.entries(identity).some(([key, value]) => row[key] !== value)) {
        throw new Error(`聊天索引已变化，已停止迁移：${plans[index].name}/${change.table}`);
      }
      if (restore && row && columns.every((column) => row[column] === wanted[column])) continue;
      if (!row || columns.some((column) => row[column] !== expected[column])) {
        throw new Error(`聊天索引已变化，已停止迁移：${plans[index].name}/${change.table}`);
      }
      database.prepare(`UPDATE ${table} SET ${columns.map((column) => `${quote(column)}=?`).join(",")} WHERE rowid=?`)
        .run(...columns.map((column) => wanted[column]), change.rowid);
    }
  }
};

/// 所有索引在同一事务内更新；文件写入失败时按原首行回滚，正文不受影响。
const executePlan = (DatabaseSync, codexHome, plan, restore = false) => {
  const database = new DatabaseSync(":memory:");
  const written = [];
  try {
    for (let index = 0; index < plan.databases.length; index += 1) {
      database.prepare(`ATTACH DATABASE ? AS ${quote(`db${index}`)}`).run(path.join(codexHome, plan.databases[index].name));
    }
    database.exec("BEGIN IMMEDIATE");
    updateDatabases(database, plan.databases, restore);
    for (const [index, file] of plan.files.entries()) {
      const before = restore ? file.after : file.before;
      const after = restore ? file.before : file.after;
      if (restore && readHeader(file.path) === after) continue;
      replaceHeader(file.path, before, after, path.join(plan.snapshotDir, `${index}${restore ? "-recovery" : ""}`));
      written.push({ ...file, before, after, index });
    }
    database.exec("COMMIT");
  } catch (error) {
    if (database.isTransaction) database.exec("ROLLBACK");
    for (const file of written.reverse()) {
      replaceHeader(file.path, file.after, file.before, path.join(plan.snapshotDir, `${file.index}-rollback`));
    }
    throw error;
  } finally {
    database.close();
  }
};

/// 同时保存可恢复的操作计划与完整原文件目录，进程退出后仍能定位每份原 inode。
const savePending = (backupDir, plan) => {
  plan.snapshotDir = fs.mkdtempSync(path.join(backupDir, "snapshots-"));
  atomicWrite(path.join(plan.snapshotDir, "plan.json"), `${JSON.stringify(plan)}\n`);
  atomicWrite(path.join(backupDir, "pending.json"), `${JSON.stringify(plan)}\n`);
};

/// 恢复尚未完成的迁移，再继续正常启动；禁止在客户端运行时修改文件或索引。
const recoverPending = (DatabaseSync, codexHome, backupDir) => {
  const pending = path.join(backupDir, "pending.json");
  if (!fs.existsSync(pending)) return;
  const plan = JSON.parse(fs.readFileSync(pending, "utf8"));
  for (const [index, file] of plan.files.entries()) {
    const adjacent = `${file.path}.gpts-original`;
    const archived = path.join(plan.snapshotDir, String(index));
    const preserved = fs.existsSync(adjacent) ? adjacent : archived;
    if (fs.existsSync(preserved)) {
      const header = readHeader(file.path);
      const bodySize = fs.statSync(file.path).size - Buffer.byteLength(header);
      const savedBodySize = fs.statSync(preserved).size - Buffer.byteLength(readHeader(preserved));
      if (![file.before, file.after].includes(header) || bodySize > savedBodySize) {
        throw new Error(`聊天文件已变化，已保留中断备份：${file.path}`);
      }
      const temporary = `${file.path}.gpts-migrating`;
      fs.rmSync(temporary, { force: true });
      fs.linkSync(preserved, temporary);
      fs.renameSync(temporary, file.path);
      if (preserved === adjacent) fs.rmSync(adjacent);
    }
    fs.rmSync(`${file.path}.gpts-migrating`, { force: true });
  }
  executePlan(DatabaseSync, codexHome, plan, true);
  fs.rmSync(pending);
};

/// 将全部本地聊天统一到稳定身份，备份首行及索引原值，保留完整正文和附件记录。
export const migrateThreadProviders = async ({ codexHome, backupDir, providerId, assertIdle }) => {
  assertIdle();
  const { DatabaseSync } = await import("node:sqlite");
  fs.mkdirSync(backupDir, { recursive: true, mode: 0o700 });
  recoverPending(DatabaseSync, codexHome, backupDir);
  const original = path.join(backupDir, "original.json");
  const first = !fs.existsSync(original);
  const originals = first ? { providerId, files: [], threads: [] } : JSON.parse(fs.readFileSync(original, "utf8"));
  const files = [];
  for (const file of [...rolloutFiles(path.join(codexHome, "sessions")), ...rolloutFiles(path.join(codexHome, "archived_sessions"))]) {
    const before = readHeader(file);
    let header;
    try { header = JSON.parse(before); } catch { throw new Error(`聊天首行无法解析，已停止迁移：${file}`); }
    if (header.type !== "session_meta") continue;
    const id = header.payload?.id;
    if (typeof id !== "string") throw new Error(`聊天缺少身份元数据，已停止迁移：${file}`);
    if ((first || header.payload.model_provider !== providerId) && !originals.files.some((entry) => entry.id === id)) {
      originals.files.push({ id, path: file, header: before });
    }
    if (header.payload.model_provider === providerId) continue;
    header.payload.model_provider = providerId;
    files.push({ path: file, id, before, after: `${JSON.stringify(header)}\n` });
  }
  const databases = databaseChanges(DatabaseSync, codexHome, files, providerId, null, (database, row) => {
    if ((first || row.model_provider !== providerId) && !originals.threads.some((entry) => entry.database === database && entry.id === row.id)) {
      originals.threads.push({ database, id: row.id, provider: row.model_provider });
    }
  });
  atomicWrite(original, `${JSON.stringify(originals)}\n`);
  if (!files.length && !databases.length) return { files: 0, threads: 0 };
  const plan = { files, databases };
  const pending = path.join(backupDir, "pending.json");
  savePending(backupDir, plan);
  assertIdle();
  executePlan(DatabaseSync, codexHome, plan);
  fs.rmSync(pending);
  return { files: files.length, threads: databases.reduce((sum, db) => sum + db.changes.filter((change) => change.table === "threads").length, 0) };
};

/// 恢复原提供商身份并反向调整当前索引，保留迁移后新增的全部消息。
export const restoreThreadProviders = async ({ codexHome, backupDir, assertIdle, fallbackProviderId = "openai" }) => {
  assertIdle();
  const original = path.join(backupDir, "original.json");
  if (!fs.existsSync(original)) return;
  const { DatabaseSync } = await import("node:sqlite");
  recoverPending(DatabaseSync, codexHome, backupDir);
  const originals = JSON.parse(fs.readFileSync(original, "utf8"));
  const available = new Map([...rolloutFiles(path.join(codexHome, "sessions")), ...rolloutFiles(path.join(codexHome, "archived_sessions"))]
    .map((file) => [JSON.parse(readHeader(file)).payload?.id, file]));
  const headers = new Map(originals.files.map((entry) => [entry.id, entry.header]));
  const files = [...available].flatMap(([id, file]) => {
    const before = readHeader(file);
    const header = JSON.parse(before);
    let after = headers.get(id);
    if (!after && header.payload?.model_provider === originals.providerId) {
      header.payload.model_provider = fallbackProviderId;
      after = `${JSON.stringify(header)}\n`;
    }
    return !after || before === after ? [] : [{ path: file, id, before, after }];
  });
  const identities = new Map(originals.threads.map((entry) => [`${entry.database}:${entry.id}`, entry.provider]));
  const plan = { files, databases: databaseChanges(DatabaseSync, codexHome, files, fallbackProviderId, identities, null, originals.providerId) };
  const pending = path.join(backupDir, "pending.json");
  savePending(backupDir, plan);
  assertIdle();
  executePlan(DatabaseSync, codexHome, plan);
  fs.rmSync(pending);
  fs.rmSync(original);
};
