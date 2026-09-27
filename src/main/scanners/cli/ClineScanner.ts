import { mkdirSync, realpathSync, renameSync, writeFileSync } from 'node:fs'
import { cpus, homedir } from 'node:os'
import { dirname, join } from 'node:path'
import type { ConversationItem } from '@shared/types'
import type { AgentScanner, ScannerOptions } from '@main/core/scanner'
import {
  CleanPrefs,
  deleteItemsWithPaths,
  listDirectories,
  makeItem,
  mapLimit,
  mtimeMs,
  pathExists,
  readJson,
  removeIfEmptyDirectory,
  removeIfExists,
  sizeOfPath,
  sortByUpdatedDesc,
  truncate
} from '@main/core/scanner'

/**
 * Cline 扫描器（Cline 与 Roo Code 的共同实现）。
 *
 * 源文件：`ConversationClean/Scanners/CLIAgents/ClineScanner.swift`。
 * `RooCodeScanner.swift` 在 Swift 里就是本类的子类，只覆写分类 / 环境变量 / 默认目录，
 * 这里同样用继承表达（见 `RooCodeScanner.ts`）。
 *
 * VS Code 扩展的数据布局（`CLINE_HOME` 可覆盖）：
 * ```
 * …/globalStorage/saoudrizwan.claude-dev/
 *   tasks/<taskId>/ui_messages.json             # UI 消息流（标题 / 摘要 / ts / cwd 都在这）
 *   tasks/<taskId>/api_conversation_history.json
 *   tasks/<taskId>/task_metadata.json           # files_in_context（项目路径的最后兜底）
 *   checkpoints/<taskId>/                       # 文件改动快照（受 cleanFileHistorySnapshots 约束）
 *   state/taskHistory.json                      # 任务索引（id / task / cwdOnTaskInitialization / ts / size）
 *   cache/                                      # 缓存（cleanAll 整目录删除后重建）
 * ```
 */

/** Swift `withTaskGroup` 的默认并发度（CPU 核心数）。 */
const PARSE_CONCURRENCY = Math.max(1, cpus().length)

interface TaskHistoryEntry {
  id: string
  task: string | null
  cwd: string | null
  ts: number | null
  size: number | null
}

export class ClineScanner implements AgentScanner {
  /** `.cline` / `.rooCode`：`RooCodeScanner` 覆写它（Swift 版是 `override var category`）。 */
  readonly category: 'cline' | 'rooCode' = 'cline'

  private readonly customStoragePath: string | undefined

  constructor(options: ScannerOptions = {}) {
    this.customStoragePath = options.storagePath
  }

  /** 覆盖数据根目录的环境变量名。子类覆写。 */
  protected get envVarName(): string {
    return 'CLINE_HOME'
  }

  /** 默认数据目录相对 `~` 的路径。子类覆写。 */
  protected get defaultStorageSegments(): readonly string[] {
    return [
      'Library',
      'Application Support',
      'Code',
      'User',
      'globalStorage',
      'saoudrizwan.claude-dev'
    ]
  }

  /** 环境变量 → `~/` 默认目录，并做一次 realpath 规范化（`/var` → `/private/var`）。 */
  get storagePath(): string {
    if (this.customStoragePath !== undefined) return canonicalPath(this.customStoragePath)
    const env = process.env[this.envVarName]
    if (env !== undefined && env.length > 0) return canonicalPath(env)
    return canonicalPath(join(homedir(), ...this.defaultStorageSegments))
  }

  get isInstalled(): boolean {
    return pathExists(this.storagePath)
  }

  // MARK: - Scan

  async scan(): Promise<ConversationItem[]> {
    if (!this.isInstalled) return []
    const root = this.storagePath

    const tasksDir = join(root, 'tasks')
    if (!pathExists(tasksDir)) return []

    // `listDirectories` 已经过滤掉隐藏项与普通文件；taskId 就是目录名。
    const targetTaskIds = listDirectories(tasksDir).map((taskId) => ({
      taskId,
      taskDirPath: join(tasksDir, taskId)
    }))
    if (targetTaskIds.length === 0) return []

    const taskHistoryMap = this.loadTaskHistory(root)
    const checkpointsDir = join(root, 'checkpoints')

    const items = await mapLimit(targetTaskIds, PARSE_CONCURRENCY, (target) =>
      this.parseTask(
        target.taskId,
        target.taskDirPath,
        checkpointsDir,
        taskHistoryMap.get(target.taskId)
      )
    )
    return sortByUpdatedDesc(items)
  }

  // MARK: - Deletion

  async delete(items: ConversationItem[]): Promise<number> {
    const root = this.storagePath
    return deleteItemsWithPaths(items, (deletedTaskIds) => {
      // taskHistory.json 是 VS Code 扩展侧的任务索引，不同步就会出现「列表里有、点开空」的幽灵任务。
      this.cleanTaskHistory(root, deletedTaskIds)
      this.cleanEmptyTaskDirectories(root)
    })
  }

  async cleanAll(): Promise<number> {
    const root = this.storagePath
    const items = await this.scan()
    let freed = await this.delete(items)

    // checkpoints/<taskId> 就是 Cline / Roo 的文件改动快照，开关关掉时整目录保留。
    const checkpointsDir = join(root, 'checkpoints')
    if (CleanPrefs.cleanFileHistorySnapshots && pathExists(checkpointsDir)) {
      const checkpointSize = sizeOfPath(checkpointsDir)
      if (removeIfExists(checkpointsDir)) {
        freed += checkpointSize
        recreateDirectory(checkpointsDir)
      }
    }

    // cache 跟会话正文无关，整目录清空后重建空目录（扩展下次启动要往里写东西）。
    const cacheDir = join(root, 'cache')
    if (pathExists(cacheDir)) {
      const cacheSize = sizeOfPath(cacheDir)
      if (removeIfExists(cacheDir)) {
        freed += cacheSize
        recreateDirectory(cacheDir)
      }
    }

    this.resetTaskHistory(root)
    return freed
  }

  // MARK: - 任务索引

  /** 读 `state/taskHistory.json`，按 taskId 建索引。 */
  private loadTaskHistory(root: string): Map<string, TaskHistoryEntry> {
    const map = new Map<string, TaskHistoryEntry>()
    const historyPath = join(root, 'state', 'taskHistory.json')
    if (!pathExists(historyPath)) return map

    const parsed = asRecordArray(readJson<unknown>(historyPath))
    if (parsed === null) return map

    for (const entry of parsed) {
      // Swift: `id` 可能是字符串，也可能是数字（`NSNumber.stringValue`）。
      const id = asIdString(entry.id)
      if (id === undefined) continue
      map.set(id, {
        id,
        task: typeof entry.task === 'string' ? entry.task : null,
        cwd: firstString(entry.cwdOnTaskInitialization, entry.cwd) ?? null,
        ts: typeof entry.ts === 'number' ? entry.ts : null,
        size: typeof entry.size === 'number' ? entry.size : null
      })
    }
    return map
  }

  /** 裁剪 `state/taskHistory.json` 里被删任务的条目。 */
  private cleanTaskHistory(root: string, excludingTaskIds: Set<string>): void {
    const historyPath = join(root, 'state', 'taskHistory.json')
    if (!pathExists(historyPath)) return

    const parsed = asRecordArray(readJson<unknown>(historyPath))
    if (parsed === null) return

    // 认不出 id 的条目保留：宁可索引多一条，也不能误删别的任务。
    const retained = parsed.filter((entry) => {
      const id = asIdString(entry.id)
      if (id === undefined) return true
      return !excludingTaskIds.has(id)
    })

    // Swift: `JSONSerialization(.prettyPrinted, .sortedKeys)`
    writeTextAtomic(historyPath, stringifySortedJson(retained))
  }

  /** `cleanAll` 时把任务索引清空成一个空数组（文件本身要留着，扩展会往里写）。 */
  private resetTaskHistory(root: string): void {
    const historyPath = join(root, 'state', 'taskHistory.json')
    if (!pathExists(historyPath)) return
    writeTextAtomic(historyPath, '[]\n')
  }

  /** `tasks/` 全部删空后回收它自己（受 `cleanEmptyProjectFolders` 开关约束）。 */
  private cleanEmptyTaskDirectories(root: string): void {
    removeIfEmptyDirectory(join(root, 'tasks'))
  }

  // MARK: - 解析单个任务

  /**
   * 解析一个任务目录。
   *
   * 标题兜底顺序：`taskHistory.task` → `ui_messages` 里 `say == "task"` 的 `text`
   * → 第一条非空 `text` → taskId（且只取第一行）。
   * 项目路径兜底顺序：`taskHistory.cwdOnTaskInitialization` → 消息里的 `cwd` / `workspace`
   * → 消息或 API 历史里正则抠出的 `Current Working Directory (...)` → `task_metadata.files_in_context[0]` 的父目录。
   * 时间：所有 `ts` 的最大值（缺失时用 `taskHistory.ts`）→ 任务目录 mtime。
   */
  private parseTask(
    taskId: string,
    taskDirPath: string,
    checkpointsDirPath: string,
    historyEntry: TaskHistoryEntry | undefined
  ): ConversationItem {
    let title: string | undefined = historyEntry?.task ?? undefined
    let projectPath: string | undefined = historyEntry?.cwd ?? undefined
    let snippet = ''
    let messageCount = 0
    let latestTimestampMs: number | undefined = historyEntry?.ts ?? undefined

    // 1. ui_messages.json
    const messages = asRecordArray(readJson<unknown>(join(taskDirPath, 'ui_messages.json')))
    if (messages !== null) {
      messageCount = messages.length

      for (const msg of messages) {
        if (typeof msg.ts === 'number') {
          if (latestTimestampMs === undefined || msg.ts > latestTimestampMs) {
            latestTimestampMs = msg.ts
          }
        }

        if (!title || title.length === 0) {
          if (msg.say === 'task' && typeof msg.text === 'string' && msg.text.trim().length > 0) {
            title = msg.text.trim()
          }
        }

        if (snippet.length === 0 && typeof msg.text === 'string' && msg.text.trim().length > 0) {
          snippet = truncate(msg.text.trim(), 200)
        }

        if (!projectPath || projectPath.length === 0) {
          if (typeof msg.cwd === 'string' && msg.cwd.length > 0) {
            projectPath = msg.cwd
          } else if (typeof msg.workspace === 'string' && msg.workspace.length > 0) {
            projectPath = msg.workspace
          } else if (typeof msg.text === 'string') {
            const extracted = extractCwdFromText(msg.text)
            if (extracted !== null) projectPath = extracted
          }
        }
      }

      // 兜底：没有 `say == "task"` 时用第一条非空 text 当标题
      if (!title || title.length === 0) {
        for (const msg of messages) {
          if (typeof msg.text === 'string' && msg.text.trim().length > 0) {
            title = msg.text.trim()
            break
          }
        }
      }
    }

    // 2. api_conversation_history.json
    const apiMessages = asRecordArray(readJson<unknown>(join(taskDirPath, 'api_conversation_history.json')))
    if (apiMessages !== null) {
      if (messageCount === 0) messageCount = apiMessages.length

      if (!projectPath || projectPath.length === 0) {
        outer: for (const message of apiMessages) {
          if (typeof message.content === 'string') {
            const extracted = extractCwdFromText(message.content)
            if (extracted !== null) {
              projectPath = extracted
              break
            }
          } else {
            const contentParts = asRecordArray(message.content)
            if (contentParts === null) continue
            for (const part of contentParts) {
              if (typeof part.text === 'string') {
                const extracted = extractCwdFromText(part.text)
                if (extracted !== null) {
                  projectPath = extracted
                  break outer
                }
              }
            }
          }
        }
      }
    }

    // 3. task_metadata.json
    if (!projectPath || projectPath.length === 0) {
      const meta = readJson<unknown>(join(taskDirPath, 'task_metadata.json'))
      if (isRecord(meta)) {
        const files = asStringArray(meta.files_in_context)
        const firstFile = files[0]
        if (firstFile !== undefined && firstFile.startsWith('/')) {
          projectPath = dirname(firstFile)
        }
      }
    }

    // 最终标题：只取第一行；第一行是空的就退回 taskId
    let finalTitle: string
    if (title !== undefined && title.length > 0) {
      const firstLine = (title.split(/\r\n|\r|\n/)[0] ?? '').trim()
      finalTitle = firstLine.length === 0 ? taskId : firstLine
    } else {
      finalTitle = taskId
    }

    if (snippet.length === 0) snippet = finalTitle

    let updatedAt: Date
    if (latestTimestampMs !== undefined && latestTimestampMs > 0) {
      // `ts` 已经是 epoch 毫秒（Swift 里是 `Date(timeIntervalSince1970: tsMs / 1000.0)`）
      updatedAt = new Date(latestTimestampMs)
    } else {
      const mtime = mtimeMs(taskDirPath)
      updatedAt = mtime !== undefined ? new Date(mtime) : new Date()
    }

    // 任务目录 + （存在时）该任务的快照目录
    const associatedPaths = [taskDirPath]
    const checkpointTaskDir = join(checkpointsDirPath, taskId)
    if (pathExists(checkpointTaskDir)) associatedPaths.push(checkpointTaskDir)

    let totalSize = 0
    for (const path of associatedPaths) totalSize += sizeOfPath(path)
    const historySize = historyEntry?.size ?? null
    if (totalSize === 0 && historySize !== null && historySize > 0) {
      // 任务目录和快照目录都算不出体积（扩展正在写 / 已被清掉）时，回落索引里记的 size。
      totalSize = historySize
    }

    return makeItem({
      sessionId: taskId,
      title: finalTitle,
      category: this.category,
      projectPath: projectPath ?? null,
      gitBranch: null,
      messageCount,
      sizeInBytes: totalSize,
      updatedAt,
      snippet,
      associatedPaths
    })
  }
}

// MARK: - 文本工具

/**
 * 从正文里抠出工作目录。两条正则，与 Swift 版逐字一致：
 * 1. `Current Working Directory (/path/to/project) Files`
 * 2. `"cwd": "/path/to/project"`
 * 只扫前 10000 字符（Swift 的 `min(nsText.length, 10000)`）。
 */
const CWD_PATTERNS = [/Current Working Directory \(([^)]+)\)/, /"cwd"\s*:\s*"([^"]+)"/]

function extractCwdFromText(text: string): string | null {
  const head = text.length > 10000 ? text.slice(0, 10000) : text
  for (const pattern of CWD_PATTERNS) {
    const match = pattern.exec(head)
    const captured = match?.[1]
    if (captured !== undefined && captured.length > 0) return captured
  }
  return null
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

/**
 * Swift `as? [[String: Any]]` 的等价物：数组里**有一个**元素不是字典，
 * 整份文件的类型转换就失败（整块逻辑跳过），所以这里整份返回 `null`。
 */
function asRecordArray(value: unknown): JsonRecord[] | null {
  if (!Array.isArray(value)) return null
  if (!value.every(isRecord)) return null
  return value
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  if (!value.every((item) => typeof item === 'string')) return []
  return value as string[]
}

/** `id` 字段：字符串原样，数字转字符串（Swift 的 `NSNumber.stringValue`），其它一律跳过。 */
function asIdString(value: unknown): string | undefined {
  if (typeof value === 'string') return value
  if (typeof value === 'number') return String(value)
  return undefined
}

function firstString(...values: unknown[]): string | undefined {
  for (const value of values) {
    if (typeof value === 'string') return value
  }
  return undefined
}

function recreateDirectory(path: string): void {
  try {
    mkdirSync(path, { recursive: true })
  } catch {
    /* Swift 是 `try?`，失败不影响后续步骤 */
  }
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
      console.error(`[cline] 写入失败 ${path}:`, error)
    }
  }
}

/** `JSONSerialization.data(options: [.prettyPrinted, .sortedKeys])` 的等价物。 */
function stringifySortedJson(value: unknown): string {
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
