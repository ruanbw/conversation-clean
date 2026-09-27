import { afterAll, beforeEach, describe, expect, it } from 'vitest'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  utimesSync,
  writeFileSync
} from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { DEFAULT_PREFS } from '@shared/types'
import { CleanPrefs } from '@main/core/scanner'
import { ContinueScanner } from './ContinueScanner'

/**
 * Continue 扫描器用例：storagePath 的解析、scan 的字段抽取、delete 的目录边界、
 * cleanAll 的清理范围，以及末尾的只读实机用例。
 * 其中还盖住了日期兜底、parts 数组、同名目录与两个开关的正反两面。
 *
 * 全部夹具都在 `os.tmpdir()` 下现造，测试自包含、不依赖任何其它文件。
 * `process.env.HOME` 在模块加载时就指向一个沙箱目录，`CleanPrefs` 才会把
 * 偏好写进沙箱而不是真实的 `~/.conversation-clean/preferences.json`。
 */

const REAL_HOME = homedir()
const SANDBOX_HOME = realpathSync(mkdtempSync(join(tmpdir(), 'continuehome')))
const ORIGINAL_HOME = process.env.HOME
const ORIGINAL_CONTINUE_HOME = process.env.CONTINUE_HOME
process.env.HOME = SANDBOX_HOME
delete process.env.CONTINUE_HOME

const created: string[] = []

function tempRoot(prefix = 'continue'): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), prefix)))
  created.push(dir)
  return dir
}

function write(path: string, content: string): string {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content, 'utf8')
  return path
}

function canonicalOrSelf(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

/** 递归快照目录内容（相对路径 + mtimeMs + size），用来验证 `scan()` 一个字节都没写。 */
function snapshotTree(root: string): string[] {
  const out: string[] = []
  const walk = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const child = join(dir, entry.name)
      if (entry.isDirectory()) {
        out.push(`${child}/`)
        walk(child)
      } else {
        const stats = statSync(child)
        out.push(`${child}:${stats.size}:${stats.mtimeMs}`)
      }
    }
  }
  if (existsSync(root)) walk(root)
  return out.sort()
}

afterAll(() => {
  process.env.HOME = ORIGINAL_HOME
  if (ORIGINAL_CONTINUE_HOME === undefined) delete process.env.CONTINUE_HOME
  else process.env.CONTINUE_HOME = ORIGINAL_CONTINUE_HOME
  for (const dir of created) rmSync(dir, { recursive: true, force: true })
  rmSync(SANDBOX_HOME, { recursive: true, force: true })
})

beforeEach(() => {
  CleanPrefs.patch({ ...DEFAULT_PREFS })
})

/** 夹具：2 个会话 + index/ + cache/ + 绝不能删的 config.json */
function buildMockRoot(): { root: string; s1: string; s2: string; config: string } {
  const root = tempRoot()
  const sessions = join(root, 'sessions')
  mkdirSync(sessions, { recursive: true })
  mkdirSync(join(root, 'index'), { recursive: true })
  mkdirSync(join(root, 'cache'), { recursive: true })

  const config = write(join(root, 'config.json'), '{"models":[{"title":"GPT-4o"}]}')

  const s1Id = 'continue-session-001'
  const s1 = write(
    join(sessions, `${s1Id}.json`),
    JSON.stringify({
      sessionId: s1Id,
      title: 'Implement Redis Caching Layer',
      workspaceDirectory: '/Users/tester/api-gateway',
      dateCreated: '2026-09-20T14:30:00.000Z',
      history: [
        { message: { role: 'user', content: 'How do I configure Redis cache eviction policy?' } },
        { message: { role: 'assistant', content: 'You can configure volatile-lru in redis.conf.' } }
      ]
    })
  )

  const s2Id = 'continue-session-002'
  const s2 = write(
    join(sessions, `${s2Id}.json`),
    JSON.stringify({
      sessionId: s2Id,
      workspaceDirectory: '/Users/tester/web-client',
      dateCreated: 1789500000000,
      history: [
        { role: 'user', content: 'Create a responsive sidebar navigation with SwiftUI' },
        { role: 'assistant', content: 'Here is a SidebarView implementation...' }
      ]
    })
  )

  write(join(root, 'index', 'index.db'), 'sqlite index data')
  write(join(root, 'cache', 'blob.bin'), 'x'.repeat(128))

  return { root, s1, s2, config }
}

describe('ContinueScanner.storagePath', () => {
  it('默认指向 ~/.continue，CONTINUE_HOME 优先，且不存在的路径原样返回', () => {
    process.env.HOME = REAL_HOME
    try {
      delete process.env.CONTINUE_HOME
      const fallback = new ContinueScanner()
      expect(fallback.storagePath).toBe(canonicalOrSelf(join(REAL_HOME, '.continue')))
    } finally {
      process.env.HOME = SANDBOX_HOME
    }

    const custom = tempRoot('continueenv')
    process.env.CONTINUE_HOME = custom
    try {
      const scanner = new ContinueScanner()
      expect(scanner.storagePath).toBe(custom)
      expect(scanner.isInstalled).toBe(true)
    } finally {
      delete process.env.CONTINUE_HOME
    }

    const missing = join(tempRoot(), 'nope')
    const scanner = new ContinueScanner({ storagePath: missing })
    expect(scanner.isInstalled).toBe(false)
  })

  it('storagePath 注入会做 realpath 规范化（macOS 的 /var → /private/var）', () => {
    const root = tempRoot()
    expect(new ContinueScanner({ storagePath: root }).storagePath).toBe(root)
  })
})

describe('ContinueScanner.scan', () => {
  it('夹具目录：2 条会话，字段逐条对上，且只读不落盘', async () => {
    const { root, s1 } = buildMockRoot()
    const scanner = new ContinueScanner({ storagePath: root })
    expect(scanner.isInstalled).toBe(true)
    expect(scanner.category).toBe('continueDev')

    const before = snapshotTree(root)
    const items = await scanner.scan()
    expect(snapshotTree(root)).toEqual(before)
    expect(items).toHaveLength(2)

    // 2026-09-20 比 1789500000000（2026-09-15）新，倒序后 session 1 在前
    expect(items[0]?.sessionId).toBe('continue-session-001')
    expect(items[1]?.sessionId).toBe('continue-session-002')

    const item1 = items[0]!
    expect(item1.category).toBe('continueDev')
    expect(item1.title).toBe('Implement Redis Caching Layer')
    expect(item1.projectPath).toBe('/Users/tester/api-gateway')
    expect(item1.gitBranch).toBeNull()
    expect(item1.messageCount).toBe(2)
    expect(item1.sizeInBytes).toBe(statSync(s1).size)
    expect(item1.updatedAt).toBe('2026-09-20T14:30:00.000Z')
    expect(item1.snippet).toBe('How do I configure Redis cache eviction policy?')
    expect(item1.isSelected).toBe(false)
    expect(item1.associatedPaths).toEqual([s1])

    // 无 title：标题与摘要都从第一条 user 消息来
    const item2 = items[1]!
    expect(item2.title).toBe('Create a responsive sidebar navigation with SwiftUI')
    expect(item2.projectPath).toBe('/Users/tester/web-client')
    expect(item2.messageCount).toBe(2)
    expect(item2.updatedAt).toBe(new Date(1789500000000).toISOString())
  })

  it('标题兜底顺序：title > 第一条 user 消息 > sessionId；多行只取第一行', async () => {
    const root = tempRoot()
    const sessions = join(root, 'sessions')
    write(
      join(sessions, 'multi-line-title.json'),
      JSON.stringify({
        title: 'First line\nSecond line',
        history: [{ message: { role: 'user', content: 'prompt from history' } }]
      })
    )
    write(
      join(sessions, 'blank-title.json'),
      JSON.stringify({
        title: '   ',
        history: [
          { role: 'assistant', content: 'assistant first, must be skipped' },
          { role: 'user', content: 'the real prompt' }
        ]
      })
    )
    // content 是 parts 数组：拼空格；且没有 role 字段也算 user 消息
    write(
      join(sessions, 'parts-title.json'),
      JSON.stringify({
        history: [{ content: [{ type: 'text', text: 'part one' }, { type: 'text', text: 'part two' }] }]
      })
    )
    // 既无 title 也无 history：回落到文件名
    write(join(sessions, 'fallback-id.json'), JSON.stringify({ messageCount: 0 }))

    const items = await new ContinueScanner({ storagePath: root }).scan()
    const byId = new Map(items.map((item) => [item.sessionId, item]))

    expect(byId.get('multi-line-title')?.title).toBe('First line')
    expect(byId.get('blank-title')?.title).toBe('the real prompt')
    expect(byId.get('parts-title')?.title).toBe('part one part two')
    expect(byId.get('fallback-id')?.title).toBe('fallback-id')
    // 摘要为空时用最终标题兜底
    expect(byId.get('fallback-id')?.snippet).toBe('fallback-id')
    // messageCount: 0 且 history 非空时回落到 history.length
    expect(byId.get('fallback-id')?.messageCount).toBe(0)
  })

  it('messageCount 优先取 messageCount 字段；sessionId 缺失时用文件名', async () => {
    const root = tempRoot()
    const sessions = join(root, 'sessions')
    write(
      join(sessions, 'explicit-count.json'),
      JSON.stringify({
        sessionId: 'explicit-count',
        messageCount: 42,
        history: [{ role: 'user', content: 'a' }, { role: 'assistant', content: 'b' }]
      })
    )
    // 非整数不算 messageCount（非整数不是合法计数）
    write(join(sessions, 'float-count.json'), JSON.stringify({ messageCount: 1.5, history: [] }))

    const items = await new ContinueScanner({ storagePath: root }).scan()
    const byId = new Map(items.map((item) => [item.sessionId, item]))
    expect(byId.get('explicit-count')?.messageCount).toBe(42)
    expect(byId.get('float-count')?.messageCount).toBe(0)
  })

  it('dateCreated 兜底：ISO / 自定义格式 / 毫秒 / 秒 / 数字串 / mtime', async () => {
    const root = tempRoot()
    const sessions = join(root, 'sessions')
    const cases: Array<[string, unknown, string]> = [
      ['iso-ms', '2026-09-20T14:30:00.000Z', '2026-09-20T14:30:00.000Z'],
      ['iso-plain', '2026-09-20T14:30:00Z', '2026-09-20T14:30:00.000Z'],
      ['custom-space', '2026-09-20 14:30:00', new Date(2026, 8, 20, 14, 30, 0).toISOString()],
      ['epoch-ms', 1789500000000, '2026-09-15T19:20:00.000Z'],
      ['epoch-s', 1789500000, '2026-09-15T19:20:00.000Z'],
      // 数字字符串没有 > 0 判断："0" 会被当成 1970 年
      ['epoch-str', '1789500000000', '2026-09-15T19:20:00.000Z'],
      // 解析不出来 / 非正数 → 文件 mtime
      ['garbage', 'not a date', '2026-01-02T03:04:05.000Z'],
      ['zero', 0, '2026-01-02T03:04:05.000Z'],
      ['missing', undefined, '2026-01-02T03:04:05.000Z']
    ]
    for (const [name, value, expected] of cases) {
      const payload: Record<string, unknown> = {}
      if (value !== undefined) payload['dateCreated'] = value
      const path = write(join(sessions, `${name}.json`), JSON.stringify(payload))
      const stamp = new Date('2026-01-02T03:04:05.000Z')
      utimesSync(path, stamp, stamp)
      expect(expected.length).toBeGreaterThan(0)
    }

    const items = await new ContinueScanner({ storagePath: root }).scan()
    const byId = new Map(items.map((item) => [item.sessionId, item]))
    for (const [name, , expected] of cases) {
      expect(byId.get(name)?.updatedAt, name).toBe(expected)
    }
  })

  it('会话文件旁有同名目录时：associatedPaths 含两条，体积含目录', async () => {
    const root = tempRoot()
    const sessions = join(root, 'sessions')
    const file = write(join(sessions, 'with-dir.json'), JSON.stringify({ sessionId: 'with-dir' }))
    write(join(sessions, 'with-dir', 'attachment.txt'), 'a'.repeat(64))

    const items = await new ContinueScanner({ storagePath: root }).scan()
    expect(items).toHaveLength(1)
    const item = items[0]!
    expect(item.associatedPaths).toEqual([file, join(sessions, 'with-dir')])
    expect(item.sizeInBytes).toBe(statSync(file).size + 64)
  })

  it('递归子目录、跳隐藏项、坏 JSON 跳过；未安装 / 无 sessions / 空目录都返回 []', async () => {
    const scanner = new ContinueScanner({ storagePath: join(tempRoot(), 'missing') })
    expect(await scanner.scan()).toEqual([])

    const root = tempRoot()
    const empty = new ContinueScanner({ storagePath: root })
    expect(await empty.scan()).toEqual([])

    mkdirSync(join(root, 'sessions'), { recursive: true })
    expect(await empty.scan()).toEqual([])

    const nested = write(join(root, 'sessions', 'group', 'deep', 'abc.json'), JSON.stringify({ sessionId: 'abc' }))
    write(join(root, 'sessions', 'not-json.txt'), 'ignored')
    write(join(root, 'sessions', '.hidden.json'), JSON.stringify({ sessionId: 'hidden' }))
    write(join(root, 'sessions', 'broken.json'), '{ not json')
    write(join(root, 'sessions', 'array.json'), '[1,2,3]')

    const items = await empty.scan()
    expect(items.map((item) => item.sessionId)).toEqual(['abc'])
    expect(items[0]?.associatedPaths).toEqual([nested])
  })
})

describe('ContinueScanner.delete', () => {
  it('删掉选中的会话、字节数正确、其余保留；空数组返回 0', async () => {
    const { root, s1, s2 } = buildMockRoot()
    const scanner = new ContinueScanner({ storagePath: root })

    const items = await scanner.scan()
    const item1 = items.find((item) => item.sessionId === 'continue-session-001')!
    const freed = await scanner.delete([item1])
    expect(freed).toBe(item1.sizeInBytes)
    expect(existsSync(s1)).toBe(false)
    expect(existsSync(s2)).toBe(true)

    const remaining = await scanner.scan()
    expect(remaining).toHaveLength(1)
    expect(remaining[0]?.sessionId).toBe('continue-session-002')

    expect(await scanner.delete([])).toBe(0)
  })

  it('cleanEmptyProjectFolders 开：删完回收 sessions 下的空目录', async () => {
    CleanPrefs.patch({ cleanEmptyProjectFolders: true })
    const root = tempRoot()
    const nested = join(root, 'sessions', 'group-a')
    write(join(nested, 'abc.json'), JSON.stringify({ sessionId: 'abc' }))

    const scanner = new ContinueScanner({ storagePath: root })
    const items = await scanner.scan()
    await scanner.delete(items)
    expect(existsSync(nested)).toBe(false)
    // sessions 本身不在回收范围内（只清子目录）
    expect(existsSync(join(root, 'sessions'))).toBe(true)
  })

  it('cleanEmptyProjectFolders 关：一个空目录都不回收', async () => {
    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    const root = tempRoot()
    const nested = join(root, 'sessions', 'group-a')
    write(join(nested, 'abc.json'), JSON.stringify({ sessionId: 'abc' }))

    const scanner = new ContinueScanner({ storagePath: root })
    const items = await scanner.scan()
    await scanner.delete(items)
    expect(existsSync(nested)).toBe(true)
  })

  it('cleanFileHistorySnapshots 关：命中快照目录名的路径保留，且不计入释放量', async () => {
    // 夹具里故意让 storagePath 落在 `backups/` 之下：`CleanPrefs.isSnapshotPath`
    // 按路径分段匹配，所以这些会话文件全部算「快照」。
    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const snapshots = tempRoot('continuebackup')
    const backupRoot = join(snapshots, 'backups')
    const file = write(join(backupRoot, 'sessions', 'abc.json'), JSON.stringify({ sessionId: 'abc' }))

    const scanner = new ContinueScanner({ storagePath: backupRoot })
    const items = await scanner.scan()
    expect(items).toHaveLength(1)
    const freed = await scanner.delete(items)
    expect(freed).toBe(0)
    expect(existsSync(file)).toBe(true)
  })

  it('cleanFileHistorySnapshots 开：同样夹具下照删不误', async () => {
    CleanPrefs.patch({ cleanFileHistorySnapshots: true })
    const snapshots = tempRoot('continuebackup')
    const backupRoot = join(snapshots, 'backups')
    const file = write(join(backupRoot, 'sessions', 'abc.json'), JSON.stringify({ sessionId: 'abc' }))

    const scanner = new ContinueScanner({ storagePath: backupRoot })
    const items = await scanner.scan()
    const freed = await scanner.delete(items)
    expect(freed).toBe(items[0]!.sizeInBytes)
    expect(existsSync(file)).toBe(false)
  })
})

describe('ContinueScanner.cleanAll', () => {
  it('清空 sessions + index + cache（并重建 index/cache 空目录），config.json 必须保留', async () => {
    const { root, s1, s2, config } = buildMockRoot()
    const scanner = new ContinueScanner({ storagePath: root })

    const freed = await scanner.cleanAll()
    expect(freed).toBeGreaterThan(0)
    expect(existsSync(s1)).toBe(false)
    expect(existsSync(s2)).toBe(false)
    expect(existsSync(config)).toBe(true)
    expect(existsSync(join(root, 'index'))).toBe(true)
    expect(existsSync(join(root, 'cache'))).toBe(true)
    expect(readdirSync(join(root, 'index'))).toEqual([])
    expect(readdirSync(join(root, 'cache'))).toEqual([])
    expect(await scanner.scan()).toEqual([])
  })

  it('未安装时 cleanAll 不抛错、返回 0', async () => {
    const scanner = new ContinueScanner({ storagePath: join(tempRoot(), 'missing') })
    expect(await scanner.cleanAll()).toBe(0)
  })
})

describe('ContinueScanner 本机真实目录（只读）', () => {
  it.skipIf(!existsSync(join(REAL_HOME, '.continue')))(
    '扫描 ~/.continue 不抛错且不修改任何文件',
    async () => {
      process.env.HOME = REAL_HOME
      try {
        const scanner = new ContinueScanner()
        expect(scanner.isInstalled).toBe(true)
        const root = scanner.storagePath
        const before = snapshotTree(root)
        const items = await scanner.scan()
        expect(snapshotTree(root)).toEqual(before)
        expect(Array.isArray(items)).toBe(true)
        for (const item of items) {
          expect(item.category).toBe('continueDev')
          expect(item.sessionId.length).toBeGreaterThan(0)
          expect(item.associatedPaths.length).toBeGreaterThan(0)
          expect(Number.isNaN(Date.parse(item.updatedAt))).toBe(false)
        }
        // 末尾一定是 updatedAt 倒序
        const times = items.map((item) => Date.parse(item.updatedAt))
        expect([...times].sort((a, b) => b - a)).toEqual(times)
      } finally {
        process.env.HOME = SANDBOX_HOME
      }
    }
  )
})
