import { basename, extname, join } from 'node:path'

import type { ConversationItem } from '@shared/types'
import { fileSize, listFiles, makeItem, mtimeMs, pathExists } from '@main/core/scanner'

/**
 * Cursor 的目录扫描兜底。
 *
 * 这两条通路都是「只有文件、没有索引」的老布局，所以解析逻辑极简：
 * 文件名去掉扩展名就是 sessionId，体积与时间直接取文件本身，
 * 标题也只由 id 前 8 位拼出来 —— 没有正文可读，编也编不出标题。
 *
 * 1. `User/globalStorage/cursor.cursor/{composer,chats,workspaces}/*.json[l]`
 * 2. `~/.cursor/chats/*.json[l]`
 */

/** 扩展 globalStorage 下会被扫的子目录。 */
const EXTENSION_SUBDIRS = ['composer', 'chats', 'workspaces'] as const

/** 这两个目录下 `.json` 与 `.jsonl` 都要。 */
const ACCEPTED_EXTENSIONS = ['.json', '.jsonl'] as const

/** `cursor.cursor/` 下的会话：一条文件 = 一条会话。 */
export function scanCursorExtensionStorage(dirPath: string): ConversationItem[] {
  const items: ConversationItem[] = []
  for (const sub of EXTENSION_SUBDIRS) {
    const subPath = join(dirPath, sub)
    if (!pathExists(subPath)) continue
    for (const filePath of listAcceptedFiles(subPath)) {
      const sid = basename(filePath, extname(filePath))
      items.push(
        makeItem({
          sessionId: sid,
          title: `Cursor 对话 ${sid.slice(0, 8)}`,
          category: 'cursor',
          projectPath: null,
          gitBranch: null,
          messageCount: 1,
          sizeInBytes: fileSize(filePath),
          updatedAt: fileDate(filePath),
          snippet: 'Cursor 扩展历史会话',
          associatedPaths: [filePath]
        })
      )
    }
  }
  return items
}

/** `~/.cursor/` 下的会话：同样是一条文件 = 一条会话。 */
export function scanDotCursorDirectory(dotPath: string): ConversationItem[] {
  const items: ConversationItem[] = []
  const chatsDir = join(dotPath, 'chats')
  if (!pathExists(chatsDir)) return items
  for (const filePath of listAcceptedFiles(chatsDir)) {
    const sid = basename(filePath, extname(filePath))
    items.push(
      makeItem({
        sessionId: sid,
        title: `Cursor 会话 ${sid.slice(0, 8)}`,
        category: 'cursor',
        projectPath: null,
        gitBranch: null,
        messageCount: 1,
        sizeInBytes: fileSize(filePath),
        updatedAt: fileDate(filePath),
        snippet: 'Cursor 用户目录会话',
        associatedPaths: [filePath]
      })
    )
  }
  return items
}

// MARK: - 小工具

/** `.json` 与 `.jsonl` 都要；目录不存在时 `listFiles` 返回 `[]`，不抛错。 */
function listAcceptedFiles(dirPath: string): string[] {
  return ACCEPTED_EXTENSIONS.flatMap((ext) => listFiles(dirPath, ext))
}

/** mtime；取不到（文件刚好被删）时退回现在。 */
function fileDate(path: string): Date {
  const ms = mtimeMs(path)
  return ms !== undefined ? new Date(ms) : new Date()
}
