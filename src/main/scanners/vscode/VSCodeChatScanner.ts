import { mkdirSync, readFileSync, realpathSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, dirname, extname, join, resolve } from 'node:path'

import type { ConversationItem } from '@shared/types'
import type { AgentScanner, ScannerOptions } from '@main/core/scanner'
import {
  fileSize,
  listDirectories,
  listFiles,
  makeItem,
  mtimeMs,
  pathExists,
  readJsonLines,
  resolveStoragePath,
  sortByUpdatedDesc
} from '@main/core/scanner'
import { cleanEmptyWorkspaceStorageDirs, removeIfExists, sizeOfPath } from '@main/core/fsutil'
import { CleanPrefs } from '@main/core/prefs'
import {
  clearAllChatSessions,
  clearCopilotSessionStore,
  removeChatSessions,
  removeCopilotSessionStore
} from '@main/core/vscdb'

/**
 * GitHub Copilot Chat / VS Code Chat 会话扫描器。
 *
 * 移植自 Swift 版 `Scanners/VSCodeFamily/VSCodeChatScanner.swift`。
 *
 * 与 Cursor 的最大差别：**只看会话文件，不解析 `state.vscdb`**。
 * Copilot 的会话正文一律落在
 * `workspaceStorage/<hash>/chatSessions/<sessionId>.jsonl` 与
 * `globalStorage/emptyWindowChatSessions/<sessionId>.jsonl`，
 * `state.vscdb` 只是索引 —— 扫描阶段不碰它，删除阶段才去改索引。
 *
 * ## 铁律
 *
 * 1. `scan()` 只读：不写文件、不开 SQLite 写连接（本类根本不开 SQLite）。
 * 2. `delete()` 里的「索引行收集」与「文件删除」是**两件独立的事**：
 *    索引行属于会话本体，永远跟着删；只有文件删除受 `cleanFileHistorySnapshots` 开关控制。
 *    照抄 Swift 原注释：删了正文却留着索引行，Agent 侧会出现永远查不到的幽灵会话。
 */

/** 会话正文为空时的兜底标题（Swift 版是同一个中文字面量）。 */
const FALLBACK_TITLE = 'GitHub Copilot 对话'

/** 一条待解析的会话文件。Swift 版是 `private struct ScanTarget`。 */
interface ScanTarget {
  /** `chatSessions/<sid>.jsonl` 或 `emptyWindowChatSessions/<sid>.jsonl` 的绝对路径。 */
  filePath: string
  /** 来自 `workspace.json` 的项目路径；`emptyWindow` 会话恒为 `null`。 */
  projectPath: string | null
  /** 同名 `chatEditingSessions/<sid>/` 快照目录；不存在为 `null`。 */
  editingDirPath: string | null
  /** Copilot 扩展的 transcripts / debug-logs，删会话时要一并带走。 */
  extraPaths: string[]
}

/** Copilot 扩展的 globalStorage 目录名，历史上大小写两种都出现过，两个都要处理。 */
const COPILOT_GLOBAL_DIR_NAMES = ['github.copilot-chat', 'GitHub.copilot-chat'] as const

export class VSCodeChatScanner implements AgentScanner {
  readonly category = 'copilotChat' as const

  /** Swift 版的 `customStorageURL`。测试用它指到夹具目录（`init(storageURL:)`）。 */
  private readonly customStoragePath: string | null

  constructor(options: ScannerOptions = {}) {
    this.customStoragePath = options.storagePath ?? null
  }

  /**
   * 注入目录 > `VSCODE_USER_DATA` > `~/Library/Application Support/Code/User`，
   * 最后做一次 `realpath` 规范化。
   */
  get storagePath(): string {
    if (this.customStoragePath !== null) return canonical(this.customStoragePath)
    return resolveStoragePath(['Library/Application Support/Code/User'], { key: 'VSCODE_USER_DATA' })
  }

  /**
   * 存储目录存在即算已安装；否则退一步看 `~/Library/Application Support/Code`
   * （User 目录被整个删掉、但 app 还在的情况）。
   */
  get isInstalled(): boolean {
    if (pathExists(this.storagePath)) return true
    if (this.customStoragePath !== null) return false
    return pathExists(join(homedir(), 'Library/Application Support/Code'))
  }

  // MARK: - 扫描

  async scan(): Promise<ConversationItem[]> {
    if (!this.isInstalled) return []

    const root = this.storagePath
    const targets: ScanTarget[] = []

    // 1. workspaceStorage/<hash>/chatSessions/*.jsonl
    const workspaceStorageDir = join(root, 'workspaceStorage')
    for (const name of listDirectories(workspaceStorageDir)) {
      const wsDir = join(workspaceStorageDir, name)
      const projectPath = extractProjectPath(join(wsDir, 'workspace.json'))

      const chatSessionsDir = join(wsDir, 'chatSessions')
      const chatEditingDir = join(wsDir, 'chatEditingSessions')
      const copilotTranscriptsDir = join(wsDir, 'GitHub.copilot-chat', 'transcripts')
      const copilotDebugDir = join(wsDir, 'GitHub.copilot-chat', 'debug-logs')

      for (const sessionFile of listFiles(chatSessionsDir, '.jsonl')) {
        const sid = basename(sessionFile, extname(sessionFile))
        const editingPath = join(chatEditingDir, sid)

        const extraPaths: string[] = []
        const transcriptFile = join(copilotTranscriptsDir, `${sid}.jsonl`)
        if (pathExists(transcriptFile)) extraPaths.push(transcriptFile)
        const debugDir = join(copilotDebugDir, sid)
        if (pathExists(debugDir)) extraPaths.push(debugDir)

        targets.push({
          filePath: sessionFile,
          projectPath,
          editingDirPath: pathExists(editingPath) ? editingPath : null,
          extraPaths
        })
      }
    }

    // 2. globalStorage/emptyWindowChatSessions/*.jsonl —— 空窗口起的会话，没有项目
    const emptyWindowDir = join(root, 'globalStorage', 'emptyWindowChatSessions')
    for (const sessionFile of listFiles(emptyWindowDir, '.jsonl')) {
      targets.push({ filePath: sessionFile, projectPath: null, editingDirPath: null, extraPaths: [] })
    }

    if (targets.length === 0) return []

    // Swift 版用 `withTaskGroup` 并发解析；这里解析是纯同步的 CPU/IO，
    // 放进 Promise 不会让它更快，反而多一层 await。循环语义与并发结果一致。
    const items: ConversationItem[] = []
    for (const target of targets) {
      const item = parseSession(target, this.category)
      if (item !== null) items.push(item)
    }
    return sortByUpdatedDesc(items)
  }

  // MARK: - 删除

  async delete(items: ConversationItem[]): Promise<number> {
    if (items.length === 0) return 0

    const root = this.storagePath
    let totalFreed = 0
    /** `state.vscdb` 路径 → 要从索引里删掉的 sessionId。 */
    const stateDbToSessions = new Map<string, Set<string>>()
    const allSessionIds = new Set(items.map((item) => item.sessionId))

    for (const item of items) {
      // 必须在物理删除之前算：路径没了 sizeOf 恒为 0。
      totalFreed += CleanPrefs.freedBytesBeforeDelete(item.sizeInBytes, item)
      // 索引行收集与物理删除分开：state.vscdb / session-store.db 的行是
      // 「会话存在性」的一部分，不受快照开关影响；只有文件删除走 deletionPaths。
      const pathsToDelete = new Set(CleanPrefs.deletionPathsFor(item))
      for (const path of item.associatedPaths) {
        if (path.includes('chatSessions')) {
          const wsDir = dirname(dirname(path))
          addSessionId(stateDbToSessions, join(wsDir, 'state.vscdb'), item.sessionId)
        } else if (path.includes('emptyWindowChatSessions')) {
          addSessionId(
            stateDbToSessions,
            join(root, 'globalStorage', 'state.vscdb'),
            item.sessionId
          )
        }
        if (pathsToDelete.has(path)) removeIfExists(path)
      }
    }

    // 同步清理 state.vscdb 索引，让 VS Code Chat 历史不留幽灵会话。
    // 索引文件不存在 / 打不开时 `removeChatSessions` 静默返回，文件删除照常成功。
    for (const [dbPath, sessionIds] of stateDbToSessions) {
      removeChatSessions(dbPath, sessionIds)
    }

    // Copilot Chat 的 session-store.db 里还有一份同 id 的记录，一并清掉。
    for (const dirName of COPILOT_GLOBAL_DIR_NAMES) {
      const dbPath = join(root, 'globalStorage', dirName, 'session-store.db')
      if (pathExists(dbPath)) removeCopilotSessionStore(dbPath, allSessionIds)
    }

    cleanEmptyWorkspaceStorageDirs(root)
    return totalFreed
  }

  // MARK: - 全部清空

  async cleanAll(): Promise<number> {
    const items = await this.scan()
    let freed = await this.delete(items)

    const root = this.storagePath

    // workspaceStorage/<hash>/ 下的 chatSessions / chatEditingSessions / 扩展目录 + 索引
    const workspaceStorageDir = join(root, 'workspaceStorage')
    for (const name of listDirectories(workspaceStorageDir)) {
      const wsDir = join(workspaceStorageDir, name)

      freed += removeAndCount(join(wsDir, 'chatSessions'))
      if (CleanPrefs.cleanFileHistorySnapshots) {
        freed += removeAndCount(join(wsDir, 'chatEditingSessions'))
      }
      freed += removeAndCount(join(wsDir, 'GitHub.copilot-chat'))

      const stateDb = join(wsDir, 'state.vscdb')
      if (pathExists(stateDb)) clearAllChatSessions(stateDb)
    }

    // emptyWindowChatSessions：整目录删掉后原样建回来（IDE 下次要能直接写）
    const emptyWindowDir = join(root, 'globalStorage', 'emptyWindowChatSessions')
    freed += removeAndCount(emptyWindowDir, true)

    // globalStorage/state.vscdb 里的聊天索引
    const globalStateDb = join(root, 'globalStorage', 'state.vscdb')
    if (pathExists(globalStateDb)) clearAllChatSessions(globalStateDb)

    // globalStorage/github.copilot-chat（两种大小写）：索引库 + 缓存 + 会话目录
    for (const dirName of COPILOT_GLOBAL_DIR_NAMES) {
      const copilotGlobal = join(root, 'globalStorage', dirName)
      if (!pathExists(copilotGlobal)) continue

      const sessionStore = join(copilotGlobal, 'session-store.db')
      if (pathExists(sessionStore)) clearCopilotSessionStore(sessionStore)

      for (const fileName of [
        'session-store.db',
        'session-store.db-shm',
        'session-store.db-wal',
        'toolEmbeddingsCache.bin'
      ]) {
        freed += removeAndCount(join(copilotGlobal, fileName))
      }

      // vscode-sessions-* / copilot-cli-images 目录。
      // Swift 版没有判断条目类型，文件与目录一视同仁，这里照抄。
      for (const name of [...listDirectories(copilotGlobal), ...listFiles(copilotGlobal)]) {
        const entryName = basename(name)
        if (entryName.startsWith('vscode-sessions-') || entryName === 'copilot-cli-images') {
          freed += removeAndCount(join(copilotGlobal, entryName))
        }
      }
    }

    cleanEmptyWorkspaceStorageDirs(root)
    return freed
  }
}

// MARK: - 解析

/**
 * 解析一条 `.jsonl` 会话文件。
 *
 * Copilot 的会话文件是**增量日志**：首行 `kind:0` 是全量快照，之后是
 * `kind:1`（属性更新）与 `kind:2`（数组追加）。任何一行无法解析就跳过 ——
 * Agent 正在写文件时半截行是常态。
 */
function parseSession(target: ScanTarget, category: 'copilotChat'): ConversationItem | null {
  if (!pathExists(target.filePath)) return null

  const mainFileSize = fileSize(target.filePath)
  const modMs = mtimeMs(target.filePath)
  const fallbackBaseName = basename(target.filePath, extname(target.filePath))

  let detectedSessionId: string | null = null
  let detectedCreationDateMs: number | null = null
  let detectedCustomTitle: string | null = null
  let firstUserPrompt: string | null = null
  let requestCount = 0

  for (const raw of readJsonLines(target.filePath)) {
    const json = asRecord(raw)
    if (json === null) continue

    const kind = asNumber(json['kind'])
    const k = Array.isArray(json['k']) ? (json['k'] as unknown[]) : null
    const v = json['v']

    // 1. 初始快照 / 全量状态：kind == 0
    if (kind === 0) {
      const vDict = asRecord(v)
      if (vDict !== null) {
        const sid = asString(vDict['sessionId'])
        if (sid !== null && sid.length > 0) detectedSessionId = sid
        const cd = asNumber(vDict['creationDate'])
        if (cd !== null) detectedCreationDateMs = cd
        const ct = asString(vDict['customTitle'])
        if (ct !== null && ct.length > 0) detectedCustomTitle = ct
        const reqs = asRecordArray(vDict['requests'])
        if (reqs !== null) {
          requestCount += reqs.length
          for (const req of reqs) {
            if (firstUserPrompt === null) firstUserPrompt = extractPromptText(req)
          }
        }
      }
    }
    // 2. 属性更新：kind == 1
    else if (kind === 1) {
      const kFirst = asString(k?.[0])
      const str = asString(v)
      if (kFirst === 'customTitle' && str !== null && str.length > 0) detectedCustomTitle = str
      else if (kFirst === 'sessionId' && str !== null && str.length > 0) detectedSessionId = str
    }
    // 3. 数组追加：kind == 2
    else if (kind === 2) {
      if (k !== null && k.length === 1 && asString(k[0]) === 'requests') {
        const reqs = asRecordArray(v)
        if (reqs !== null) {
          requestCount += reqs.length
          for (const req of reqs) {
            if (firstUserPrompt === null) firstUserPrompt = extractPromptText(req)
          }
        }
      }
    }

    // 非增量格式（每行都是完整状态）的兜底
    if (detectedSessionId === null) {
      const sid = asString(json['sessionId'])
      if (sid !== null && sid.length > 0) detectedSessionId = sid
    }
    if (detectedCreationDateMs === null) {
      const cd = asNumber(json['creationDate'])
      if (cd !== null) detectedCreationDateMs = cd
    }
    if (firstUserPrompt === null) {
      const reqs = asRecordArray(json['requests'])
      if (reqs !== null) {
        for (const req of reqs) {
          if (firstUserPrompt === null) firstUserPrompt = extractPromptText(req)
        }
      }
    }
  }

  const sessionId = detectedSessionId ?? fallbackBaseName

  // 标题：首条用户提问 > customTitle > 兜底文案
  const finalTitle =
    firstUserPrompt !== null && firstUserPrompt.length > 0
      ? orFallback(firstLine(firstUserPrompt), FALLBACK_TITLE, 80)
      : detectedCustomTitle !== null && detectedCustomTitle.length > 0
        ? orFallback(firstLine(detectedCustomTitle), FALLBACK_TITLE, 80)
        : FALLBACK_TITLE

  const snippet =
    firstUserPrompt !== null && firstUserPrompt.length > 0
      ? trimSpaces(firstUserPrompt.replace(/\n/g, ' ')).slice(0, 160)
      : finalTitle

  // 时间：会话自报的创建时间 > 文件 mtime > 现在
  const updatedAt =
    detectedCreationDateMs !== null && detectedCreationDateMs > 0
      ? new Date(detectedCreationDateMs)
      : modMs !== undefined
        ? new Date(modMs)
        : new Date()

  // associatedPaths：主文件 + 同名 chatEditingSessions + Copilot 扩展产物
  const associatedPaths = [target.filePath]
  let totalSize = mainFileSize
  if (target.editingDirPath !== null && pathExists(target.editingDirPath)) {
    associatedPaths.push(target.editingDirPath)
    totalSize += sizeOfPath(target.editingDirPath)
  }
  for (const extraPath of target.extraPaths) {
    if (!pathExists(extraPath)) continue
    associatedPaths.push(extraPath)
    totalSize += sizeOfPath(extraPath)
  }

  return makeItem({
    sessionId,
    title: finalTitle,
    category,
    projectPath: target.projectPath,
    gitBranch: null,
    messageCount: requestCount,
    sizeInBytes: totalSize,
    updatedAt,
    snippet,
    associatedPaths
  })
}

/** 从一条 request 里挖出用户提问文本，兼容 Copilot 历史上的 4 种字段名。 */
function extractPromptText(req: Record<string, unknown>): string | null {
  const message = asRecord(req['message'])
  if (message !== null) {
    const text = asString(message['text'])
    if (text !== null) {
      const trimmed = text.trim()
      if (trimmed.length > 0) return trimmed
    }
    const parts = message['parts']
    if (Array.isArray(parts)) {
      let combined = ''
      for (const part of parts) {
        const record = asRecord(part)
        const partText = record === null ? null : asString(record['text'])
        if (partText !== null) combined += partText
      }
      const trimmed = combined.trim()
      if (trimmed.length > 0) return trimmed
    }
    return null
  }

  const messageString = asString(req['message'])
  if (messageString !== null) {
    const trimmed = messageString.trim()
    if (trimmed.length > 0) return trimmed
    return null
  }

  for (const field of ['text', 'prompt'] as const) {
    const value = asString(req[field])
    if (value === null) continue
    const trimmed = value.trim()
    if (trimmed.length > 0) return trimmed
  }
  return null
}

/** `workspace.json` → 项目路径。`file://` URI 会被还原成普通路径。 */
function extractProjectPath(workspaceJsonPath: string): string | null {
  let json: unknown
  try {
    // workspace.json 很小，直接读文本更省一次中间对象。
    json = JSON.parse(readFileSync(workspaceJsonPath, 'utf8'))
  } catch {
    return null
  }
  const dict = asRecord(json)
  if (dict === null) return null
  const uriString = asString(dict['folder']) ?? asString(dict['workspace'])
  if (uriString === null) return null
  if (!uriString.startsWith('file://')) return uriString
  try {
    return decodeURI(new URL(uriString).pathname)
  } catch {
    const stripped = uriString.slice('file://'.length)
    try {
      return decodeURI(stripped)
    } catch {
      return stripped
    }
  }
}

// MARK: - 小工具

function addSessionId(
  map: Map<string, Set<string>>,
  dbPath: string,
  sessionId: string
): void {
  const bucket = map.get(dbPath)
  if (bucket) bucket.add(sessionId)
  else map.set(dbPath, new Set([sessionId]))
}

/** 删掉一个路径并返回释放的字节数；不存在返回 0。`recreate` 时删完原样建回来。 */
function removeAndCount(path: string, recreate = false): number {
  if (!pathExists(path)) return 0
  const size = sizeOfPath(path)
  if (!removeIfExists(path)) return 0
  if (recreate) {
    try {
      mkdirSync(path, { recursive: true })
    } catch {
      // 建不回来也不该让整次清理失败
    }
  }
  return size
}

/** `realpath` 规范化；路径不存在时退回 `resolve` 的标准化结果（对齐 Swift 的 `.standardized`）。 */
function canonical(path: string): string {
  const normalized = resolve(path)
  try {
    return realpathSync(normalized)
  } catch {
    return normalized
  }
}

/** `components(separatedBy: .newlines).first` —— 取第一行。 */
function firstLine(text: string): string {
  const index = text.search(/\r\n|[\n\r\u0085\u2028\u2029]/)
  return index === -1 ? text : text.slice(0, index)
}

/** `trimmingCharacters(in: .whitespaces)` —— 只去空格/制表符，保留换行。 */
function trimSpaces(text: string): string {
  return text.replace(/^[^\S\r\n]+|[^\S\r\n]+$/g, '')
}

function orFallback(text: string, fallback: string, limit: number): string {
  return text.length === 0 ? fallback : text.slice(0, limit)
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

/** Swift 的 `as? [[String: Any]]`：只要有一个元素不是字典，整个转换就失败。 */
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
