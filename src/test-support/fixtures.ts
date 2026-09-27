/**
 * 测试夹具工厂（文件系统 + 会话条目部分）。
 *
 * **一条必须遵守的约定：临时目录必须解析符号链接（realpath）。**
 * macOS 的 `tmpdir()` 给的是 `/var/folders/...`，真身却是 `/private/var/folders/...`；
 * 不 realpath 的话，扫描器里 `resolveStoragePath` 返回的规范路径和断言里的路径对不上，
 * 整条 `delete()` 链路的断言会随机红。
 *
 * **测试不要读用户真实目录**：一律用 `useTempDir()` / `createTempDir()` 自造夹具，
 * 否则会扫到本机真实会话数据，用例结果不可复现。
 *
 * 本文件**只导出辅助函数**，不含任何 `describe` / `test`。
 * SQLite 夹具（mock `state.vscdb` / `session-store.db`）在 `./sqliteFixtures`。
 */

import { randomUUID } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterEach } from 'vitest'
import { sizeOfPath } from '@main/core/fsutil'
import type { AgentCategory, ConversationItem } from '@shared/types'

// MARK: - 临时目录

/**
 * 建一个临时目录并返回其 **realpath**（macOS 的 `/var` 是 `/private/var` 的软链，
 * 不解析会让所有路径断言错位）。
 *
 * 目录会被登记到模块内的登记表，`cleanupTempDirs()` 一次全删。
 */
export function createTempDir(prefix = 'cc-test-'): string {
  const raw = mkdtempSync(join(tmpdir(), prefix))
  // 符号链接已解析：macOS 的 tmpdir 是 /var → /private/var 的软链。
  const resolved = realpathSafe(raw)
  if (resolved !== raw) createdTempDirs.add(resolved)
  createdTempDirs.add(raw)
  return resolved
}

const createdTempDirs = new Set<string>()

/** 删掉一个临时目录（不存在也不报错）。 */
export function removeTempDir(dir: string): void {
  createdTempDirs.delete(dir)
  rmSync(dir, { recursive: true, force: true })
}

/** 删掉本进程内 `createTempDir` 建过的全部临时目录。 */
export function cleanupTempDirs(): void {
  for (const dir of [...createdTempDirs]) removeTempDir(dir)
}

/**
 * 一行版：建临时目录 + 注册 `afterEach` 自动清理。
 *
 * 顶层（文件作用域）与 `describe` 作用域都合法：vitest 里顶层 `afterEach`
 * 是文件级钩子，对本文件每个用例都生效。
 *
 * ```ts
 * describe('ClaudeCodeScanner', () => {
 *   const root = useTempDir('cc-claude-')
 *   it('…', () => { writeFile(join(root, 'x.jsonl'), '…') })
 * })
 * ```
 */
export function useTempDir(prefix?: string): string {
  const dir = createTempDir(prefix)
  afterEach(() => removeTempDir(dir))
  return dir
}

/** 跑一段用到临时目录的逻辑，结束后无条件清理。 */
export async function withTempDir<T>(fn: (dir: string) => T | Promise<T>, prefix?: string): Promise<T> {
  const dir = createTempDir(prefix)
  try {
    return await fn(dir)
  } finally {
    removeTempDir(dir)
  }
}

// MARK: - 目录 / 文件

/** 递归建目录，返回传入的路径。 */
export function ensureDir(path: string): string {
  mkdirSync(path, { recursive: true })
  return path
}

/** 写 UTF-8 文本（父目录自动创建），返回落盘路径。 */
export function writeFile(path: string, content: string): string {
  ensureDir(dirname(path))
  writeFileSync(path, content, 'utf8')
  return path
}

/** 在 `dir` 下以 `name` 写 UTF-8 文本并返回绝对路径。 */
export function writeFileIn(dir: string, name: string, content: string): string {
  return writeFile(join(dir, name), content)
}

/** 写 JSON 文件（无缩进，键序即对象字面量序）。 */
export function writeJsonFile(path: string, value: unknown): string {
  return writeFile(path, JSON.stringify(value))
}

/** 写 JSONL 文件：每条一行。`values` 里的字符串按原样写（可用来塞坏行）。 */
export function writeJsonLinesFile(path: string, values: readonly unknown[]): string {
  const lines = values.map((v) => (typeof v === 'string' ? v : JSON.stringify(v)))
  return writeFile(path, `${lines.join('\n')}\n`)
}

/** 拼路径的小糖：`p('a', 'b')` → `<a>/<b>`。 */
export function p(...segments: string[]): string {
  return join(...segments)
}

/** 路径是否还在（断言删除结果用）。 */
export function exists(path: string): boolean {
  return existsSync(path)
}

function realpathSafe(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

// MARK: - 会话条目

/** `makeItem` 的输入，字段名与 `core/scanner.ts` 一致。 */
export interface SessionSpec {
  sessionId: string
  category?: Exclude<AgentCategory, 'all'>
  title?: string
  projectPath?: string | null
  gitBranch?: string | null
  messageCount?: number
  sizeInBytes?: number
  updatedAt?: Date
  snippet?: string
  associatedPaths?: string[]
  id?: string
}

/**
 * 造一条 `ConversationItem`，只要求给 `sessionId`，其余按 `makeItem` 的默认值补齐。
 *
 * 这里直接构造对象而**不** import `@main/core/scanner`：
 * 那个模块会顺着 `prefs` 拉进 `electron`，夹具模块要能被任意测试环境直接 import。
 * 默认值口径与 `makeItem` 保持一致（见 `scanner.test.ts` 对 `makeItem` 的断言）。
 */
export function makeConversationItem(spec: SessionSpec): ConversationItem {
  const size = spec.sizeInBytes ?? 0
  return {
    id: spec.id ?? randomUUID(),
    sessionId: spec.sessionId,
    title: spec.title ?? spec.sessionId,
    category: spec.category ?? 'claudeCode',
    projectPath: spec.projectPath ?? null,
    gitBranch: spec.gitBranch ?? null,
    messageCount: spec.messageCount ?? 0,
    sizeInBytes: size,
    updatedAt: (spec.updatedAt ?? new Date(0)).toISOString(),
    isSelected: false,
    snippet: spec.snippet ?? '',
    associatedPaths: spec.associatedPaths ?? []
  }
}

/** 批量造会话条目（`sizeInBytes` 默认按序号递增，方便断言排序 / 扣减）。 */
export function makeConversationItems(
  sessionIds: readonly string[],
  overrides: Partial<SessionSpec> = {}
): ConversationItem[] {
  return sessionIds.map((sessionId, index) =>
    makeConversationItem({
      ...overrides,
      sessionId,
      sizeInBytes: overrides.sizeInBytes ?? index * 100
    })
  )
}

/** 往已有条目上打补丁（扫描器用例里改 `isSelected` 之类）。 */
export function patchItem(
  item: ConversationItem,
  patch: Partial<ConversationItem>
): ConversationItem {
  return { ...item, ...patch }
}

// MARK: - 常用路径形状

/** `<dir>/<sessionId>.jsonl` —— Claude Code / Pi Agent 一类会话正文。 */
export function sessionJsonlPath(dir: string, sessionId: string): string {
  return join(dir, `${sessionId}.jsonl`)
}

/** `<dir>/<sessionId>/` —— 目录型 Agent（Cline / Cursor / OpenHands…）的会话目录。 */
export function sessionDirPath(dir: string, sessionId: string): string {
  return join(dir, sessionId)
}

/** 快照目录：`<agentRoot>/<kind>/<sessionId>/`，`kind` 取 5 个快照目录名之一。 */
export type SnapshotKind = 'file-history' | 'shell-snapshots' | 'backups' | 'checkpoints' | 'chatEditingSessions'

/** 造一个「被 `cleanFileHistorySnapshots` 开关控制」的快照目录，返回绝对路径。 */
export function makeSnapshotDir(agentRoot: string, kind: SnapshotKind, sessionId: string): string {
  const dir = ensureDir(join(agentRoot, kind, sessionId))
  writeFile(join(dir, 'state.json'), '{"version":1}')
  return dir
}

/** 造一条「会话正文 + 快照」组合，返回条目本身（`associatedPaths` 已填好）。
 *
 *  `sizeInBytes` 用 `sizeOfPath` 现场量两个路径（**目录是递归求和**，
 *  与 `scanner.ts` / `fsutil.ts` 的口径完全一致），所以可以直接拿去
 *  断言 `delete()` 返回的 freed 扣减。 */
export function makeSessionWithSnapshot(options: {
  agentRoot: string
  sessionId: string
  snapshotKind?: SnapshotKind
  bodyBytes?: number
  updatedAt?: Date
  category?: Exclude<AgentCategory, 'all'>
}): ConversationItem {
  const bodyPath = sessionJsonlPath(options.agentRoot, options.sessionId)
  writeFile(bodyPath, 'x'.repeat(options.bodyBytes ?? 128))
  const snapshotDir = makeSnapshotDir(
    options.agentRoot,
    options.snapshotKind ?? 'file-history',
    options.sessionId
  )
  return makeConversationItem({
    sessionId: options.sessionId,
    category: options.category ?? 'claudeCode',
    sizeInBytes: sizeOfPath(bodyPath) + sizeOfPath(snapshotDir),
    updatedAt: options.updatedAt ?? new Date(0),
    associatedPaths: [bodyPath, snapshotDir]
  })
}
