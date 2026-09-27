import { mkdirSync, readFileSync, realpathSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, dirname, extname, join, resolve } from 'node:path'

import type { ConversationItem } from '@shared/types'
import type { AgentScanner, ScannerOptions } from '@main/core/scanner'
import {
  listDirectories,
  listFiles,
  pathExists,
  resolveStoragePath,
  sortByUpdatedDesc
} from '@main/core/scanner'
import { cleanEmptyWorkspaceStorageDirs, removeIfExists, sizeOfPath } from '@main/core/fsutil'
import { CleanPrefs } from '@main/core/prefs'
import { clearAllChatSessions, removeChatSessions } from '@main/core/vscdb'
import { parseJsonlSession } from './CursorScanner+JSONL'
import {
  clearStateDatabaseChatData,
  deleteComposersFromStateDb,
  parseStateDatabase
} from './CursorScanner+StateDatabase'
import { scanCursorExtensionStorage, scanDotCursorDirectory } from './CursorScanner+DirectoryScan'

/**
 * Cursor 会话扫描器。
 *
 * 移植自 Swift 版 `Scanners/VSCodeFamily/CursorScanner.swift`。
 * Swift 把主类拆成了三个 extension，本目录按同样的 1:1 对应拆成三个模块：
 *
 * | 本文件 | Swift 源 | 职责 |
 * |---|---|---|
 * | `CursorScanner.ts`            | `CursorScanner.swift`              | 存储路径解析 / scan / delete / cleanAll |
 * | `CursorScanner+JSONL.ts`      | `CursorScanner+JSONL.swift`        | `chatSessions/*.jsonl` 解析 |
 * | `CursorScanner+StateDatabase.ts` | `CursorScanner+StateDatabase.swift` | `state.vscdb` 索引解析与清理 |
 * | `CursorScanner+DirectoryScan.ts` | `CursorScanner+DirectoryScan.swift` | `globalStorage/cursor.cursor/` 与 `~/.cursor/` 兜底扫描 |
 *
 * ## 三个数据来源
 *
 * 1. `User/workspaceStorage/<hash>/chatSessions/*.jsonl` —— 新版 Cursor 的会话正文
 * 2. `User/workspaceStorage/<hash>/state.vscdb` 的 `composer.composerData`
 *    与 `workbench.panel.aichat.view.aichat.chatdata` —— 老版 Cursor 的会话**只在索引里**
 * 3. `User/globalStorage/cursor.cursor/{composer,chats,workspaces}/*.json` 与 `~/.cursor/chats/*.json`
 *    —— 目录扫描兜底
 *
 * 注意第 1、2 两个来源之间**没有去重**（照抄 Swift）：同一个 id 若两边都有，
 * 界面上就是两条。`state.vscdb` 里的条目 `associatedPaths` 只有库文件自身，
 * 所以删索引条目不会误删同名 jsonl —— 这一点由 `delete()` 区分 `.vscdb` 路径来保证。
 */

/** 一条待解析的会话文件。Swift 版是 `struct ScanTarget`（internal，供 extension 共用）。 */
export interface CursorScanTarget {
  /** `chatSessions/<sid>.jsonl` 或 `emptyWindowChatSessions/<sid>.jsonl` 的绝对路径。 */
  filePath: string
  /** 来自 `workspace.json` 的项目路径；`emptyWindow` 会话恒为 `null`。 */
  projectPath: string | null
  /** 同名 `chatEditingSessions/<sid>/` 快照目录；不存在为 `null`。 */
  editingDirPath: string | null
}

export class CursorScanner implements AgentScanner {
  readonly category = 'cursor' as const

  /** Swift 版的 `customStorageURL`。测试用它指到夹具目录（`init(storageURL:)`）。 */
  private readonly customStoragePath: string | null

  constructor(options: ScannerOptions = {}) {
    this.customStoragePath = options.storagePath ?? null
  }

  /**
   * 注入目录 > `CURSOR_HOME` > `~/Library/Application Support/Cursor`，
   * 最后做一次 `realpath` 规范化。
   */
  get storagePath(): string {
    if (this.customStoragePath !== null) return canonical(this.customStoragePath)
    return resolveStoragePath(['Library/Application Support/Cursor'], { key: 'CURSOR_HOME' })
  }

  /**
   * 真正的 userData 目录。
   *
   * 新版 Cursor 是 `Cursor/User/{workspaceStorage,globalStorage}`；
   * 极老的版本直接把 `workspaceStorage` 摆在 `Cursor/` 底下。
   * 先按新版找，找不到再看有没有老布局，都没有就按新版拼（路径不存在时后续枚举自然空转）。
   */
  get userDirectoryPath(): string {
    const directUser = join(this.storagePath, 'User')
    if (pathExists(directUser)) return directUser
    if (pathExists(join(this.storagePath, 'workspaceStorage'))) return this.storagePath
    return directUser
  }

  /**
   * `~/.cursor` —— Cursor CLI 的会话目录。
   * 注入夹具目录下如果带了 `.cursor/` 就用它，否则一律取真实的 home。
   */
  get dotCursorPath(): string {
    if (this.customStoragePath !== null) {
      const candidate = join(this.customStoragePath, '.cursor')
      if (pathExists(candidate)) return candidate
    }
    return join(homedir(), '.cursor')
  }

  /**
   * 存储目录存在即算已安装；否则退一步看 `~/.cursor`（只装了 CLI 的情况）。
   * 注入夹具时不回落，避免一个坏路径扫到用户真实的 `~/.cursor`。
   */
  get isInstalled(): boolean {
    if (pathExists(this.storagePath)) return true
    if (this.customStoragePath !== null) return false
    return pathExists(join(homedir(), '.cursor'))
  }

  // MARK: - 扫描

  async scan(): Promise<ConversationItem[]> {
    if (!this.isInstalled) return []

    const items: ConversationItem[] = []
    const userDir = this.userDirectoryPath
    const workspaceStorageDir = join(userDir, 'workspaceStorage')

    // 1 + 2. User/workspaceStorage/<hash>/{chatSessions,state.vscdb}
    const jsonlTargets: CursorScanTarget[] = []
    for (const name of listDirectories(workspaceStorageDir)) {
      const wsDir = join(workspaceStorageDir, name)
      const projectPath = extractProjectPath(join(wsDir, 'workspace.json'))

      const chatSessionsDir = join(wsDir, 'chatSessions')
      const chatEditingDir = join(wsDir, 'chatEditingSessions')
      for (const sessionFile of listFiles(chatSessionsDir, '.jsonl')) {
        const sid = basename(sessionFile, extname(sessionFile))
        const editingPath = join(chatEditingDir, sid)
        jsonlTargets.push({
          filePath: sessionFile,
          projectPath,
          editingDirPath: pathExists(editingPath) ? editingPath : null
        })
      }

      // state.vscdb 里可能存着 JSONL 早已删掉的会话，扫描阶段只读打开。
      const stateDbPath = join(wsDir, 'state.vscdb')
      if (pathExists(stateDbPath)) {
        items.push(...parseStateDatabase(stateDbPath, projectPath))
      }
    }

    // 3. User/globalStorage/emptyWindowChatSessions/*.jsonl —— 空窗口会话，没有项目
    const globalStorageDir = join(userDir, 'globalStorage')
    const emptyWindowDir = join(globalStorageDir, 'emptyWindowChatSessions')
    for (const sessionFile of listFiles(emptyWindowDir, '.jsonl')) {
      jsonlTargets.push({ filePath: sessionFile, projectPath: null, editingDirPath: null })
    }

    // 解析 JSONL。Swift 版用 `withTaskGroup` 并发，这里是纯同步解析，循环即可。
    for (const target of jsonlTargets) {
      const item = parseJsonlSession(target)
      if (item !== null) items.push(item)
    }

    // 4. 扩展的 globalStorage 目录
    const cursorExtDir = join(globalStorageDir, 'cursor.cursor')
    if (pathExists(cursorExtDir)) {
      items.push(...scanCursorExtensionStorage(cursorExtDir))
    }

    // 5. ~/.cursor
    const dotCursor = this.dotCursorPath
    if (pathExists(dotCursor)) {
      items.push(...scanDotCursorDirectory(dotCursor))
    }

    return sortByUpdatedDesc(items)
  }

  // MARK: - 删除

  async delete(items: ConversationItem[]): Promise<number> {
    if (items.length === 0) return 0

    const userDir = this.userDirectoryPath
    let totalFreed = 0
    /** `state.vscdb` 路径 → 要从索引里删掉的 sessionId。 */
    const stateDbToSessions = new Map<string, Set<string>>()

    for (const item of items) {
      // 必须在物理删除之前算：路径没了 sizeOf 恒为 0。
      totalFreed += CleanPrefs.freedBytesBeforeDelete(item.sizeInBytes, item)
      // state.vscdb 索引行不属于快照，始终跟着删；只有文件删除受开关控制。
      const pathsToDelete = new Set(CleanPrefs.deletionPathsFor(item))
      for (const path of item.associatedPaths) {
        if (path.endsWith('.vscdb')) {
          // 索引条目本身没有独立文件要删，只登记 sessionId
          addSessionId(stateDbToSessions, path, item.sessionId)
          continue
        }
        if (path.includes('chatSessions')) {
          const wsDir = dirname(dirname(path))
          addSessionId(stateDbToSessions, join(wsDir, 'state.vscdb'), item.sessionId)
        } else if (path.includes('emptyWindowChatSessions')) {
          addSessionId(
            stateDbToSessions,
            join(userDir, 'globalStorage', 'state.vscdb'),
            item.sessionId
          )
        }
        if (pathsToDelete.has(path)) removeIfExists(path)
      }
    }

    // 同步清理 state.vscdb：composer.composerData 与 chat.ChatSessionStore.index 都要裁
    for (const [dbPath, sessionIds] of stateDbToSessions) {
      removeChatSessions(dbPath, sessionIds)
      deleteComposersFromStateDb(dbPath, sessionIds)
    }

    cleanEmptyWorkspaceStorageDirs(userDir)
    return totalFreed
  }

  // MARK: - 全部清空

  async cleanAll(): Promise<number> {
    const items = await this.scan()
    let freed = await this.delete(items)

    const userDir = this.userDirectoryPath
    const workspaceStorageDir = join(userDir, 'workspaceStorage')
    for (const name of listDirectories(workspaceStorageDir)) {
      const wsDir = join(workspaceStorageDir, name)

      freed += removeAndCount(join(wsDir, 'chatSessions'))
      if (CleanPrefs.cleanFileHistorySnapshots) {
        freed += removeAndCount(join(wsDir, 'chatEditingSessions'))
      }

      const stateDb = join(wsDir, 'state.vscdb')
      if (pathExists(stateDb)) clearAllChatSessions(stateDb)
    }

    // globalStorage/state.vscdb 的聊天索引
    const globalStorageDir = join(userDir, 'globalStorage')
    const globalStateDb = join(globalStorageDir, 'state.vscdb')
    if (pathExists(globalStateDb)) clearAllChatSessions(globalStateDb)

    // emptyWindowChatSessions 与扩展目录：整目录删掉后原样建回来
    freed += removeAndCount(join(globalStorageDir, 'emptyWindowChatSessions'), true)
    freed += removeAndCount(join(globalStorageDir, 'cursor.cursor'), true)

    // ~/.cursor/chats
    freed += removeAndCount(join(this.dotCursorPath, 'chats'), true)

    cleanEmptyWorkspaceStorageDirs(userDir)
    return freed
  }

  // MARK: - 内部方法

  /**
   * 清空一个 `state.vscdb` 的聊天数据（`composer.composerData` 与 aichat chatdata）。
   *
   * ⚠️ Swift 版同样**没有在任何地方调用**这个方法（`cleanAll()` 走的是
   * `VSCDBHelper.clearAllChatSessions`）。这里原样保留以维持文件对照，
   * 不要以为它已经接进了清理流程。
   */
  clearStateDatabase(dbPath: string): void {
    clearStateDatabaseChatData(dbPath)
  }
}

// MARK: - 小工具

function addSessionId(map: Map<string, Set<string>>, dbPath: string, sessionId: string): void {
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

/** `workspace.json` → 项目路径。`file://` URI 会被还原成普通路径。 */
function extractProjectPath(workspaceJsonPath: string): string | null {
  let json: unknown
  try {
    json = JSON.parse(readFileSync(workspaceJsonPath, 'utf8'))
  } catch {
    return null
  }
  const dict = asRecord(json)
  if (dict === null) return null
  const uri = asString(dict['folder']) ?? asString(dict['workspace'])
  if (uri === null) return null
  if (!uri.startsWith('file://')) return uri
  try {
    return decodeURI(new URL(uri).pathname)
  } catch {
    const stripped = uri.slice('file://'.length)
    try {
      return decodeURI(stripped)
    } catch {
      return stripped
    }
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

function asString(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}
