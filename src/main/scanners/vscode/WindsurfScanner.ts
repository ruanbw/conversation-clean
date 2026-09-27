import { mkdirSync, readdirSync, realpathSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, dirname, extname, join } from 'node:path'
import type { ConversationItem } from '@shared/types'
import type { AgentScanner, ScannerOptions } from '@main/core/scanner'
import {
  fileSize,
  isDirectory,
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
  removeIfEmptyDirectory,
  removeIfExists,
  sizeOfPath
} from '@main/core/fsutil'
import { clearAllChatSessions, removeChatSessions } from '@main/core/vscdb'

/**
 * Windsurf 会话扫描器。
 *
 * 数据根：`WINDSURF_HOME` > `~/Library/Application Support/Windsurf`（测试可注入）。
 *
 * Windsurf 的会话分**三个来源**，扫描时按这个顺序分三段扫、然后合并去重：
 *
 * 1. `User/workspaceStorage/<hash>/chatSessions/*.jsonl`
 *    —— 工作区会话正文；同名的 `chatEditingSessions/<sid>/` 是文件改动快照。
 * 2. `User/globalStorage/emptyWindowChatSessions/*.jsonl`
 *    —— 没有工作区的「空窗口」会话，没有项目路径。
 * 3. `~/.codeium/windsurf/{cascades,cascade,chats}/`
 *    —— Codeium CLI 侧的 Cascade 会话，每个一个目录或一个 `.json`。
 *
 * `state.vscdb` **不在 scan 里读**：它只是 delete 时的清理目标。
 * 索引行留着，Windsurf 的聊天下拉框就会一直显示「点进去是空的」的幽灵会话，
 * 所以 `delete` / `cleanAll` 必须把 9 个索引 key 一起改掉（`core/vscdb.ts` 已经全包了）。
 */
export class WindsurfScanner implements AgentScanner {
  readonly category = 'windsurf' as const

  /** 测试注入的数据根；为 `null` 时走环境变量 / 默认目录。 */
  private readonly custom: string | null

  constructor(options: ScannerOptions = {}) {
    this.custom = options.storagePath ?? null
  }

  /**
   * 数据根目录：注入目录 > `WINDSURF_HOME` > `~/Library/Application Support/Windsurf`，
   * 再做一次 realpath 规范化（`/var` → `/private/var` 这类别名不解析，
   * 侧栏显示的路径会跟 Finder 里点开的不一致）。
   */
  get storagePath(): string {
    if (this.custom !== null) return canonical(this.custom)
    return resolveStoragePath(['Library', 'Application Support', 'Windsurf'], { key: 'WINDSURF_HOME' })
  }

  /**
   * `User/` 子目录。
   *
   * Windsurf 新版把数据直接摊在 userData 根上（没有 `User/` 一层），
   * 所以：`User/` 存在用 `User/`；否则根下有 `workspaceStorage/` 就用根；都没有则仍按 `User/` 算。
   */
  private get userDirectory(): string {
    const directUser = join(this.storagePath, 'User')
    const directWS = join(this.storagePath, 'workspaceStorage')
    if (pathExists(directUser)) return directUser
    if (pathExists(directWS)) return this.storagePath
    return directUser
  }

  /**
   * Codeium CLI 的数据目录。
   *
   * 注入目录时先找 `<custom>/.codeium/windsurf`、再找 `<custom>/codeium/windsurf`；
   * 都找不到（或没注入）就一律回落到 `~/.codeium/windsurf`。
   *
   * 已知风险：注入目录下没有 `.codeium/windsurf` 时会回落到**真实的**
   * `~/.codeium/windsurf`，于是夹具的 `delete` / `cleanAll` 可能去动用户真目录。
   * 写单测时必须在夹具里建一个 `.codeium/windsurf`。
   */
  private get codeiumWindsurfDirectory(): string {
    if (this.custom !== null) {
      const candidate1 = join(this.custom, '.codeium', 'windsurf')
      if (pathExists(candidate1)) return candidate1
      const candidate2 = join(this.custom, 'codeium', 'windsurf')
      if (pathExists(candidate2)) return candidate2
    }
    return canonical(join(homedir(), '.codeium', 'windsurf'))
  }

  /**
   * 已安装判定：数据根目录存在即可。
   *
   * 没注入目录时（真实用户场景）额外看一眼 `~/.codeium/windsurf` ——
   * 只装了 Codeium CLI、没跑过 IDE 的机器上这是唯一的数据痕迹。
   * 注入了目录就只看目录本身，不去翻用户真实的 `~`。
   */
  get isInstalled(): boolean {
    if (pathExists(this.storagePath)) return true
    if (this.custom !== null) return false
    return pathExists(join(homedir(), '.codeium', 'windsurf'))
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

    // 3. ~/.codeium/windsurf/ 下的 Cascade 会话
    const codeiumDir = this.codeiumWindsurfDirectory
    if (pathExists(codeiumDir)) items.push(...scanCodeiumWindsurfDirectory(codeiumDir))

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

        if (!pathsToDelete.has(path)) continue
        if (!pathExists(path)) continue

        const wasDirectory = isDirectory(path)
        removeIfExists(path)

        // Cascade 是「一个会话一个目录」的结构，删掉里面的文件后顺手回收空的父目录。
        if (!wasDirectory) {
          const parentDir = dirname(path)
          const metaFile = join(parentDir, 'meta.json')
          const cascadeFile = join(parentDir, 'cascade.json')
          if (!pathExists(metaFile) && !pathExists(cascadeFile)) {
            removeIfEmptyDirectory(parentDir)
          }
        }
      }

      // 标准 Cascade 存储位置：会话正文可能只剩一个目录或一个 <sid>.json，
      // 上面那圈 associatedPaths 未必覆盖得到，这里按 sessionId 再兜一次。
      const codeiumDir = this.codeiumWindsurfDirectory
      for (const sub of CASCADE_FOLDERS) {
        const cascadeDir = join(codeiumDir, sub, item.sessionId)
        if (pathExists(cascadeDir)) removeIfExists(cascadeDir)
        const cascadeJSONFile = join(codeiumDir, sub, `${item.sessionId}.json`)
        if (pathExists(cascadeJSONFile)) removeIfExists(cascadeJSONFile)
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

    // globalStorage/emptyWindowChatSessions：删完**建回来**，Windsurf 运行时不能缺这个目录。
    const emptyWindowDir = join(userDir, 'globalStorage', 'emptyWindowChatSessions')
    if (pathExists(emptyWindowDir)) {
      const sz = sizeOfPath(emptyWindowDir)
      if (removeIfExists(emptyWindowDir)) {
        freed += sz
        createDirectory(emptyWindowDir)
      }
    }

    const globalStateDb = join(userDir, 'globalStorage', 'state.vscdb')
    if (pathExists(globalStateDb)) clearAllChatSessions(globalStateDb)

    // ~/.codeium/windsurf 下的 cascades / chats / memories / cascade，同样删完建回来
    const codeiumDir = this.codeiumWindsurfDirectory
    for (const sub of CODEIUM_CLEAN_FOLDERS) {
      const subPath = join(codeiumDir, sub)
      if (pathExists(subPath)) {
        const sz = sizeOfPath(subPath)
        if (removeIfExists(subPath)) {
          freed += sz
          createDirectory(subPath)
        }
      }
    }

    cleanEmptyWorkspaceStorageDirs(userDir)

    return freed
  }
}

// MARK: - 类型与常量

interface ScanTarget {
  filePath: string
  projectPath: string | null
  editingDir: string | null
}

/** Cascade 会话目录的三种叫法（历史版本叫法不统一，三个都扫）。 */
const CASCADE_FOLDERS = ['cascades', 'cascade', 'chats'] as const

/** cleanAll 额外清的四类（比扫描的三类多一个 `memories`）。 */
const CODEIUM_CLEAN_FOLDERS = ['cascades', 'chats', 'memories', 'cascade'] as const

/** Cascade 目录里可能承载元数据的三个文件名，按优先级。 */
const CASCADE_META_FILES = ['meta.json', 'cascade.json', 'session.json'] as const

// MARK: - 通用小工具（与 Trae 版逐字重复，两份是刻意各留一份的）

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
 * 解析一条 Windsurf 会话正文。
 *
 * 字段优先级：首条用户提示 > 自定义标题 > `"Windsurf 对话"`；
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
    finalTitle = single.length === 0 ? 'Windsurf 对话' : single.slice(0, 80)
  } else if (detectedCustomTitle !== null && detectedCustomTitle.length > 0) {
    const single = firstLine(detectedCustomTitle)
    finalTitle = single.length === 0 ? 'Windsurf 对话' : single.slice(0, 80)
  } else {
    finalTitle = 'Windsurf 对话'
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
    category: 'windsurf',
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

// MARK: - Codeium Windsurf 目录

/**
 * 扫 `~/.codeium/windsurf/{cascades,cascade,chats}/`。
 *
 * 一个条目 = 一个会话：目录形态读 `meta.json` / `cascade.json` / `session.json`，
 * 文件形态读条目自己的 `.json`。都没有标题时回落到 `Windsurf Cascade 会话 <sid 前 8 位>`。
 *
 * 已知问题：命中了元数据文件但里面既没有 `title` 也没有 `prompt`/`name` 时，
 * 标题会退化成空字符串（该分支没有 JSONL 那句 `length === 0` 兜底），UI 上会显示一条空标题。
 * 不修是因为修它要改标题构造的全部分支，收益只是一条罕见数据的显示效果。
 */
function scanCodeiumWindsurfDirectory(codeiumDir: string): ConversationItem[] {
  const items: ConversationItem[] = []

  for (const sub of CASCADE_FOLDERS) {
    const subDir = join(codeiumDir, sub)
    if (!pathExists(subDir)) continue

    for (const entryPath of listAllEntries(subDir)) {
      if (!pathExists(entryPath)) continue

      const sid = basenameWithoutExtension(entryPath)
      if (sid.length === 0 || sid.startsWith('.')) continue

      const size = sizeOfPath(entryPath)
      const date = new Date(mtimeMs(entryPath) ?? Date.now())

      let promptTitle: string | null = null
      let projectPath: string | null = null

      if (isDirectory(entryPath)) {
        for (const metaName of CASCADE_META_FILES) {
          const metaFile = join(entryPath, metaName)
          if (!pathExists(metaFile)) continue
          const json = readJson<unknown>(metaFile)
          if (!isRecord(json)) continue
          promptTitle = firstString(json['title'], json['prompt'], json['name'])
          projectPath = firstString(json['cwd'], json['projectPath'], json['workspace'])
          break
        }
      } else if (extname(entryPath).toLowerCase() === '.json') {
        const json = readJson<unknown>(entryPath)
        if (isRecord(json)) {
          promptTitle = firstString(json['title'], json['prompt'])
          projectPath = firstString(json['cwd'], json['projectPath'])
        }
      }

      const finalTitle =
        promptTitle !== null && promptTitle.length > 0
          ? firstLine(promptTitle).slice(0, 80)
          : `Windsurf Cascade 会话 ${sid.slice(0, 8)}`

      items.push(
        makeItem({
          sessionId: sid,
          title: finalTitle,
          category: 'windsurf',
          projectPath,
          gitBranch: null,
          messageCount: 1,
          sizeInBytes: size,
          updatedAt: date,
          snippet: finalTitle,
          associatedPaths: [entryPath]
        })
      )
    }
  }

  return items
}
