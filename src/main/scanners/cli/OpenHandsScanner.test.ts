import { existsSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join, relative } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ConversationItem } from '@shared/types'
import { CleanPrefs, sizeOfPath } from '@main/core/scanner'
import { OpenHandsScanner } from './OpenHandsScanner'

/**
 * OpenHands 扫描器用例。
 *
 * 自包含：夹具全部现造在 `os.tmpdir()` 下（`mkdtempSync`），不依赖任何其它测试文件；
 * 最后一个只读用例扫本机真实的 `~/.openhands` / `~/.open-devin`（不存在就跳过）。
 *
 * 注意：注入 `storagePath` 之后，**扫描用的目录来自注入值本身**（不是 realpath 之后的
 * `storagePath`），所以这里断言 `associatedPaths` 一律用 `rawRoot` 而不是 `scanner.storagePath`。
 */

let rawRoot = ''
let outsideDir = ''
let scanner: OpenHandsScanner
const extraRoots: string[] = []

const SESSION_1 = 'session-oh-001'
const SESSION_2 = 'session-oh-002'

function writeJson(path: string, value: unknown): void {
  writeFileSync(path, JSON.stringify(value), 'utf8')
}

function writeText(path: string, text: string): void {
  writeFileSync(path, text, 'utf8')
}

/** 与用例逐条对齐的夹具。 */
function buildFixture(base: string): void {
  mkdirSync(join(base, 'sessions'), { recursive: true })
  mkdirSync(join(base, 'logs'), { recursive: true })
  mkdirSync(join(base, 'workspace'), { recursive: true })

  // 1. 目录形态会话：metadata.json + events.jsonl
  const session1 = join(base, 'sessions', SESSION_1)
  mkdirSync(session1, { recursive: true })
  writeJson(join(session1, 'metadata.json'), {
    session_id: SESSION_1,
    title: 'Implement Stripe webhook handler',
    directory: '/Users/tester/payment-api',
    created_at: '2026-09-20T10:00:00Z'
  })
  writeText(
    join(session1, 'events.jsonl'),
    '{"action":"message","args":{"content":"Please implement stripe webhook verification"},"timestamp":"2026-09-20T10:00:05Z"}\n' +
      '{"action":"run","args":{"command":"go test ./..."},"timestamp":"2026-09-20T10:00:10Z"}\n'
  )

  // 2. 单文件形态会话：sessions/<id>.json
  writeJson(join(base, 'sessions', `${SESSION_2}.json`), {
    session_id: SESSION_2,
    title: 'Fix CSS grid responsiveness',
    events: [{}, {}, {}]
  })

  // 3. 日志：一条对上 session-oh-001，一条是系统日志（对不上任何会话）
  writeText(join(base, 'logs', `${SESSION_1}.log`), 'session log entry line 1\nline 2\n')
  writeText(join(base, 'logs', 'openhands-server.log'), 'server starting on :3000\nready\n')

  // 4. workspace：目录名对上 session-oh-001
  const workspace = join(base, 'workspace', SESSION_1)
  mkdirSync(workspace, { recursive: true })
  writeText(join(workspace, 'webhook.go'), 'package main')
}

function find(items: readonly ConversationItem[], sessionId: string): ConversationItem {
  const item = items.find((candidate) => candidate.sessionId === sessionId)
  expect(item, `应当能找到会话 ${sessionId}`).toBeDefined()
  return item as ConversationItem
}

/** 目录树快照；用于「只读」与「双分支行为一致」两类断言。 */
function treeSnapshot(dir: string): Map<string, string> {
  const out = new Map<string, string>()
  const walk = (current: string): void => {
    let entries
    try {
      entries = readdirSync(current, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      const full = join(current, entry.name)
      const rel = relative(dir, full)
      if (entry.isDirectory()) {
        out.set(rel, 'dir')
        walk(full)
      } else {
        const stats = statSync(full)
        out.set(rel, `${stats.size}@${stats.mtimeMs}`)
      }
    }
  }
  walk(dir)
  return out
}

function freshFixture(): { scanner: OpenHandsScanner; raw: string } {
  const base = mkdtempSync(join(tmpdir(), 'mock_openhands_'))
  extraRoots.push(base)
  buildFixture(base)
  return { scanner: new OpenHandsScanner({ storagePath: base }), raw: base }
}

beforeEach(() => {
  rawRoot = mkdtempSync(join(tmpdir(), 'mock_openhands_'))
  outsideDir = mkdtempSync(join(tmpdir(), 'mock_openhands_outside_'))
  buildFixture(rawRoot)
  scanner = new OpenHandsScanner({ storagePath: rawRoot })
  CleanPrefs.patch({ cleanFileHistorySnapshots: true, cleanEmptyProjectFolders: true })
})

afterEach(() => {
  for (const dir of [rawRoot, outsideDir, ...extraRoots]) {
    rmSync(dir, { recursive: true, force: true })
  }
  extraRoots.length = 0
  // 还原成默认开关，别把偏好写坏给后面的测试文件。
  CleanPrefs.patch({ cleanFileHistorySnapshots: true, cleanEmptyProjectFolders: true })
})

describe('OpenHandsScanner · storagePath', () => {
  it('OPENHANDS_HOME 优先于默认目录，且这一支不做 realpath 规范化', () => {
    const previous = process.env.OPENHANDS_HOME
    process.env.OPENHANDS_HOME = rawRoot
    try {
      expect(new OpenHandsScanner().storagePath).toBe(rawRoot)
    } finally {
      if (previous === undefined) delete process.env.OPENHANDS_HOME
      else process.env.OPENHANDS_HOME = previous
    }
  })

  it('没有环境变量时在 ~/.openhands 与 ~/.open-devin 之间二选一', () => {
    const previous = process.env.OPENHANDS_HOME
    delete process.env.OPENHANDS_HOME
    try {
      const primary = join(homedir(), '.openhands')
      const legacy = join(homedir(), '.open-devin')
      const expected = existsSync(primary) ? primary : existsSync(legacy) ? legacy : primary
      expect(new OpenHandsScanner().storagePath).toBe(expected)
    } finally {
      if (previous !== undefined) process.env.OPENHANDS_HOME = previous
    }
  })

  it('注入路径会被 realpath 规范化，但扫描用的是注入的原始路径', () => {
    // storagePath 走 canonicalPath，associatedPaths 走 custom 本身 —— 两者同源不同值。
    expect(scanner.storagePath).toBe(realpathSync(rawRoot))
    expect(scanner.storagePath).not.toBe(rawRoot) // macOS 的 /var → /private/var
    expect(scanner.isInstalled).toBe(true)
  })

  it('未安装时 isInstalled=false 且 scan() 返回空数组', async () => {
    const missing = new OpenHandsScanner({ storagePath: join(rawRoot, 'no-such-dir') })
    expect(missing.isInstalled).toBe(false)
    await expect(missing.scan()).resolves.toEqual([])
    await expect(missing.delete([])).resolves.toBe(0)
  })
})

describe('OpenHandsScanner · 夹具扫描', () => {
  it('列出会话并把 logs / workspace 关联上去，无主日志聚合成一条', async () => {
    const items = await scanner.scan()

    expect(items).toHaveLength(3)
    expect(items.every((item) => item.category === 'openHands')).toBe(true)
    // 两条会话的来源是刚生成的文件，只有 session-oh-001 用了 metadata 里的历史时间戳。
    expect(items[items.length - 1]?.sessionId).toBe(SESSION_1)

    const session1 = find(items, SESSION_1)
    expect(session1.title).toBe('Implement Stripe webhook handler')
    expect(session1.snippet).toBe('Implement Stripe webhook handler')
    expect(session1.projectPath).toBe('/Users/tester/payment-api')
    expect(session1.messageCount).toBe(2)
    expect(session1.updatedAt).toBe('2026-09-20T10:00:00.000Z')
    expect(session1.associatedPaths).toEqual([
      join(rawRoot, 'sessions', SESSION_1),
      join(rawRoot, 'logs', `${SESSION_1}.log`),
      join(rawRoot, 'workspace', SESSION_1)
    ])
    expect(session1.sizeInBytes).toBe(
      sizeOfPath(join(rawRoot, 'sessions', SESSION_1)) +
        sizeOfPath(join(rawRoot, 'logs', `${SESSION_1}.log`)) +
        sizeOfPath(join(rawRoot, 'workspace', SESSION_1))
    )

    const session2 = find(items, SESSION_2)
    expect(session2.title).toBe('Fix CSS grid responsiveness')
    expect(session2.messageCount).toBe(3)
    expect(session2.associatedPaths).toEqual([join(rawRoot, 'sessions', `${SESSION_2}.json`)])

    const logGroup = items.find((item) => item.sessionId.startsWith('openhands-logs-'))
    expect(logGroup).toBeDefined()
    expect(logGroup?.associatedPaths).toEqual([join(rawRoot, 'logs', 'openhands-server.log')])
    expect(logGroup?.messageCount).toBe(1)
    expect(logGroup?.projectPath).toBe(join(rawRoot, 'logs'))
    expect(logGroup?.title).toContain('1 个文件')
  })

  it('解析兜底：无 metadata 的目录取 events.json 里的首条用户输入', async () => {
    const dir = join(rawRoot, 'sessions', 'session-oh-003')
    mkdirSync(dir, { recursive: true })
    writeJson(join(dir, 'events.json'), [
      { action: 'run', args: { command: 'ls' } },
      { action: 'message', source: 'user', args: { content: '  修复构建失败  ' } }
    ])

    const item = find(await scanner.scan(), 'session-oh-003')
    expect(item.title).toBe('修复构建失败')
    expect(item.snippet).toBe('修复构建失败')
    expect(item.projectPath).toBeNull()
    expect(item.messageCount).toBe(2)
  })

  it('解析兜底：单文件 .jsonl 会话的标题来自首个用户事件', async () => {
    writeText(
      join(rawRoot, 'sessions', 'session-oh-004.jsonl'),
      '{"action":"message","args":{"content":"写个 README"}}\n{"action":"run","args":{"command":"ls"}}\n{"action":"message","args":{"content":"再来一次"}}\n'
    )
    const item = find(await scanner.scan(), 'session-oh-004')
    expect(item.title).toBe('写个 README')
    expect(item.messageCount).toBe(3)
    expect(item.associatedPaths).toEqual([join(rawRoot, 'sessions', 'session-oh-004.jsonl')])
  })

  it('隐藏会话目录被跳过，坏 JSON 只降级不抛错', async () => {
    const hidden = join(rawRoot, 'sessions', '.tmp-session')
    mkdirSync(hidden, { recursive: true })
    writeJson(join(hidden, 'metadata.json'), { title: '不该被看到' })
    writeFileSync(join(rawRoot, 'sessions', 'broken.json'), '{ not json', 'utf8')

    const items = await scanner.scan()
    expect(items.some((item) => item.title === '不该被看到')).toBe(false)
    expect(find(items, 'broken').title).toBe('OpenHands 会话 broken')
    expect(find(items, 'broken').messageCount).toBe(1)
  })
})

describe('OpenHandsScanner · 删除', () => {
  it('删除会话：目录 / 日志 / workspace 一起消失，其它会话与系统日志保留', async () => {
    const session1 = find(await scanner.scan(), SESSION_1)

    const freed = await scanner.delete([session1])

    expect(freed).toBe(session1.sizeInBytes)
    expect(existsSync(join(rawRoot, 'sessions', SESSION_1))).toBe(false)
    expect(existsSync(join(rawRoot, 'logs', `${SESSION_1}.log`))).toBe(false)
    expect(existsSync(join(rawRoot, 'workspace', SESSION_1))).toBe(false)
    expect(existsSync(join(rawRoot, 'sessions', `${SESSION_2}.json`))).toBe(true)
    expect(existsSync(join(rawRoot, 'logs', 'openhands-server.log'))).toBe(true)
  })

  it('数据根之外的路径被 isSafeToDelete 拦下（但 freedBytes 照记）', async () => {
    const outside = join(outsideDir, 'not-ours.txt')
    writeText(outside, 'x'.repeat(64))
    const item = {
      id: 'outside',
      sessionId: 'outside',
      title: 'outside',
      category: 'openHands' as const,
      projectPath: null,
      gitBranch: null,
      messageCount: 1,
      sizeInBytes: 1000,
      updatedAt: new Date().toISOString(),
      isSelected: false,
      snippet: '',
      associatedPaths: [outside]
    }

    const freed = await scanner.delete([item])

    expect(freed).toBe(1000)
    expect(existsSync(outside)).toBe(true)
  })

  it('cleanFileHistorySnapshots 开：快照路径一起删，freedBytes 全额记账', async () => {
    const snapshotDir = join(rawRoot, 'checkpoints', SESSION_2)
    mkdirSync(snapshotDir, { recursive: true })
    writeText(join(snapshotDir, 'state.json'), 'x'.repeat(300))
    const item = {
      id: 'snap-on',
      sessionId: SESSION_2,
      title: 'snap',
      category: 'openHands' as const,
      projectPath: null,
      gitBranch: null,
      messageCount: 1,
      sizeInBytes: 1000,
      updatedAt: new Date().toISOString(),
      isSelected: false,
      snippet: '',
      associatedPaths: [join(rawRoot, 'sessions', `${SESSION_2}.json`), snapshotDir]
    }

    const freed = await scanner.delete([item])

    expect(freed).toBe(1000)
    expect(existsSync(join(rawRoot, 'sessions', `${SESSION_2}.json`))).toBe(false)
    expect(existsSync(snapshotDir)).toBe(false)
  })

  it('cleanFileHistorySnapshots 关：快照路径保留，freedBytes 扣掉它占的字节', async () => {
    const snapshotDir = join(rawRoot, 'checkpoints', SESSION_2)
    mkdirSync(snapshotDir, { recursive: true })
    writeText(join(snapshotDir, 'state.json'), 'x'.repeat(300))
    const item = {
      id: 'snap-off',
      sessionId: SESSION_2,
      title: 'snap',
      category: 'openHands' as const,
      projectPath: null,
      gitBranch: null,
      messageCount: 1,
      sizeInBytes: 1000,
      updatedAt: new Date().toISOString(),
      isSelected: false,
      snippet: '',
      associatedPaths: [join(rawRoot, 'sessions', `${SESSION_2}.json`), snapshotDir]
    }

    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const freed = await scanner.delete([item])

    expect(freed).toBe(1000 - sizeOfPath(snapshotDir))
    expect(existsSync(join(rawRoot, 'sessions', `${SESSION_2}.json`))).toBe(false)
    expect(existsSync(snapshotDir)).toBe(true)
  })

  it('删除空列表返回 0', async () => {
    await expect(scanner.delete([])).resolves.toBe(0)
  })
})

describe('OpenHandsScanner · cleanAll', () => {
  it('清空后重扫为 0，三个子目录重建为空目录', async () => {
    const freed = await scanner.cleanAll()

    expect(freed).toBeGreaterThan(0)
    await expect(scanner.scan()).resolves.toEqual([])

    for (const subdir of ['sessions', 'logs', 'workspace']) {
      expect(statSync(join(rawRoot, subdir)).isDirectory()).toBe(true)
      expect(readdirSync(join(rawRoot, subdir))).toEqual([])
    }
  })

  it('cleanEmptyProjectFolders 开与关行为一致：OpenHands 从不回收空目录', async () => {
    const on = freshFixture()
    CleanPrefs.patch({ cleanEmptyProjectFolders: true })
    const freedOn = await on.scanner.cleanAll()
    const stateOn = treeSnapshot(on.raw)

    const off = freshFixture()
    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    const freedOff = await off.scanner.cleanAll()
    const stateOff = treeSnapshot(off.raw)

    expect(freedOff).toBe(freedOn)
    expect(stateOff).toEqual(stateOn)
    expect(stateOff.get('sessions')).toBe('dir')
    expect(stateOff.get('logs')).toBe('dir')
    expect(stateOff.get('workspace')).toBe('dir')
  })
})

describe('OpenHandsScanner · 本机真实目录（只读）', () => {
  it('装了就扫真实的 ~/.openhands / ~/.open-devin，扫描过程一个文件都不动', async () => {
    const realRoots = [join(homedir(), '.openhands'), join(homedir(), '.open-devin')].filter(
      (dir) => existsSync(dir)
    )
    if (realRoots.length === 0) return

    for (const real of realRoots) {
      const realScanner = new OpenHandsScanner()
      const before = treeSnapshot(real)
      const items = await realScanner.scan()
      expect(treeSnapshot(real)).toEqual(before)
      expect(items.every((item) => item.category === 'openHands')).toBe(true)
      expect(Array.isArray(items)).toBe(true)
    }
  })

  it('没装时也走一遍真实目录 + 环境变量分支，仍然只读', async () => {
    const real = mkdtempSync(join(tmpdir(), 'real_openhands_'))
    extraRoots.push(real)
    buildFixture(real)
    const previous = process.env.OPENHANDS_HOME
    process.env.OPENHANDS_HOME = real
    try {
      const realScanner = new OpenHandsScanner()
      expect(realScanner.isInstalled).toBe(true)
      const before = treeSnapshot(real)
      const items = await realScanner.scan()
      expect(treeSnapshot(real)).toEqual(before)
      expect(items).toHaveLength(3)
    } finally {
      if (previous === undefined) delete process.env.OPENHANDS_HOME
      else process.env.OPENHANDS_HOME = previous
    }
  })
})
