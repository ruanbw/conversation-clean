import { mkdirSync, readFileSync, readdirSync, realpathSync, renameSync, writeFileSync } from 'node:fs'
import { basename, dirname, extname, join } from 'node:path'
import type { ConversationItem } from '@shared/types'
import type { AgentScanner, ScannerOptions } from '@main/core/scanner'
import {
  CleanPrefs,
  deleteItemsWithPaths,
  dirName,
  isDirectory,
  listDirectories,
  listFiles,
  makeItem,
  mapLimit,
  mtimeMs,
  pathExists,
  readJsonLinesHead,
  removeIfExists,
  resolveStoragePath,
  sizeOfPath,
  sortByUpdatedDesc,
  truncate
} from '@main/core/scanner'

/**
 * Claude Code 会话扫描器。
 *
 * 移植自 `ConversationClean/Scanners/CLIAgents/ClaudeCodeScanner.swift`。
 *
 * Claude Code 是 15 款 Agent 里目录结构最复杂的一个：会话正文在
 * `projects/<mangled-cwd>/<sessionId>.jsonl`，另外还有三类**旁挂**产物
 * （`file-history/` 改动快照、`plans/` 计划、`session-env/` 环境快照），
 * 一条会话的占盘体积要把它们全算进去。删会话时 `history.jsonl` 与
 * `sessions-index.json` 也必须同步裁剪，否则 Agent 侧会留下查不到的幽灵会话。
 */

/** 预索引的旁挂目录名，顺序即 `associatedPaths` 里的追加顺序。 */
const ASSOCIATED_DIR_NAMES = ['file-history', 'plans', 'session-env'] as const

/** 一键清空时额外处理的目录：`cache` 不是快照，`backups` / `shell-snapshots` 是。 */
const CLEAN_ALL_EXTRA_DIRS = ['cache', 'backups', 'shell-snapshots'] as const

/**
 * 会话头最多解析多少行。
 *
 * Swift 版在 `enumerateLines` 里 `lineIdx > 50` 时 `stop` —— 计数器在自增之后比较，
 * 所以实际处理第 1~51 行。这里对齐为 51。
 */
const HEADER_LINE_LIMIT = 51

/** JSONL 头解析上限，与 Swift 的 `FileHandle.readData(ofLength: 64 * 1024)` 一致。 */
const HEADER_BYTE_LIMIT = 64 * 1024

/** 一个待解析的会话文件。 */
interface SessionTarget {
  filePath: string
  sessionId: string
  projectDir: string
}

/** `history.jsonl` 里某个 sessionId 的汇总。 */
interface HistoryRecord {
  displays: string[]
  project: string | null
  timestamp: Date | null
}

/** 预索引结果：路径与体积都提前算好，避免每条会话再去探盘。 */
interface AssociatedArtifacts {
  pathsBySessionId: Map<string, string[]>
  sizeBySessionId: Map<string, number>
}

/** 会话 JSONL 头里我们关心的字段。 */
interface SessionHeaderEntry {
  type?: unknown
  cwd?: unknown
  gitBranch?: unknown
  slug?: unknown
  message?: unknown
}

export class ClaudeCodeScanner implements AgentScanner {
  readonly category = 'claudeCode' as const

  private readonly root: string

  constructor(options: ScannerOptions = {}) {
    // Swift 版三条来源（自定义 URL / `CLAUDE_HOME` / `~/.claude`）之后统一做一次
    // realpath；`resolveStoragePath` 负责后两条，自定义路径在这里补上同一层规范化。
    this.root =
      options.storagePath !== undefined
        ? canonical(options.storagePath)
        : resolveStoragePath(['.claude'], { key: 'CLAUDE_HOME' })
  }

  get storagePath(): string {
    return this.root
  }

  /** Swift 版是 `fileExists`（不分文件 / 目录），这里同样用 `pathExists`。 */
  get isInstalled(): boolean {
    return pathExists(this.root)
  }

  async scan(): Promise<ConversationItem[]> {
    if (!this.isInstalled) return []

    const targets = this.collectTargets()
    if (targets.length === 0) return []

    const historyMap = this.loadHistory()
    const artifacts = this.preIndexAssociatedDirectories()

    const items = await mapLimit(targets, 16, (target) =>
      this.parseSession(target, historyMap.get(target.sessionId), artifacts)
    )

    return sortByUpdatedDesc(items)
  }

  async delete(items: ConversationItem[]): Promise<number> {
    if (items.length === 0) return 0
    return deleteItemsWithPaths(items, (deletedSessionIds) => {
      this.cleanHistory(deletedSessionIds)
      this.cleanSessionsIndex(deletedSessionIds)
      this.cleanEmptyProjectDirectories()
    })
  }

  async cleanAll(): Promise<number> {
    const items = await this.scan()
    let freed = await this.delete(items)

    // backups / shell-snapshots 是「一键清空」路径上唯二属于文件快照的目录，
    // 开关关掉时保留；cache 不是快照，照旧清。
    for (const name of CLEAN_ALL_EXTRA_DIRS) {
      const path = join(this.root, name)
      if (!CleanPrefs.cleanFileHistorySnapshots && CleanPrefs.isSnapshotPath(path)) continue
      const size = sizeOfPath(path)
      if (removeIfExists(path)) {
        freed += size
        mkdirSync(path, { recursive: true })
      }
    }

    this.removeAllSessionsIndices()
    return freed
  }

  // MARK: - 目标枚举

  /**
   * 枚举 `projects` 下各 project 目录里的 `.jsonl` 与 `sessions` 下的 `.jsonl`，
   * 按 sessionId 去重。
   *
   * 同一 sessionId 只会保留先遇到的那一个；Swift 用 `Set` 在收集阶段就去重，
   * 这里保持一致（先收集再去重，不要等解析阶段再过滤）。
   */
  private collectTargets(): SessionTarget[] {
    const targets: SessionTarget[] = []
    const seen = new Set<string>()

    const projectsDir = join(this.root, 'projects')
    if (isDirectory(projectsDir)) {
      for (const projectName of listDirectories(projectsDir)) {
        const projectDir = join(projectsDir, projectName)
        for (const filePath of listFiles(projectDir, '.jsonl')) {
          const sessionId = stripExtension(basename(filePath))
          if (sessionId.length === 0 || seen.has(sessionId)) continue
          seen.add(sessionId)
          targets.push({ filePath, sessionId, projectDir })
        }
      }
    }

    // 也看一眼 `~/.claude/sessions/`，那里的会话没有 project 目录。
    const directSessionsDir = join(this.root, 'sessions')
    if (isDirectory(directSessionsDir)) {
      for (const filePath of listFiles(directSessionsDir, '.jsonl')) {
        const sessionId = stripExtension(basename(filePath))
        if (sessionId.length === 0 || seen.has(sessionId)) continue
        seen.add(sessionId)
        targets.push({ filePath, sessionId, projectDir: directSessionsDir })
      }
    }

    return targets
  }

  // MARK: - 预索引 & 解析

  /**
   * 预先算好 `file-history` / `plans` / `session-env` 三个目录下的条目。
   *
   * Swift 版在每条会话里现调 `sizeOf`，N 条会话就把同一批目录递归 stat N 遍；
   * 这里提前按 sessionId 聚合一次，解析时只查 Map。
   */
  private preIndexAssociatedDirectories(): AssociatedArtifacts {
    const pathsBySessionId = new Map<string, string[]>()
    const sizeBySessionId = new Map<string, number>()

    for (const dirName of ASSOCIATED_DIR_NAMES) {
      const targetDir = join(this.root, dirName)
      if (!isDirectory(targetDir)) continue
      // Swift 版是 `contentsOfDirectory` 不过滤文件 / 目录，只跳隐藏项。
      for (const name of listEntryNames(targetDir)) {
        if (name.length === 0) continue
        const path = join(targetDir, name)
        const size = sizeOfPath(path)
        const bucket = pathsBySessionId.get(name)
        if (bucket) bucket.push(path)
        else pathsBySessionId.set(name, [path])
        sizeBySessionId.set(name, (sizeBySessionId.get(name) ?? 0) + size)
      }
    }

    return { pathsBySessionId, sizeBySessionId }
  }

  /** 读 `history.jsonl`，按 sessionId 汇总 prompt 列表 / project / 最后时间戳。 */
  private loadHistory(): Map<string, HistoryRecord> {
    const map = new Map<string, HistoryRecord>()
    const historyPath = join(this.root, 'history.jsonl')
    let content: string
    try {
      content = readFileSync(historyPath, 'utf8')
    } catch {
      return map
    }

    for (const line of enumerateLines(content)) {
      let json: unknown
      try {
        json = JSON.parse(line)
      } catch {
        continue
      }
      if (!isPlainObject(json)) continue
      const sessionId = json.sessionId
      if (typeof sessionId !== 'string') continue

      const display = typeof json.display === 'string' ? json.display : ''
      const project = typeof json.project === 'string' ? json.project : null
      const rawTimestamp = json.timestamp
      const timestamp =
        typeof rawTimestamp === 'number' && Number.isFinite(rawTimestamp)
          ? new Date(rawTimestamp)
          : null

      const existing = map.get(sessionId)
      if (existing) {
        if (display.length > 0) existing.displays.push(display)
        if (existing.project === null && project !== null) existing.project = project
        if (timestamp !== null && !Number.isNaN(timestamp.getTime())) {
          existing.timestamp = timestamp
        }
      } else {
        map.set(sessionId, {
          displays: display.length > 0 ? [display] : [],
          project,
          timestamp: timestamp !== null && !Number.isNaN(timestamp.getTime()) ? timestamp : null
        })
      }
    }

    return map
  }

  private parseSession(
    target: SessionTarget,
    history: HistoryRecord | undefined,
    artifacts: AssociatedArtifacts
  ): ConversationItem {
    const { filePath, sessionId, projectDir } = target
    const associatedPaths: string[] = [filePath]

    // project 目录里与 sessionId 同名的子目录：subagent 的工作区。
    const sessionDir = join(projectDir, sessionId)
    let subagentDirSize = 0
    if (pathExists(sessionDir)) {
      associatedPaths.push(sessionDir)
      subagentDirSize = sizeOfPath(sessionDir)
    }

    const prePaths = artifacts.pathsBySessionId.get(sessionId)
    if (prePaths) associatedPaths.push(...prePaths)
    const preIndexedSize = artifacts.sizeBySessionId.get(sessionId) ?? 0

    const totalBytes = sizeOfPath(filePath) + subagentDirSize + preIndexedSize

    const fileMtime = mtimeMs(filePath)
    const modDate =
      fileMtime !== undefined ? new Date(fileMtime) : (history?.timestamp ?? new Date())

    let detectedCwd: string | null = history?.project ?? null
    let detectedBranch: string | undefined
    let detectedSlug: string | undefined
    let firstUserPrompt: string | undefined = history?.displays[0]
    let messageCount = history?.displays.length ?? 0

    // 只读头 64KB：cwd / gitBranch / slug / 首条 user prompt 都在前几行。
    const header = readJsonLinesHead<SessionHeaderEntry>(filePath, HEADER_BYTE_LIMIT)
    for (const entry of header.slice(0, HEADER_LINE_LIMIT)) {
      if (detectedCwd === null && typeof entry.cwd === 'string') detectedCwd = entry.cwd
      if (detectedBranch === undefined && typeof entry.gitBranch === 'string') {
        detectedBranch = entry.gitBranch
      }
      if (detectedSlug === undefined && typeof entry.slug === 'string') detectedSlug = entry.slug

      if (firstUserPrompt === undefined || firstUserPrompt.length === 0) {
        const prompt = extractFirstUserPrompt(entry)
        if (prompt !== null) firstUserPrompt = prompt
      }
    }

    // JSON 里没有 cwd 时从 project 目录名反推：`-Users-me-proj` → `/Users/me/proj`
    if (detectedCwd === null) {
      const name = dirName(projectDir)
      if (name.startsWith('-')) {
        detectedCwd = '/' + name.slice(1).replace(/-/g, '/')
      }
    }

    let title: string
    if (firstUserPrompt !== undefined && firstUserPrompt.length > 0) {
      title = flattenNewlines(truncate(firstUserPrompt, 80))
    } else if (detectedSlug !== undefined && detectedSlug.length > 0) {
      title = detectedSlug
    } else {
      title = `会话 ${truncate(sessionId, 8)}`
    }

    const lastDisplay = history?.displays.length ? history.displays[history.displays.length - 1] : undefined
    let snippet: string
    if (lastDisplay !== undefined && lastDisplay !== title) {
      snippet = flattenNewlines(truncate(lastDisplay, 120))
    } else if (firstUserPrompt !== undefined) {
      snippet = flattenNewlines(truncate(firstUserPrompt, 120))
    } else {
      snippet = `项目: ${detectedCwd ?? '未知'}`
    }

    if (messageCount === 0) {
      messageCount = Math.max(1, Math.floor(totalBytes / 1024 / 20))
    }

    return makeItem({
      sessionId,
      title,
      category: this.category,
      projectPath: detectedCwd,
      gitBranch: detectedBranch ?? null,
      messageCount,
      sizeInBytes: totalBytes,
      updatedAt: modDate,
      snippet,
      associatedPaths
    })
  }

  // MARK: - 索引清理

  /** 裁剪 `history.jsonl`：删掉属于已删 sessionId 的行，其余原样保留。 */
  private cleanHistory(excludingSessionIds: Set<string>): void {
    const historyPath = join(this.root, 'history.jsonl')
    let content: string
    try {
      content = readFileSync(historyPath, 'utf8')
    } catch {
      return
    }

    const retained: string[] = []
    for (const line of enumerateLines(content)) {
      // 解析失败 / 没有 sessionId 的行一律保留 —— Swift 的 guard 分支也是 append(line)。
      let json: unknown
      try {
        json = JSON.parse(line)
      } catch {
        retained.push(line)
        continue
      }
      if (!isPlainObject(json)) {
        retained.push(line)
        continue
      }
      const sessionId = json.sessionId
      if (typeof sessionId !== 'string' || !excludingSessionIds.has(sessionId)) {
        retained.push(line)
      }
    }

    const next = retained.join('\n') + (retained.length === 0 ? '' : '\n')
    writeFileAtomic(historyPath, next)
  }

  /** 裁剪每个 project 目录下的 `sessions-index.json` 与根 `sessions-index.json`。 */
  private cleanSessionsIndex(excludingSessionIds: Set<string>): void {
    if (excludingSessionIds.size === 0) return

    const indexPaths: string[] = []
    const projectsDir = join(this.root, 'projects')
    if (isDirectory(projectsDir)) {
      for (const name of listDirectories(projectsDir)) {
        const indexPath = join(projectsDir, name, 'sessions-index.json')
        if (pathExists(indexPath)) indexPaths.push(indexPath)
      }
    }
    const directIndex = join(this.root, 'sessions-index.json')
    if (pathExists(directIndex)) indexPaths.push(directIndex)

    for (const indexPath of indexPaths) this.cleanSingleSessionsIndex(indexPath, excludingSessionIds)
  }

  /**
   * 单个 `sessions-index.json` 的四种形状全要认。
   *
   * · `{"entries": [{sessionId|id}]}`      —— 数组
   * · `{"sessions": [{sessionId|id}]}`     —— 数组
   * · `{"sessions": {sid: …}}`             —— 字典
   * · 其它字典（键即 sessionId）
   *
   * 裁剪后为空 → 删文件；读不出来 / 解析失败 → 同样删文件（Swift 版就是这么干的）。
   * 数组元素缺 `sessionId` 与 `id` 的一律丢弃 —— Swift 的 filter 也是这个口径。
   */
  private cleanSingleSessionsIndex(filePath: string, excludingSessionIds: Set<string>): void {
    let parsed: unknown
    try {
      parsed = JSON.parse(readFileSync(filePath, 'utf8'))
    } catch {
      removeIfExists(filePath)
      return
    }

    const keepEntry = (entry: unknown): boolean => {
      if (!isPlainObject(entry)) return false
      const raw = entry.sessionId !== undefined ? entry.sessionId : entry.id
      const sessionId = typeof raw === 'string' ? raw : ''
      return sessionId.length > 0 && !excludingSessionIds.has(sessionId)
    }

    let shouldRemoveFile = false
    let modified: Record<string, unknown> | unknown[] | null = null
    let didModify = false

    if (isPlainObject(parsed)) {
      const dict = parsed as Record<string, unknown>
      if (Array.isArray(dict.entries) && dict.entries.every(isPlainObject)) {
        const filtered = dict.entries.filter(keepEntry)
        if (filtered.length === 0) shouldRemoveFile = true
        else {
          dict.entries = filtered
          modified = dict
          didModify = true
        }
      } else if (Array.isArray(dict.sessions) && dict.sessions.every(isPlainObject)) {
        const filtered = dict.sessions.filter(keepEntry)
        if (filtered.length === 0) shouldRemoveFile = true
        else {
          dict.sessions = filtered
          modified = dict
          didModify = true
        }
      } else if (isPlainObject(dict.sessions)) {
        const sessions = dict.sessions as Record<string, unknown>
        const filtered = filterKeys(sessions, excludingSessionIds)
        if (Object.keys(filtered).length === 0) shouldRemoveFile = true
        else {
          dict.sessions = filtered
          modified = dict
          didModify = true
        }
      } else {
        const filtered = filterKeys(dict, excludingSessionIds)
        if (Object.keys(filtered).length === 0) shouldRemoveFile = true
        else {
          modified = filtered
          didModify = true
        }
      }
    } else if (Array.isArray(parsed) && parsed.every(isPlainObject)) {
      const filtered = parsed.filter(keepEntry)
      if (filtered.length === 0) shouldRemoveFile = true
      else {
        modified = filtered
        didModify = true
      }
    }

    if (shouldRemoveFile) {
      removeIfExists(filePath)
    } else if (didModify && modified !== null) {
      writeFileAtomic(filePath, JSON.stringify(sortKeysDeep(modified), null, 2))
    }
  }

  /** 一键清空：把所有 `sessions-index.json` 干掉。 */
  private removeAllSessionsIndices(): void {
    const projectsDir = join(this.root, 'projects')
    // Swift 版这里有 `guard projects 目录存在` 的早退，因此 `projects` 不存在时
    // 根 `sessions-index.json` 也会被跳过。照抄这个行为。
    if (!isDirectory(projectsDir)) return

    for (const name of listDirectories(projectsDir)) {
      const indexPath = join(projectsDir, name, 'sessions-index.json')
      if (pathExists(indexPath)) removeIfExists(indexPath)
    }

    const directIndex = join(this.root, 'sessions-index.json')
    if (pathExists(directIndex)) removeIfExists(directIndex)
  }

  /**
   * 回收空 project 目录。
   *
   * 「回收空项目目录」关掉时磁盘上保留空目录 —— `removeIfEmptyDirectory` 也会拦一道，
   * 这里提前 return 只是为了不白跑一遍枚举。
   */
  private cleanEmptyProjectDirectories(): void {
    if (!CleanPrefs.cleanEmptyProjectFolders) return

    const projectsDir = join(this.root, 'projects')
    if (!isDirectory(projectsDir)) return

    for (const name of listDirectories(projectsDir)) {
      const dir = join(projectsDir, name)
      let contents: string[]
      try {
        // 注意这里**不跳隐藏项**：过滤条件自己会丢掉 `.` 开头的名字。
        contents = readdirSync(dir)
      } catch {
        continue
      }
      const remaining = contents.filter(
        (entry) => entry !== 'memory' && !entry.startsWith('.') && entry !== 'sessions-index.json'
      )
      if (remaining.length === 0) removeIfExists(dir)
    }
  }
}

// MARK: - 小工具

/** realpath 规范化；取不到（路径不存在）就原样返回。 */
function canonical(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

/** `abc.jsonl` → `abc`。 */
function stripExtension(name: string): string {
  return name.slice(0, name.length - extname(name).length)
}

/** 列目录里的全部子项（跳隐藏项），不区分文件 / 目录；不存在返回 `[]`。 */
function listEntryNames(path: string): string[] {
  try {
    return readdirSync(path).filter((name) => !name.startsWith('.'))
  } catch {
    return []
  }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * 等价于 Swift 的 `String.enumerateLines`：按换行切分，**不产生尾部空行**。
 * `""` → `[]`，`"a\n"` → `["a"]`，`"a\n\n"` → `["a", ""]`。
 */
function enumerateLines(content: string): string[] {
  const lines = content.split(/\r\n|\n|\r/)
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop()
  return lines
}

/** 从一行会话记录里取首条 user prompt 的文本；取不到返回 `null`。 */
function extractFirstUserPrompt(entry: SessionHeaderEntry): string | null {
  if (entry.type !== 'user') return null
  const message = entry.message
  if (!isPlainObject(message)) return null
  const content = message.content

  if (typeof content === 'string') {
    const trimmed = content.trim()
    return trimmed.length > 0 ? trimmed : null
  }

  if (Array.isArray(content)) {
    for (const item of content) {
      if (!isPlainObject(item)) continue
      const text = item.text
      if (typeof text === 'string' && text.length > 0) return text.trim()
    }
  }

  return null
}

/** 标题 / 摘要里换行压成空格。Swift 版是 `replacingOccurrences(of: "\n", with: " ")`。 */
function flattenNewlines(text: string): string {
  return text.replace(/\n/g, ' ')
}

function filterKeys(
  source: Record<string, unknown>,
  excludingSessionIds: Set<string>
): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const key of Object.keys(source)) {
    if (!excludingSessionIds.has(key)) out[key] = source[key]
  }
  return out
}

/** `JSONSerialization` 的 `.sortedKeys`：递归按键名排序后再序列化。 */
function sortKeysDeep(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeysDeep)
  if (isPlainObject(value)) {
    const out: Record<string, unknown> = {}
    for (const key of Object.keys(value).sort()) out[key] = sortKeysDeep(value[key])
    return out
  }
  return value
}

/** 对应 Swift 的 `write(to:atomically:true)`：先写同目录隐藏临时文件再 rename。 */
function writeFileAtomic(path: string, content: string): void {
  const tmp = join(dirname(path), `.${basename(path)}.${process.pid}.tmp`)
  try {
    writeFileSync(tmp, content, 'utf8')
    renameSync(tmp, path)
  } catch (error) {
    console.error(`[claudeCode] 写入失败 ${path}:`, error)
    try {
      writeFileSync(path, content, 'utf8')
    } catch {
      /* 与 Swift 的 `try?` 一致：写不进去就算了 */
    }
  }
}
