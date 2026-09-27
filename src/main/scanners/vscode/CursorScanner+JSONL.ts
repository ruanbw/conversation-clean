import { basename, extname } from 'node:path'

import type { ConversationItem } from '@shared/types'
import { fileSize, makeItem, mtimeMs, pathExists, readJsonLines } from '@main/core/scanner'
import { sizeOfPath } from '@main/core/fsutil'
import type { CursorScanTarget } from './CursorScanner'

/**
 * Cursor 的 `chatSessions/*.jsonl` 解析。
 *
 * 移植自 Swift 版 `Scanners/VSCodeFamily/CursorScanner+JSONL.swift` 的
 * `parseJsonlSession(target:)`。
 *
 * 会话文件是**增量日志**：`kind:0` 全量快照、`kind:1` 属性更新、`kind:2` 数组追加。
 * 任何一行解析失败都跳过 —— Agent 正在写文件时半截行是常态。
 *
 * ⚠️ 与 `VSCodeChatScanner` 的两处刻意的**不一致**（照抄 Swift，不是笔误）：
 * 1. 兜底标题是「Cursor 对话」而不是「GitHub Copilot 对话」；
 * 2. 少了「顶层 `requests` 数组」那一条兜底分支，所以非增量格式的老会话
 *    标题会一律落到兜底文案。
 */

/** 会话正文为空时的兜底标题。 */
const FALLBACK_TITLE = 'Cursor 对话'

/**
 * 解析一条会话文件，失败（文件已消失 / 读不了）返回 `null`。
 * 与 Swift 的 `-> ConversationItem?` 一致：单条坏会话不该让整个分类消失。
 */
export function parseJsonlSession(target: CursorScanTarget): ConversationItem | null {
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

  const associatedPaths = [target.filePath]
  let totalSize = mainFileSize
  if (target.editingDirPath !== null && pathExists(target.editingDirPath)) {
    associatedPaths.push(target.editingDirPath)
    totalSize += sizeOfPath(target.editingDirPath)
  }

  return makeItem({
    sessionId,
    title: finalTitle,
    category: 'cursor',
    projectPath: target.projectPath,
    gitBranch: null,
    messageCount: requestCount,
    sizeInBytes: totalSize,
    updatedAt,
    snippet,
    associatedPaths
  })
}

/** 从一条 request 里挖出用户提问文本，兼容 4 种历史字段名。 */
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

/** `components(separatedBy: .newlines).first` —— 取第一行。 */
function firstLine(text: string): string {
  // .newlines = \n \r \r\n 以及 U+0085 / U+2028 / U+2029
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
