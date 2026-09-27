import {
  closeSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  realpathSync
} from 'node:fs'
import type { Dirent } from 'node:fs'
import { homedir } from 'node:os'
import { basename, join, resolve } from 'node:path'
import type { ConversationItem } from '@shared/types'
import type { AgentScanner, ScannerOptions } from '@main/core/scanner'
import {
  deleteItemsWithPaths,
  fileSize,
  isDirectory,
  makeItem,
  mtimeMs,
  pathExists,
  removeIfExists,
  resolveStoragePath,
  sizeOfPath,
  sortByUpdatedDesc,
  truncate
} from '@main/core/scanner'

/**
 * Aider 扫描器。
 *
 * 移植自 `ConversationClean/Scanners/CLIAgents/AiderScanner.swift`，逐条对齐：
 *   · `storageURL`：`storagePath` > `AIDER_HOME` > `~/.aider`，realpath 规范化。
 *     `isInstalled` 额外认 home 下的 4 个指示文件与任意 `.aider*` 条目
 *   · `scan()`：一条「全局」会话（`~/.aider` + home 下的 3 个全局文件）
 *     + `~/projects` 深度 3 以内的项目级会话（每个命中的目录一条）
 *   · `delete()`：每条路径先过 `isSafeToDelete` 护栏 —— `.aider.conf.yml` 永不删，
 *     且只删 `~/.aider` 之内或 Aider 自己的三个文件名
 *   · `cleanAll()`：scan + delete，再整个删掉 `~/.aider`（并重建空目录）
 *     与 home 下遗留的 3 个全局文件
 *
 * 与 Swift 版本的已知偏差：
 *   1. `sessionId` 里的短哈希改用确定性 FNV-1a —— Swift 的 `String.hashValue` 每次进程
 *      启动都换种子，同一个项目两次扫描的 `sessionId` 不一样，删除时无法按 id 定位。
 *   2. 目录深度上限 3、跳过目录清单、`.aider.conf.yml` 保护均照抄 Swift。
 */

/** 命中即认为该目录有 Aider 历史的文件名。 */
const CHAT_HISTORY = '.aider.chat.history.md'
const INPUT_HISTORY = '.aider.input.history'
const TAGS_CACHE_PREFIX = '.aider.tags.cache'
const TAGS_CACHE_V3 = '.aider.tags.cache.v3'

/** home 下的全局历史 / 缓存文件（`.aider.conf.yml` 故意不在其中：它是配置，永不删）。 */
const GLOBAL_FILES = [CHAT_HISTORY, INPUT_HISTORY, TAGS_CACHE_V3]

/** 项目级枚举时跳过的目录，照抄 Swift。 */
const SKIP_DIRS = new Set([
  '.git',
  '.svn',
  '.hg',
  'node_modules',
  'Pods',
  'DerivedData',
  '.build',
  'vendor',
  '.venv',
  'venv',
  'env',
  'dist',
  'build',
  'target',
  '.next',
  '.nuxt',
  'Caches',
  '.cache'
])

/**
 * Swift `trimmingCharacters(in: .whitespaces)` 的字符集：空格 / 制表 / Unicode 空格分隔符，
 * **不含** `\n` `\r` `\v` `\f`，所以不能拿 JS 的 `String.trim()` 顶。
 */
const SPACE_RUN = /^[\t \u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]+|[\t \u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]+$/g

export class AiderScanner implements AgentScanner {
  readonly category = 'aider' as const
  private readonly root: string
  private readonly custom: string | null

  constructor(options: ScannerOptions = {}) {
    this.custom = options.storagePath ?? null
    // Swift: `customStorageURL ?? AIDER_HOME ?? ~/.aider`，随后 `canonicalPath ?? standardized`。
    this.root =
      this.custom !== null ? canonical(this.custom) : resolveStoragePath(['.aider'], { key: 'AIDER_HOME' })
  }

  get storagePath(): string {
    return this.root
  }

  get isInstalled(): boolean {
    if (pathExists(this.root)) return true

    const home = homedir()
    for (const indicator of ['.aider.conf.yml', INPUT_HISTORY, CHAT_HISTORY, TAGS_CACHE_V3]) {
      if (pathExists(join(home, indicator))) return true
    }
    return listNames(home).some((entry) => entry.startsWith('.aider'))
  }

  // MARK: - Scan

  async scan(): Promise<ConversationItem[]> {
    if (!this.isInstalled) return []

    const items: ConversationItem[] = []

    // 1. 全局 Aider：home 下的全局历史 / 缓存 + `~/.aider` 目录
    const globalItem = scanGlobalAider(this.root)
    if (globalItem !== null) items.push(globalItem)

    // 2. 项目级 Aider：`~/projects`（注入路径时是 `<custom>/projects`，没有则退回 `<custom>`）
    const projectsRoot = this.projectsRoot()
    if (pathExists(projectsRoot)) {
      for (const projectDir of findAiderProjectDirectories(projectsRoot, 3)) {
        const item = parseProjectAider(projectDir)
        if (item !== null) items.push(item)
      }
    }

    return sortByUpdatedDesc(items)
  }

  // MARK: - Deletion & Clean

  async delete(items: ConversationItem[]): Promise<number> {
    if (items.length === 0) return 0

    // Swift 在每条路径上有一道 `isSafeToDelete` 护栏，而公共原语 `deleteItemsWithPaths`
    // 不该带上 Aider 私有语义，所以先在 items 上预筛一遍再交给它。
    // 预筛只决定「删哪些路径」，`sizeInBytes` 原样保留，记账口径与 Swift 一致。
    const guarded = items.map((item) => {
      const safe = item.associatedPaths.filter((path) => this.isSafeToDelete(path))
      return safe.length === item.associatedPaths.length ? item : { ...item, associatedPaths: safe }
    })

    return deleteItemsWithPaths(guarded)
  }

  async cleanAll(): Promise<number> {
    let freed = await this.delete(await this.scan())

    // 清空 ~/.aider 目录，删完把空目录重建回去
    if (pathExists(this.root)) {
      const size = sizeOfPath(this.root)
      if (removeIfExists(this.root)) {
        freed += size
        try {
          mkdirSync(this.root, { recursive: true })
        } catch {
          // Swift 是 `try?`：重建失败不改变本次清理结果
        }
      }
    }

    // 清掉 home 里遗留的全局历史 / 缓存文件（`.aider.conf.yml` 不在其中）
    const home = homedir()
    for (const file of GLOBAL_FILES) {
      const path = join(home, file)
      if (!pathExists(path)) continue
      const size = sizeOfPath(path)
      if (removeIfExists(path)) freed += size
    }

    return freed
  }

  // MARK: - Safety Checks

  /**
   * 逐条删除前的护栏：
   *   · `.aider.conf.yml` 永不删（删了用户的模型 / git 行为配置就没了）
   *   · `~/.aider/` 之内的路径可删
   *   · 其余只认 Aider 自己的三个文件名，绝不碰用户源码
   */
  private isSafeToDelete(path: string): boolean {
    const name = basename(path)
    if (name === '.aider.conf.yml') return false
    // Swift 是字符串前缀比较（不是路径分量比较），`~/.aider-backup/x` 也会被判成安全。
    if (path.startsWith(this.root)) return true
    return name === CHAT_HISTORY || name === INPUT_HISTORY || name.startsWith(TAGS_CACHE_PREFIX)
  }

  /** 注入 `storagePath` 时扫 `<custom>/projects`，没有这个子目录就退回 `<custom>`。 */
  private projectsRoot(): string {
    if (this.custom === null) return join(homedir(), 'projects')
    const customProjects = join(this.custom, 'projects')
    return pathExists(customProjects) ? customProjects : this.custom
  }
}

// MARK: - Global Aider Scanner

function scanGlobalAider(root: string): ConversationItem | null {
  const home = homedir()
  const associatedPaths: string[] = []
  let totalBytes = 0
  let latest = Number.NEGATIVE_INFINITY
  let promptCount = 0
  let firstPrompt: string | null = null

  // 1. ~/.aider 目录（缓存与模型历史）
  if (pathExists(root)) {
    const size = sizeOfPath(root)
    if (size > 0) {
      associatedPaths.push(root)
      totalBytes += size
      const mtime = mtimeMs(root)
      if (mtime !== undefined && mtime > latest) latest = mtime
    }
  }

  // 2. home 下的全局文件
  for (const fileName of GLOBAL_FILES) {
    const path = join(home, fileName)
    if (!pathExists(path)) continue

    const size = sizeOfPath(path)
    if (size === 0) continue

    associatedPaths.push(path)
    totalBytes += size

    const mtime = mtimeMs(path)
    if (mtime !== undefined && mtime > latest) latest = mtime

    if (fileName === CHAT_HISTORY) {
      const parsed = parseChatHistory(path)
      promptCount += parsed.messageCount
      if (firstPrompt === null) firstPrompt = parsed.firstPrompt
    } else if (fileName === INPUT_HISTORY) {
      const content = readText(path)
      if (content !== null) promptCount += Math.max(1, countNonBlankLines(content))
    }
  }

  // 3. home 下其它版本号的 tags 缓存（`.aider.tags.cache.v4` …）。
  //    Swift 这一支不更新 `latest`、也不判空目录大小，照抄。
  for (const entry of listNames(home)) {
    if (!entry.startsWith(`${TAGS_CACHE_PREFIX}.`) || entry === TAGS_CACHE_V3) continue
    const path = join(home, entry)
    if (associatedPaths.includes(path)) continue
    associatedPaths.push(path)
    totalBytes += sizeOfPath(path)
  }

  if (associatedPaths.length === 0 || totalBytes === 0) return null

  const date = latest === Number.NEGATIVE_INFINITY ? new Date() : new Date(latest)
  const title = firstPrompt ?? 'Aider 全局历史与模型缓存'
  const snippet = firstPrompt ?? '包含 Aider 全局缓存、代码标签索引及输入历史'

  return makeItem({
    sessionId: 'aider-global',
    title,
    category: 'aider',
    projectPath: home,
    gitBranch: null,
    messageCount: Math.max(1, promptCount),
    sizeInBytes: totalBytes,
    updatedAt: date,
    snippet,
    associatedPaths
  })
}

// MARK: - Project Level Scanner

/** 广度优先找出含 Aider 历史文件的目录，最多下探 `maxDepth` 层。 */
function findAiderProjectDirectories(root: string, maxDepth: number): string[] {
  const results: string[] = []
  const queue: Array<{ url: string; depth: number }> = [{ url: root, depth: 1 }]

  while (queue.length > 0) {
    const current = queue.shift() as { url: string; depth: number }
    if (current.depth > maxDepth) continue

    // Swift 用 `options: []`，即**包含**隐藏项，再靠下面的名字过滤跳过。
    const entries = listDirents(current.url)

    let hasAider = false
    for (const entry of entries) {
      if (isAiderMarker(entry.name)) {
        hasAider = true
        break
      }
    }
    if (hasAider) results.push(current.url)

    for (const entry of entries) {
      if (SKIP_DIRS.has(entry.name) || entry.name.startsWith('.')) continue
      // Swift 的 `fileExists(atPath:isDirectory:)` 跟随软链，而 `Dirent.isDirectory()` 不跟。
      if (!entry.isDirectory() && !entry.isSymbolicLink()) continue
      const child = join(current.url, entry.name)
      if (!isDirectory(child)) continue
      queue.push({ url: child, depth: current.depth + 1 })
    }
  }

  return results
}

function isAiderMarker(name: string): boolean {
  return name === CHAT_HISTORY || name === INPUT_HISTORY || name.startsWith(TAGS_CACHE_PREFIX)
}

function parseProjectAider(projectDir: string): ConversationItem | null {
  const chatHistoryPath = join(projectDir, CHAT_HISTORY)
  const inputHistoryPath = join(projectDir, INPUT_HISTORY)

  const associatedPaths: string[] = []
  let totalBytes = 0
  let latest = Number.NEGATIVE_INFINITY
  let messageCount = 0
  let firstPrompt: string | null = null

  // 聊天记录
  if (pathExists(chatHistoryPath)) {
    associatedPaths.push(chatHistoryPath)
    totalBytes += sizeOfPath(chatHistoryPath)
    const mtime = mtimeMs(chatHistoryPath)
    if (mtime !== undefined && mtime > latest) latest = mtime

    const parsed = parseChatHistory(chatHistoryPath)
    messageCount += parsed.messageCount
    firstPrompt = parsed.firstPrompt
  }

  // 输入历史
  if (pathExists(inputHistoryPath)) {
    associatedPaths.push(inputHistoryPath)
    totalBytes += sizeOfPath(inputHistoryPath)
    const mtime = mtimeMs(inputHistoryPath)
    if (mtime !== undefined && mtime > latest) latest = mtime

    const content = readText(inputHistoryPath)
    if (content !== null) {
      const lines = content.split('\n').filter((line) => !isBlank(line))
      messageCount += Math.max(1, lines.length)
      // Swift 取的是**原始**行（没 trim），照抄。
      if (firstPrompt === null && lines.length > 0) firstPrompt = lines[0]
    }
  }

  // 项目目录里的 tags 缓存
  for (const entry of listNames(projectDir)) {
    if (!entry.startsWith(TAGS_CACHE_PREFIX)) continue
    const path = join(projectDir, entry)
    if (associatedPaths.includes(path)) continue
    associatedPaths.push(path)
    totalBytes += sizeOfPath(path)
    const mtime = mtimeMs(path)
    if (mtime !== undefined && mtime > latest) latest = mtime
  }

  if (associatedPaths.length === 0 || totalBytes === 0) return null

  const projectName = basename(projectDir)
  const date = latest === Number.NEGATIVE_INFINITY ? new Date() : new Date(latest)
  const title = firstPrompt !== null ? oneLine(truncate(firstPrompt, 80)) : `Aider: ${projectName}`
  const snippet = firstPrompt !== null ? oneLine(truncate(firstPrompt, 120)) : `项目: ${projectDir}`

  return makeItem({
    sessionId: `aider-${projectName}-${shortHash(projectDir)}`,
    title,
    category: 'aider',
    projectPath: projectDir,
    gitBranch: null,
    messageCount: Math.max(1, messageCount),
    sizeInBytes: totalBytes,
    updatedAt: date,
    snippet,
    associatedPaths
  })
}

/**
 * 解析 `.aider.chat.history.md`：只读前 64KB，统计 `#### ` 与 `> `（排除 `> /`）开头的行，
 * 第一条就是首个 prompt。文件大于 64KB 时按剩余体积粗估再补几条（Swift 的算法）。
 */
function parseChatHistory(path: string): { firstPrompt: string | null; messageCount: number } {
  const head = readHead(path, 64 * 1024)
  if (head === null) return { firstPrompt: null, messageCount: 1 }

  let firstPrompt: string | null = null
  let promptCount = 0

  for (const rawLine of head.split('\n')) {
    const trimmed = trimSpaces(rawLine)
    let prompt: string | null = null
    if (trimmed.startsWith('#### ')) {
      promptCount += 1
      prompt = trimSpaces(trimmed.slice(5))
    } else if (trimmed.startsWith('> ') && !trimmed.startsWith('> /')) {
      promptCount += 1
      prompt = trimSpaces(trimmed.slice(2))
    }
    if (firstPrompt === null && prompt !== null && prompt.length > 0) firstPrompt = prompt
  }

  const size = fileSize(path)
  if (size > 64 * 1024) {
    const estimatedExtra = Math.trunc((size - 64 * 1024) / 1024 / 4)
    promptCount += Math.max(1, estimatedExtra)
  }

  return { firstPrompt, messageCount: Math.max(1, promptCount) }
}

// MARK: - 杂项

function canonical(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return resolve(path)
  }
}

function listNames(path: string): string[] {
  try {
    return readdirSync(path)
  } catch {
    return []
  }
}

function listDirents(path: string): Dirent[] {
  try {
    return readdirSync(path, { withFileTypes: true })
  } catch {
    return []
  }
}

function readText(path: string): string | null {
  try {
    return readFileSync(path, 'utf8')
  } catch {
    return null
  }
}

function readHead(path: string, byteLimit: number): string | null {
  let fd: number
  try {
    fd = openSync(path, 'r')
  } catch {
    return null
  }
  try {
    const buffer = Buffer.alloc(byteLimit)
    const read = readSync(fd, buffer, 0, byteLimit, 0)
    return buffer.subarray(0, read).toString('utf8')
  } catch {
    return null
  } finally {
    try {
      closeSync(fd)
    } catch {
      /* ignore */
    }
  }
}

function trimSpaces(text: string): string {
  return text.replace(SPACE_RUN, '')
}

function isBlank(text: string): boolean {
  return trimSpaces(text).length === 0
}

function countNonBlankLines(content: string): number {
  let count = 0
  for (const line of content.split('\n')) {
    if (!isBlank(line)) count += 1
  }
  return count
}

/** Swift `replacingOccurrences(of: "\n", with: " ")`：只换 `\n`，不动 `\r`。 */
function oneLine(text: string): string {
  return text.replaceAll('\n', ' ')
}

/** 确定性 32 位 FNV-1a，取十进制前 6 位（Swift 取 `abs(hashValue)` 的前 6 位）。 */
function shortHash(path: string): string {
  let hash = 0x811c9dc5
  for (let i = 0; i < path.length; i += 1) {
    hash ^= path.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193) >>> 0
  }
  return String(Math.abs(hash)).slice(0, 6)
}
