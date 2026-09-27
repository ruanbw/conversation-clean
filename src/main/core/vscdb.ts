import { DatabaseSync } from 'node:sqlite'
import { existsSync, statSync } from 'node:fs'

/**
 * VS Code 系 IDE 的 `state.vscdb` 索引读写。
 *
 * 用 Node 24 内建的 `node:sqlite`（`DatabaseSync`），不引 `better-sqlite3`：
 * 后者是原生模块，要跟着 Electron 的 ABI 重建，测试环境与生产环境会变成两套二进制。
 * Electron 44 内嵌 Node 24.21，两者都自带。
 *
 * ## 为什么必须有这一层
 *
 * VS Code 系（VS Code / Cursor / Windsurf / Trae / Antigravity / Copilot）除了
 * 会话文件，还在 `state.vscdb` 的 `ItemTable` 里维护**一堆**索引：正文删了而索引行还在，
 * Agent 侧就会留下永远查不到的幽灵会话。所以「删干净」= 删文件 + 改这批 key。
 *
 * ## 用法约定
 *
 * - 扫描路径一律用 `readOnly: true` 打开：IDE 可能正持有这个库，写模式打开会拿不到锁。
 * - 改索引用默认读写模式，改完立刻 `VACUUM`（SQLite 删行不会自动缩文件）。
 * - 所有函数对「文件不存在 / 表结构不对」一律静默返回：索引清理是清理流程的**补充**，
 *   不是前置条件，索引坏了不该让文件删除也失败。
 */

/** 用只读模式打开一个 SQLite 文件；文件不存在或打不开返回 `null`。 */
export function openReadOnly(dbPath: string): DatabaseSync | null {
  if (!existsSync(dbPath)) return null
  try {
    return new DatabaseSync(dbPath, { readOnly: true })
  } catch {
    return null
  }
}

/** 用读写模式打开；打不开返回 `null`。 */
export function openReadWrite(dbPath: string): DatabaseSync | null {
  if (!existsSync(dbPath)) return null
  try {
    return new DatabaseSync(dbPath)
  } catch {
    return null
  }
}

/** 读 `ItemTable` 里某个 key 的 value；不存在返回 `null`。 */
export function readItem(db: DatabaseSync, key: string): string | null {
  try {
    const row = db.prepare('SELECT value FROM ItemTable WHERE key = ?').get(key) as
      | { value: unknown }
      | undefined
    const value = row?.value
    return typeof value === 'string' ? value : value == null ? null : String(value)
  } catch {
    return null
  }
}

/** 写回 `ItemTable` 里某个 key 的 value。 */
function writeItem(db: DatabaseSync, key: string, value: string): void {
  db.prepare('UPDATE ItemTable SET value = ? WHERE key = ?').run(value, key)
}

/** 删掉 `ItemTable` 里某个 key。 */
function deleteItem(db: DatabaseSync, key: string): void {
  db.prepare('DELETE FROM ItemTable WHERE key = ?').run(key)
}

function safeJsonParse<T>(text: string | null): T | null {
  if (text === null) return null
  try {
    return JSON.parse(text) as T
  } catch {
    return null
  }
}

function base64(text: string): string {
  return Buffer.from(text, 'utf8').toString('base64')
}

/** 会话 id 的两种形态：明文，以及 VS Code 索引里常见的 base64 形态。 */
function idForms(sessionIds: Iterable<string>): { plain: Set<string>; encoded: Set<string> } {
  const plain = new Set<string>()
  const encoded = new Set<string>()
  for (const sid of sessionIds) {
    if (sid.length === 0) continue
    plain.add(sid)
    encoded.add(base64(sid))
  }
  return { plain, encoded }
}

/** 任意字符串里是否出现了这批 id 的任一形态。 */
function mentions(text: string, forms: { plain: Set<string>; encoded: Set<string> }): boolean {
  for (const sid of forms.plain) if (text.includes(sid)) return true
  for (const enc of forms.encoded) if (text.includes(enc)) return true
  return false
}

/** 条目里 `id` / `sessionId` / `resource` 任一字段命中就返回 true。 */
function entryMatches(
  entry: unknown,
  forms: { plain: Set<string>; encoded: Set<string> }
): boolean {
  if (typeof entry === 'string') return forms.plain.has(entry) || forms.encoded.has(entry)
  if (entry === null || typeof entry !== 'object') return false
  const dict = entry as Record<string, unknown>
  for (const field of ['id', 'sessionId'] as const) {
    const value = dict[field]
    if (typeof value === 'string' && (forms.plain.has(value) || forms.encoded.has(value))) {
      return true
    }
  }
  const resource = dict['resource']
  if (typeof resource === 'string' && mentions(resource, forms)) return true
  return false
}

// MARK: - 8 个索引 key 的清理器

/** 1. `chat.ChatSessionStore.index` → `entries` 字典里删掉命中的 sid。 */
function updateChatSessionStoreIndex(db: DatabaseSync, sessionIds: Set<string>): void {
  const root = safeJsonParse<Record<string, unknown>>(readItem(db, 'chat.ChatSessionStore.index'))
  if (!root) return
  const entries = root['entries']
  if (entries === null || typeof entries !== 'object' || Array.isArray(entries)) return

  let mutated = false
  const record = entries as Record<string, unknown>
  for (const sid of sessionIds) {
    if (Object.prototype.hasOwnProperty.call(record, sid)) {
      delete record[sid]
      mutated = true
    }
  }
  if (mutated) {
    root['entries'] = record
    writeItem(db, 'chat.ChatSessionStore.index', JSON.stringify(root))
  }
}

/** 2. `memento/interactive-session%` —— 值里含 sid 的整条删掉。 */
function cleanMementoInteractiveSessions(
  db: DatabaseSync,
  forms: { plain: Set<string>; encoded: Set<string> }
): void {
  for (const sid of forms.plain) {
    db.prepare(
      `DELETE FROM ItemTable
       WHERE (key = 'memento/interactive-session-view-copilot' OR key LIKE 'memento/interactive-session%')
         AND (value LIKE ? OR value LIKE ?)`
    ).run(`%${sid}%`, `%${base64(sid)}%`)
  }
}

/** 3. `interactive.sessions` —— 数组按条目删，对象按 key 删，删空就整条 key 删掉。 */
function cleanInteractiveSessions(
  db: DatabaseSync,
  forms: { plain: Set<string>; encoded: Set<string> }
): void {
  const KEY = 'interactive.sessions'
  const text = readItem(db, KEY)
  if (text === null) return
  // 快速否决：值里一个 id 都没有就别解析了，几十 MB 的 JSON 解析不便宜。
  if (!mentions(text, forms)) return

  const json = safeJsonParse<unknown>(text)
  if (json === null) {
    deleteItem(db, KEY)
    return
  }

  if (Array.isArray(json)) {
    const filtered = json.filter((entry) => !entryMatches(entry, forms))
    if (filtered.length === json.length) return
    if (filtered.length === 0) deleteItem(db, KEY)
    else writeItem(db, KEY, JSON.stringify(filtered))
    return
  }

  if (json !== null && typeof json === 'object') {
    const dict = json as Record<string, unknown>
    let mutated = false

    for (const sid of forms.plain) {
      if (Object.prototype.hasOwnProperty.call(dict, sid)) {
        delete dict[sid]
        mutated = true
      }
    }
    const entries = dict['entries']
    if (entries !== null && typeof entries === 'object' && !Array.isArray(entries)) {
      const record = entries as Record<string, unknown>
      for (const sid of forms.plain) {
        if (Object.prototype.hasOwnProperty.call(record, sid)) {
          delete record[sid]
          mutated = true
        }
      }
      dict['entries'] = record
    }

    if (Object.keys(dict).length === 0) deleteItem(db, KEY)
    else if (mutated) writeItem(db, KEY, JSON.stringify(dict))
    return
  }

  // 形状不认识：宁可整条删掉，也不要留一个永远查不到的幽灵条目。
  deleteItem(db, KEY)
}

/** 4. `workbench.panel.chat%` —— 值里含 sid 的整条删掉。 */
function cleanWorkbenchPanelChat(
  db: DatabaseSync,
  forms: { plain: Set<string>; encoded: Set<string> }
): void {
  for (const sid of forms.plain) {
    db.prepare(
      `DELETE FROM ItemTable
       WHERE (key = 'workbench.panel.chat' OR key LIKE 'workbench.panel.chat%')
         AND (value LIKE ? OR value LIKE ?)`
    ).run(`%${sid}%`, `%${base64(sid)}%`)
  }
}

/** 5 / 6. `agentSessions.state.cache` / `agentSessions.model.cache` —— 数组按条目删。 */
function cleanAgentSessionsCache(
  db: DatabaseSync,
  key: string,
  forms: { plain: Set<string>; encoded: Set<string> }
): void {
  const json = safeJsonParse<unknown[]>(readItem(db, key))
  if (!Array.isArray(json)) return
  const filtered = json.filter((entry) => !entryMatches(entry, forms))
  if (filtered.length === json.length) return
  if (filtered.length === 0) deleteItem(db, key)
  else writeItem(db, key, JSON.stringify(filtered))
}

/** 7. `composer.composerData` → `allComposers`（Cursor）。 */
function cleanComposerData(db: DatabaseSync, sessionIds: Set<string>): void {
  const KEY = 'composer.composerData'
  const root = safeJsonParse<Record<string, unknown>>(readItem(db, KEY))
  if (!root) return
  const composers = root['allComposers']
  if (!Array.isArray(composers)) return

  const filtered = composers.filter((entry) => {
    if (entry === null || typeof entry !== 'object') return true
    const dict = entry as Record<string, unknown>
    for (const field of ['composerId', 'id'] as const) {
      const value = dict[field]
      if (typeof value === 'string' && sessionIds.has(value)) return false
    }
    return true
  })
  if (filtered.length === composers.length) return
  if (filtered.length === 0) deleteItem(db, KEY)
  else {
    root['allComposers'] = filtered
    writeItem(db, KEY, JSON.stringify(root))
  }
}

/** 8. `workbench.panel.aichat.view.aichat.chatdata` → `tabs`（Cursor）。 */
function cleanAiChatData(db: DatabaseSync, sessionIds: Set<string>): void {
  const KEY = 'workbench.panel.aichat.view.aichat.chatdata'
  const root = safeJsonParse<Record<string, unknown>>(readItem(db, KEY))
  if (!root) return
  const tabs = root['tabs']
  if (!Array.isArray(tabs)) return

  const filtered = tabs.filter((entry) => {
    if (entry === null || typeof entry !== 'object') return true
    const dict = entry as Record<string, unknown>
    for (const field of ['id', 'tabId'] as const) {
      const value = dict[field]
      if (typeof value === 'string' && sessionIds.has(value)) return false
    }
    return true
  })
  if (filtered.length === tabs.length) return
  if (filtered.length === 0) deleteItem(db, KEY)
  else {
    root['tabs'] = filtered
    writeItem(db, KEY, JSON.stringify(root))
  }
}

// MARK: - 对外 API

/**
 * 从 `state.vscdb` 的全部已知索引 key 里删掉给定 sessionId。
 * 处理 VS Code、Cursor、Windsurf、Trae 的全部索引结构。
 */
export function removeChatSessions(dbPath: string, sessionIds: Iterable<string>): void {
  const forms = idForms(sessionIds)
  if (forms.plain.size === 0) return
  const db = openReadWrite(dbPath)
  if (!db) return
  try {
    updateChatSessionStoreIndex(db, forms.plain)
    cleanMementoInteractiveSessions(db, forms)
    cleanInteractiveSessions(db, forms)
    cleanWorkbenchPanelChat(db, forms)
    cleanAgentSessionsCache(db, 'agentSessions.state.cache', forms)
    cleanAgentSessionsCache(db, 'agentSessions.model.cache', forms)
    cleanComposerData(db, forms.plain)
    cleanAiChatData(db, forms.plain)
    db.exec('VACUUM;')
  } catch (error) {
    console.error(`[vscdb] 清理索引失败 ${dbPath}:`, error)
  } finally {
    db.close()
  }
}

/** 清空 `state.vscdb` 里的全部聊天会话索引。 */
export function clearAllChatSessions(dbPath: string): void {
  const db = openReadWrite(dbPath)
  if (!db) return
  const deleteKeys = [
    `DELETE FROM ItemTable WHERE key = 'chat.ChatSessionStore.index';`,
    `DELETE FROM ItemTable WHERE key = 'memento/interactive-session-view-copilot';`,
    `DELETE FROM ItemTable WHERE key LIKE 'memento/interactive-session%';`,
    `DELETE FROM ItemTable WHERE key = 'interactive.sessions';`,
    `DELETE FROM ItemTable WHERE key = 'workbench.panel.chat';`,
    `DELETE FROM ItemTable WHERE key LIKE 'workbench.panel.chat%';`,
    `DELETE FROM ItemTable WHERE key = 'agentSessions.state.cache';`,
    `DELETE FROM ItemTable WHERE key = 'agentSessions.model.cache';`,
    `DELETE FROM ItemTable WHERE key = 'composer.composerData';`,
    `DELETE FROM ItemTable WHERE key = 'workbench.panel.aichat.view.aichat.chatdata';`,
    'VACUUM;'
  ]
  try {
    for (const sql of deleteKeys) db.exec(sql)
  } catch (error) {
    console.error(`[vscdb] 清空索引失败 ${dbPath}:`, error)
  } finally {
    db.close()
  }
}

/** Cursor 的 composer 与会话是同一个 id 空间，所以它就是 `removeChatSessions` 的别名。 */
export function removeComposers(dbPath: string, composerIds: Iterable<string>): void {
  removeChatSessions(dbPath, composerIds)
}

// MARK: - GitHub Copilot Chat Session Store（globalStorage）

/** Copilot 的 `session-store.db` 里按 `session_id` 关联的这几张表。 */
const COPILOT_SESSION_TABLES = [
  'turns',
  'checkpoints',
  'session_files',
  'session_refs',
  'search_index',
  'sessions'
] as const

/**
 * 从 Copilot Chat 的 `session-store.db` 删除给定 sessionId 的全部记录。
 *
 * 与 `state.vscdb` 不同，这里的表是**正规关系表**（有 `session_id` 外键列），
 * 所以用参数化 DELETE 逐表清，不需要碰 JSON。
 */
export function removeCopilotSessionStore(
  dbPath: string,
  sessionIds: Iterable<string>
): void {
  const ids = [...sessionIds].filter((s) => s.length > 0)
  if (ids.length === 0) return
  const db = openReadWrite(dbPath)
  if (!db) return
  try {
    for (const sid of ids) {
      for (const table of COPILOT_SESSION_TABLES) {
        // `sessions` 用 `id` 主键，其余用 `session_id`。
        const column = table === 'sessions' ? 'id' : 'session_id'
        try {
          db.prepare(`DELETE FROM ${table} WHERE ${column} = ?`).run(sid)
        } catch {
          // 表不存在（Copilot 版本差异）：跳过这张，不影响其他表。
        }
      }
    }
    db.exec('VACUUM;')
  } catch (error) {
    console.error(`[vscdb] 清理 Copilot 索引失败 ${dbPath}:`, error)
  } finally {
    db.close()
  }
}

/** 清空 Copilot `session-store.db` 里的全部会话记录。 */
export function clearCopilotSessionStore(dbPath: string): void {
  const db = openReadWrite(dbPath)
  if (!db) return
  try {
    for (const table of COPILOT_SESSION_TABLES) {
      try {
        db.exec(`DELETE FROM ${table};`)
      } catch {
        /* 表不存在 */
      }
    }
    db.exec('VACUUM;')
  } catch (error) {
    console.error(`[vscdb] 清空 Copilot 索引失败 ${dbPath}:`, error)
  } finally {
    db.close()
  }
}

/**
 * 从 `state.vscdb` 里读出一个 key 的原始 JSON。
 * 给「按索引反查会话列表」的扫描器用（Cursor 的 JSONL 缺失时从索引兜底）。
 */
export function readItemJson<T = unknown>(dbPath: string, key: string): T | null {
  const db = openReadOnly(dbPath)
  if (!db) return null
  try {
    return safeJsonParse<T>(readItem(db, key))
  } finally {
    db.close()
  }
}

/**
 * 读一个 SQLite 文件的 mtime（毫秒）。
 * 扫描器靠它判断「索引比会话文件新」来决定要不要走索引兜底。
 */
export function dbMtimeMs(dbPath: string): number | undefined {
  try {
    return statSync(dbPath).mtimeMs
  } catch {
    return undefined
  }
}

/** 读一个 SQLite 文件的字节大小。 */
export function dbSizeBytes(dbPath: string): number {
  try {
    return statSync(dbPath).size
  } catch {
    return 0
  }
}
