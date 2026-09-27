import { mkdirSync, readdirSync, realpathSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, extname, join, resolve } from 'node:path'
import type { ConversationItem } from '@shared/types'
import type { AgentScanner, ScannerOptions } from '@main/core/scanner'
import {
  CleanPrefs,
  isDirectory,
  makeItem,
  mapLimit,
  mtimeMs,
  pathExists,
  readJson,
  readJsonLinesHead,
  removeIfExists,
  sizeOfPath,
  sortByUpdatedDesc,
  truncate
} from '@main/core/scanner'
import { parseIsoDate } from '@main/core/datetime'
import { isInside } from '@main/core/fsutil'

/**
 * OpenHands（原 Devin）扫描器：扫 `~/.openhands`（`OPENHANDS_HOME` 可覆盖），
 * 兼容旧版目录 `~/.open-devin`。
 *
 * 会话可以有两种形态，**都在 `sessions/` 下**：
 * · 目录（新版）：`sessions/<id>/{metadata.json, events.jsonl | events.json}`
 * · 单文件（旧版）：`sessions/<id>.json` 或 `sessions/<id>.jsonl`
 *
 * 与 Zed 那种「每个来源各自独立」不同，OpenHands 的会话在 `logs/` 和 `workspace/`
 * 里**没有**任何标记，唯一的线索是**文件名/目录名里含 sessionId**。
 * 所以扫描分三步：先列 sessions，再回头把 logs / workspace 里能对上的文件挂到会话上，
 * 对不上的日志归成一条「系统日志」聚合项。
 *
 * ⚠️ 目录名关联用的是**双向包含判断**（`a.includes(b) || b.includes(a)`），
 * 存在把 `session-1` 匹配到 `session-10` 的可能。这里原样保留 —— 误挂的后果只是
 * 多删/少删一个日志文件，比「收紧匹配」引入行为差异安全。
 */

/** 项目改名后的新目录名：`.openhands` 为主，`.open-devin` 为兼容旧版。 */
const PRIMARY_DIR = '.openhands'
const LEGACY_DIR = '.open-devin'
/** 被打包成单条会话的「无主日志」组的 sessionId 前缀。 */
const LOG_GROUP_PREFIX = 'openhands-logs-'

/** 标题 / 摘要的统一口径：先截断到 N 字符，再把换行换成空格。 */
function flatten(text: string, limit: number): string {
  return truncate(text, limit).replace(/\n/g, ' ')
}

/** `resourceValues(forKeys: .canonicalPathKey)` 的等价物；失败落回 `standardized`。 */
function canonical(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return resolve(path)
  }
}

/** 文件 mtime；取不到回落到「现在」（宁时间不准，也不能让 item 没法排序）。 */
function modifiedAt(path: string): Date {
  const ms = mtimeMs(path)
  return ms === undefined ? new Date() : new Date(ms)
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return null
  return value as Record<string, unknown>
}

/**
 * 一次 `readdir` 列出目录下全部子项（跳过隐藏项），保留枚举顺序。
 *
 * `sessions/` 必须**一次**枚举后再分流（目录 → 会话目录、文件 → 会话文件），
 * 分两次调用会打乱顺序，而后面 logs 关联是「先到先得」，顺序会影响关联结果。
 */
function listEntries(dir: string): string[] {
  try {
    return readdirSync(dir, { withFileTypes: true })
      .filter((entry) => !entry.name.startsWith('.'))
      .map((entry) => join(dir, entry.name))
  } catch {
    return []
  }
}

/** `sessions/` 下会被当成会话的单个文件：`.json` / `.jsonl`。 */
function isSessionFile(path: string): boolean {
  const ext = extname(path).toLowerCase()
  return ext === '.json' || ext === '.jsonl'
}

/** 按 key 列表的优先顺序取第一个「非空字符串」字段并去空白。 */
function extractField(json: Record<string, unknown>, keys: readonly string[]): string | undefined {
  for (const key of keys) {
    const value = json[key]
    if (typeof value !== 'string') continue
    const trimmed = value.trim()
    if (trimmed.length > 0) return trimmed
  }
  return undefined
}

const TITLE_KEYS = ['title', 'initial_prompt', 'task', 'instructions', 'prompt'] as const
const SNIPPET_KEYS = ['initial_prompt', 'task', 'instructions', 'title', 'prompt'] as const
const PROJECT_KEYS = ['directory', 'project_dir', 'workspace', 'cwd', 'selected_repository'] as const

/** `created_at` 缺失时回落到 `updated_at`；两个都不是字符串则返回 `undefined`。 */
function extractTimestamp(json: Record<string, unknown>): Date | null {
  for (const key of ['created_at', 'updated_at'] as const) {
    const parsed = parseIsoDate(json[key])
    if (parsed !== null) return parsed
  }
  return null
}

/**
 * 事件里的「首条用户输入」。
 * OpenHands 的事件统一是 `{action, source, args:{content}}`，
 * 用户发言有两种写法：`action == "message"` 或 `source == "user"`。
 */
function firstUserContent(event: Record<string, unknown>): string | undefined {
  const action = event['action']
  const source = event['source']
  if (action !== 'message' && source !== 'user') return undefined
  const args = asRecord(event['args'])
  const content = args?.['content']
  if (typeof content !== 'string') return undefined
  const trimmed = content.trim()
  return trimmed.length > 0 ? trimmed : undefined
}

/**
 * `events.jsonl` → `[首条用户输入, 事件数]`。
 * 只读**前 64KB** —— 标题一定在开头，而完整事件流动辄几十 MB。
 */
function parseEventsJsonl(path: string): [string | undefined, number] {
  const events = readJsonLinesHead(path, 64 * 1024)
  let firstUserPrompt: string | undefined
  let count = 0
  for (const raw of events) {
    const event = asRecord(raw)
    if (event === null) continue // 非对象的行不计入消息数
    count += 1
    if (firstUserPrompt === undefined) {
      firstUserPrompt = firstUserContent(event)
    }
  }
  return [firstUserPrompt, Math.max(1, count)]
}

/** `events.json`（整个事件数组）→ `[首条用户输入, 事件数]`。不是「对象数组」时回落到 `(undefined, 1)`。 */
function parseEventsJson(path: string): [string | undefined, number] {
  const parsed = readJson(path)
  if (!Array.isArray(parsed)) return [undefined, 1]
  const events: Record<string, unknown>[] = []
  for (const raw of parsed) {
    const event = asRecord(raw)
    if (event === null) return [undefined, 1]
    events.push(event)
  }
  let firstPrompt: string | undefined
  for (const event of events) {
    const content = firstUserContent(event)
    if (content !== undefined) {
      firstPrompt = content
      break
    }
  }
  return [firstPrompt, Math.max(1, events.length)]
}

/** `sessions/<id>/` 目录形态的会话。 */
function parseSessionDirectory(dir: string): ConversationItem | null {
  const sessionId = basename(dir)
  if (sessionId.length === 0 || sessionId.startsWith('.')) return null

  const size = sizeOfPath(dir)
  let updatedAt = modifiedAt(dir)
  let title: string | undefined
  let snippet: string | undefined
  let projectPath: string | undefined
  let messageCount = 0

  // 1. metadata.json：标题 / 摘要 / 项目路径 / 时间
  const metadata = asRecord(readJson(join(dir, 'metadata.json')))
  if (metadata !== null) {
    title = extractField(metadata, TITLE_KEYS)
    snippet = extractField(metadata, SNIPPET_KEYS)
    projectPath = extractField(metadata, PROJECT_KEYS)
    updatedAt = extractTimestamp(metadata) ?? updatedAt
  }

  // 2. events.jsonl 优先于 events.json；它只补 metadata 里没有的标题。
  const eventsJsonl = join(dir, 'events.jsonl')
  const eventsJson = join(dir, 'events.json')
  if (pathExists(eventsJsonl)) {
    const [eventTitle, count] = parseEventsJsonl(eventsJsonl)
    if (title === undefined || title.length === 0) title = eventTitle
    messageCount = count
  } else if (pathExists(eventsJson)) {
    const [eventTitle, count] = parseEventsJson(eventsJson)
    if (title === undefined || title.length === 0) title = eventTitle
    messageCount = count
  }

  const finalTitle = title ?? `OpenHands 会话 ${truncate(sessionId, 8)}`
  const finalSnippet = snippet ?? title ?? 'OpenHands 任务会话'
  return makeItem({
    sessionId,
    title: flatten(finalTitle, 80),
    category: 'openHands',
    projectPath: projectPath ?? null,
    messageCount: Math.max(1, messageCount),
    sizeInBytes: size,
    updatedAt,
    snippet: flatten(finalSnippet, 120),
    associatedPaths: [dir]
  })
}

/** `sessions/<id>.json` / `sessions/<id>.jsonl` 单文件形态的会话。 */
function parseSessionFile(file: string): ConversationItem | null {
  const ext = extname(file).toLowerCase()
  const sessionId = basename(file, extname(file))
  if (sessionId.length === 0 || sessionId.startsWith('.')) return null

  const size = sizeOfPath(file)
  let updatedAt = modifiedAt(file)
  let title: string | undefined
  let snippet: string | undefined
  let projectPath: string | undefined
  let messageCount = 1

  if (ext === '.json') {
    const json = asRecord(readJson(file))
    if (json !== null) {
      title = extractField(json, TITLE_KEYS)
      snippet = extractField(json, SNIPPET_KEYS)
      projectPath = extractField(json, PROJECT_KEYS)
      updatedAt = extractTimestamp(json) ?? updatedAt
      // 事件数：events 优先，其次 messages；都没有就保持 1。
      const events = json['events']
      const messages = json['messages']
      if (Array.isArray(events)) messageCount = events.length
      else if (Array.isArray(messages)) messageCount = messages.length
    }
  } else if (ext === '.jsonl') {
    // jsonl 里没有 metadata 可兜底，事件的标题就是会话标题。
    const [eventTitle, count] = parseEventsJsonl(file)
    title = eventTitle
    messageCount = count
  }

  const finalTitle = title ?? `OpenHands 会话 ${truncate(sessionId, 8)}`
  const finalSnippet = snippet ?? title ?? 'OpenHands 任务会话'
  return makeItem({
    sessionId,
    title: flatten(finalTitle, 80),
    category: 'openHands',
    projectPath: projectPath ?? null,
    messageCount: Math.max(1, messageCount),
    sizeInBytes: size,
    updatedAt,
    snippet: flatten(finalSnippet, 120),
    associatedPaths: [file]
  })
}

/** 名称关联：`logs/<sid>.log`、`workspace/<sid>` 与会话 id 的双向包含判断。 */
function namesMatch(a: string, b: string): boolean {
  return a === b || a.includes(b) || b.includes(a)
}

export class OpenHandsScanner implements AgentScanner {
  readonly category = 'openHands' as const
  /** 构造注入的原始路径，`null` 表示用默认解析。 */
  private readonly custom: string | null

  constructor(options: ScannerOptions = {}) {
    this.custom = options.storagePath ?? null
  }

  /**
   * `OPENHANDS_HOME` > `~/.openhands` > `~/.open-devin`。
   * 只有「两个默认目录都存在」时才二选一：装了新版但也留着旧目录时优先新版。
   * 注意这里**只对注入路径做 realpath**，环境变量那一支是原样返回的。
   */
  get storagePath(): string {
    if (this.custom !== null) return canonical(this.custom)
    const env = process.env.OPENHANDS_HOME
    if (env !== undefined && env.length > 0) return env
    const primary = join(homedir(), PRIMARY_DIR)
    if (pathExists(primary)) return primary
    const legacy = join(homedir(), LEGACY_DIR)
    if (pathExists(legacy)) return legacy
    return primary
  }

  /** 旧版目录。`isInstalled` 与扫描的目标根都要把它一起算上。 */
  private get legacyPath(): string {
    return join(homedir(), LEGACY_DIR)
  }

  get isInstalled(): boolean {
    if (this.custom !== null) return pathExists(this.custom)
    return pathExists(this.storagePath) || pathExists(this.legacyPath)
  }

  /** 本次扫描 / 删除要处理的数据根：新旧目录可能同时存在，两个都算。 */
  private targetRoots(): string[] {
    if (this.custom !== null) return [this.custom]
    const roots: string[] = []
    const primary = this.storagePath
    if (pathExists(primary)) roots.push(primary)
    const legacy = this.legacyPath
    if (legacy !== primary && pathExists(legacy)) roots.push(legacy)
    if (roots.length === 0) roots.push(primary)
    return roots
  }

  async scan(): Promise<ConversationItem[]> {
    if (!this.isInstalled) return []

    const allItems: ConversationItem[] = []
    for (const root of this.targetRoots()) {
      if (!pathExists(root)) continue
      allItems.push(...(await scanRoot(root)))
    }
    return sortByUpdatedDesc(allItems)
  }

  /**
   * 删除会话。与通用流程 `deleteItemsWithPaths` 的差别只有一处：每条路径都要过
   * `isSafeToDelete` —— 只允许删 `~/.openhands` / `~/.open-devin` 之内的东西。
   * 不用通用原语的原因：这里的 `associatedPaths` 是从 `logs/` 与 `workspace/`
   * **按名称模糊匹配**挂上去的，路径可信度低于其它扫描器直接枚举出来的路径，
   * 多一道 `isInside` 护栏才防得住 IPC 传进来的畸形路径伤到根目录之外。
   */
  async delete(items: ConversationItem[]): Promise<number> {
    if (items.length === 0) return 0
    let freed = 0
    for (const item of items) {
      // 必须在物理删除之前算：路径没了 `sizeOf` 恒为 0。
      freed += CleanPrefs.freedBytesBeforeDelete(item.sizeInBytes, item)
      for (const path of CleanPrefs.deletionPathsFor(item)) {
        if (!this.isSafeToDelete(path)) continue
        removeIfExists(path)
      }
    }
    return freed
  }

  /**
   * 全清 = 逐条删 + 三个子目录整目录删掉再重建。
   * 逐条删之后 `sessions/` 里剩下的多半是空目录或隐藏文件（OpenHands 自己的锁文件），
   * 但它们同样占着用户的磁盘，所以整目录清一遍再重建空壳。
   */
  async cleanAll(): Promise<number> {
    let freed = await this.delete(await this.scan())
    for (const root of this.targetRoots()) {
      if (!pathExists(root)) continue
      for (const subdir of ['sessions', 'logs', 'workspace']) {
        const dir = join(root, subdir)
        if (!pathExists(dir)) continue
        const size = sizeOfPath(dir)
        if (!removeIfExists(dir)) continue
        freed += size
        try {
          mkdirSync(dir, { recursive: true })
        } catch (error) {
          console.error(`[openhands] 重建目录失败 ${dir}:`, error)
        }
      }
    }
    return freed
  }

  private isSafeToDelete(path: string): boolean {
    const normalized = resolve(path)
    return this.targetRoots().some((root) => isInside(resolve(root), normalized))
  }
}

/** 扫描一个数据根：`sessions/` 列会话，再把 `logs/`、`workspace/` 关联上去。 */
async function scanRoot(root: string): Promise<ConversationItem[]> {
  // 1. sessions/
  const sessions: ConversationItem[] = []
  const parsed = await mapLimit(listEntries(join(root, 'sessions')), 8, (entry) => {
    if (!pathExists(entry)) return null
    if (isDirectory(entry)) return parseSessionDirectory(entry)
    if (isSessionFile(entry)) return parseSessionFile(entry)
    return null
  })
  for (const item of parsed) if (item !== null) sessions.push(item)

  // 2. logs/：能对上 sessionId 的挂到会话上，对不上的归成「系统日志」一条。
  const logsDir = join(root, 'logs')
  const orphanedLogs: string[] = []
  let orphanedBytes = 0
  let latestLogMs = Number.NEGATIVE_INFINITY
  for (const logPath of listEntries(logsDir)) {
    const logSize = sizeOfPath(logPath)
    const logName = basename(logPath, extname(logPath))
    const ms = mtimeMs(logPath)
    if (ms !== undefined && ms > latestLogMs) latestLogMs = ms

    let matched = false
    for (const session of sessions) {
      if (!namesMatch(logName, session.sessionId)) continue
      if (!session.associatedPaths.includes(logPath)) {
        session.associatedPaths.push(logPath)
        session.sizeInBytes += logSize
      }
      matched = true
      break
    }
    if (!matched) {
      orphanedLogs.push(logPath)
      orphanedBytes += logSize
    }
  }

  // 3. workspace/：同样按名称关联，不计入「系统日志」组（对不上的就是无关目录）。
  for (const wsPath of listEntries(join(root, 'workspace'))) {
    const wsName = basename(wsPath)
    const wsSize = sizeOfPath(wsPath)
    for (const session of sessions) {
      if (!namesMatch(wsName, session.sessionId)) continue
      if (!session.associatedPaths.includes(wsPath)) {
        session.associatedPaths.push(wsPath)
        session.sizeInBytes += wsSize
      }
      break
    }
  }

  const items = sessions
  if (orphanedLogs.length > 0 && orphanedBytes > 0) {
    items.push(
      makeItem({
        sessionId: `${LOG_GROUP_PREFIX}${basename(root)}`,
        title: `OpenHands 运行与调用日志 (${orphanedLogs.length} 个文件)`,
        category: 'openHands',
        projectPath: logsDir,
        messageCount: orphanedLogs.length,
        sizeInBytes: orphanedBytes,
        updatedAt: Number.isFinite(latestLogMs) ? new Date(latestLogMs) : new Date(),
        snippet: 'OpenHands 系统运行、LLM API 调用及诊断日志',
        associatedPaths: orphanedLogs
      })
    )
  }
  return items
}
