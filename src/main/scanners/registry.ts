import type { AgentCategory, AgentInfo, ConversationItem, ScanIssue } from '@shared/types'
import { SCANNER_CATEGORIES } from '@shared/types'
import type { AgentScanner } from '@main/core/scanner'

import { ClaudeCodeScanner } from './cli/ClaudeCodeScanner'
import { CodexScanner } from './cli/CodexScanner'
import { PiAgentScanner } from './cli/PiAgentScanner'
import { ClineScanner } from './cli/ClineScanner'
import { RooCodeScanner } from './cli/RooCodeScanner'
import { ContinueScanner } from './cli/ContinueScanner'
import { OpenVikingScanner } from './cli/OpenVikingScanner'
import { AiderScanner } from './cli/AiderScanner'
import { ZedScanner } from './cli/ZedScanner'
import { OpenHandsScanner } from './cli/OpenHandsScanner'
import { VSCodeChatScanner } from './vscode/VSCodeChatScanner'
import { CursorScanner } from './vscode/CursorScanner'
import { WindsurfScanner } from './vscode/WindsurfScanner'
import { TraeScanner } from './vscode/TraeScanner'
import { AntigravityScanner } from './vscode/AntigravityScanner'

/**
 * 全部 15 个扫描器的注册表。
 *
 * 移植自 Swift 版 `Core/AgentScanService.swift` 的 `AgentScanService.shared.scanners`，
 * **顺序逐个对应**：侧栏的分类顺序、扫描的并发顺序都依赖它。
 *
 * 新增扫描器时只改这里一处，不要在别处再 `new` 一遍。
 */
export function createScanners(): AgentScanner[] {
  return [
    new ClaudeCodeScanner(),
    new CodexScanner(),
    new ClineScanner(),
    new RooCodeScanner(),
    new ContinueScanner(),
    new PiAgentScanner(),
    new VSCodeChatScanner(),
    new CursorScanner(),
    new WindsurfScanner(),
    new TraeScanner(),
    new OpenVikingScanner(),
    new AiderScanner(),
    new ZedScanner(),
    new OpenHandsScanner(),
    new AntigravityScanner()
  ]
}

/** 一次性实例化：整个进程共用一份扫描器（它们无状态，但 `storagePath` 解析要读盘）。 */
let shared: AgentScanner[] | null = null

export function allScanners(): AgentScanner[] {
  if (shared === null) shared = createScanners()
  return shared
}

/** 按分类取扫描器；`all` 或未找到返回 `null`。 */
export function scannerFor(category: AgentCategory): AgentScanner | null {
  if (category === 'all') return null
  return allScanners().find((scanner) => scanner.category === category) ?? null
}

/** 校验注册表完整性：15 个分类一一对应，不多不少。启动时打一条日志，出错立刻能看出来。 */
export function validateRegistry(scanners: AgentScanner[] = allScanners()): string[] {
  const problems: string[] = []
  const seen = new Set<string>()
  for (const scanner of scanners) {
    if (seen.has(scanner.category)) problems.push(`分类重复：${scanner.category}`)
    seen.add(scanner.category)
  }
  for (const category of SCANNER_CATEGORIES) {
    if (!seen.has(category)) problems.push(`注册表缺少分类：${category}`)
  }
  if (scanners.length !== SCANNER_CATEGORIES.length) {
    problems.push(`扫描器数量应为 ${SCANNER_CATEGORIES.length}，实际 ${scanners.length}`)
  }
  return problems
}

/**
 * 并发扫描全部 Agent 并聚合。
 *
 * 移植自 Swift 版 `AgentScanService.scanAll()`（那里用 `withTaskGroup`）。
 * 这里用 `Promise.all` + 逐个 `catch`：**一个 Agent 挂掉不能拖垮整次扫描**，
 * 失败原因进 `issues` 带回 UI。
 */
export async function scanAll(
  scanners: AgentScanner[] = allScanners()
): Promise<{ items: ConversationItem[]; issues: ScanIssue[] }> {
  const results = await Promise.all(
    scanners.map(async (scanner): Promise<{ items: ConversationItem[]; issue?: ScanIssue }> => {
      try {
        return { items: await scanner.scan() }
      } catch (error) {
        return {
          items: [],
          issue: { category: scanner.category, message: errorMessage(error) }
        }
      }
    })
  )

  const items: ConversationItem[] = []
  const issues: ScanIssue[] = []
  for (const result of results) {
    items.push(...result.items)
    if (result.issue) issues.push(result.issue)
  }
  // Swift 版同样是全局按 updatedAt 倒序，不按分类分组。
  items.sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : a.updatedAt > b.updatedAt ? -1 : 0))
  return { items, issues }
}

/**
 * 按分类分组删除。
 *
 * 同一分类的会话必须**一起**交给同一个扫描器：Cursor / Claude Code 这类
 * 「删文件 + 改索引」的实现需要看到完整的待删 sessionId 集合才能正确裁剪索引。
 */
export async function deleteItems(
  items: readonly ConversationItem[],
  scanners: AgentScanner[] = allScanners()
): Promise<number> {
  if (items.length === 0) return 0

  const byCategory = new Map<string, ConversationItem[]>()
  for (const item of items) {
    const bucket = byCategory.get(item.category)
    if (bucket) bucket.push(item)
    else byCategory.set(item.category, [item])
  }

  let totalFreed = 0
  for (const [category, categoryItems] of byCategory) {
    const scanner = scanners.find((s) => s.category === category)
    if (!scanner) continue
    try {
      totalFreed += await scanner.delete(categoryItems)
    } catch (error) {
      console.error(`[scan] 删除 ${category} 失败：`, error)
    }
  }
  return totalFreed
}

/**
 * 清空指定分类（`null` / `all` = 全部）的会话。
 * 与 Swift 版一致：逐个扫描器串行执行，不并发 —— 多个扫描器同时删磁盘上的
 * 同一批目录会互相干扰，收益（省时间）远小于风险。
 */
export async function cleanAll(
  category: AgentCategory | null = null,
  scanners: AgentScanner[] = allScanners()
): Promise<number> {
  let totalFreed = 0
  for (const scanner of scanners) {
    if (category !== null && category !== 'all' && scanner.category !== category) continue
    try {
      totalFreed += await scanner.cleanAll()
    } catch (error) {
      console.error(`[scan] 清空 ${scanner.category} 失败：`, error)
    }
  }
  return totalFreed
}

/** 从会话列表反推每个分类的体检数据。侧栏「可回收空间」与设置页都用它。 */
export function agentInfosFrom(
  items: readonly ConversationItem[],
  scanners: AgentScanner[] = allScanners()
): AgentInfo[] {
  return scanners.map((scanner) => {
    let sessionCount = 0
    let totalBytes = 0
    for (const item of items) {
      if (item.category !== scanner.category) continue
      sessionCount += 1
      totalBytes += item.sizeInBytes
    }
    return {
      category: scanner.category,
      isInstalled: scanner.isInstalled,
      storagePath: scanner.storagePath,
      sessionCount,
      totalBytes
    }
  })
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  return String(error)
}
