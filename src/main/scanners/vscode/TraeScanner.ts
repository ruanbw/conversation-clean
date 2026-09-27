import { mkdirSync, readdirSync, realpathSync } from 'node:fs'
import { basename, dirname, extname, join } from 'node:path'
import type { ConversationItem } from '@shared/types'
import type { AgentScanner, ScannerOptions } from '@main/core/scanner'
import {
  fileSize,
  listDirectories,
  listFiles,
  makeItem,
  mtimeMs,
  pathExists,
  readJson,
  readJsonLines,
  resolveStoragePath,
  sortByUpdatedDesc
} from '@main/core/scanner'
import { CleanPrefs } from '@main/core/prefs'
import {
  cleanEmptyWorkspaceStorageDirs,
  removeIfExists,
  sizeOfPath
} from '@main/core/fsutil'
import { clearAllChatSessions, removeChatSessions } from '@main/core/vscdb'

/**
 * Trae 会话扫描器。
 *
 * 数据根：`TRAE_HOME` > `~/Library/Application Support/Trae`（测试可注入）。
 *
 * Trae 的会话布局和 Windsurf 几乎一致（同一套 VS Code 内核），但**没有** `~/.codeium`
 * 那一层 Cascade 数据，相应地：
 *
 * 1. `User/workspaceStorage/<hash>/chatSessions/*.jsonl`（+ 同名 `chatEditingSessions/<sid>/` 快照）
 * 2. `User/globalStorage/emptyWindowChatSessions/*.jsonl`
 *
 * `state.vscdb` 同样不在 scan 里读，只在 delete / cleanAll 里清 9 个索引 key。
 * 少了索引同步，Trae 的历史面板会一直显示点进去是空的幽灵会话。
 */
export class TraeScanner implements AgentScanner {
  readonly category = 'trae' as const

  /** 测试注入的数据根；为 `null` 时走环境变量 / 默认目录。 */
  private readonly custom: string | null

  constructor(options: ScannerOptions = {}) {
    this.custom = options.storagePath ?? null
  }

  /**
   * 数据根目录：注入目录 > `TRAE_HOME` > `~/Library/Application Support/Trae`，
   * 再做一次 realpath 规范化（`/var` → `/private/var` 这类别名不解析）。
   */
  get storagePath(): string {
    if (this.custom !== null) return canonical(this.custom)
    return resolveStoragePath(['Library', 'Application Support', 'Trae'], { key: 'TRAE_HOME' })
  }

  /**
   * `User/` 子目录。
   *
   * Trae 新版把数据直接摊在 userData 根上：`User/` 存在用 `User/`；
   * 否则根下有 `workspaceStorage/` 就用根；都没有则仍按 `User/` 算。
   */
  private get userDirectory(): string {
    const directUser = join(this.storagePath, 'User')
    const directWS = join(this.storagePath, 'workspaceStorage')
    if (pathExists(directUser)) return directUser
    if (pathExists(directWS)) return this.storagePath
    return directUser
  }

    /** 已安装判定：只看数据根目录存不存在，不查别的位置。 */
  get isInstalled(): boolean {
    return pathExists(this.storagePath)
  }

  // MARK: - Scan

  async scan(): Promise<ConversationItem[]> {
    if (!this.isInstalled) return []

    const items: ConversationItem[] = []
    const userDir = this.userDirectory
    const workspaceStorageDir = join(userDir, 'workspaceStorage')

    // 1. User/workspaceStorage/<hash>/chatSessions/*.jsonl
    const targets: ScanTarget[] = []
    for (const wsName of listDirectories(workspaceStorageDir)) {
      const wsDir = join(workspaceStorageDir, wsName)
      const projectPath = extractProjectPath(join(wsDir, 'workspace.json'))

      const chatSessionsDir = join(wsDir, 'chatSessions')
      const chatEditingDir = join(wsDir, 'chatEditingSessions')
      for (const sessionFile of listFiles(chatSessionsDir, '.jsonl')) {
        const sid = basenameWithoutExtension(sessionFile)
        const editingURL = join(chatEditingDir, sid)
        targets.push({
          filePath: sessionFile,
          projectPath,
          editingDir: pathExists(editingURL) ? editingURL : null
        })
      }
    }
    for (const target of targets) {
      const item = parseJsonlSession(target)
      if (item !== null) items.push(item)
    }

    // 2. User/globalStorage/emptyWindowChatSessions/*.jsonl
    const emptyWindowDir = join(userDir, 'globalStorage', 'emptyWindowChatSessions')
    for (const sessionFile of listFiles(emptyWindowDir, '.jsonl')) {
      const item = parseJsonlSession({ filePath: sessionFile, projectPath: null, editingDir: null })
      if (item !== null) items.push(item)
    }

    return sortByUpdatedDesc(items)
  }

  // MARK: - Delete & Clean

  async delete(items: ConversationItem[]): Promise<number> {
    if (items.length === 0) return 0

    const userDir = this.userDirectory
    let totalFreed = 0
    const stateDbToSessions = new Map<string, Set<string>>()
    const allSessionIds = new Set(items.map((item) => item.sessionId))

    for (const item of items) {
      totalFreed += CleanPrefs.freedBytesBeforeDelete(item.sizeInBytes, item)

      // state.vscdb 的索引行不属于快照，**始终**跟着删；只有文件删除受开关控制。
      const pathsToDelete = new Set(CleanPrefs.deletionPathsFor(item))
      for (const path of item.associatedPaths) {
        if (path.includes('chatSessions')) {
          // <userDir>/workspaceStorage/<hash>/chatSessions/<sid>.jsonl → <hash>/state.vscdb
          const stateDbURL = join(dirname(dirname(path)), 'state.vscdb')
          addSession(stateDbToSessions, stateDbURL, item.sessionId)
        } else if (path.includes('emptyWindowChatSessions')) {
          const globalDb = join(userDir, 'globalStorage', 'state.vscdb')
          addSession(stateDbToSessions, globalDb, item.sessionId)
        }

        if (pathsToDelete.has(path)) removeIfExists(path)
      }
    }

    // 逐个 workspace 精确同步
    for (const [stateDbURL, sessionIds] of stateDbToSessions) {
      removeChatSessions(stateDbURL, sessionIds)
    }

    // 剩下没被关联到的 state.vscdb 也用全部被删 sessionId 扫一遍
    const workspaceStorageDir = join(userDir, 'workspaceStorage')
    for (const wsName of listDirectories(workspaceStorageDir)) {
      const stateDbURL = join(workspaceStorageDir, wsName, 'state.vscdb')
      if (pathExists(stateDbURL) && !stateDbToSessions.has(stateDbURL)) {
        removeChatSessions(stateDbURL, allSessionIds)
      }
    }
    const globalStateDb = join(userDir, 'globalStorage', 'state.vscdb')
    if (pathExists(globalStateDb) && !stateDbToSessions.has(globalStateDb)) {
      removeChatSessions(globalStateDb, allSessionIds)
    }

    cleanEmptyWorkspaceStorageDirs(userDir)

    return totalFreed
  }

  async cleanAll(): Promise<number> {
    const items = await this.scan()
    let freed = await this.delete(items)

    const userDir = this.userDirectory
    const workspaceStorageDir = join(userDir, 'workspaceStorage')

    // workspaceStorage/<hash>/ 下的 chatSessions、chatEditingSessions 与索引
    for (const wsName of listDirectories(workspaceStorageDir)) {
      const wsDir = join(workspaceStorageDir, wsName)

      const chatDir = join(wsDir, 'chatSessions')
      if (pathExists(chatDir)) {
        const sz = sizeOfPath(chatDir)
        if (removeIfExists(chatDir)) freed += sz
      }

      const editDir = join(wsDir, 'chatEditingSessions')
      if (CleanPrefs.cleanFileHistorySnapshots && pathExists(editDir)) {
        const sz = sizeOfPath(editDir)
        if (removeIfExists(editDir)) freed += sz
      }

      const stateDb = join(wsDir, 'state.vscdb')
      if (pathExists(stateDb)) clearAllChatSessions(stateDb)
    }

    // globalStorage/emptyWindowChatSessions：删完**建回来**，Trae 运行时不能缺这个目录。
    const globalStorageDir = join(userDir, 'globalStorage')
    const emptyWindowDir = join(globalStorageDir, 'emptyWindowChatSessions')
    if (pathExists(emptyWindowDir)) {
      const sz = sizeOfPath(emptyWindowDir)
      if (removeIfExists(emptyWindowDir)) {
        freed += sz
        createDirectory(emptyWindowDir)
      }
    }

    const globalStateDb = join(globalStorageDir, 'state.vscdb')
    if (pathExists(globalStateDb)) clearAllChatSessions(globalStateDb)

    // globalStorage 下 Trae 扩展自己的缓存目录：名字里带 trae / chat 的统统清掉再建回来。
    //
    // 已知问题：这一段跑在 emptyWindowChatSessions 被重建**之后**，
    // 而 `emptywindowchatsessions` 名字里含 "chat"，所以它会被再删一次再重建一次
    // （第二次 size 为 0，不影响统计，只是多一轮 IO）。不修是因为修它要改
    // cleanAll 的分段顺序，风险大于收益。
    for (const entry of listAllEntries(globalStorageDir)) {
      const name = basename(entry).toLowerCase()
      if (!name.includes('trae') && !name.includes('chat')) continue
      const sz = sizeOfPath(entry)
      if (removeIfExists(entry)) {
        freed += sz
        createDirectory(entry)
      }
    }

    cleanEmptyWorkspaceStorageDirs(userDir)

    return freed
  }
}

// MARK: - 类型

interface ScanTarget {
  filePath: string
  projectPath: string | null
  editingDir: string | null
}

// MARK: - 通用小工具（与 Windsurf 版逐字重复，两份是刻意各留一份的）

function canonical(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** `??` 语义：取第一个**是字符串**的值（允许空串，空串的判空交给调用方）。 */
function firstString(...values: unknown[]): string | null {
  for (const value of values) if (typeof value === 'string') return value
  return null
}

/** 取非空字符串（sessionId / customTitle 都要求非空，空串当没有）。 */
function nonEmptyString(value: unknown): string | null {
  return typeof value === 'string' && value.length > 0 ? value : null
}

function asNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

/** 取「数组里的每一项都是对象」的值；有一项不是就整体当 null。 */
function asRecordArray(value: unknown): Record<string, unknown>[] | null {
  if (!Array.isArray(value)) return null
  for (const element of value) if (!isRecord(element)) return null
  return value as Record<string, unknown>[]
}

/** `deletingPathExtension().lastPathComponent` */
function basenameWithoutExtension(path: string): string {
  return basename(path, extname(path))
}

/** `components(separatedBy: .newlines).first` + 去首尾空白。 */
function firstLine(text: string): string {
  const parts = text.split(/\r\n|[\n\r\v\f\u2028\u2029]/)
  return (parts[0] ?? text).trim()
}

/** `URL.path` 是**已解码**的路径，`new URL().pathname` 不是。 */
function decodedPathname(url: URL): string {
  try {
    return decodeURIComponent(url.pathname)
  } catch {
    return url.pathname
  }
}

/** 目录枚举（跳过隐藏项），文件与子目录都返回，保持 readdir 原始顺序。 */
function listAllEntries(path: string): string[] {
  try {
    return readdirSync(path, { withFileTypes: true })
      .filter((entry) => !entry.name.startsWith('.'))
      .map((entry) => join(path, entry.name))
  } catch {
    return []
  }
}

function createDirectory(path: string): void {
  try {
    mkdirSync(path, { recursive: true })
  } catch {
    // 建不回来也不让整个 cleanAll 失败。
  }
}

function addSession(map: Map<string, Set<string>>, key: string, sessionId: string): void {
  const existing = map.get(key)
  if (existing) existing.add(sessionId)
  else map.set(key, new Set([sessionId]))
}

// MARK: - JSONL 解析

/**
 * 解析一条 Trae 会话正文。
 *
 * 字段优先级：首条用户提示 > 自定义标题 > `"Trae 对话"`；
 * 摘要 = 首条用户提示（换行压成空格）> 标题；
 * 时间 = `creationDate`（epoch 毫秒，> 0）> 文件 mtime > 此刻。
 */
function parseJsonlSession(target: ScanTarget): ConversationItem | null {
  if (!pathExists(target.filePath)) return null

  const mainFileSize = fileSize(target.filePath)
  const fallbackBaseName = basenameWithoutExtension(target.filePath)

  let detectedSessionId: string | null = null
  let detectedCreationDateMs: number | null = null
  let detectedCustomTitle: string | null = null
  let firstUserPrompt: string | null = null
  let requestCount = 0

  for (const line of readJsonLines<unknown>(target.filePath)) {
    if (!isRecord(line)) continue

    const kind = line['kind']
    const k = line['k']
    const v = line['v']

    if (kind === 0) {
      if (isRecord(v)) {
        const sid = nonEmptyString(v['sessionId'])
        if (sid !== null) detectedSessionId = sid
        const cd = asNumber(v['creationDate'])
        if (cd !== null) detectedCreationDateMs = cd
        const ct = nonEmptyString(v['customTitle'])
        if (ct !== null) detectedCustomTitle = ct
        const requests = asRecordArray(v['requests'])
        if (requests !== null) {
          requestCount += requests.length
          for (const request of requests) {
            if (firstUserPrompt === null) firstUserPrompt = extractPromptText(request)
          }
        }
      }
    } else if (kind === 1) {
      const kFirst = Array.isArray(k) ? nonEmptyString(k[0]) : null
      if (kFirst === 'customTitle') {
        const str = nonEmptyString(v)
        if (str !== null) detectedCustomTitle = str
      } else if (kFirst === 'sessionId') {
        const str = nonEmptyString(v)
        if (str !== null) detectedSessionId = str
      }
    } else if (kind === 2) {
      const requests = Array.isArray(k) && k.length === 1 && k[0] === 'requests'
        ? asRecordArray(v)
        : null
      if (requests !== null) {
        requestCount += requests.length
        for (const request of requests) {
          if (firstUserPrompt === null) firstUserPrompt = extractPromptText(request)
        }
      }
    }

    // 顶层字段兜底：只填「还没定下来」的，不覆盖上面已解析到的值
    if (detectedSessionId === null) {
      const sid = nonEmptyString(line['sessionId'])
      if (sid !== null) detectedSessionId = sid
    }
    if (detectedCreationDateMs === null) {
      const cd = asNumber(line['creationDate'])
      if (cd !== null) detectedCreationDateMs = cd
    }
  }

  const sessionId = detectedSessionId ?? fallbackBaseName

  let finalTitle: string
  if (firstUserPrompt !== null && firstUserPrompt.length > 0) {
    const single = firstLine(firstUserPrompt)
    finalTitle = single.length === 0 ? 'Trae 对话' : single.slice(0, 80)
  } else if (detectedCustomTitle !== null && detectedCustomTitle.length > 0) {
    const single = firstLine(detectedCustomTitle)
    finalTitle = single.length === 0 ? 'Trae 对话' : single.slice(0, 80)
  } else {
    finalTitle = 'Trae 对话'
  }

  const snippet =
    firstUserPrompt !== null && firstUserPrompt.length > 0
      ? firstUserPrompt.replace(/\n/g, ' ').trim().slice(0, 160)
      : finalTitle

  const updatedAt =
    detectedCreationDateMs !== null && detectedCreationDateMs > 0
      ? new Date(detectedCreationDateMs)
      : new Date(mtimeMs(target.filePath) ?? Date.now())

  const associatedPaths: string[] = [target.filePath]
  let totalSize = mainFileSize
  if (target.editingDir !== null && pathExists(target.editingDir)) {
    associatedPaths.push(target.editingDir)
    totalSize += sizeOfPath(target.editingDir)
  }

  return makeItem({
    sessionId,
    title: finalTitle,
    category: 'trae',
    projectPath: target.projectPath,
    gitBranch: null,
    messageCount: requestCount,
    sizeInBytes: totalSize,
    updatedAt,
    snippet,
    associatedPaths
  })
}

/** 从一条 request 里取用户提示文本；`message.text` > 拼接 `message.parts` > `message` 本身。 */
function extractPromptText(req: Record<string, unknown>): string | null {
  const message = req['message']
  if (isRecord(message)) {
    const text = message['text']
    if (typeof text === 'string') {
      const trimmed = text.trim()
      if (trimmed.length > 0) return trimmed
    }
    const parts = message['parts']
    if (Array.isArray(parts)) {
      let combined = ''
      for (const part of parts) {
        if (isRecord(part) && typeof part['text'] === 'string') combined += part['text']
      }
      const trimmed = combined.trim()
      if (trimmed.length > 0) return trimmed
    }
  } else if (typeof message === 'string') {
    const trimmed = message.trim()
    if (trimmed.length > 0) return trimmed
  }

  const text = req['text']
  if (typeof text === 'string') {
    const trimmed = text.trim()
    if (trimmed.length > 0) return trimmed
  }

  const prompt = req['prompt']
  if (typeof prompt === 'string') {
    const trimmed = prompt.trim()
    if (trimmed.length > 0) return trimmed
  }

  return null
}

/** `workspace.json` 里的 `folder` / `workspace` → 项目路径（`file://` 会解码成裸路径）。 */
function extractProjectPath(workspaceJSONPath: string): string | null {
  const json = readJson<unknown>(workspaceJSONPath)
  if (!isRecord(json)) return null
  const uriString = firstString(json['folder'], json['workspace'])
  if (uriString === null) return null
  if (uriString.startsWith('file://')) {
    try {
      return decodedPathname(new URL(uriString))
    } catch {
      const stripped = uriString.slice(7)
      try {
        return decodeURIComponent(stripped)
      } catch {
        return stripped
      }
    }
  }
  return uriString
}
