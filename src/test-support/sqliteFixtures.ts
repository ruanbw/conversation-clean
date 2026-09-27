/**
 * SQLite 夹具工厂：用 `node:sqlite` 造 mock `state.vscdb` / `session-store.db`。
 *
 * 移植自 Swift 版 `scripts/tests/VSCDBIndexSyncTests.swift` 的建库段落
 * （那里直接 `sqlite3_open` + 手写 `CREATE TABLE` / `INSERT`；
 * 这里用 Node 24 内建的 `node:sqlite` `DatabaseSync`，SQL 完全一致）。
 * 另收编了 `Fixtures.swift` 的 `Fixture.sqlite(at:failureMessage:_:)`：
 * 「打开 → 建表写入 → 关闭」这段样板在这里收口成一行调用。
 *
 * 只导出辅助函数，不含 `describe` / `test`。
 */

import { DatabaseSync } from 'node:sqlite'
import { dirname } from 'node:path'
import { ensureDir, writeJsonFile } from './fixtures'

// MARK: - 基础

/** `state.vscdb` 的建表语句，与 VS Code 实际结构一致。 */
export const ITEM_TABLE_DDL = 'CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);'

/** Copilot `session-store.db` 的 6 张表。顺序与 `core/vscdb.ts` 的 `COPILOT_SESSION_TABLES` 一致。 */
export const COPILOT_TABLE_DDL: Readonly<Record<CopilotTable, string>> = {
  turns: 'CREATE TABLE turns (id INTEGER PRIMARY KEY, session_id TEXT, user_message TEXT);',
  checkpoints: 'CREATE TABLE checkpoints (id INTEGER PRIMARY KEY, session_id TEXT, ref TEXT);',
  session_files: 'CREATE TABLE session_files (id INTEGER PRIMARY KEY, session_id TEXT, uri TEXT);',
  session_refs: 'CREATE TABLE session_refs (id INTEGER PRIMARY KEY, session_id TEXT, ref_uri TEXT);',
  search_index: 'CREATE TABLE search_index (id INTEGER PRIMARY KEY, session_id TEXT, chunk TEXT);',
  sessions: 'CREATE TABLE sessions (id TEXT PRIMARY KEY, summary TEXT);'
}

export type CopilotTable = 'turns' | 'checkpoints' | 'session_files' | 'session_refs' | 'search_index' | 'sessions'

/** 会话 id 的 base64 形态：VS Code 索引里 `resource` 字段常见这个写法。 */
export function b64(text: string): string {
  return Buffer.from(text, 'utf8').toString('base64')
}

/** 打开（必要时创建）库、执行 `body`、关闭。对应 Swift `Fixture.sqlite(at:failureMessage:_:)`。 */
export function withSqlite<T>(dbPath: string, body: (db: DatabaseSync) => T): T {
  ensureDir(dirname(dbPath))
  const db = new DatabaseSync(dbPath)
  try {
    return body(db)
  } finally {
    db.close()
  }
}

/** 只读打开（跑完自动关）。扫描器侧的「验证索引还在不在」用它。 */
export function querySqlite<T>(dbPath: string, body: (db: DatabaseSync) => T): T | null {
  let db: DatabaseSync
  try {
    db = new DatabaseSync(dbPath, { readOnly: true })
  } catch {
    return null
  }
  try {
    return body(db)
  } finally {
    db.close()
  }
}

// MARK: - state.vscdb（ItemTable）

/**
 * 建一个只含 `ItemTable` 的 `state.vscdb`，值一律 `JSON.stringify` 后写入。
 * 返回库路径。
 */
export function createStateVscdb(
  dbPath: string,
  entries: Readonly<Record<string, unknown>> = {}
): string {
  return withSqlite(dbPath, (db) => {
    db.exec(ITEM_TABLE_DDL)
    writeStateItems(db, entries)
    return dbPath
  })
}

/** **原样**写 value（可塞非 JSON 文本，用来测「形状不认识就整条删」的分支）。 */
export function createStateVscdbRaw(
  dbPath: string,
  entries: readonly (readonly [string, string])[]
): string {
  return withSqlite(dbPath, (db) => {
    db.exec(ITEM_TABLE_DDL)
    for (const [key, value] of entries) {
      db.prepare('INSERT INTO ItemTable (key, value) VALUES (?, ?)').run(key, value)
    }
    return dbPath
  })
}

/** 往已存在的库里补 key（值会被 `JSON.stringify`）。 */
export function writeStateItems(
  db: DatabaseSync,
  entries: Readonly<Record<string, unknown>>
): void {
  const insert = db.prepare('INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)')
  for (const [key, value] of Object.entries(entries)) {
    insert.run(key, JSON.stringify(value))
  }
}

/** 读某个 key 的原始 value 字符串；不存在返回 `null`。 */
export function readStateRaw(dbPath: string, key: string): string | null {
  return querySqlite(dbPath, (db) => {
    const row = db.prepare('SELECT value FROM ItemTable WHERE key = ?').get(key) as
      | { value: unknown }
      | undefined
    const value = row?.value
    return value == null ? null : String(value)
  })
}

/** 读某个 key 的 JSON 值；不存在或解析失败返回 `null`。 */
export function readStateJson<T = unknown>(dbPath: string, key: string): T | null {
  const raw = readStateRaw(dbPath, key)
  if (raw === null) return null
  try {
    return JSON.parse(raw) as T
  } catch {
    return null
  }
}

/** 列出 `ItemTable` 现存的所有 key（已排序）。 */
export function stateKeys(dbPath: string): string[] {
  return (
    querySqlite(dbPath, (db) =>
      (db.prepare('SELECT key FROM ItemTable').all() as { key: string }[]).map((r) => r.key)
    ) ?? []
  ).sort()
}

/** `ItemTable` 行数。`clearAllChatSessions` 之后应当为 0。 */
export function stateRowCount(dbPath: string): number {
  return (
    querySqlite(dbPath, (db) => {
      const row = db.prepare('SELECT COUNT(*) AS n FROM ItemTable').get() as
        | { n: number }
        | undefined
      return row?.n ?? 0
    }) ?? 0
  )
}

// MARK: - Copilot session-store.db

export interface CopilotSessionSeed {
  id: string
  summary?: string
  turns?: string[]
}

/**
 * 建 Copilot `session-store.db`：6 张表 + 每个 session 一行 `sessions` + 若干 `turns`。
 * 返回库路径。
 */
export function createCopilotSessionStore(
  dbPath: string,
  sessions: readonly CopilotSessionSeed[] = []
): string {
  return withSqlite(dbPath, (db) => {
    for (const ddl of Object.values(COPILOT_TABLE_DDL)) db.exec(ddl)
    const insertSession = db.prepare('INSERT INTO sessions (id, summary) VALUES (?, ?)')
    const insertTurn = db.prepare('INSERT INTO turns (session_id, user_message) VALUES (?, ?)')
    for (const session of sessions) {
      insertSession.run(session.id, session.summary ?? `summary-${session.id}`)
      for (const turn of session.turns ?? []) insertTurn.run(session.id, turn)
    }
    return dbPath
  })
}

/** `sessions.id` 全量（已排序）。 */
export function copilotSessionIds(dbPath: string): string[] {
  return (
    querySqlite(dbPath, (db) =>
      (db.prepare('SELECT id FROM sessions').all() as { id: string }[]).map((r) => r.id)
    ) ?? []
  ).sort()
}

/** `turns` 行数；给了 `sessionId` 就只数该会话的。 */
export function copilotTurnCount(dbPath: string, sessionId?: string): number {
  return (
    querySqlite(dbPath, (db) => {
      const row =
        sessionId === undefined
          ? (db.prepare('SELECT COUNT(*) AS n FROM turns').get() as { n: number } | undefined)
          : (db
              .prepare('SELECT COUNT(*) AS n FROM turns WHERE session_id = ?')
              .get(sessionId) as { n: number } | undefined)
      return row?.n ?? 0
    }) ?? 0
  )
}

// MARK: - VS Code 系目录形状

/** `<root>/User` —— VS Code 系各家的 userData 根。 */
export function vscodeUserDir(root: string): string {
  return ensureDir(`${root}/User`)
}

/** `<root>/User/workspaceStorage` */
export function workspaceStorageDir(root: string): string {
  return ensureDir(`${vscodeUserDir(root)}/workspaceStorage`)
}

/** `<root>/User/workspaceStorage/<hash>` —— 一个工作区。 */
export function workspaceDir(root: string, hash = 'mock-ws-hash-123'): string {
  return ensureDir(`${workspaceStorageDir(root)}/${hash}`)
}

/** `<root>/User/workspaceStorage/<hash>/chatSessions` */
export function chatSessionsDir(root: string, hash = 'mock-ws-hash-123'): string {
  return ensureDir(`${workspaceDir(root, hash)}/chatSessions`)
}

/** 给一个工作区补上 `workspace.json`，返回落盘路径。 */
export function writeWorkspaceJson(
  root: string,
  folder = 'file:///Users/tester/synced-vsc-project',
  hash = 'mock-ws-hash-123'
): string {
  return writeJsonFile(`${workspaceDir(root, hash)}/workspace.json`, { folder })
}

// MARK: - Swift 版 8 个索引 key 的标准载荷

/**
 * 复刻 `VSCDBIndexSyncTests.swift` 里那 8 个索引 key 的初始载荷。
 *
 * 这是「删掉 sid1、sid2 必须完好无损」这条断言的原始素材，
 * 后续各 VS Code 系扫描器的用例直接 `createStateVscdb(path, defaultIndexFixture(sid1, sid2))` 即可，
 * 不用每个文件重抄一遍。
 */
export function defaultIndexFixture(sid1: string, sid2: string): Record<string, unknown> {
  const enc1 = b64(sid1)
  const enc2 = b64(sid2)
  return {
    'chat.ChatSessionStore.index': {
      version: 1,
      entries: {
        [sid1]: { sessionId: sid1, title: 'First prompt in session 1', lastMessageDate: 1789000000000 },
        [sid2]: { sessionId: sid2, title: 'Second prompt in session 2', lastMessageDate: 1789100000000 }
      }
    },
    'memento/interactive-session-view-copilot': {
      sessionResource: { external: `vscode-chat-session://local/${enc1}` }
    },
    'interactive.sessions': [sid1, sid2],
    'workbench.panel.chat': { activeSession: sid1 },
    'agentSessions.state.cache': [
      { resource: `vscode-chat-session://local/${enc1}`, read: 1 },
      { resource: `vscode-chat-session://local/${enc2}`, read: 1 }
    ],
    'agentSessions.model.cache': [
      { resource: `vscode-chat-session://local/${enc1}`, label: 'm1' },
      { resource: `vscode-chat-session://local/${enc2}`, label: 'm2' }
    ],
    'composer.composerData': {
      allComposers: [
        { composerId: sid1, name: 'c1' },
        { composerId: sid2, name: 'c2' }
      ]
    },
    'workbench.panel.aichat.view.aichat.chatdata': {
      tabs: [
        { id: sid1, chatTitle: 't1' },
        { id: sid2, chatTitle: 't2' }
      ]
    }
  }
}

/** Copilot `globalStorage` 下 `github.copilot-chat` 目录。 */
export function copilotGlobalDir(root: string): string {
  return ensureDir(`${root}/globalStorage/github.copilot-chat`)
}
