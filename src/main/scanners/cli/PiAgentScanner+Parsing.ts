import { closeSync, openSync, readSync, statSync } from 'node:fs'
import type { Stats } from 'node:fs'
import { basename, join } from 'node:path'
import type { ConversationItem } from '@shared/types'
import { parseIsoDate } from '@main/core/datetime'
import {
  isDirectory,
  listDirectories,
  makeItem,
  sizeOfPath,
  truncate
} from '@main/core/scanner'

/**
 * Pi Agent 会话解析 —— 移植自 `PiAgentScanner+Parsing.swift`。
 *
 * 两条线：
 * 1. `preIndexTasks()`：**预索引** `~/.pi/tasks` 下的任务产物目录，供解析会话时关联子代理产物；
 * 2. `parseSession()`：读一个 `<projectDir>/<timestamp>_<sid>.jsonl`，
 *    从头部 512KB 里解出 sessionId / cwd / 首条用户提问 / 消息数，再拼出 `associatedPaths`。
 *
 * 这里的**每一条兜底顺序都与 Swift 版逐条对齐**，不要顺手改：
 * 标题（首条用户提问 → `Pi 会话 <前 8 位>`）、摘要（提问 → `项目: <cwd>`）、
 * 项目路径（jsonl 的 `cwd` → 目录名 `--a-b--` 反解成 `/a/b`）、
 * 消息数（`type=="message"` 行数 → 至少 1）。
 */

/** 头部预读上限。Swift 版是 `readData(ofLength: 512 * 1024)`。 */
const HEADER_BYTES = 512 * 1024
/** 大文件续读的块大小，与 Swift 的 `autoreleasepool` 循环一致。 */
const CHUNK_BYTES = 256 * 1024
/** 任务目录名前缀长度（一个 UUID 的长度），与 Swift 的 `dirName.count >= 36` 对应。 */
const TASK_DIR_PREFIX_LENGTH = 36

/** 扫描阶段枚举出来的一条待解析会话文件。 */
export interface SessionTarget {
  /** `.jsonl` 会话文件的绝对路径。 */
  filePath: string
  /** 所属项目目录（`agent/sessions/<--Users-mock-projectA-->`）的绝对路径。 */
  projectDir: string
  /** 文件名去掉 `.jsonl` 后的 basename，同时也是会话子目录名。 */
  baseName: string
  /** 从文件名的**最后一个下划线**之后切出来的 id（`2026-09-01T10-00-00-000Z_<sid>` → `<sid>`）。 */
  fileSessionId: string
}

/** `~/.pi/tasks` 的预索引结果。 */
export interface TaskArtifacts {
  /** 会话 id（前 36 位）→ 该会话的任务产物目录绝对路径。 */
  pathsBySessionId: Map<string, string[]>
  /** 会话 id（前 36 位）→ 上述目录的体积合计。 */
  sizeBySessionId: Map<string, number>
}

/**
 * 预索引 `~/.pi/tasks` 下的任务产物目录，供 `parseSession` 关联子代理产物。
 *
 * Swift 的匹配规则照抄：目录名至少 36 位，取前 36 位当 key，
 * 目录名**恰好等于**该前缀或以 `<前缀>-` 开头才算命中（`0102ab…-99999` 这种）。
 * 按 `sizeOfPath` 逐个统计，目录顺序由 `readdirSync` 决定，不做排序。
 */
export function preIndexTasks(tasksDir: string): TaskArtifacts {
  const artifacts: TaskArtifacts = {
    pathsBySessionId: new Map(),
    sizeBySessionId: new Map()
  }
  // `listDirectories` 自身过滤了隐藏项与文件，等价于 Swift 的 `contentsOfDirectory(.skipsHiddenFiles)` + `isDirectory` 判断。
  for (const name of listDirectories(tasksDir)) {
    if (name.length < TASK_DIR_PREFIX_LENGTH) continue
    const prefix = name.slice(0, TASK_DIR_PREFIX_LENGTH)
    if (name !== prefix && !name.startsWith(`${prefix}-`)) continue
    const path = join(tasksDir, name)
    const size = sizeOfPath(path)
    const bucket = artifacts.pathsBySessionId.get(prefix)
    if (bucket) bucket.push(path)
    else artifacts.pathsBySessionId.set(prefix, [path])
    artifacts.sizeBySessionId.set(prefix, (artifacts.sizeBySessionId.get(prefix) ?? 0) + size)
  }
  return artifacts
}

/**
 * 解析一条会话文件，返回一条 `ConversationItem`。
 *
 * 与 Swift 版的差异只有一处：Swift 是 `withTaskGroup` 里的同步闭包，
 * 这里是同步函数，由主类的 `mapLimit` 负责并发。
 */
export function parseSession(
  target: SessionTarget,
  taskArtifacts: TaskArtifacts
): ConversationItem {
  const stats = statOf(target.filePath)
  // Swift: `fileAttrs[.size] ?? FileSizeHelper.sizeOf(path:)` —— 属性取不到就退化成递归求体积。
  const mainFileSize = stats ? stats.size : sizeOfPath(target.filePath)

  let detectedSessionId = target.fileSessionId
  let detectedCwd: string | null = null
  let detectedTimestamp: Date | null = null
  let firstUserPrompt: string | null = null
  let messageCount = 0
  let totalLineCount = 0

  const head = readHead(target.filePath, mainFileSize)
  if (head !== null) {
    for (const line of enumerateLines(head.text)) {
      totalLineCount += 1
      const json = parseJsonObject(line)
      if (json === null) continue

      const type = json['type']
      if (type === 'session') {
        const id = json['id']
        if (typeof id === 'string' && id.length > 0) detectedSessionId = id
        const cwd = json['cwd']
        if (typeof cwd === 'string' && cwd.length > 0) detectedCwd = cwd
        const ts = json['timestamp']
        // Swift 这里是无条件赋值（解析失败会把已有值抹成 nil），照抄。
        if (typeof ts === 'string') detectedTimestamp = parseIsoDate(ts)
      } else if (type === 'message') {
        messageCount += 1
        if (firstUserPrompt === null) {
          const message = json['message']
          if (isRecord(message) && message['role'] === 'user') {
            const prompt = extractText(message['content'])
            if (prompt !== null) firstUserPrompt = prompt
          }
        }
      }
    }
    // Swift: 文件大于 512KB 时，从文件句柄当前位置继续流式数换行并**加到 messageCount** 上。
    // 这是一处已知的粗糙近似（把「行数」当成「消息数」），按移植铁律照抄。
    messageCount += head.trailingNewlines
  }

  // 整份文件都没解析出消息时，至少按行数给一个非零值。
  if (messageCount === 0) messageCount = Math.max(1, totalLineCount)

  // 项目路径兜底：目录名 `--Users-ruanbw-projects-bennett--` → `/Users/ruanbw/projects/bennett`。
  if (detectedCwd === null || detectedCwd.length === 0) {
    const projectDirName = basename(target.projectDir)
    if (projectDirName.startsWith('--') && projectDirName.endsWith('--')) {
      const inner = projectDirName.slice(2, -2)
      detectedCwd = inner.length === 0 ? '/' : `/${inner.replace(/-/g, '/')}`
    }
  }

  // Swift: `fileAttrs[.modificationDate] ?? detectedTimestamp ?? Date()`
  const mtime = stats ? stats.mtimeMs : undefined
  const modDate =
    mtime !== undefined ? new Date(mtime) : (detectedTimestamp ?? new Date())

  const prompt =
    firstUserPrompt !== null && firstUserPrompt.length > 0 ? firstUserPrompt : null
  const title = prompt !== null ? flattenNewlines(prompt, 80) : `Pi 会话 ${detectedSessionId.slice(0, 8)}`
  const snippet =
    prompt !== null ? flattenNewlines(prompt, 120) : `项目: ${detectedCwd ?? '未知'}`

  const associatedPaths: string[] = [target.filePath]
  let totalBytes = mainFileSize

  // 1. 与文件同名的会话子目录（子代理会话、快照等产物）
  const subfolderByBase = join(target.projectDir, target.baseName)
  const visitedDirs = new Set<string>()
  if (isDirectory(subfolderByBase)) {
    associatedPaths.push(subfolderByBase)
    visitedDirs.add(subfolderByBase)
    totalBytes += sizeOfPath(subfolderByBase)
  }

  // 2. 与 sessionId 同名的会话子目录（与 1 不同才加，避免重复计体积）
  const subfolderBySid = join(target.projectDir, detectedSessionId)
  if (!visitedDirs.has(subfolderBySid) && isDirectory(subfolderBySid)) {
    associatedPaths.push(subfolderBySid)
    visitedDirs.add(subfolderBySid)
    totalBytes += sizeOfPath(subfolderBySid)
  }

  // 3. 命中的 tasks/ 目录
  const matchedTaskPaths = new Set<string>()
  const sidTaskPaths = taskArtifacts.pathsBySessionId.get(detectedSessionId)
  if (sidTaskPaths) {
    for (const path of sidTaskPaths) {
      if (matchedTaskPaths.has(path)) continue
      matchedTaskPaths.add(path)
      associatedPaths.push(path)
    }
    totalBytes += taskArtifacts.sizeBySessionId.get(detectedSessionId) ?? 0
  }

  // 3b. 文件名里的 id 与会话头里的 id 不一致时，文件名的那个也再匹配一次
  //     （逐个 `sizeOfPath` 累加，不走 sizeBySessionId，与 Swift 一致）。
  if (target.fileSessionId !== detectedSessionId) {
    const fileTaskPaths = taskArtifacts.pathsBySessionId.get(target.fileSessionId)
    if (fileTaskPaths) {
      for (const path of fileTaskPaths) {
        if (matchedTaskPaths.has(path)) continue
        matchedTaskPaths.add(path)
        associatedPaths.push(path)
        totalBytes += sizeOfPath(path)
      }
    }
  }

  return makeItem({
    sessionId: detectedSessionId,
    title,
    category: 'piAgent',
    projectPath: detectedCwd,
    gitBranch: null,
    messageCount,
    sizeInBytes: totalBytes,
    updatedAt: modDate,
    snippet,
    associatedPaths
  })
}

// MARK: - 私有工具

function statOf(path: string): Stats | null {
  try {
    return statSync(path)
  } catch {
    return null
  }
}

/**
 * 读会话文件的头部，并顺带数出「头部之外」的换行数。
 * 打不开文件时返回 `null`（Swift 的 `try? FileHandle(forReadingFrom:)` 同样是整段跳过）。
 */
function readHead(
  filePath: string,
  mainFileSize: number
): { text: string; trailingNewlines: number } | null {
  let fd: number | undefined
  try {
    fd = openSync(filePath, 'r')
  } catch {
    return null
  }
  try {
    const header = Buffer.alloc(HEADER_BYTES)
    const bytesRead = readSync(fd, header, 0, HEADER_BYTES, 0)
    const text = header.subarray(0, bytesRead).toString('utf8')

    let trailingNewlines = 0
    if (mainFileSize > HEADER_BYTES) {
      // Swift 从文件句柄的当前位置（= 512KB 处）继续 256KB 一块地读空为止。
      const chunk = Buffer.alloc(CHUNK_BYTES)
      let position = bytesRead
      for (;;) {
        const read = readSync(fd, chunk, 0, CHUNK_BYTES, position)
        if (read <= 0) break
        let index = chunk.indexOf(10)
        while (index !== -1 && index < read) {
          trailingNewlines += 1
          index = chunk.indexOf(10, index + 1)
        }
        position += read
      }
    }
    return { text, trailingNewlines }
  } catch {
    return null
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

/**
 * 逐行切分，等价于 Swift 的 `String.enumerateLines`：
 * 以换行符切分、**不产生**末尾空行（`"a\n"` 只有一行）。
 */
function enumerateLines(text: string): string[] {
  if (text.length === 0) return []
  const lines = text.split('\n')
  if (lines[lines.length - 1] === '') lines.pop()
  return lines
}

/** `firstUserPrompt` 的取值口径：字符串、或内容块数组里的所有非空 `text`。 */
function extractText(content: unknown): string | null {
  if (typeof content === 'string') {
    const trimmed = content.trim()
    return trimmed.length === 0 ? null : trimmed
  }
  // Swift 的 `content as? [[String: Any]]` 要求**每个**元素都是字典，混进别的类型就整体落空。
  if (Array.isArray(content) && content.every(isRecord)) {
    const texts: string[] = []
    for (const item of content as Record<string, unknown>[]) {
      const text = item['text']
      if (typeof text !== 'string') continue
      const trimmed = text.trim()
      if (trimmed.length > 0) texts.push(trimmed)
    }
    if (texts.length > 0) return texts.join(' ')
  }
  return null
}

/** 取前 `limit` 个字符并把换行换成空格（Swift：`prefix(n).replacingOccurrences(of: "\n", with: " ")`）。 */
function flattenNewlines(text: string, limit: number): string {
  return truncate(text, limit).replace(/\n/g, ' ')
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function parseJsonObject(line: string): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(line)
    return isRecord(value) ? value : null
  } catch {
    // 截断的末行 / 半行写入，Swift 那边同样是 `try?` 落空后 `return`。
    return null
  }
}
