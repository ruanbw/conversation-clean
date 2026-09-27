import { readdirSync, renameSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { CleanPrefs, listDirectories, pathExists, readJson, removeIfExists } from '@main/core/scanner'

/**
 * pi-acp 会话映射表同步。
 *
 * `~/.pi/pi-acp/session-map.json` 是 ACP 客户端侧边栏的会话索引：
 *
 * ```json
 * { "version": 1, "sessions": { "<key>": { "sessionId": "…", "sessionFile": "…" } } }
 * ```
 *
 * 它只记指针，不记正文。会话文件删了而这里不裁剪，ACP 客户端侧边栏就会留着一串
 * 点进去是空的**幽灵会话**。裁剪时认三种来源：key 命中、条目里的 `sessionId` 命中、
 * 以及 `sessionFile` 指向已删除 / 已不存在的文件。
 */

/**
 * 裁剪 `session-map.json`，避免 ACP 客户端侧边栏残留幽灵会话。
 *
 * - `sessionIds`：本次删掉的会话 id 集合（来自 `ConversationItem.sessionId`）。
 * - `deletedPaths`：本次删掉的**完整** `associatedPaths` 集合 —— 注意这里不经过
 *   `CleanPrefs.deletionPathsFor` 过滤，快照开关关着时也照样算进去。
 *
 * 裁剪后若一条不剩，整个文件删掉；否则原子回写。
 */
export function pruneACPSessionMap(
  mapPath: string,
  sessionIds: ReadonlySet<string>,
  deletedPaths: ReadonlySet<string>
): void {
  if (sessionIds.size === 0 && deletedPaths.size === 0) return

  const root = readJson<unknown>(mapPath)
  if (!isRecord(root)) return
  const sessions = root['sessions']
  if (!isRecord(sessions)) return

  const staleKeys = new Set<string>()
  for (const [key, value] of Object.entries(sessions)) {
    let isStale = sessionIds.has(key)
    if (!isStale && isRecord(value)) {
      const sid = value['sessionId']
      if (typeof sid === 'string' && sessionIds.has(sid)) {
        isStale = true
      } else {
        const file = value['sessionFile']
        if (typeof file === 'string') {
          // 指向已删除（或早就已不存在）的会话文件的条目本身就是幽灵条目。
          if (deletedPaths.has(file) || (file.length > 0 && !pathExists(file))) {
            isStale = true
          }
        }
      }
    }
    if (isStale) staleKeys.add(key)
  }

  if (staleKeys.size === 0) return

  const remaining: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(sessions)) {
    if (!staleKeys.has(key)) remaining[key] = value
  }

  if (Object.keys(remaining).length === 0) {
    removeIfExists(mapPath)
    return
  }

  root['sessions'] = remaining
  writeJsonAtomic(mapPath, root)
}

/**
 * 回收 `agent/sessions/` 下不再含任何 `.jsonl` 的项目目录。
 *
 * 「回收空项目目录」关掉时磁盘上保留空 project 目录 —— 开关判据写在最前面。
 */
export function cleanEmptyProjectDirectories(sessionsDir: string): void {
  if (!CleanPrefs.cleanEmptyProjectFolders) return
  if (!pathExists(sessionsDir)) return

  for (const name of listDirectories(sessionsDir)) {
    const dir = join(sessionsDir, name)
    // 判据是「目录里没有任何 `.jsonl`」，而不是「目录为空」：
    // 残留的子目录 / 索引文件不算数，只要会话文件走光就回收这个项目目录。
    if (listSessionFiles(dir).length === 0) removeIfExists(dir)
  }
}

// MARK: - 小工具

/**
 * 目录下的 `.jsonl` 条目名。
 *
 * 这里刻意**不**用 `listFiles(dir, '.jsonl')`：那个原语会过滤掉非文件项并跳过隐藏项，
 * 这里只要后缀匹配 —— 目录里连一个 jsonl 都没有就回收，含隐藏 jsonl 也回收。
 */
function listSessionFiles(dir: string): string[] {
  let entries: string[]
  try {
    entries = readdirSync(dir)
  } catch {
    return []
  }
  return entries.filter((entry) => entry.endsWith('.jsonl'))
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** 原子写：先写 `.tmp` 再 `rename`，与 `core/prefs.ts` 同一套断电保护。 */
function writeJsonAtomic(path: string, value: unknown): void {
  const tmp = `${path}.tmp`
  try {
    writeFileSync(tmp, `${JSON.stringify(sortKeysDeep(value), null, 2)}\n`, 'utf8')
    renameSync(tmp, path)
  } catch (error) {
    console.error(`[piAgent] 回写 pi-acp session-map 失败 ${path}:`, error)
  }
}

/** 递归按 key 排序，让回写结果稳定可比对。 */
function sortKeysDeep(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeysDeep)
  if (isRecord(value)) {
    const out: Record<string, unknown> = {}
    for (const key of Object.keys(value).sort()) out[key] = sortKeysDeep(value[key])
    return out
  }
  return value
}
