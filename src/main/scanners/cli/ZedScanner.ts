import { randomUUID } from 'node:crypto'
import { mkdirSync, realpathSync } from 'node:fs'
import { basename, extname, join, resolve } from 'node:path'
import type { ConversationItem } from '@shared/types'
import type { AgentScanner, ScannerOptions } from '@main/core/scanner'
import {
  CleanPrefs,
  listFiles,
  makeItem,
  mapLimit,
  mtimeMs,
  pathExists,
  readJson,
  removeIfExists,
  resolveStoragePath,
  sizeOfPath,
  sortByUpdatedDesc,
  truncate
} from '@main/core/scanner'
import { parseIsoDate } from '@main/core/datetime'
import { openReadOnly, openReadWrite } from '@main/core/vscdb'

/**
 * Zed AI 扫描器。
 *
 * 数据根：`ZED_HOME` > `~/Library/Application Support/Zed`（测试可注入）。
 *
 * Zed 的数据是**三处分散**的，而且互相不知道对方的存在：
 *   1. `threads/threads.db` —— 正经的线程索引（SQLite，`threads` 表）
 *   2. `threads/*.json`     —— 早期版本的线程落盘格式
 *   3. `conversations/*.json` / `hang_traces/*` —— 存档与崩溃转储
 *
 * 1 与 2 的会话 id 空间是同一套（`threads/zed-th-xxx.json` 与 `threads` 表的 `id` 对应），
 * 但 Zed 自己不会互相清理，所以扫描时**分开列**、删除时**合并回收**。
 *
 * ⚠️ `threads.db` 出现在每条 DB 线程的 `associatedPaths` 里，但它是**所有线程共用的索引文件**，
 * 删一条会话绝不能把它删掉。`delete()` 因此**刻意绕开** `deleteItemsWithPaths`，
 * 手动逐条筛掉 DB 路径 —— 走那个公共 helper 就会把 `threads.db` 一起删掉，
 * 等于抹掉剩下所有线程的索引。
 */

/** `associatedPaths` 里用来标记「这条会话在 threads.db 里有一行」的伪路径前缀。 */
const THREAD_MARKER = 'zed-thread:'
/** `hang_traces` 被打包成单条会话时的固定 sessionId。 */
const HANG_TRACES_ID = 'zed-hang-traces'

/** `threads` 表里取用的列：`id, summary, updated_at, data_type, folder_paths, created_at, length(data)`。 */
interface ThreadRow {
  id: unknown
  summary: unknown
  updated_at: unknown
  folder_paths: unknown
  created_at: unknown
  data_length: unknown
}

/** 标题 / 摘要的统一口径：先截断到 N 字符，再把换行换成空格。 */
function flatten(text: string, limit: number): string {
  return truncate(text, limit).replace(/\n/g, ' ')
}

/**
 * realpath 规范化；路径不存在时 realpath 会抛，此时退回**纯词法**规范化（不解符号链接）。
 */
function canonical(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return resolve(path)
  }
}

/** SQLite 文本列取值：NULL → null，blob 按 UTF-8 解，其余转字符串。 */
function columnText(value: unknown): string | null {
  if (value === null || value === undefined) return null
  if (typeof value === 'string') return value
  if (value instanceof Uint8Array) return Buffer.from(value).toString('utf8')
  return String(value)
}

/** 文件 mtime；取不到回落到「现在」（排序不至于把未知时间的会话塞到末尾）。 */
function modifiedAt(path: string): Date {
  const ms = mtimeMs(path)
  return ms === undefined ? new Date() : new Date(ms)
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return null
  return value as Record<string, unknown>
}

/**
 * `folder_paths` 列 → 项目路径。
 * 两种形状都见过：Zed 新版写 `["/path/a"]`，旧版写 `[{"path": "/path/a"}]`。
 */
function parseFolderPaths(raw: string | null): string | null {
  if (raw === null) return null
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return null
  }
  if (!Array.isArray(parsed)) return null
  if (parsed.every((entry) => typeof entry === 'string')) {
    const first = parsed[0]
    return typeof first === 'string' ? first : null
  }
  for (const entry of parsed) {
    const record = asRecord(entry)
    const path = record?.['path']
    if (typeof path === 'string') return path
  }
  return null
}

/** `threads/threads.db` 里的一条线程 → 会话。 */
function threadItem(row: ThreadRow, dbPath: string): ConversationItem {
  const id = columnText(row.id) ?? randomUUID()
  const summary = columnText(row.summary) ?? ''
  const updatedAtText = columnText(row.updated_at) ?? ''
  const createdAtText = columnText(row.created_at)
  const dataLength = Number(row.data_length ?? 0)

  const trimmed = summary.trim()
  const title =
    trimmed.length > 0 ? flatten(trimmed, 80) : `Zed AI 会话 ${truncate(id, 8)}`
  const snippet = trimmed.length > 0 ? flatten(trimmed, 120) : 'Zed 助手对话记录'

  return makeItem({
    sessionId: id,
    title,
    category: 'zed',
    projectPath: parseFolderPaths(columnText(row.folder_paths)),
    messageCount: Math.max(1, Math.floor(dataLength / 1024 / 2)),
    // 索引行本身有开销，再加上 SQLite 的行头；下限 512 让「小会话」在 UI 上不显示 0B。
    sizeInBytes: Math.max(dataLength + 256, 512),
    updatedAt: parseIsoDate(updatedAtText) ?? parseIsoDate(createdAtText ?? '') ?? new Date(),
    snippet,
    associatedPaths: [`${THREAD_MARKER}${id}`, dbPath]
  })
}

/** `threads/threads.db` 全表扫描。库打不开 / 表结构不对时静默返回 `[]`。 */
function scanThreadsDatabase(dbPath: string): ConversationItem[] {
  if (!pathExists(dbPath)) return []
  const db = openReadOnly(dbPath)
  if (!db) return []
  try {
    const rows = db
      .prepare(
        `SELECT id, summary, updated_at, data_type, folder_paths, created_at, length(data) AS data_length
         FROM threads;`
      )
      .all() as unknown as ThreadRow[]
    return rows.map((row) => threadItem(row, dbPath))
  } catch (error) {
    console.error('[zed] 读取 threads.db 失败：', error)
    return []
  } finally {
    db.close()
  }
}

/** `threads/*.json`（旧版线程落盘格式）。 */
function threadFileItem(path: string): ConversationItem {
  const sessionId = basename(path, extname(path))
  const json = asRecord(readJson(path))
  const summary = json?.['summary']
  const title = json?.['title']

  const picked =
    typeof summary === 'string' && summary.length > 0
      ? summary
      : typeof title === 'string' && title.length > 0
        ? title
        : null

  return makeItem({
    sessionId,
    title: picked === null ? `Zed 线程 ${truncate(sessionId, 8)}` : flatten(picked, 80),
    category: 'zed',
    messageCount: 1,
    sizeInBytes: sizeOfPath(path),
    updatedAt: modifiedAt(path),
    snippet: picked === null ? 'Zed AI 线程记录' : flatten(picked, 120),
    associatedPaths: [path]
  })
}

/** `conversations/*.json`（Zed 的会话存档）。 */
function conversationFileItem(path: string): ConversationItem {
  const sessionId = basename(path, extname(path))
  const json = asRecord(readJson(path))
  const title = json?.['title']
  const summary = json?.['summary']

  const picked =
    typeof title === 'string' && title.length > 0
      ? title
      : typeof summary === 'string' && summary.length > 0
        ? summary
        : null

  const messages = json?.['messages']
  const count = Array.isArray(messages) ? Math.max(1, messages.length) : 1

  return makeItem({
    sessionId,
    title: picked === null ? `Zed 会话 ${truncate(sessionId, 8)}` : flatten(picked, 80),
    category: 'zed',
    messageCount: count,
    sizeInBytes: sizeOfPath(path),
    updatedAt: modifiedAt(path),
    snippet: picked === null ? 'Zed 会话存档' : flatten(picked, 120),
    associatedPaths: [path]
  })
}

/**
 * `hang_traces/` 打包成**一条**会话。
 *
 * 这些是 Zed 无响应时落的 miniprof 堆栈快照，数量多、单个无意义，
 * 所以按「全部转储」聚合成一条，用户一次勾选就清掉。
 */
function hangTracesItem(dir: string): ConversationItem | null {
  const traceFiles = listFiles(dir).filter(
    (path) => extname(path).toLowerCase() === '.json' || basename(path).startsWith('hang-')
  )
  if (traceFiles.length === 0) return null

  let totalBytes = 0
  let latestMs = Number.NEGATIVE_INFINITY
  for (const file of traceFiles) {
    totalBytes += sizeOfPath(file)
    const ms = mtimeMs(file)
    if (ms !== undefined && ms > latestMs) latestMs = ms
  }
  if (totalBytes <= 0) return null

  return makeItem({
    sessionId: HANG_TRACES_ID,
    title: `Zed 挂起与崩溃转储日志 (${traceFiles.length} 个文件)`,
    category: 'zed',
    messageCount: traceFiles.length,
    sizeInBytes: totalBytes,
    updatedAt: Number.isFinite(latestMs) ? new Date(latestMs) : new Date(),
    snippet: 'Zed 编辑器无响应时的性能转储与堆栈快照 (miniprof)',
    associatedPaths: traceFiles
  })
}

/** 从 `threads` 表删掉给定 id，然后 `VACUUM` 回收（SQLite 删行不会自动缩文件）。 */
function deleteThreadsFromDb(dbPath: string, threadIds: readonly string[]): void {
  const db = openReadWrite(dbPath)
  if (!db) return
  try {
    for (const id of threadIds) {
      try {
        db.prepare('DELETE FROM threads WHERE id = ?;').run(id)
      } catch (error) {
        console.error(`[zed] 删除线程索引行失败 ${id}:`, error)
      }
    }
    try {
      db.exec('VACUUM;')
    } catch (error) {
      console.error('[zed] VACUUM 失败：', error)
    }
  } finally {
    db.close()
  }
}

/** 清空 `threads` 表并 `VACUUM`。 */
function clearAllThreadsInDb(dbPath: string): void {
  const db = openReadWrite(dbPath)
  if (!db) return
  try {
    db.exec('DELETE FROM threads; VACUUM;')
  } catch (error) {
    console.error('[zed] 清空 threads 表失败：', error)
  } finally {
    db.close()
  }
}

export class ZedScanner implements AgentScanner {
  readonly category = 'zed' as const
  private readonly root: string

  constructor(options: ScannerOptions = {}) {
    // `ZED_HOME` > `~/Library/Application Support/Zed`，两条路径都过一次 realpath。
    this.root =
      options.storagePath !== undefined
        ? canonical(options.storagePath)
        : resolveStoragePath(['Library', 'Application Support', 'Zed'], { key: 'ZED_HOME' })
  }

  get storagePath(): string {
    return this.root
  }

  get isInstalled(): boolean {
    return pathExists(this.root)
  }

  private threadsDir(): string {
    return join(this.root, 'threads')
  }

  private threadsDbPath(): string {
    return join(this.threadsDir(), 'threads.db')
  }

  private conversationsDir(): string {
    return join(this.root, 'conversations')
  }

  private hangTracesDir(): string {
    return join(this.root, 'hang_traces')
  }

  async scan(): Promise<ConversationItem[]> {
    if (!this.isInstalled) return []

    const items: ConversationItem[] = []

    // 1. threads.db —— 正式线程。
    items.push(...scanThreadsDatabase(this.threadsDbPath()))

    // 2. threads/*.json —— 旧版线程文件。
    items.push(
      ...(await mapLimit(listFiles(this.threadsDir(), '.json'), 8, (path) => threadFileItem(path)))
    )

    // 3. conversations/*.json —— 会话存档。
    items.push(
      ...(await mapLimit(
        listFiles(this.conversationsDir(), '.json'),
        8,
        (path) => conversationFileItem(path)
      ))
    )

    // 4. hang_traces/ —— 崩溃 / 挂起转储，聚合成一条。
    const hangTraces = hangTracesItem(this.hangTracesDir())
    if (hangTraces !== null) items.push(hangTraces)

    return sortByUpdatedDesc(items)
  }

  /**
   * 删除会话。
   *
   * 与绝大多数扫描器的「逐条删 associatedPaths」有一处**故意的不同**：
   * `threads.db` 在每条 DB 线程的 `associatedPaths` 里，但它是所有线程共用的索引文件，
   * 这里显式跳过它，只把该 sessionId 的行从库里删掉。
   * 判据是「这个会话根本没有物理文件」（纯索引行）：即便 `associatedPaths` 里
   * 没有 DB 路径，只要物理文件全没删掉，就把索引行也删掉，否则界面上会留下一条空会话。
   */
  async delete(items: ConversationItem[]): Promise<number> {
    if (items.length === 0) return 0

    const dbPath = this.threadsDbPath()
    const dbExists = pathExists(dbPath)
    const threadIds: string[] = []
    let freed = 0

    for (const item of items) {
      // 必须在物理删除之前算：路径没了 `sizeOf` 恒为 0。
      freed += CleanPrefs.freedBytesBeforeDelete(item.sizeInBytes, item)

      // 索引行属于「会话存在性」，不受快照开关影响；只有物理文件走 deletionPaths。
      const pathsToDelete = new Set(CleanPrefs.deletionPathsFor(item))
      let hasPhysicalFile = false
      for (const path of item.associatedPaths) {
        if (path === dbPath || path.startsWith(THREAD_MARKER)) continue
        if (!pathsToDelete.has(path)) continue
        if (removeIfExists(path)) hasPhysicalFile = true
      }

      const fromIndex = item.associatedPaths.some(
        (path) => path === dbPath || path.startsWith(THREAD_MARKER)
      )
      if (dbExists && (fromIndex || !hasPhysicalFile)) {
        threadIds.push(item.sessionId)
      }
    }

    if (threadIds.length > 0 && dbExists) {
      deleteThreadsFromDb(dbPath, threadIds)
    }
    return freed
  }

  /**
   * 全清。**不**走 `delete()`：索引行、目录、目录里的 json 分四步各自记账。
   * `conversations/` 与 `hang_traces/` 整目录删掉后**重建**（Zed 正在运行时
   * 缺目录会报错），而 `threads/` 只删 json —— `threads.db` 要留在原地。
   */
  async cleanAll(): Promise<number> {
    if (!this.isInstalled) return 0
    let freed = 0

    // 1. 清空 threads.db，只按「文件缩小了多少」记账（VACUUM 后才会真缩）。
    const dbPath = this.threadsDbPath()
    if (pathExists(dbPath)) {
      const before = sizeOfPath(dbPath)
      clearAllThreadsInDb(dbPath)
      freed += Math.max(0, before - sizeOfPath(dbPath))
    }

    // 2 & 3. conversations/ 与 hang_traces/：整目录删掉再重建。
    for (const dir of [this.conversationsDir(), this.hangTracesDir()]) {
      if (!pathExists(dir)) continue
      freed += sizeOfPath(dir)
      removeIfExists(dir)
      try {
        mkdirSync(dir, { recursive: true })
      } catch (error) {
        console.error(`[zed] 重建目录失败 ${dir}:`, error)
      }
    }

    // 4. threads/ 里的 json 文件（threads.db 保留 —— 索引文件本身要留给 Zed 重用）。
    for (const file of listFiles(this.threadsDir(), '.json')) {
      freed += sizeOfPath(file)
      removeIfExists(file)
    }

    return freed
  }
}
