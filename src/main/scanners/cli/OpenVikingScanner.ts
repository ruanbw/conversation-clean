import { mkdirSync, realpathSync } from 'node:fs'
import { join, resolve } from 'node:path'
import type { ConversationItem } from '@shared/types'
import type { AgentScanner, ScannerOptions } from '@main/core/scanner'
import {
  deleteItemsWithPaths,
  fileSize,
  listFiles,
  makeItem,
  mapLimit,
  mtimeMs,
  pathExists,
  readJson,
  removeIfEmptyDirectory,
  removeIfExists,
  resolveStoragePath,
  sizeOfPath,
  sortByUpdatedDesc,
  truncate
} from '@main/core/scanner'
import { parseIsoDate } from '@main/core/datetime'

/**
 * OpenViking（`~/.openviking`）扫描器。
 *
 * 磁盘形态与其它扫描器不同：`pending/` 下每个 `.json` 是**一条待处理消息**（不是一条会话），
 * 按 `sessionId` 分组后一个会话 = 一组文件；标题取时间最早的 user 消息。
 * 删除就是删该会话的全部分组文件，再尝试回收 `pending/`。
 *
 * 三处刻意不统一：
 *   1. `cleanAll` **不走** scan+delete，而是直接整个清空 `pending/`（并重建空目录）。
 *      两个理由，第二个才是主要的：
 *      · `scan()` 会把 `sessionId` 为空的文件归到 `''` 组、随后被
 *        `if (sessionId.length === 0) continue` 跳过，于是它们**永远不会成为
 *        `ConversationItem`** —— `delete()` 够不着这些文件，scan+delete 删不干净。
 *      · 「清空本分类」的语义本就是「把这个目录抹干净」，包括扫不出来的那些。
 *        逐条删反而会在目录里留下扫不出来的残留。
 *   2. `createdAt` 的秒/毫秒判定比其它扫描器严：只有 `> 1e9` 的值才当秒（其余直接回落文件
 *      mtime）。早期版本会写下 1e9 附近的秒级时间戳，阈值抬高到 1e12 会把它们误判成毫秒。
 *   3. 标题 / 摘要按 UTF-16 码元切截断，超长非 ASCII 文本末尾可能多/少半个字。
 */

type Dict = Record<string, unknown>

/** `pending/` 里一个 `.json` 解析出来的中间态。 */
interface PendingRecord {
  path: string
  fileSize: number
  fileModDate: number
  sessionId: string
  createdAt: number | null
  role: string | null
  text: string | null
  peerId: string | null
}

export class OpenVikingScanner implements AgentScanner {
  readonly category = 'openViking' as const
  private readonly root: string

  constructor(options: ScannerOptions = {}) {
    // `storagePath` > `OPENVIKING_HOME` > `~/.openviking`，随后做一次 realpath 规范化。
    this.root = options.storagePath
      ? canonical(options.storagePath)
      : resolveStoragePath(['.openviking'], { key: 'OPENVIKING_HOME' })
  }

  get storagePath(): string {
    return this.root
  }

  get isInstalled(): boolean {
    return pathExists(this.root)
  }

  // MARK: - Scan

  async scan(): Promise<ConversationItem[]> {
    if (!this.isInstalled) return []

    const pendingDir = join(this.root, 'pending')
    if (!pathExists(pendingDir)) return []

    // 跳过隐藏项后按扩展名过滤
    const jsonFiles = listFiles(pendingDir, '.json')
    if (jsonFiles.length === 0) return []

    // 有界并发解析
    const records = await mapLimit(jsonFiles, 16, (file) => parsePendingFile(file))
    const usable = records.filter((record): record is PendingRecord => record !== null)
    if (usable.length === 0) return []

    // 按 sessionId 分组
    const grouped = new Map<string, PendingRecord[]>()
    for (const record of usable) {
      const bucket = grouped.get(record.sessionId)
      if (bucket) bucket.push(record)
      else grouped.set(record.sessionId, [record])
    }

    const items: ConversationItem[] = []
    for (const [sessionId, sessionRecords] of grouped) {
      if (sessionId.length === 0) continue

      let sizeInBytes = 0
      for (const record of sessionRecords) sizeInBytes += record.fileSize
      const messageCount = sessionRecords.length
      const associatedPaths = sessionRecords.map((record) => record.path).sort()

      // 按时间升序，找最早的消息并取最新时间戳
      const sortedByTime = [...sessionRecords].sort((a, b) => timeOf(a) - timeOf(b))
      const last = sortedByTime[sortedByTime.length - 1]
      const latestDate = new Date((last?.createdAt ?? last?.fileModDate) ?? Date.now())

      let firstUserPrompt: string | null = null
      let firstAnyText: string | null = null
      let detectedPeerId: string | null = null

      for (const record of sortedByTime) {
        if (detectedPeerId === null && record.peerId !== null && record.peerId.length > 0) {
          detectedPeerId = record.peerId
        }
        if (record.text !== null && record.text.length > 0) {
          if (firstAnyText === null) firstAnyText = record.text
          if (record.role === 'user' && firstUserPrompt === null) {
            firstUserPrompt = record.text
            break
          }
        }
      }

      // 标题与摘要同源：优先 user 消息，否则任意文本；都没有就走兜底文案
      const firstText = nonEmpty(firstUserPrompt) ?? nonEmpty(firstAnyText)
      const title = firstText !== null ? oneLine(truncate(firstText, 80)) : `OpenViking 会话 ${sessionId.slice(0, 8)}`
      const snippet =
        firstText !== null ? oneLine(truncate(firstText, 120)) : `包含 ${messageCount} 条待处理消息与操作记录`

      items.push(
        makeItem({
          sessionId,
          title,
          category: this.category,
          projectPath: resolveProjectPath(detectedPeerId),
          gitBranch: null,
          messageCount,
          sizeInBytes,
          updatedAt: latestDate,
          snippet,
          associatedPaths
        })
      )
    }

    return sortByUpdatedDesc(items)
  }

  // MARK: - Deletion & Clean

  async delete(items: ConversationItem[]): Promise<number> {
    if (items.length === 0) return 0
    const freed = await deleteItemsWithPaths(items)
    removeIfEmptyDirectory(join(this.root, 'pending'))
    return freed
  }

  async cleanAll(): Promise<number> {
    if (!this.isInstalled) return 0

    // cleanAll 不走 scan+delete：`pending/` 整个删掉再重建空目录。
    let freed = 0
    const pendingDir = join(this.root, 'pending')
    if (pathExists(pendingDir)) {
      freed += sizeOfPath(pendingDir)
      removeIfExists(pendingDir)
      try {
        mkdirSync(pendingDir, { recursive: true })
      } catch {
        // 重建失败不改变本次清理结果（目录给不回去也不能报错）
      }
    }
    return freed
  }
}

// MARK: - File Parsing Helpers

function parsePendingFile(path: string): PendingRecord | null {
  const json = readJson<Dict>(path)
  if (!isDict(json)) return null

  const sessionId = json['sessionId']
  if (typeof sessionId !== 'string' || sessionId.length === 0) return null

  const mtime = mtimeMs(path) ?? Date.now()

  let createdAt: number | null = null
  const raw = json['createdAt']
  if (typeof raw === 'number') {
    // 毫秒原值 / 秒（×1000 换成 JS 的毫秒制）。秒的下限是 1e9 而非 0：
    // 早期版本会写 1e9 附近的秒级时间戳，判成毫秒会得到 1970 年；
    // 小于 1e9 的值直接不要（`createdAt` 留 null，回落到文件 mtime）。
    if (raw > 1_000_000_000_000) createdAt = raw
    else if (raw > 1_000_000_000) createdAt = raw * 1000
  } else if (typeof raw === 'string') {
    const parsed = parseIsoDate(raw)
    if (parsed !== null) createdAt = parsed.getTime()
  }

  const payload = isDict(json['payload']) ? json['payload'] : null
  const role = payload !== null && typeof payload['role'] === 'string' ? payload['role'] : null
  const peerId =
    payload !== null && typeof payload['peer_id'] === 'string' ? payload['peer_id'] : null

  if (createdAt === null && payload !== null && typeof payload['created_at'] === 'string') {
    const parsed = parseIsoDate(payload['created_at'])
    if (parsed !== null) createdAt = parsed.getTime()
  }

  return {
    path,
    fileSize: fileSize(path),
    fileModDate: mtime,
    sessionId,
    createdAt,
    role,
    text: extractText(payload),
    peerId
  }
}

function timeOf(record: PendingRecord): number {
  return record.createdAt ?? record.fileModDate
}

/**
 * 从 `payload` 里挖出可读文本，顺序（行为如此，勿调换）：
 * `parts[].text`（先只认 `type == "text"`，再退到任意 `text`）→ `payload.text` → `content` → `prompt`。
 */
function extractText(payload: Dict | null): string | null {
  if (payload === null) return null

  const parts = payload['parts']
  if (Array.isArray(parts)) {
    for (const part of parts) {
      if (!isDict(part)) continue
      if (part['type'] !== 'text') continue
      const trimmed = trimmedText(part['text'])
      if (trimmed !== null) return trimmed
    }
    for (const part of parts) {
      if (!isDict(part)) continue
      const trimmed = trimmedText(part['text'])
      if (trimmed !== null) return trimmed
    }
  }

  for (const key of ['text', 'content', 'prompt'] as const) {
    const trimmed = trimmedText(payload[key])
    if (trimmed !== null) return trimmed
  }

  return null
}

function trimmedText(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed.length > 0 ? trimmed : null
}

/**
 * `peer_id` 形如 `-Users-tester-projects-my-app`（OpenViking 把绝对路径的 `/` 换成 `-`）。
 * 直接还原成路径；还原不出来就逐段在文件系统上试，能对上哪段就拼哪段 ——
 * 目录名本身带连字符时（`flow-filtering-system`）才认得出来。
 */
function resolveProjectPath(peerId: string | null): string | null {
  if (peerId === null || !peerId.startsWith('-')) return null

  const directCandidate = '/' + peerId.slice(1).replaceAll('-', '/')
  if (pathExists(directCandidate)) return directCandidate

  const segments = peerId.split('-').filter((segment) => segment.length > 0)
  if (segments.length === 0) return directCandidate

  let current = ''
  for (const segment of segments) {
    if (current.length === 0) {
      current = '/' + segment
      continue
    }
    const slashPath = `${current}/${segment}`
    const hyphenPath = `${current}-${segment}`
    if (pathExists(slashPath)) current = slashPath
    else if (pathExists(hyphenPath)) current = hyphenPath
    else current = slashPath
  }

  return pathExists(current) ? current : directCandidate
}

// MARK: - 杂项

function isDict(value: unknown): value is Dict {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function nonEmpty(value: string | null): string | null {
  return value !== null && value.length > 0 ? value : null
}

/** 只换 `\n`，不动 `\r`。 */
function oneLine(text: string): string {
  return text.replaceAll('\n', ' ')
}

function canonical(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return resolve(path)
  }
}
