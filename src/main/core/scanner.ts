import { randomUUID } from 'node:crypto'
import {
  existsSync,
  readFileSync,
  readdirSync,
  realpathSync,
  statSync,
  openSync,
  readSync,
  closeSync
} from 'node:fs'
import { homedir } from 'node:os'
import { basename, extname, join } from 'node:path'
import type { AgentCategory, ConversationItem } from '@shared/types'
import { CleanPrefs } from './prefs'
import { sizeOfPath, removeIfExists, removeIfEmptyDirectory } from './fsutil'

/**
 * 扫描器协议 + 跨扫描器共享的解析原语。
 *
 * 实现是普通对象 + `Promise`：`scan` 只读，`delete` / `cleanAll` 才落盘。
 *
 * 约定（所有实现都必须遵守）：
 * 1. `scan()` 内部**绝不**修改任何文件。连 mtime 都不许写。
 * 2. `delete()` 返回的是「实际释放字节数」，必须走 `CleanPrefs.freedBytesBeforeDelete`
 *    扣掉被保留的快照，否则 UI 的「预计释放」会报一个比实际大的数。
 * 3. `associatedPaths` 列出这条会话真正占盘的全部路径（含索引文件、快照目录），
 *    删除时逐条删 —— 不要在 `delete()` 里另外去找文件。
 * 4. 抛错只发生在「这个 Agent 整个不可用」时；单条会话解析失败应当跳过并继续，
 *    不要让一个坏 JSONL 把整个分类清空。
 */
export interface AgentScanner {
  readonly category: Exclude<AgentCategory, 'all'>
  /** 数据根目录是否存在。用户没装这个 Agent 时为 false，`scan()` 直接返回 `[]`。 */
  readonly isInstalled: boolean
  /** 数据根目录的绝对路径。侧栏「存储路径」与设置页的「打开目录」都用它。 */
  readonly storagePath: string

  scan(): Promise<ConversationItem[]>
  delete(items: ConversationItem[]): Promise<number>
  cleanAll(): Promise<number>
}

/** 扫描器构造选项：允许测试注入临时目录。 */
export interface ScannerOptions {
  /** 覆盖默认数据目录。测试用它指到夹具目录。 */
  storagePath?: string
}

// MARK: - 基础 IO 原语（目录 / 文件枚举一律跳过 `.` 前缀项）

export function isDirectory(path: string): boolean {
  try {
    return statSync(path).isDirectory()
  } catch {
    return false
  }
}

export function isFile(path: string): boolean {
  try {
    return statSync(path).isFile()
  } catch {
    return false
  }
}

export function pathExists(path: string): boolean {
  return existsSync(path)
}

/** 列目录里的子目录名（跳过隐藏项）。目录不存在返回 `[]`，不抛错。 */
export function listDirectories(path: string): string[] {
  try {
    return readdirSync(path, { withFileTypes: true })
      .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
      .map((e) => e.name)
  } catch {
    return []
  }
}

/** 列目录里的子文件绝对路径，可按扩展名过滤（`.jsonl` / `.json`）。目录不存在返回 `[]`。 */
export function listFiles(path: string, extension?: string): string[] {
  try {
    return readdirSync(path, { withFileTypes: true })
      .filter((e) => {
        if (e.name.startsWith('.')) return false
        if (!e.isFile() && !e.isSymbolicLink()) return false
        if (extension) return extname(e.name).toLowerCase() === extension
        return true
      })
      .map((e) => join(path, e.name))
  } catch {
    return []
  }
}

/** 文件修改时间的 epoch 毫秒；取不到返回 `undefined`。 */
export function mtimeMs(path: string): number | undefined {
  try {
    return statSync(path).mtimeMs
  } catch {
    return undefined
  }
}

/** 文件字节数；取不到返回 0。 */
export function fileSize(path: string): number {
  try {
    return statSync(path).size
  } catch {
    return 0
  }
}

// MARK: - JSON / JSONL 解析

/**
 * 读一个 JSON 文件。文件缺失或解析失败返回 `null`。
 *
 * 扫描器面对的是**用户机器上别人写的文件**，一个坏 JSON 不该让整个分类消失，
 * 所以这里一律「失败即 null」，由调用方决定跳过还是回落。
 */
export function readJson<T = unknown>(path: string): T | null {
  try {
    return JSON.parse(readFileSync(path, 'utf8')) as T
  } catch {
    return null
  }
}

/**
 * 读一个 JSONL 文件，逐行解析，**跳过解析失败的行**而不是整份放弃。
 * 返回原始 JSON 值数组，调用方自己按形状收窄。
 */
export function readJsonLines<T = unknown>(path: string): T[] {
  let content: string
  try {
    content = readFileSync(path, 'utf8')
  } catch {
    return []
  }
  const out: T[] = []
  for (const line of content.split('\n')) {
    const trimmed = line.trim()
    if (trimmed.length === 0) continue
    try {
      out.push(JSON.parse(trimmed) as T)
    } catch {
      // 半行写入（Agent 正在写）导致的解析失败是常态，跳过。
    }
  }
  return out
}

/**
 * 读一个 JSONL 文件的**前 N 字节**并逐行解析。
 *
 * Claude Code / Pi Agent 这类会话文件动辄几十 MB，而标题、cwd、gitBranch
 * 全在头几行 —— 扫全量是纯浪费，所以默认只读前 64KB。
 * 末行可能被截断，解析失败的那行自动跳过。
 */
export function readJsonLinesHead<T = unknown>(path: string, byteLimit = 64 * 1024): T[] {
  let fd: number | undefined
  try {
    fd = openSync(path, 'r')
    const buffer = Buffer.alloc(byteLimit)
    const bytesRead = readSync(fd, buffer, 0, byteLimit, 0)
    const head = buffer.subarray(0, bytesRead).toString('utf8')
    const out: T[] = []
    for (const line of head.split('\n')) {
      const trimmed = line.trim()
      if (trimmed.length === 0) continue
      try {
        out.push(JSON.parse(trimmed) as T)
      } catch {
        /* 截断的末行 */
      }
    }
    return out
  } catch {
    return []
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

// MARK: - 杂项

/** 有界并发的 map。不限并发时几千个文件会同时打开 fd，直接打爆。 */
export async function mapLimit<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R> | R
): Promise<R[]> {
  const results = new Array<R>(items.length)
  let cursor = 0
  const workerCount = Math.max(1, Math.min(limit, items.length))
  const workers = Array.from({ length: workerCount }, async () => {
    for (;;) {
      const index = cursor++
      if (index >= items.length) return
      results[index] = await fn(items[index] as T, index)
    }
  })
  await Promise.all(workers)
  return results
}

/** 按 updatedAt 倒序（新的在前）。扫描结果的统一排序口径。 */
export function sortByUpdatedDesc(items: ConversationItem[]): ConversationItem[] {
  return items.sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : a.updatedAt > b.updatedAt ? -1 : 0))
}

/** 截断并压掉换行，供标题 / 摘要用。 */
export function truncate(text: string, limit: number): string {
  return text.length > limit ? text.slice(0, limit) : text
}

/** 单行化：换行与连续空白压成一个空格。 */
export function singleLine(text: string): string {
  return text.replace(/\s+/g, ' ').trim()
}

/** 生成一条会话。字段默认值集中在这里，避免每个扫描器各填一遍。 */
export function makeItem(input: {
  sessionId: string
  title: string
  category: Exclude<AgentCategory, 'all'>
  projectPath?: string | null
  gitBranch?: string | null
  messageCount?: number
  sizeInBytes: number
  updatedAt: Date
  snippet?: string
  associatedPaths?: string[]
  id?: string
}): ConversationItem {
  return {
    id: input.id ?? randomUUID(),
    sessionId: input.sessionId,
    title: input.title,
    category: input.category,
    projectPath: input.projectPath ?? null,
    gitBranch: input.gitBranch ?? null,
    messageCount: input.messageCount ?? 0,
    sizeInBytes: input.sizeInBytes,
    updatedAt: input.updatedAt.toISOString(),
    isSelected: false,
    snippet: input.snippet ?? '',
    associatedPaths: input.associatedPaths ?? []
  }
}

/**
 * 解析数据根目录：`storagePath` 覆盖 > 环境变量 > `~/` 下的默认目录。
 *
 * 一定要做一次 `realpath`：`/var` → `/private/var` 这类别名不解析的话，
 * 侧栏显示的路径会跟 Finder 里点开的不一致，删除时也会出现「文件明明存在却删不掉」。
 * realpath 失败（路径还不存在）就原样返回。
 */
export function resolveStoragePath(
  fallbackSegments: string[],
  env?: Record<string, string | undefined>
): string {
  const raw = process.env[env?.key ?? '']
  if (raw && raw.length > 0) return canonical(raw)
  return canonical(join(homedir(), ...fallbackSegments))
}

function canonical(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

/** `~/.claude` → `/Users/x/.claude`。`~` 在 Agent 的 JSON 里是常见写法。 */
export function expandTilde(path: string, home: string = homedir()): string {
  if (path === '~') return home
  if (path.startsWith('~/')) return join(home, path.slice(2))
  return path
}

/** 目录名里的 basename，扫描器大量用它从 `<projectDir>` 反推项目名。 */
export function dirName(path: string): string {
  return basename(path)
}

// MARK: - 删除流程的标准实现

/**
 * 「逐条删 associatedPaths + 记账」的标准实现。
 *
 * 绝大多数 CLI Agent 的 `delete()` 就是这一段，差异只在**之后**还要不要清理索引
 * （Claude Code 要改 `history.jsonl`，Cursor 要改 `state.vscdb`）。
 * 把公共部分收在这里，各扫描器只写自己那部分索引清理，避免十几份复制品漂移。
 *
 * @param afterDelete 会话文件删完后调用，参数是被删的 sessionId 集合。
 *                    在这里做索引同步 / 空目录回收。
 * @returns 实际释放字节数（已扣除保留的快照）。
 */
export async function deleteItemsWithPaths(
  items: readonly ConversationItem[],
  afterDelete?: (deletedSessionIds: Set<string>) => void | Promise<void>
): Promise<number> {
  if (items.length === 0) return 0
  let freed = 0
  const deletedSessionIds = new Set<string>()

  for (const item of items) {
    // 必须在物理删除**之前**算：路径没了 sizeOf 恒为 0。
    freed += CleanPrefs.freedBytesBeforeDelete(item.sizeInBytes, item)
    deletedSessionIds.add(item.sessionId)
    for (const path of CleanPrefs.deletionPathsFor(item)) {
      removeIfExists(path)
    }
  }

  await afterDelete?.(deletedSessionIds)
  return freed
}

/**
 * 「删一个目录后回收它自己」的小工具。
 * 复用 `removeIfEmptyDirectory`，所以「回收空项目目录」开关关掉时它自动空转。
 */
export function removeAndReclaimDir(path: string): boolean {
  const removed = removeIfExists(path)
  if (removed) removeIfEmptyDirectory(path)
  return removed
}

/** 目录体积，扫描器统计 `associatedPaths` 之外的整目录时用。 */
export { sizeOfPath, removeIfExists, removeIfEmptyDirectory, CleanPrefs }
