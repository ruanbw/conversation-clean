import { createHash } from 'node:crypto'
import { readdirSync, readFileSync, realpathSync } from 'node:fs'
import type { Dirent } from 'node:fs'
import { basename, extname, join } from 'node:path'
import type { DatabaseSync } from 'node:sqlite'
import { listFiles, removeIfExists } from '@main/core/scanner'
import { openReadWrite } from '@main/core/vscdb'

/**
 * Pi Agent 的 context-mode 双层索引同步。
 *
 * ## 为什么删了会话文件还不够
 *
 * context-mode 在 `~/.pi/context-mode/` 下维护两套 SQLite 索引：
 *   · `sessions/*.db` —— 每个项目一个库，表是 `session_meta` / `session_events` /
 *     `session_resume` / `tool_calls`，都带一列 `session_id`；
 *   · `content/*.db`   —— 全局内容库（fts5 `chunks`），也带 `session_id`；
 * 另外还有 `stats-pid-<pid>.json` 的进程统计缓存。
 *
 * 会话文件删了而索引行还在，Pi 界面就会列出一堆点进去是空的**幽灵会话**。
 * 所以 `delete()` 删完文件必须回头把这些行清掉。
 *
 * ## 关键约定：session_id 就是路径的哈希
 *
 * context-mode 的 Pi adapter 用 `sha256(会话文件绝对路径)` 的**前 16 位小写十六进制**
 * 当 `session_id`（见 `contextModeSessionIdFor`）。因此不必「读会话文件反查 id」，
 * 拿到路径就能直接算出该删哪几行。
 *
 * ## 为什么表名 / 列名都是「探测」出来的
 *
 * context-mode 迭代很快，同一个 `sessions/` 目录下可能同时存在新旧两种 schema，
 * 还有 fts5 自动生成的影子表。因此不写死表清单，而是遍历 `sqlite_master`，
 * 对每张表用 `PRAGMA table_info` 找出归一化后等于 `sessionid` 的列再删。
 */

/** `sessions/*.db` 必须是正规索引库才允许「清空即删文件」。 */
const SESSION_META_TABLE = 'session_meta'
/** 收集子代理嵌套会话 `.jsonl` 的上限：子代理可嵌套出大量会话，攒够 128 条就停。 */
const JSONL_ENUMERATE_LIMIT = 128

/**
 * context-mode 用 `sha256(会话文件绝对路径)` 的前 16 位小写十六进制作为 `session_id`，
 * 所以可以由路径精确反查索引行。
 */
export function contextModeSessionIdFor(sessionFilePath: string): string {
  return createHash('sha256').update(sessionFilePath, 'utf8').digest('hex').slice(0, 16)
}

/**
 * 递归收集目录下所有 `.jsonl`（子代理嵌套会话：`<sessionDir>/<uuid>/run-0/session.jsonl`）。
 *
 * 隐藏项跳过，攒够 `limit` 个就停。
 * 扩展名比较**大小写敏感**：`x.JSONL` 不算数。
 */
export function jsonlPathsUnder(
  directory: string,
  limit: number = JSONL_ENUMERATE_LIMIT
): Set<string> {
  const paths = new Set<string>()

  const walk = (dir: string): void => {
    if (paths.size >= limit) return
    let entries: Dirent[]
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      if (paths.size >= limit) return
      if (entry.name.startsWith('.')) continue
      const child = join(dir, entry.name)
      // Dirent 基于 lstat：软链不是目录，不会顺着软链走进环里。
      if (entry.isDirectory()) walk(child)
      else if (extname(entry.name) === '.jsonl') paths.add(child)
    }
  }

  walk(directory)
  return paths
}

/**
 * 从被删除的会话文件路径集合推导 context-mode 的 `session_id` 集合，
 * 同步清理所有索引载体（SQLite 索引行 + stats 缓存）。
 */
export function purgeContextModeArtifacts(
  contextModeDir: string,
  sessionFilePaths: ReadonlySet<string>
): void {
  if (sessionFilePaths.size === 0) return

  const sessionIds = new Set<string>()
  for (const path of sessionFilePaths) {
    sessionIds.add(contextModeSessionIdFor(path))
    // 路径可能存在 `/private/var` 之类的 realpath 规范化差异，两种形态的哈希都写进去。
    const canonical = canonicalPath(path)
    if (canonical !== path) sessionIds.add(contextModeSessionIdFor(canonical))
  }

  purgeContextModeDatabases(contextModeDir, sessionIds)
  purgeContextModeStatsFiles(contextModeDir, sessionIds, sessionFilePaths)
}

/** 遍历 context-mode 下所有 SQLite 索引（`sessions/` 每项目一个库，`content/` 内容库）。 */
function purgeContextModeDatabases(
  contextModeDir: string,
  sessionIds: ReadonlySet<string>
): void {
  if (sessionIds.size === 0) return

  const targets: { dir: string; removeWhenEmpty: boolean }[] = [
    { dir: join(contextModeDir, 'sessions'), removeWhenEmpty: true },
    { dir: join(contextModeDir, 'content'), removeWhenEmpty: false }
  ]

  for (const target of targets) {
    for (const entry of listDbFiles(target.dir)) {
      purgeContextModeDatabase(entry, sessionIds, target.removeWhenEmpty)
    }
  }
}

/**
 * 清理单个库：删掉所有「含 session_id 列」的表里的匹配行；
 * 库被清空后连带 `-wal` / `-shm` 一起移除。
 */
function purgeContextModeDatabase(
  dbPath: string,
  sessionIds: ReadonlySet<string>,
  removeWhenEmpty: boolean
): void {
  const db = openReadWrite(dbPath)
  if (!db) return

  let emptiedDatabase = false
  try {
    // 250ms 忙等：Pi 进程可能正持有这个库，不等一下就直接撞 SQLITE_BUSY。
    db.exec('PRAGMA busy_timeout = 250;')
    const tables = listTables(db)
    const deletedRows = tables.length > 0 ? deleteSessionRows(db, tables, sessionIds) : 0
    emptiedDatabase =
      removeWhenEmpty &&
      deletedRows > 0 &&
      tables.includes(SESSION_META_TABLE) &&
      databaseIsEmpty(db, tables)
  } catch (error) {
    console.error(`[piAgent] 清理 context-mode 索引失败 ${dbPath}:`, error)
  } finally {
    closeQuietly(db)
  }

  if (!emptiedDatabase) return
  for (const suffix of ['', '-wal', '-shm']) {
    removeIfExists(dbPath + suffix)
  }
}

/** 库里的全部表名（排除 `sqlite_%` 内部表）。 */
function listTables(db: DatabaseSync): string[] {
  try {
    const rows = db
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';")
      .all() as { name?: unknown }[]
    const tables: string[] = []
    for (const row of rows) {
      if (typeof row.name === 'string') tables.push(row.name)
    }
    return tables
  } catch {
    return []
  }
}

/** 表中承接会话主键的列名（`session_id` / `sessionId` / `Session_Id`），没有则返回 `null`。 */
function sessionIdColumn(db: DatabaseSync, table: string): string | null {
  let rows: { name?: unknown }[]
  try {
    rows = db.prepare(`PRAGMA table_info("${table}");`).all() as { name?: unknown }[]
  } catch {
    return null
  }
  for (const row of rows) {
    if (typeof row.name !== 'string') continue
    // 归一化后与 `sessionid` 逐字比较：`session_id` / `sessionId` / `Session_Id` 都算命中。
    if (row.name.toLowerCase().replace(/_/g, '') === 'sessionid') return row.name
  }
  return null
}

/** 逐表删除匹配行，返回删掉的行数。 */
function deleteSessionRows(
  db: DatabaseSync,
  tables: string[],
  sessionIds: ReadonlySet<string>
): number {
  // 排序只为让 SQL 文本可复现（参数化绑定与顺序无关）。
  const orderedIds = [...sessionIds].sort()
  if (orderedIds.length === 0) return 0
  const placeholders = orderedIds.map(() => '?').join(',')

  let deletedRows = 0
  for (const table of tables) {
    const column = sessionIdColumn(db, table)
    if (column === null) continue
    try {
      const result = db
        .prepare(`DELETE FROM "${table}" WHERE "${column}" IN (${placeholders});`)
        .run(...orderedIds)
      deletedRows += Number(result.changes)
    } catch {
      // 单表删不掉（锁 / 触发器报错）不影响其它表。
    }
  }
  return deletedRows
}

/** 库内所有表都为 0 行时才算「空」。 */
function databaseIsEmpty(db: DatabaseSync, tables: string[]): boolean {
  for (const table of tables) {
    let row: Record<string, unknown> | undefined
    try {
      row = db.prepare(`SELECT COUNT(*) FROM "${table}" LIMIT 1;`).get() as
        | Record<string, unknown>
        | undefined
    } catch {
      continue
    }
    const count = row?.['COUNT(*)']
    if (typeof count === 'number' && count > 0) return false
  }
  return true
}

/** 清理内容引用了被删会话的 `stats-pid-*.json` 进程统计缓存。 */
function purgeContextModeStatsFiles(
  contextModeDir: string,
  sessionIds: ReadonlySet<string>,
  sessionFilePaths: ReadonlySet<string>
): void {
  const candidates = [join(contextModeDir, 'sessions'), join(contextModeDir, 'stats')]

  for (const dir of candidates) {
    for (const entry of listJsonFiles(dir)) {
      if (!basename(entry).startsWith('stats-pid-')) continue
      let text: string
      try {
        text = readFileSync(entry, 'utf8')
      } catch {
        continue
      }
      // 命中判据：内容里出现任一 session_id **或**任一会话文件绝对路径。
      if (containsAny(text, sessionIds) || containsAny(text, sessionFilePaths)) {
        removeIfExists(entry)
      }
    }
  }
}

// MARK: - 小工具

/**
 * 列出目录下的 `.db` 文件。
 *
 * 不用 `listFiles(dir, '.db')`：那个原语把扩展名转成小写再比，
 * 这里刻意**大小写敏感**地比 `extname`。
 */
function listDbFiles(dir: string): string[] {
  return listFiles(dir).filter((path) => extname(path) === '.db')
}

/** 同上，`.json` 大小写敏感匹配。 */
function listJsonFiles(dir: string): string[] {
  return listFiles(dir).filter((path) => extname(path) === '.json')
}

function containsAny(text: string, needles: ReadonlySet<string>): boolean {
  for (const needle of needles) {
    if (text.includes(needle)) return true
  }
  return false
}

function canonicalPath(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

function closeQuietly(db: DatabaseSync): void {
  try {
    db.close()
  } catch {
    /* ignore */
  }
}
