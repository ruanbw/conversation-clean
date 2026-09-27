import { realpathSync } from 'node:fs'
import { join } from 'node:path'
import type { ConversationItem } from '@shared/types'
import type { AgentScanner, ScannerOptions } from '@main/core/scanner'
import {
  listDirectories,
  makeItem,
  mtimeMs,
  pathExists,
  resolveStoragePath,
  sortByUpdatedDesc
} from '@main/core/scanner'
import { parseIsoDate } from '@main/core/datetime'
import { CleanPrefs } from '@main/core/prefs'
import { removeIfExists, sizeOfPath } from '@main/core/fsutil'
import { openReadOnly, openReadWrite } from '@main/core/vscdb'

/**
 * Antigravity 会话扫描器。
 *
 * 移植自 Swift 版 `ConversationClean/Scanners/VSCodeFamily/AntigravityScanner.swift`。
 *
 * Antigravity 不走 VS Code 的 `state.vscdb`，它自己有一套 SQLite 布局，而且**索引在前**：
 *
 * 1. `~/.gemini/antigravity/conversation_summaries.db` 的 `conversation_summaries` 表
 *    —— UI 侧栏真正认的索引，`scan()` 以它为主来源（**只读**打开，IDE 可能正持有该库）。
 * 2. `~/.gemini/antigravity/brain/<convId>/` 里存在、但**没被索引收录**的目录
 *    —— 索引漏记或索引被手工改过的残留工件，单列为「孤立的记忆工件」。
 *
 * 每条会话的关联文件：`brain/<id>/`、`conversations/<id>.db`（含 `-wal` / `-shm`）、
 * `annotations/<id>.pbtxt`，存在的都算进 `associatedPaths` 与体积。
 *
 * 删除时**跳过活跃会话**（`ANTIGRAVITY_CONVERSATION_ID`，默认取一个内置 id），
 * 免得用户在实时结对编程时把自己正在用的会话删掉。
 */
export class AntigravityScanner implements AgentScanner {
  readonly category = 'antigravity' as const

  /** 测试注入的数据根；为 `null` 时走环境变量 / 默认目录。 */
  private readonly custom: string | null

  constructor(options: ScannerOptions = {}) {
    this.custom = options.storagePath ?? null
  }

  /**
   * 数据根目录：注入目录 > `ANTIGRAVITY_HOME` > `~/.gemini/antigravity`，
   * 再做一次 realpath 规范化。
   */
  get storagePath(): string {
    if (this.custom !== null) return canonical(this.custom)
    return resolveStoragePath(['.gemini', 'antigravity'], { key: 'ANTIGRAVITY_HOME' })
  }

  /** 已安装判定：只看数据根目录存在与否。 */
  get isInstalled(): boolean {
    return pathExists(this.storagePath)
  }

  /**
   * 当前活跃会话 id —— `delete` / `cleanAll` 见到它就跳过。
   *
   * 环境变量优先；没设时返回一个内置 id（Swift 版就是这个硬编码常量）。
   * 已知问题（照抄 Swift）：这个默认值是一个不透明的 UUID，用户真的在用它结对编程时，
   * 删除**不会**被拦住。端口阶段不修，修要改 Swift 版一起改。
   */
  get activeConversationId(): string {
    const envId = process.env['ANTIGRAVITY_CONVERSATION_ID']
    if (envId !== undefined && envId.length > 0) return envId
    return DEFAULT_ACTIVE_CONVERSATION_ID
  }

  // MARK: - Scan

  async scan(): Promise<ConversationItem[]> {
    if (!this.isInstalled) return []

    const root = this.storagePath
    const items: ConversationItem[] = []
    const scannedIds = new Set<string>()

    const dbPath = join(root, 'conversation_summaries.db')
    const brainDir = join(root, 'brain')
    const conversationsDir = join(root, 'conversations')
    const annotationsDir = join(root, 'annotations')

    // 1. conversation_summaries.db（UI 索引）。只读打开 —— IDE 可能正持有该库。
    if (pathExists(dbPath)) {
      const db = openReadOnly(dbPath)
      if (db !== null) {
        try {
          const rows = db
            .prepare(
              'SELECT conversation_id, title, preview, step_count, last_modified_time, workspace_uris FROM conversation_summaries;'
            )
            .all() as Record<string, unknown>[]

          for (const row of rows) {
            const convId = columnText(row['conversation_id'])
            if (convId === null) continue
            scannedIds.add(convId)

            const rawTitle = (columnText(row['title']) ?? '').trim()
            const preview = (columnText(row['preview']) ?? '').trim()
            const stepCount = columnInt(row['step_count'])

            const lastModified = columnText(row['last_modified_time'])
            const updatedAt =
              (lastModified !== null ? parseIsoDate(lastModified) : null) ?? new Date()

            const workspaceUris = columnText(row['workspace_uris'])
            const projectPath =
              workspaceUris !== null ? parseWorkspacePath(workspaceUris.trim()) : null

            // 关联文件：索引行只管「有哪些会话」，真正占盘的是这四类路径
            const associatedPaths: string[] = []
            const brainConv = join(brainDir, convId)
            if (pathExists(brainConv)) associatedPaths.push(brainConv)

            const convDb = join(conversationsDir, `${convId}.db`)
            if (pathExists(convDb)) {
              associatedPaths.push(convDb)
              const wal = join(conversationsDir, `${convId}.db-wal`)
              if (pathExists(wal)) associatedPaths.push(wal)
              const shm = join(conversationsDir, `${convId}.db-shm`)
              if (pathExists(shm)) associatedPaths.push(shm)
            }

            const annotationFile = join(annotationsDir, `${convId}.pbtxt`)
            if (pathExists(annotationFile)) associatedPaths.push(annotationFile)

            const totalSize = associatedPaths.reduce((sum, p) => sum + sizeOfPath(p), 0)
            const displayTitle =
              rawTitle.length > 0
                ? rawTitle
                : preview.length > 0
                  ? preview
                  : `Antigravity 对话 (${convId.slice(0, 8)})`

            items.push(
              makeItem({
                sessionId: convId,
                title: displayTitle,
                category: 'antigravity',
                projectPath,
                gitBranch: null,
                messageCount: Math.max(stepCount, 1),
                sizeInBytes: totalSize,
                updatedAt,
                snippet: preview.length === 0 ? displayTitle : preview,
                associatedPaths
              })
            )
          }
        } catch {
          // 表结构对不上（版本差异）就当没有索引，退化成只扫 brain/ 孤儿目录。
        } finally {
          db.close()
        }
      }
    }

    // 2. brain/ 里没被索引收录的孤儿目录
    for (const name of listDirectories(brainDir)) {
      if (scannedIds.has(name)) continue
      const entryPath = join(brainDir, name)

      items.push(
        makeItem({
          sessionId: name,
          title: `孤立的 Antigravity 记忆工件 (${name.slice(0, 8)})`,
          category: 'antigravity',
          projectPath: null,
          gitBranch: null,
          messageCount: 1,
          sizeInBytes: sizeOfPath(entryPath),
          updatedAt: new Date(mtimeMs(entryPath) ?? Date.now()),
          snippet: '未被会话数据库索引的本地残留工件',
          associatedPaths: [entryPath]
        })
      )
    }

    return sortByUpdatedDesc(items)
  }

  // MARK: - Delete & Clean

  async delete(items: ConversationItem[]): Promise<number> {
    if (items.length === 0) return 0

    let totalFreed = 0
    const sessionIdsToDeleteFromDB: string[] = []
    const activeId = this.activeConversationId

    for (const item of items) {
      // 安全护栏：活跃会话一律跳过 —— 文件不删、索引也不动。
      if (item.sessionId === activeId) continue

      totalFreed += CleanPrefs.freedBytesBeforeDelete(item.sizeInBytes, item)

      for (const path of CleanPrefs.deletionPathsFor(item)) {
        removeIfExists(path)
      }

      sessionIdsToDeleteFromDB.push(item.sessionId)
    }

    // 索引行一起删，否则 Antigravity 侧栏会留下点进去是空的幽灵菜单。
    if (sessionIdsToDeleteFromDB.length > 0) {
      deleteFromSummariesDatabase(join(this.storagePath, 'conversation_summaries.db'), sessionIdsToDeleteFromDB)
    }

    return totalFreed
  }

  async cleanAll(): Promise<number> {
    const items = await this.scan()
    const activeId = this.activeConversationId
    const cleanable = items.filter((item) => item.sessionId !== activeId)
    return this.delete(cleanable)
  }
}

// MARK: - 常量与工具

/** Swift 版硬编码的兜底活跃会话 id。 */
const DEFAULT_ACTIVE_CONVERSATION_ID = 'd72aac4b-eb6f-4cdc-af17-bb25a2d18e19'

function canonical(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

/**
 * 对应 `sqlite3_column_text`：NULL → null，数字/大整数转成字符串，其余形状 → null。
 * `node:sqlite` 把 INTEGER / REAL 分别映射成 number / bigint，
 * 而 C API 在这里会把它们当文本读出来，所以这里补上同样的转换。
 */
function columnText(value: unknown): string | null {
  if (value === null || value === undefined) return null
  if (typeof value === 'string') return value
  if (typeof value === 'number' || typeof value === 'bigint') return String(value)
  return null
}

/** 对应 `sqlite3_column_int`：非数字一律当 0。 */
function columnInt(value: unknown): number {
  if (typeof value === 'number' && Number.isFinite(value)) return Math.trunc(value)
  if (typeof value === 'bigint') return Number(value)
  if (typeof value === 'string') {
    const parsed = Number.parseInt(value, 10)
    return Number.isNaN(parsed) ? 0 : parsed
  }
  return 0
}

/**
 * `workspace_uris` → 项目路径。支持三种形态，与 Swift 版逐字一致：
 * · `file://…`        → 解码后的裸路径
 * · `["file://…"]`    → JSON 数组，取第一个再递归
 * · `/abs/path`       → 原样返回
 * 其余（`untitled:`、`vscode-remote://…` 之类）一律 `nil`。
 */
function parseWorkspacePath(raw: string): string | null {
  if (raw.length === 0) return null
  if (raw.startsWith('file://')) {
    try {
      const url = new URL(raw)
      try {
        return decodeURIComponent(url.pathname)
      } catch {
        return url.pathname
      }
    } catch {
      return raw.slice(7)
    }
  }
  if (raw.startsWith('[')) {
    try {
      const parsed: unknown = JSON.parse(raw)
      if (Array.isArray(parsed) && typeof parsed[0] === 'string') {
        return parseWorkspacePath(parsed[0])
      }
    } catch {
      // 不是合法 JSON 数组：落回下面的 `startsWith("/")` 判定。
    }
  }
  return raw.startsWith('/') ? raw : null
}

/**
 * 从 `conversation_summaries` 表里按 `conversation_id` 删行，再 `VACUUM` 缩文件。
 *
 * 与 `core/vscdb.ts` 里的 `state.vscdb` 清理器是**两套**索引：那张是 `ItemTable`
 * 的 JSON blob，这张是正规关系表。`core/vscdb.ts` 只封装了前者，所以这里直接用
 * `node:sqlite`（同一个内建模块，不引原生依赖）自己开读写库。
 * 库不存在 / 打不开 / 表不存在一律静默返回：索引清理是补充，不是文件删除的前置条件。
 */
function deleteFromSummariesDatabase(dbPath: string, sessionIds: string[]): void {
  if (!pathExists(dbPath)) return
  const db = openReadWrite(dbPath)
  if (db === null) return
  try {
    const stmt = db.prepare('DELETE FROM conversation_summaries WHERE conversation_id = ?;')
    for (const sid of sessionIds) stmt.run(sid)
    db.exec('VACUUM;')
  } catch (error) {
    console.error(`[antigravity] 清理会话索引失败 ${dbPath}:`, error)
  } finally {
    db.close()
  }
}
