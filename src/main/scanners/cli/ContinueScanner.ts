import { mkdirSync, readdirSync, realpathSync } from 'node:fs'
import type { Dirent } from 'node:fs'
import { extname, join, resolve } from 'node:path'
import type { ConversationItem } from '@shared/types'
import type { AgentScanner, ScannerOptions } from '@main/core/scanner'
import {
  deleteItemsWithPaths,
  isDirectory,
  makeItem,
  mapLimit,
  mtimeMs,
  pathExists,
  readJson,
  removeIfExists,
  resolveStoragePath,
  sizeOfPath,
  sortByUpdatedDesc
} from '@main/core/scanner'
import { cleanEmptyDirectories } from '@main/core/fsutil'
import { parseIsoDate } from '@main/core/datetime'

/**
 * Continue.dev（`~/.continue`）会话扫描器。
 *
 * 移植自 `ConversationClean/Scanners/CLIAgents/ContinueScanner.swift`，逐条对齐：
 *   · `storageURL`：`storagePath` > `CONTINUE_HOME` > `~/.continue`，再做一次 realpath 规范化
 *   · `scan()`：递归列 `sessions/` 下所有 `.json`（跳隐藏项），从 `history` 里
 *     第一条 `role == "user"`（或没有 role）的消息决定标题与摘要
 *   · `delete()`：删会话文件 + 同名目录，然后回收 `sessions/` 下的空目录
 *   · `cleanAll()`：scan + delete，再把 `index/` 与 `cache/` 整个清空（并重建空目录）
 *
 * 与 Swift 版本的已知偏差（都在下面逐处标注）：
 *   1. 递归枚举加了 12 层深度上限（Swift 的 `FileManager.enumerator` 没有上限）。
 *   2. `prefix(n)` 按 UTF-16 码元切，Swift 按字素簇切 —— 超长非 ASCII 摘要末尾可能多/少半个字。
 */

type Dict = Record<string, unknown>

/** Swift `String.components(separatedBy: .newlines)` 对应的字符集。 */
const NEWLINES = /[\n\r\u000b\u000c\u0085\u2028\u2029]/

/** Swift 自定义 `DateFormatter` 的两种格式：`yyyy-MM-dd'T'HH:mm:ss.SSSZ` / `yyyy-MM-dd HH:mm:ss`。 */
const CUSTOM_DATE = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$/

/** Swift `Double(_:)` 认得的数字串。`Double("")` / `Double(" 1 ")` 是 nil，不能拿 `Number()` 顶。 */
const NUMERIC = /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/

export class ContinueScanner implements AgentScanner {
  readonly category = 'continueDev' as const
  private readonly root: string

  constructor(options: ScannerOptions = {}) {
    // Swift: `customStorageURL ?? CONTINUE_HOME ?? ~/.continue`，随后 `canonicalPath ?? standardized`。
    this.root = options.storagePath
      ? canonical(options.storagePath)
      : resolveStoragePath(['.continue'], { key: 'CONTINUE_HOME' })
  }

  get storagePath(): string {
    return this.root
  }

  get isInstalled(): boolean {
    return pathExists(this.root)
  }

  // MARK: - Scan

  async scan(): Promise<ConversationItem[]> {
    if (!this.isInstalled) return []

    const sessionsDir = join(this.root, 'sessions')
    if (!pathExists(sessionsDir)) return []

    const sessionFiles = findSessionFiles(sessionsDir)
    if (sessionFiles.length === 0) return []

    // Swift 是 `withTaskGroup` 全并发；这里用有界并发，语义一致（末尾还要按 updatedAt 倒序排）。
    const parsed = await mapLimit(sessionFiles, 16, (file) => this.parseSessionFile(file))
    return sortByUpdatedDesc(parsed.filter((item): item is ConversationItem => item !== null))
  }

  // MARK: - Delete & Clean

  async delete(items: ConversationItem[]): Promise<number> {
    if (items.length === 0) return 0
    const freed = await deleteItemsWithPaths(items)
    cleanEmptyDirectories(join(this.root, 'sessions'))
    return freed
  }

  async cleanAll(): Promise<number> {
    let freed = await this.delete(await this.scan())

    // 清空 `index/` 与 `cache/`，清完把空目录重建回去（Continue 会立刻重新生成它们，
    // 留着目录比留着内容更重要）。
    for (const name of ['index', 'cache']) {
      const dir = join(this.root, name)
      if (!pathExists(dir)) continue
      const size = sizeOfPath(dir)
      if (!removeIfExists(dir)) continue
      freed += size
      try {
        mkdirSync(dir, { recursive: true })
      } catch {
        // Swift 是 `try?`：重建失败不改变本次清理结果
      }
    }
    return freed
  }

  // MARK: - Parsing Session File

  private parseSessionFile(filePath: string): ConversationItem | null {
    const dict = readJson<Dict>(filePath)
    if (!isDict(dict)) return null

    const stem = deletingPathExtension(filePath)
    const sessionId = asString(dict['sessionId']) ?? basename(stem)
    const rawTitle = asString(dict['title'])
    const workspaceDir =
      asString(dict['workspaceDirectory']) ?? asString(dict['workspace']) ?? asString(dict['cwd'])

    const history = Array.isArray(dict['history']) ? (dict['history'] as unknown[]) : []

    let messageCount = asInt(dict['messageCount']) ?? history.length
    if (messageCount === 0 && history.length > 0) messageCount = history.length

    // 提取第一条 user（或没有 role 的）消息：既是标题兜底，也是摘要
    let extractedPrompt: string | null = null
    let snippet = ''
    for (const entry of history) {
      if (!isDict(entry)) continue
      const msgObj = isDict(entry['message']) ? entry['message'] : entry
      const role = asString(msgObj['role'])
      const raw = contentText(msgObj)
      if (raw === null) continue
      const content = raw.trim()
      if (content.length === 0) continue
      if (role === 'user' || role === null) {
        if (extractedPrompt === null) extractedPrompt = content
        if (snippet.length === 0) snippet = content.slice(0, 200)
        break
      }
    }

    let finalTitle: string
    if (rawTitle !== null && rawTitle.trim().length > 0) {
      const titleLine = firstLine(rawTitle.trim())
      finalTitle = titleLine.length > 0 ? titleLine : (extractedPrompt ?? sessionId)
    } else {
      finalTitle = firstLineOfTitle(extractedPrompt, sessionId)
    }
    if (snippet.length === 0) snippet = finalTitle

    const updatedAt = resolveUpdatedDate(dict['dateCreated'], mtimeMs(filePath))

    // 会话文件 + 同名目录（`foo.json` 旁可能有 `foo/` 存附件）
    const associatedPaths: string[] = [filePath]
    if (isDirectory(stem)) associatedPaths.push(stem)

    let sizeInBytes = 0
    for (const path of associatedPaths) sizeInBytes += sizeOfPath(path)

    return makeItem({
      sessionId,
      title: finalTitle,
      category: this.category,
      projectPath: workspaceDir,
      gitBranch: null,
      messageCount,
      sizeInBytes,
      updatedAt,
      snippet,
      associatedPaths
    })
  }
}

// MARK: - 文件发现

/** 递归列出目录下所有 `.json` 文件，跳过隐藏项。 */
function findSessionFiles(directory: string): string[] {
  const result: string[] = []
  const walk = (dir: string, depth: number): void => {
    // Swift 的 `FileManager.enumerator` 没有深度上限；这里加一道防御（与 `fsutil` 同一口径）。
    if (depth > 12) return
    for (const entry of listDirents(dir)) {
      if (entry.name.startsWith('.')) continue
      const child = join(dir, entry.name)
      if (entry.isDirectory()) walk(child, depth + 1)
      else if (extname(entry.name).toLowerCase() === '.json') result.push(child)
    }
  }
  walk(directory, 0)
  return result
}

function listDirents(path: string): Dirent[] {
  try {
    return readdirSync(path, { withFileTypes: true })
  } catch {
    return []
  }
}

// MARK: - 解析辅助

function canonical(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return resolve(path)
  }
}

function isDict(value: unknown): value is Dict {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function asString(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

/** `as? Int`：Swift 只有在 JSON 数字是整数时才转换成功。 */
function asInt(value: unknown): number | null {
  return typeof value === 'number' && Number.isInteger(value) ? value : null
}

function basename(path: string): string {
  const index = path.lastIndexOf('/')
  return index < 0 ? path : path.slice(index + 1)
}

/** `message.content` 可能是字符串，也可能是 `[{text}, …]`（多段内容用空格连接）。 */
function contentText(msgObj: Dict): string | null {
  const content = msgObj['content']
  if (typeof content === 'string') return content
  if (Array.isArray(content)) {
    const parts: string[] = []
    for (const part of content) {
      if (!isDict(part)) continue
      const text = part['text']
      if (typeof text === 'string') parts.push(text)
    }
    return parts.join(' ')
  }
  return null
}

function firstLine(text: string): string {
  const [first = ''] = text.split(NEWLINES)
  return first.trim()
}

/** 标题兜底：prompt 的第一行；还是空就回落到 sessionId。 */
function firstLineOfTitle(prompt: string | null, sessionId: string): string {
  if (prompt === null || prompt.length === 0) return sessionId
  const first = firstLine(prompt)
  return first.length > 0 ? first : sessionId
}

/**
 * `dateCreated` 的四路兜底，与 Swift 逐条对应：
 *   1. ISO 字符串 → `parseISO8601Date`（标准 ISO + 两种自定义格式）
 *   2. 数字字符串 → `> 1e12` 视作毫秒，否则视作秒。**没有** `> 0` 判断，
 *      所以 `"0"` 会得到 1970-01-01（Swift 的已知行为，照抄）
 *   3. 数字 → `> 1e12` 毫秒 / `> 0` 秒 / 否则文件 mtime
 *   4. 其余一切（缺失、对象、数组）→ 文件 mtime，再不济 `new Date()`
 */
function resolveUpdatedDate(raw: unknown, mtime: number | undefined): Date {
  const fallback = (): Date => (mtime !== undefined ? new Date(mtime) : new Date())
  if (raw === undefined || raw === null) return fallback()

  if (typeof raw === 'string') {
    const parsed = parseContinueDate(raw)
    if (parsed !== null) return parsed
    if (NUMERIC.test(raw)) {
      const value = Number(raw)
      // 大于是毫秒原值，小于是秒（×1000 换成 JS 的毫秒制）
      return new Date(value > 1_000_000_000_000 ? value : value * 1000)
    }
    return fallback()
  }

  if (typeof raw === 'number') {
    if (raw > 1_000_000_000_000) return new Date(raw)
    if (raw > 0) return new Date(raw * 1000)
    return fallback()
  }

  return fallback()
}

/** `ISODate.parse` 之外的两条自定义格式，JS 的 `Date` 构造器恰好都能吃下。 */
function parseContinueDate(value: string): Date | null {
  if (value.length === 0) return null
  const iso = parseIsoDate(value)
  if (iso !== null) return iso
  if (!CUSTOM_DATE.test(value)) return null
  const parsed = new Date(value.replace(' ', 'T'))
  return Number.isNaN(parsed.getTime()) ? null : parsed
}

function deletingPathExtension(path: string): string {
  const ext = extname(path)
  return ext.length > 0 ? path.slice(0, path.length - ext.length) : path
}
