import { randomUUID } from 'node:crypto'
import { readFileSync, renameSync, writeFileSync } from 'node:fs'

import type { ConversationItem } from '@shared/types'
import { mtimeMs, makeItem } from '@main/core/scanner'
import { removeIfExists, sizeOfPath } from '@main/core/fsutil'
import { openReadWrite, openReadOnly, removeComposers } from '@main/core/vscdb'

/**
 * Cursor 的 `state.vscdb` 索引读写。
 *
 * Cursor 有两代会话存储：
 * · 新版 —— 正文在 `chatSessions/<sid>.jsonl`，索引里只有摘要
 * · 旧版 —— **正文全在索引里**：`composer.composerData` 的 `allComposers`
 *   与 `workbench.panel.aichat.view.aichat.chatdata` 的 `tabs`
 *
 * 旧版的会话没有独立文件，所以扫描阶段必须读索引才能把它们列出来；
 * 代价是 `sizeInBytes` 只能按「库大小 ÷ 条目数」摊派。
 *
 * ## 只读纪律
 *
 * `parseStateDatabase` 一律 `readOnly: true` 打开 —— Cursor 可能正持有这个库，
 * 写模式打不开就等于整个分类扫不出来。扫描阶段**不写任何东西**，
 * 连 `VACUUM` 都不能有（那会改文件、也会改 mtime）。
 */

/** Cursor 老版会话的两个索引 key。 */
const COMPOSER_DATA_KEY = 'composer.composerData'
const AI_CHAT_DATA_KEY = 'workbench.panel.aichat.view.aichat.chatdata'

/** 老版 AI Chat 面板的兜底标题。 */
const FALLBACK_CHAT_TITLE = 'Cursor 对话'

/** SQLite 文件头。用来挡掉「把整个二进制库当 JSON 读」的无谓开销。 */
const SQLITE_MAGIC = 'SQLite format 3\0'

/**
 * 解析一个 `state.vscdb` 里的全部会话条目。
 *
 * @param dbPath   `workspaceStorage/<hash>/state.vscdb`
 * @param projectPath 该 workspace 的项目路径（来自 `workspace.json`）
 */
export function parseStateDatabase(dbPath: string, projectPath: string | null): ConversationItem[] {
  const items: ConversationItem[] = []
  const totalDbSize = sizeOfPath(dbPath)

  // 一律只读打开：Cursor 可能正持有这个库
  const db = openReadOnly(dbPath)
  if (db !== null) {
    try {
      const rows = db
        .prepare('SELECT key, value FROM ItemTable WHERE key IN (?, ?)')
        .all(COMPOSER_DATA_KEY, AI_CHAT_DATA_KEY) as { key: unknown; value: unknown }[]
      for (const row of rows) {
        const value = asString(row.value)
        if (value === null) continue
        if (row.key === COMPOSER_DATA_KEY) {
          items.push(...parseComposerDataString(value, dbPath, totalDbSize, projectPath))
        } else if (row.key === AI_CHAT_DATA_KEY) {
          items.push(...parseAiChatDataString(value, dbPath, projectPath))
        }
      }
    } catch {
      // ItemTable 不存在 / 库损坏：当成没有索引条目，文件分支仍然照常扫。
    } finally {
      db.close()
    }
  }

  // 兜底：「测试夹具 / 早期版本」下 state.vscdb 其实是纯 JSON，不是 SQLite。
  // 只在「确实是 SQLite 文件」时跳过这条兜底 —— 否则一次 50MB 的二进制读取纯属白费。
  if (items.length === 0 && !isSqliteFile(dbPath)) {
    let text: string
    try {
      text = readFileSync(dbPath, 'utf8')
    } catch {
      return items
    }
    items.push(...parseComposerDataString(text, dbPath, totalDbSize, projectPath))
  }

  return items
}

/**
 * 从 `state.vscdb` 删掉给定 composer。
 *
 * 走 `core/vscdb` 的 `removeComposers`（等价于 `removeChatSessions`，
 * 同一整套索引 key 清理器）；随后额外处理「纯 JSON 夹具」形态：
 * `allComposers` 被删空就整个删掉文件，否则把改写后的 JSON 原子写回。
 */
export function deleteComposersFromStateDb(dbPath: string, sessionIds: Set<string>): void {
  removeComposers(dbPath, sessionIds)

  if (isSqliteFile(dbPath)) return
  const dict = asRecord(safeParseJson(readTextOrEmpty(dbPath)))
  if (dict === null) return
  const composers = asRecordArray(dict['allComposers'])
  if (composers === null) return

  const kept = composers.filter((composer) => {
    const id = asString(composer['composerId'])
    return id === null || !sessionIds.has(id)
  })

  if (kept.length === composers.length) return
  if (kept.length === 0) {
    removeIfExists(dbPath)
    return
  }
  dict['allComposers'] = kept
  writeJsonAtomically(dbPath, dict)
}

/**
 * 清空一个 `state.vscdb` 的聊天数据（两个索引 key），并 `VACUUM` 缩文件。
 * 打不开或表结构不对时退化为「删掉整个库文件」。
 *
 * ⚠️ **未被任何地方调用的旁路**：`cleanAll()` 走的是 `core/vscdb` 的
 * `clearAllChatSessions`，不是这里。保留是为了说明「清空一个库」另有实现，
 * 不要误以为它已经接进了清理流程。
 */
export function clearStateDatabaseChatData(dbPath: string): void {
  const db = openReadWrite(dbPath)
  if (db === null) {
    removeIfExists(dbPath)
    return
  }
  try {
    db.exec(
      `DELETE FROM ItemTable WHERE key IN ('${COMPOSER_DATA_KEY}', '${AI_CHAT_DATA_KEY}');`
    )
    db.exec('VACUUM;')
  } catch {
    // 表结构不对：退化到删掉整个库文件
    removeIfExists(dbPath)
  } finally {
    db.close()
  }
}

// MARK: - 解析

/** `composer.composerData` → 老版 composer 会话。 */
function parseComposerDataString(
  text: string,
  dbPath: string,
  totalDbSize: number,
  projectPath: string | null
): ConversationItem[] {
  const dict = asRecord(safeParseJson(text))
  if (dict === null) return []
  const composers = asRecordArray(dict['allComposers'])
  if (composers === null || composers.length === 0) return []

  // 老版会话没有独立文件，体积只能按「库大小 ÷ 条目数」摊派。
  const perComposerSize = Math.max(1, Math.floor(totalDbSize / composers.length))
  const dbModMs = mtimeMs(dbPath)

  const results: ConversationItem[] = []
  for (const composer of composers) {
    const cid = asString(composer['composerId']) ?? randomUUID()
    const rawTitle =
      asString(composer['name']) ??
      asString(composer['text']) ??
      asString(composer['richText']) ??
      'Cursor Composer'
    const singleLine = firstLine(rawTitle)
    const title = singleLine.length === 0 ? 'Cursor Composer' : singleLine.slice(0, 80)

    let msgCount = 1
    const conversation = composer['conversation']
    if (Array.isArray(conversation)) msgCount = conversation.length
    else {
      const messages = composer['messages']
      if (Array.isArray(messages)) msgCount = messages.length
    }

    const lastUpdated = asNumber(composer['lastUpdatedAt'])
    const created = asNumber(composer['createdAt'])
    let updatedAt: Date
    if (lastUpdated !== null && lastUpdated > 0) {
      updatedAt = new Date(epochSeconds(lastUpdated) * 1000)
    } else if (created !== null && created > 0) {
      updatedAt = new Date(epochSeconds(created) * 1000)
    } else {
      updatedAt = dbModMs !== undefined ? new Date(dbModMs) : new Date()
    }

    results.push(
      makeItem({
        sessionId: cid,
        title,
        category: 'cursor',
        projectPath,
        gitBranch: null,
        messageCount: msgCount,
        sizeInBytes: perComposerSize,
        updatedAt,
        snippet: title,
        // 索引条目没有独立文件，associatedPaths 只有库文件本身。
        // `delete()` 见到 `.vscdb` 结尾的路径只登记 sessionId，不会把库删掉。
        associatedPaths: [dbPath]
      })
    )
  }
  return results
}

/** `workbench.panel.aichat.view.aichat.chatdata` → 旧版 AI Chat 面板的会话 tab。 */
function parseAiChatDataString(
  text: string,
  dbPath: string,
  projectPath: string | null
): ConversationItem[] {
  const dict = asRecord(safeParseJson(text))
  if (dict === null) return []
  const tabs = asRecordArray(dict['tabs'])
  if (tabs === null || tabs.length === 0) return []

  const totalDbSize = sizeOfPath(dbPath)
  const perTabSize = Math.max(1, Math.floor(totalDbSize / tabs.length))
  const dbModMs = mtimeMs(dbPath)
  const updatedAt = dbModMs !== undefined ? new Date(dbModMs) : new Date()

  const results: ConversationItem[] = []
  for (const tab of tabs) {
    const tid = asString(tab['id']) ?? asString(tab['tabId']) ?? randomUUID()
    const chatTitle = asString(tab['chatTitle']) ?? FALLBACK_CHAT_TITLE
    const bubbles = asRecordArray(tab['bubbles']) ?? []

    results.push(
      makeItem({
        sessionId: tid,
        title: chatTitle.slice(0, 80),
        category: 'cursor',
        projectPath,
        gitBranch: null,
        messageCount: bubbles.length,
        sizeInBytes: perTabSize,
        updatedAt,
        snippet: chatTitle,
        associatedPaths: [dbPath]
      })
    )
  }
  return results
}

// MARK: - 小工具

/** Cursor 有时写秒、有时写毫秒；1e12 是分界线。 */
function epochSeconds(value: number): number {
  return value > 1e12 ? value / 1000 : value
}

/** 文件是不是真的 SQLite 库。用来挡掉「把 50MB 二进制当 JSON 读」的无谓开销。 */
function isSqliteFile(path: string): boolean {
  try {
    const buffer = readFileSync(path)
    return buffer.length >= 16 && buffer.toString('latin1', 0, 16) === SQLITE_MAGIC
  } catch {
    return false
  }
}

function safeParseJson(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
}

/** 读文本；读不到（文件已删 / 无权限）返回空串，交给上层的解析失败分支处理。 */
function readTextOrEmpty(path: string): string {
  try {
    return readFileSync(path, 'utf8')
  } catch {
    return ''
  }
}

/** 原子写：先写临时文件再 rename，断电不会留半截 JSON。 */
function writeJsonAtomically(path: string, value: unknown): void {
  const tmp = `${path}.tmp`
  try {
    writeFileSync(tmp, JSON.stringify(value, null, 2), 'utf8')
    renameSync(tmp, path)
  } catch {
    // 写不回去就保留原文件：索引残留好过索引损坏
  }
}

/** 取第一行。行分隔符含 `\n` `\r` `\r\n` 以及 U+0085 / U+2028 / U+2029。 */
function firstLine(text: string): string {
  const index = text.search(/\r\n|[\n\r\u0085\u2028\u2029]/)
  return index === -1 ? text : text.slice(0, index)
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

function asString(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function asNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

/** 收窄语义：只要有一个元素不是字典，整个转换就失败（不会跳过坏元素）。 */
function asRecordArray(value: unknown): Record<string, unknown>[] | null {
  if (!Array.isArray(value)) return null
  const out: Record<string, unknown>[] = []
  for (const entry of value) {
    const record = asRecord(entry)
    if (record === null) return null
    out.push(record)
  }
  return out
}
