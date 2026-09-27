import type { Dirent } from 'node:fs'
import { existsSync, lstatSync, readdirSync, rmSync, statSync } from 'node:fs'
import { join, sep } from 'node:path'
import { CleanPrefs } from './prefs'

/**
 * 跨扫描器共享的文件系统原语。
 *
 * 移植自 Swift 版 `Core/AgentScannerProtocol.swift` 的 `enum FileSizeHelper`
 * 与 `Core/FileSystem/DirectoryCleaner.swift`。
 *
 * Swift 版 `sizeOf` 用 `FileManager.enumerator(options: [.skipsHiddenFiles])`，
 * 这里对应 `readdirSync` + 手动跳过 `.` 前缀项，语义一致。
 */

/** 递归求一个文件或目录的字节数。目录跳过隐藏项；不存在返回 0。 */
export function sizeOfPath(path: string): number {
  let stats
  try {
    stats = lstatSync(path)
  } catch {
    return 0
  }
  if (!stats.isDirectory()) return stats.isFile() ? stats.size : 0

  let total = 0
  let entries: string[]
  try {
    entries = readdirSync(path)
  } catch {
    return 0
  }
  for (const entry of entries) {
    if (entry.startsWith('.')) continue
    const child = join(path, entry)
    let childStats
    try {
      childStats = lstatSync(child)
    } catch {
      continue
    }
    if (childStats.isDirectory()) {
      total += sizeOfPath(child)
    } else if (childStats.isFile()) {
      total += childStats.size
    }
  }
  return total
}

/** 删掉一个文件或目录；不存在或失败返回 false。 */
export function removeIfExists(path: string): boolean {
  if (!existsSync(path)) return false
  try {
    rmSync(path, { recursive: true, force: true })
    return true
  } catch (error) {
    console.error(`[fs] 删除失败 ${path}:`, error)
    return false
  }
}

/**
 * 目录里只剩隐藏项时把整个目录删掉。
 *
 * 「回收空项目目录」关掉时一个目录都不能删 —— 这是所有「删空目录」的唯一原语，
 * 在这里收口，扫描器就不会漏掉某一处。
 */
export function removeIfEmptyDirectory(path: string): void {
  if (!CleanPrefs.cleanEmptyProjectFolders) return
  let stats
  try {
    stats = statSync(path)
  } catch {
    return
  }
  if (!stats.isDirectory()) return
  let contents: string[]
  try {
    contents = readdirSync(path)
  } catch {
    return
  }
  if (contents.some((name) => !name.startsWith('.'))) return
  for (const entry of contents) {
    try {
      rmSync(join(path, entry), { recursive: true, force: true })
    } catch {
      /* 单个隐藏项删不掉就算了，不影响目录本身被回收 */
    }
  }
  try {
    rmSync(path, { recursive: true, force: true })
  } catch (error) {
    console.error(`[fs] 回收空目录失败 ${path}:`, error)
  }
}

/**
 * 清理 VS Code 系 `workspaceStorage/<hash>/` 下残留的空 `chatSessions` 与
 * `chatEditingSessions` 目录。
 *
 * @param root workspace 数据根目录，通常是 `<userDir>/User`。
 */
export function cleanEmptyWorkspaceStorageDirs(root: string): void {
  // 开关关掉时整个方法空转：下面那层 removeIfEmptyDirectory 也会拦一道，
  // 这里提前 return 是为了不白跑一遍 workspaceStorage 的目录枚举。
  if (!CleanPrefs.cleanEmptyProjectFolders) return

  const workspaceStorageDir = join(root, 'workspaceStorage')
  let entries: string[]
  try {
    entries = readdirSync(workspaceStorageDir)
  } catch {
    return
  }
  for (const entry of entries) {
    const wsDir = join(workspaceStorageDir, entry)
    try {
      if (!statSync(wsDir).isDirectory()) continue
    } catch {
      continue
    }
    removeIfEmptyDirectory(join(wsDir, 'chatSessions'))
    removeIfEmptyDirectory(join(wsDir, 'chatEditingSessions'))
  }
}

/**
 * 递归删除 `root` 下所有空目录，从最深层开始向上收缩。
 *
 * @param root 要清理的根目录；不存在时直接返回。
 */
export function cleanEmptyDirectories(root: string): void {
  if (!CleanPrefs.cleanEmptyProjectFolders) return

  const subdirectories: string[] = []
  const walk = (dir: string, depth: number): void => {
    if (depth > 12) return // 防御异常深的目录树
    let dirents: Dirent[]
    try {
      dirents = readdirSync(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of dirents) {
      if (entry.name.startsWith('.')) continue
      if (!entry.isDirectory()) continue
      const child = join(dir, entry.name)
      subdirectories.push(child)
      walk(child, depth + 1)
    }
  }
  try {
    if (!statSync(root).isDirectory()) return
  } catch {
    return
  }
  walk(root, 0)

  // 先处理最深的目录（按路径长度倒序即可保证深度序），父目录才能在子目录清空后一并移除。
  for (const dir of subdirectories.sort((a, b) => b.length - a.length)) {
    removeIfEmptyDirectory(dir)
  }
}

/** 判断 `child` 是否在 `parent` 之内（用于「只删本 Agent 目录下的文件」这类护栏）。 */
export function isInside(parent: string, child: string): boolean {
  const normalizedParent = parent.endsWith(sep) ? parent : parent + sep
  return child.startsWith(normalizedParent)
}
