import {
  closeSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  realpathSync,
  renameSync,
  writeFileSync,
  type Dirent
} from 'node:fs'
import { cpus, homedir } from 'node:os'
import { basename, extname, join } from 'node:path'
import type { ConversationItem } from '@shared/types'
import type { AgentScanner, ScannerOptions } from '@main/core/scanner'
import {
  deleteItemsWithPaths,
  fileSize,
  makeItem,
  mapLimit,
  mtimeMs,
  pathExists,
  removeIfExists,
  sizeOfPath,
  sortByUpdatedDesc,
  truncate
} from '@main/core/scanner'
import { cleanEmptyDirectories } from '@main/core/fsutil'

/**
 * Codex 扫描器。
 *
 * 源文件：`ConversationClean/Scanners/CLIAgents/CodexScanner.swift`。
 *
 * Codex 的数据布局（默认 `~/.codex`，`CODEX_HOME` 可覆盖）：
 * ```
 * ~/.codex/
 *   session_index.jsonl      # 会话索引：id / filename / title / cwd / updated_at
 *   sessions/YYYY/MM/DD/<id>.jsonl
 *   archived_sessions/YYYY/MM/DD/<id>.jsonl
 *   history.jsonl            # 命令历史（cleanAll 补删）
 *   cache/  tmp/             # 缓存（cleanAll 补删）
 *   .codex-global-state.json # 全局状态：活跃会话 / 最近会话（删除时同步）
 * ```
 * 会话正文 `.jsonl` 本身就是**唯一**的会话本体，没有快照目录，
 * 所以 `cleanFileHistorySnapshots` 开关对 Codex 不产生任何影响（照抄 Swift 版行为）。
 */

/** Swift `withTaskGroup` 的默认并发度（CPU 核心数）。 */
const PARSE_CONCURRENCY = Math.max(1, cpus().length)

/** 只读会话文件前 64KB —— 与 Swift `FileHandle.readData(ofLength: 64 * 1024)` 一致。 */
const HEADER_BYTE_LIMIT = 64 * 1024

/**
 * 头部最多解析多少行。
 * Swift 版是 `if lineCount > 40 { stop = true }`：**第 41 行解析完就停**，
 * 所以 `messageCount` 的上界是 41，标题 / cwd 也只看前 41 行。
 */
const MAX_HEADER_LINES = 41

/** 目录递归深度上限，防止异常深的目录树把扫描拖死。 */
const MAX_WALK_DEPTH = 12

interface CodexIndexInfo {
  id: string
  title: string | null
  cwd: string | null
  updatedAt: Date | null
}

interface CodexTarget {
  file: string
  indexInfo: CodexIndexInfo | null
}

export class CodexScanner implements AgentScanner {
  readonly category = 'codex' as const

  private readonly customStoragePath: string | undefined

  constructor(options: ScannerOptions = {}) {
    this.customStoragePath = options.storagePath
  }

  /**
   * `CODEX_HOME` → `~/.codex`，并做一次 realpath 规范化。
   * 与 Swift 版的 `canonicalPathKey` 一致：`/var` → `/private/var` 这类别名不解析，
   * 侧栏显示的路径会跟用户在 Finder 里点开的不一致。
   */
  get storagePath(): string {
    if (this.customStoragePath !== undefined) return canonicalPath(this.customStoragePath)
    const env = process.env.CODEX_HOME
    if (env !== undefined && env.length > 0) return canonicalPath(env)
    return canonicalPath(join(homedir(), '.codex'))
  }

  /** Swift: `FileManager.default.fileExists(atPath: storageURL.path)`。存在**文件**也算装过。 */
  get isInstalled(): boolean {
    return pathExists(this.storagePath)
  }

  async scan(): Promise<ConversationItem[]> {
    if (!this.isInstalled) return []
    const root = this.storagePath

    const indexMap = this.loadSessionIndex(root)
    const targets: CodexTarget[] = []

    for (const name of ['sessions', 'archived_sessions']) {
      const sessionDir = join(root, name)
      if (!pathExists(sessionDir)) continue
      for (const file of collectJsonlFiles(sessionDir)) {
        // 先按「带扩展名的文件名」查，再按「去掉扩展名的文件名」查。
        const info = indexMap.get(basename(file)) ?? indexMap.get(basename(file, extname(file)))
        targets.push({ file, indexInfo: info ?? null })
      }
    }

    if (targets.length === 0) return []

    // Swift 用 `withTaskGroup` 并发解析；这里用有界并发的 `mapLimit`，
    // 上限取 CPU 核心数（`withTaskGroup` 的默认并发度），语义一致。
    const items = await mapLimit(targets, PARSE_CONCURRENCY, (target) =>
      this.parseCodexSession(target)
    )
    return sortByUpdatedDesc(items)
  }

  async delete(items: ConversationItem[]): Promise<number> {
    const root = this.storagePath
    return deleteItemsWithPaths(items, (deletedSessionIds) => {
      // 会话文件删完后同步两处索引，否则 Codex 侧会留下一堆查不到的幽灵会话。
      this.cleanSessionIndex(root, deletedSessionIds)
      this.cleanGlobalState(root, deletedSessionIds)
      // 回收 `sessions/YYYY/MM/DD` 这类空日期目录（受 `cleanEmptyProjectFolders` 开关约束）。
      cleanEmptyDirectories(join(root, 'sessions'))
      cleanEmptyDirectories(join(root, 'archived_sessions'))
    })
  }

  async cleanAll(): Promise<number> {
    const root = this.storagePath
    const items = await this.scan()
    let freed = await this.delete(items)

    // 会话正文之外的三块：命令历史、缓存、临时文件。
    for (const name of ['history.jsonl', 'cache', 'tmp']) {
      const path = join(root, name)
      const size = sizeOfPath(path)
      if (removeIfExists(path)) freed += size
    }

    // Swift 版在 delete() 之后又调了一次；幂等（没有可改的内容就不落盘），照抄。
    this.cleanGlobalState(root, new Set(items.map((item) => item.sessionId)))
    return freed
  }

  // MARK: - 索引

  /**
   * 读 `session_index.jsonl`，建「文件名 / id / 去扩展名的文件名」→ 索引条目的映射。
   *
   * 索引里的 `filename` 可能是 `2026/09/26/<id>.jsonl` 这种带日期目录的相对路径，
   * 所以三个键都要登记，实际命中靠的还是 `id`。
   */
  private loadSessionIndex(root: string): Map<string, CodexIndexInfo> {
    const map = new Map<string, CodexIndexInfo>()
    const indexPath = join(root, 'session_index.jsonl')
    if (!pathExists(indexPath)) return map

    let content: string
    try {
      content = readFileSync(indexPath, 'utf8')
    } catch {
      return map
    }

    for (const line of enumerateLines(content)) {
      const json = parseJsonRecord(line)
      if (json === null) continue
      const id = firstString(json.id, json.sessionId, json.session_id)
      if (id === undefined) continue

      let updatedAt: Date | null = null
      const ts = firstNumber(json.updated_at, json.timestamp)
      if (ts !== undefined) {
        // Swift: `ts > 1_000_000_000_000 ? ts / 1000.0 : ts`（毫秒 / 秒混写都见过）
        updatedAt = new Date(ts > 1_000_000_000_000 ? ts : ts * 1000)
      }

      const filename = typeof json.filename === 'string' ? json.filename : `${id}.jsonl`
      const info: CodexIndexInfo = {
        id,
        title: typeof json.title === 'string' ? json.title : null,
        cwd: firstString(json.cwd, json.project) ?? null,
        updatedAt
      }
      map.set(filename, info)
      map.set(id, info)
      if (filename.endsWith('.jsonl')) {
        map.set(filename.slice(0, -'.jsonl'.length), info)
      }
    }
    return map
  }

  /** 裁剪 `session_index.jsonl`：删掉这些会话的索引行，其余原样保留。 */
  private cleanSessionIndex(root: string, excludingSessionIds: Set<string>): void {
    const indexPath = join(root, 'session_index.jsonl')
    if (!pathExists(indexPath)) return

    let content: string
    try {
      content = readFileSync(indexPath, 'utf8')
    } catch {
      return
    }

    const retained: string[] = []
    for (const line of enumerateLines(content)) {
      const json = parseJsonRecord(line)
      const sid = json === null ? undefined : firstString(json.id, json.sessionId, json.session_id)
      // 认不出 id 的行**保留**：宁可索引多一行，也不能把别的会话抹掉。
      if (json === null || sid === undefined) {
        retained.push(line)
        continue
      }
      // 索引行的 `filename` 带 `.jsonl`，而删除集合里是 sessionId，所以要去掉扩展名再比一次。
      const filenameWithoutExt =
        typeof json.filename === 'string' ? json.filename.split('.jsonl').join('') : ''
      if (!excludingSessionIds.has(sid) && !excludingSessionIds.has(filenameWithoutExt)) {
        retained.push(line)
      }
    }

    writeTextAtomic(indexPath, retained.length === 0 ? '' : `${retained.join('\n')}\n`)
  }

  /**
   * 裁剪全局状态文件里的会话痕迹。
   *
   * 候选路径有两个：数据根目录下的 `.codex-global-state.json` 与 `~/.codex-global-state.json`
   * （同一个文件时只处理一次）。三类痕迹：
   * 1. 活跃会话指针（`activeSessionId` 等）→ 置 `null`
   * 2. 最近会话 / 会话数组 / 线程列表 / 历史 → 剔除被删的 id
   * 3. 顶层以 sessionId 为键的条目 → 直接删键
   */
  private cleanGlobalState(root: string, excludingSessionIds: Set<string>): void {
    if (excludingSessionIds.size === 0) return

    const candidates = [
      join(root, '.codex-global-state.json'),
      join(homedir(), '.codex-global-state.json')
    ]

    const processed = new Set<string>()
    for (const statePath of candidates) {
      if (processed.has(statePath) || !pathExists(statePath)) continue
      processed.add(statePath)

      let content: string
      try {
        content = readFileSync(statePath, 'utf8')
      } catch {
        continue
      }
      let parsed: unknown
      try {
        parsed = JSON.parse(content)
      } catch {
        continue
      }
      const json = isRecord(parsed) ? parsed : null
      if (json === null) continue

      let modified = false

      // 1. 活跃会话指针
      for (const key of ['activeSessionId', 'active_session_id', 'currentSessionId', 'active_thread_id']) {
        const current = json[key]
        if (typeof current === 'string' && excludingSessionIds.has(current)) {
          json[key] = null // Swift 写的是 NSNull，落盘即 JSON null
          modified = true
        }
      }

      // 2. 会话数组 / 字典
      for (const key of ['recentSessions', 'recent_sessions', 'sessions', 'threads', 'history', 'sessionIds']) {
        const value = json[key]
        if (Array.isArray(value)) {
          const filtered = value.filter((item) => {
            if (typeof item === 'string') return !excludingSessionIds.has(item)
            if (isRecord(item)) {
              const sid = firstString(item.id, item.sessionId, item.session_id, item.thread_id) ?? ''
              if (sid.length > 0 && excludingSessionIds.has(sid)) return false
            }
            return true
          })
          if (filtered.length !== value.length) {
            json[key] = filtered
            modified = true
          }
        } else if (isRecord(value)) {
          const next: Record<string, unknown> = {}
          let dictModified = false
          for (const [entryKey, entryValue] of Object.entries(value)) {
            if (excludingSessionIds.has(entryKey)) {
              dictModified = true
              continue
            }
            if (isRecord(entryValue)) {
              const sid = firstString(entryValue.id, entryValue.sessionId, entryValue.session_id) ?? ''
              if (sid.length > 0 && excludingSessionIds.has(sid)) {
                dictModified = true
                continue
              }
            }
            next[entryKey] = entryValue
          }
          if (dictModified) {
            json[key] = next
            modified = true
          }
        }
      }

      // 3. 顶层以 sessionId 为键的条目
      for (const sid of excludingSessionIds) {
        if (json[sid] !== undefined) {
          delete json[sid]
          modified = true
        }
      }

      if (modified) {
        // Swift: `JSONSerialization(.prettyPrinted, .sortedKeys)` —— 键排序后落盘，diff 友好。
        writeTextAtomic(statePath, stringifySortedJson(json))
      }
    }
  }

  // MARK: - 解析

  /**
   * 解析一个会话文件。
   *
   * 标题兜底顺序（Swift 原样）：索引 title → 头部里的首条用户 prompt → `Codex 会话 <id 前 8 位>`。
   * 项目路径兜底顺序：索引 cwd → 头部任意一行的 `cwd` / `project` / `working_directory`。
   * 时间：索引 `updated_at` / `timestamp` → 文件 mtime。
   */
  private parseCodexSession(target: CodexTarget): ConversationItem {
    const { file, indexInfo } = target
    const fileName = basename(file)
    const defaultId = basename(file, extname(file))
    const sessionId = indexInfo?.id ?? defaultId

    // Swift: `attributesOfItem(.size)`，取不到才回落到递归 sizeOf。
    const size = fileSize(file) || sizeOfPath(file)
    const mtime = mtimeMs(file)
    const updatedAt = indexInfo?.updatedAt ?? (mtime !== undefined ? new Date(mtime) : new Date())

    let detectedTitle: string | undefined = indexInfo?.title ?? undefined
    let detectedCwd: string | undefined = indexInfo?.cwd ?? undefined
    let firstPrompt: string | undefined

    const headerLines = readHeadLines(file)
    for (const line of headerLines) {
      const json = parseJsonRecord(line)
      if (json === null) continue

      if (detectedCwd === undefined) {
        const cwd = firstString(json.cwd, json.project, json.working_directory)
        if (cwd !== undefined) detectedCwd = cwd
      }

      if (firstPrompt === undefined) {
        if (json.role === 'user' && typeof json.content === 'string') {
          firstPrompt = json.content.trim()
        } else {
          const prompt = firstString(json.prompt, json.display)
          if (prompt !== undefined) {
            firstPrompt = prompt.trim()
          } else if (Array.isArray(json.messages) && json.messages.every(isRecord)) {
            for (const message of json.messages) {
              if (message.role === 'user' && typeof message.content === 'string') {
                firstPrompt = message.content.trim()
                break
              }
            }
          }
        }
      }
    }
    // Swift 的 lineCount 统计的是**读到多少行**（含解析失败的行），不是解析成功多少行。
    const messageCount = headerLines.length

    let title: string
    if (detectedTitle !== undefined && detectedTitle.length > 0) {
      title = detectedTitle
    } else if (firstPrompt !== undefined && firstPrompt.length > 0) {
      title = truncate(firstPrompt, 80).replaceAll('\n', ' ')
    } else {
      title = `Codex 会话 ${sessionId.slice(0, 8)}`
    }

    let snippet: string
    if (firstPrompt !== undefined && firstPrompt.length > 0) {
      snippet = truncate(firstPrompt, 120).replaceAll('\n', ' ')
    } else if (detectedCwd !== undefined) {
      snippet = `项目: ${detectedCwd}`
    } else {
      snippet = fileName
    }

    return makeItem({
      sessionId,
      title,
      category: this.category,
      projectPath: detectedCwd ?? null,
      gitBranch: null,
      messageCount: Math.max(1, messageCount),
      sizeInBytes: size,
      updatedAt,
      snippet,
      associatedPaths: [file]
    })
  }
}

// MARK: - 模块内工具

type JsonRecord = Record<string, unknown>

/** Swift 的 `canonicalPathKey`：`/var` → `/private/var`；解析失败就原样返回。 */
function canonicalPath(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** 单行 JSON 解析：认不出就返回 `null`（半行写入是常态，不能让整个分类消失）。 */
function parseJsonRecord(line: string): JsonRecord | null {
  try {
    const parsed: unknown = JSON.parse(line)
    return isRecord(parsed) ? parsed : null
  } catch {
    return null
  }
}

function firstString(...values: unknown[]): string | undefined {
  for (const value of values) {
    if (typeof value === 'string') return value
  }
  return undefined
}

function firstNumber(...values: unknown[]): number | undefined {
  for (const value of values) {
    if (typeof value === 'number') return value
  }
  return undefined
}

/**
 * Swift `String.enumerateLines` 的等价物：按 `\r\n` / `\r` / `\n` 切分，
 * 且**不以换行结尾时不会再产出一个空行**。空串 → 空数组。
 */
function enumerateLines(content: string): string[] {
  if (content.length === 0) return []
  const lines = content.split(/\r\n|\r|\n/)
  if (lines[lines.length - 1] === '') lines.pop()
  return lines
}

/**
 * 读会话文件前 64KB 并切出前 41 行。
 * 标题 / cwd 都在头几行，读全量是纯浪费；末行可能被截断，交给 `parseJsonRecord` 丢弃。
 */
function readHeadLines(path: string): string[] {
  return enumerateLines(readHeadBytes(path, HEADER_BYTE_LIMIT)).slice(0, MAX_HEADER_LINES)
}

function readHeadBytes(path: string, byteLimit: number): string {
  let fd: number | undefined
  try {
    fd = openSync(path, 'r')
    const buffer = Buffer.alloc(byteLimit)
    const bytesRead = readSync(fd, buffer, 0, byteLimit, 0)
    return buffer.subarray(0, bytesRead).toString('utf8')
  } catch {
    return ''
  } finally {
    if (fd !== undefined) {
      try {
        closeSync(fd)
      } catch {
        /* ignore */
      }
    }
  }
}

/** 递归收集 `root` 下的 `.jsonl` 文件，跳过隐藏项（对应 Swift 的 `.skipsHiddenFiles`）。 */
function collectJsonlFiles(root: string): string[] {
  const out: string[] = []
  const walk = (dir: string, depth: number): void => {
    if (depth > MAX_WALK_DEPTH) return
    let entries: Dirent[]
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      if (entry.name.startsWith('.')) continue
      const child = join(dir, entry.name)
      if (entry.isDirectory()) {
        walk(child, depth + 1)
      } else if (extname(entry.name) === '.jsonl') {
        // Swift 的守卫只判 `pathExtension == "jsonl"`，软链也是这么算进来的。
        out.push(child)
      }
    }
  }
  walk(root, 0)
  return out
}

/** Swift `Data.write(to:options:.atomic)`：先写临时文件再 rename。 */
function writeTextAtomic(path: string, content: string): void {
  const tmp = `${path}.tmp`
  try {
    writeFileSync(tmp, content, 'utf8')
    renameSync(tmp, path)
  } catch {
    try {
      writeFileSync(path, content, 'utf8')
    } catch (error) {
      console.error(`[codex] 写入失败 ${path}:`, error)
    }
  }
}

/** `JSONSerialization.data(options: [.prettyPrinted, .sortedKeys])` 的等价物。 */
function stringifySortedJson(value: JsonRecord): string {
  return JSON.stringify(
    value,
    (_key, inner: unknown) =>
      isRecord(inner)
        ? Object.fromEntries(
            Object.entries(inner).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
          )
        : inner,
    2
  )
}
