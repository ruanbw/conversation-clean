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
import { OpenVikingScanner } from './OpenVikingScanner'

/**
 * OpenViking 扫描器用例：storagePath 的解析、scan 的字段抽取、delete 的分组边界、
 * cleanAll 的整目录清空，以及末尾的只读实机用例。
 * 其中 scan 侧还盖住了标题回退、文本抽取的各级兜底、createdAt 的秒/毫秒/ISO 变体、
 * peer_id 反解项目路径与两个开关的正反两面。
 *
 * 夹具全部现造在 `os.tmpdir()` 下，测试自包含。`HOME` 指向沙箱，
 * 免得 `CleanPrefs` 把偏好写进真实的 `~/.conversation-clean/preferences.json`。
 */

const REAL_HOME = homedir()
const SANDBOX_HOME = realpathSync(mkdtempSync(join(tmpdir(), 'ovkhome')))
const ORIGINAL_HOME = process.env.HOME
const ORIGINAL_OPENVIKING_HOME = process.env.OPENVIKING_HOME
process.env.HOME = SANDBOX_HOME
delete process.env.OPENVIKING_HOME

const created: string[] = []

/**
 * 夹具用的临时根，**尽量**保证整条绝对路径不含连字符。
 *
 * `peer_id` 反解项目路径的连字符分支依赖「前 N 段都能按斜杠路径命中真实目录」，
 * 所以那个用例要求沙箱路径本身干净。原来的写法把 `os.tmpdir()` 直接当根，
 * 再在用例里断言 `expect(root).not.toContain('-')` —— 那是把**前提寄托在环境变量上**：
 * macOS 下某些工具会把 `TMPDIR` 指到 `.../T/.ctx-mode-XXXX` 这种形态，
 * 临时目录名自带连字符，前置断言就随环境漂移。实测踩到过。
 *
 * 这里改成自己找一个无连字符的根。⚠️ 找���到时**不抛异常**：
 * 第一版这里 `throw`，结果是「环境里 TMPDIR 带连字符」从一个用例的断言失败，
 * 升级成**整个测试文件无法加载**（579 个用例掉到 564）。窄失败宽化是倒退。
 * 兜底就退回 `os.tmpdir()`，让那一条断言自己把问题说出来。
 */
function pickHyphenFreeRoot(): string {
  // 候选按优先级：TMPDIR 下 → macOS 的 /tmp（realpath 是 /private/tmp，无连字符）
  // → TMPDIR 的各级父目录。逐个试第一个不含连字符的。
  const tmp = tmpdir()
  const candidates = [join(tmp, 'ovk'), '/tmp/ovk', dirname(tmp), dirname(dirname(tmp))]
  for (const candidate of candidates) {
    try {
      mkdirSync(candidate, { recursive: true })
      const real = realpathSync(candidate)
      if (!real.includes('-')) return real
    } catch {
      // 候选不可用（权限 / 不存在），试下一个。
    }
  }
  // 都带连字符：退回原始 tmpdir，让断言去报，不在这里抛。
  mkdirSync(tmp, { recursive: true })
  return realpathSync(tmp)
}

const HYPHEN_FREE_TMP = pickHyphenFreeRoot()
const ORIGINAL_TMPDIR = process.env.TMPDIR
process.env.TMPDIR = HYPHEN_FREE_TMP

function tempRoot(prefix = 'ovk'): string {
  const dir = realpathSync(mkdtempSync(join(HYPHEN_FREE_TMP, prefix)))
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
  if (ORIGINAL_TMPDIR === undefined) delete process.env.TMPDIR
  else process.env.TMPDIR = ORIGINAL_TMPDIR
  if (ORIGINAL_OPENVIKING_HOME === undefined) delete process.env.OPENVIKING_HOME
  else process.env.OPENVIKING_HOME = ORIGINAL_OPENVIKING_HOME
  for (const dir of created) rmSync(dir, { recursive: true, force: true })
  rmSync(SANDBOX_HOME, { recursive: true, force: true })
})

beforeEach(() => {
  CleanPrefs.patch({ ...DEFAULT_PREFS })
})

/** 夹具：一个 2 消息会话 + 一个只有操作记录的会话。 */
function buildMockRoot(): { root: string; pending: string; f1: string; f2: string; f3: string } {
  const root = tempRoot()
  const pending = join(root, 'pending')
  mkdirSync(pending, { recursive: true })

  const sid1 = 'dsh-session-test-0001'
  const sid2 = 'dsh-session-test-0002'

  const f1 = write(
    join(pending, 'f1.json'),
    JSON.stringify({
      type: 'addMessage',
      sessionId: sid1,
      payload: {
        role: 'user',
        parts: [{ type: 'text', text: 'Optimize database queries' }],
        peer_id: '-Users-tester-projects-backend'
      },
      createdAt: 1786888290000
    })
  )
  const f2 = write(
    join(pending, 'f2.json'),
    JSON.stringify({
      type: 'addMessage',
      sessionId: sid1,
      payload: { role: 'assistant', parts: [{ type: 'tool', tool_name: 'bash' }] },
      createdAt: 1786888300000
    })
  )
  const f3 = write(
    join(pending, 'f3.json'),
    JSON.stringify({
      type: 'commitSession',
      sessionId: sid2,
      payload: { keep_recent_count: 5 },
      createdAt: 1786888400000
    })
  )

  return { root, pending, f1, f2, f3 }
}

describe('OpenVikingScanner.storagePath', () => {
  it('默认指向 ~/.openviking，OPENVIKING_HOME 优先，不存在则未安装', () => {
    process.env.HOME = REAL_HOME
    try {
      delete process.env.OPENVIKING_HOME
      expect(new OpenVikingScanner().storagePath).toBe(canonicalOrSelf(join(REAL_HOME, '.openviking')))
    } finally {
      process.env.HOME = SANDBOX_HOME
    }

    const custom = tempRoot('ovkenv')
    process.env.OPENVIKING_HOME = custom
    try {
      const scanner = new OpenVikingScanner()
      expect(scanner.storagePath).toBe(custom)
      expect(scanner.isInstalled).toBe(true)
    } finally {
      delete process.env.OPENVIKING_HOME
    }

    const scanner = new OpenVikingScanner({ storagePath: join(tempRoot(), 'missing') })
    expect(scanner.isInstalled).toBe(false)
  })
})

describe('OpenVikingScanner.scan', () => {
  it('夹具目录：按 sessionId 分组成 2 条会话，字段逐条对上，且只读不落盘', async () => {
    const { root, f1, f2 } = buildMockRoot()
    const scanner = new OpenVikingScanner({ storagePath: root })
    expect(scanner.isInstalled).toBe(true)
    expect(scanner.category).toBe('openViking')

    const before = snapshotTree(root)
    const items = await scanner.scan()
    expect(snapshotTree(root)).toEqual(before)
    expect(items).toHaveLength(2)

    // createdAt 更大的会话在前
    expect(items[0]?.sessionId).toBe('dsh-session-test-0002')
    expect(items[1]?.sessionId).toBe('dsh-session-test-0001')

    const item1 = items[1]!
    expect(item1.title).toBe('Optimize database queries')
    expect(item1.snippet).toBe('Optimize database queries')
    expect(item1.messageCount).toBe(2)
    expect(item1.associatedPaths).toEqual([f1, f2].sort())
    expect(item1.sizeInBytes).toBe(statSync(f1).size + statSync(f2).size)
    expect(item1.updatedAt).toBe(new Date(1786888300000).toISOString())
    expect(item1.gitBranch).toBeNull()
    // peer_id `-Users-tester-projects-backend` 直接还原成路径（目录不存在时返回还原值）
    expect(item1.projectPath).toBe('/Users/tester/projects/backend')

    // 没有任何可读文本的操作记录：标题与摘要都走兜底
    const item2 = items[0]!
    expect(item2.title).toBe('OpenViking 会话 dsh-sess')
    expect(item2.snippet).toBe('包含 1 条待处理消息与操作记录')
    expect(item2.messageCount).toBe(1)
    expect(item2.projectPath).toBeNull()
  })

  it('标题取时间最早的 user 消息；没有 user 就取最早的任意文本', async () => {
    const root = tempRoot()
    const pending = join(root, 'pending')
    // 时间顺序与文件名字母序故意相反，用来验证确实按 createdAt 排序而不是按文件名
    write(
      join(pending, 'a.json'),
      JSON.stringify({
        sessionId: 's1',
        createdAt: 2000_000_000_000,
        payload: { role: 'assistant', text: 'assistant speaks first' }
      })
    )
    write(
      join(pending, 'b.json'),
      JSON.stringify({ sessionId: 's1', createdAt: 2000_000_000_001, payload: { role: 'user', text: 'real prompt' } })
    )
    write(
      join(pending, 'c.json'),
      JSON.stringify({ sessionId: 's2', createdAt: 2000_000_000_002, payload: { role: 'assistant', text: 'only text' } })
    )

    const items = await new OpenVikingScanner({ storagePath: root }).scan()
    const byId = new Map(items.map((item) => [item.sessionId, item]))
    expect(byId.get('s1')?.title).toBe('real prompt')
    expect(byId.get('s2')?.title).toBe('only text')
    expect(byId.get('s2')?.projectPath).toBeNull()
  })

  it('文本抽取：parts 的 text / type、payload.text / content / prompt 逐级兜底', async () => {
    const root = tempRoot()
    const pending = join(root, 'pending')
    const cases: Array<[string, unknown, string]> = [
      [
        'typed-parts',
        { role: 'user', parts: [{ type: 'image', text: 'typed first' }, { type: 'text', text: 'typed text' }] },
        'typed text'
      ],
      ['untyped-parts', { role: 'user', parts: [{ type: 'tool', text: 'untyped text' }] }, 'untyped text'],
      ['payload-text', { role: 'user', text: 'from text' }, 'from text'],
      ['payload-content', { role: 'user', content: '  from content  ' }, 'from content'],
      ['payload-prompt', { role: 'user', prompt: 'from prompt' }, 'from prompt']
    ]
    for (const [id, payload] of cases) {
      write(join(pending, `${id}.json`), JSON.stringify({ sessionId: id, payload, createdAt: 2000_000_000_000 }))
    }
    // 空白文本 / 没有 payload 的都拿不到文本 → 走兜底
    write(
      join(pending, 'blank.json'),
      JSON.stringify({ sessionId: 'blank', payload: { role: 'user', text: '   ' }, createdAt: 2000_000_000_000 })
    )
    write(join(pending, 'nopayload.json'), JSON.stringify({ sessionId: 'nopayload', createdAt: 2000_000_000_000 }))

    const items = await new OpenVikingScanner({ storagePath: root }).scan()
    const byId = new Map(items.map((item) => [item.sessionId, item]))
    for (const [id, , expected] of cases) {
      expect(byId.get(id)?.snippet, id).toBe(expected)
    }
    expect(byId.get('blank')?.title).toBe('OpenViking 会话 blank')
    expect(byId.get('nopayload')?.snippet).toBe('包含 1 条待处理消息与操作记录')
  })

  it('createdAt：毫秒 / 秒 / ISO 串 / payload.created_at / 缺失回落到文件 mtime', async () => {
    const root = tempRoot()
    const pending = join(root, 'pending')
    const stamp = new Date('2026-01-02T03:04:05.000Z')
    const files: Array<[string, Record<string, unknown>]> = [
      ['ms', { createdAt: 1786888290000 }],
      ['sec', { createdAt: 1786888400 }],
      ['iso', { createdAt: '2026-08-16T13:55:00Z' }],
      ['payload', { payload: { created_at: '2026-08-16T13:56:00Z' } }]
    ]
    for (const [id, extra] of files) {
      const path = write(join(pending, `${id}.json`), JSON.stringify({ sessionId: id, ...extra }))
      utimesSync(path, stamp, stamp)
    }
    // 数值落在 0 ~ 1e9 之间（既不是毫秒也不是秒）→ createdAt 解析失败，回落到 mtime
    const fallback = write(join(pending, 'fallback.json'), JSON.stringify({ sessionId: 'fallback', createdAt: 12345 }))
    utimesSync(fallback, stamp, stamp)

    const items = await new OpenVikingScanner({ storagePath: root }).scan()
    const byId = new Map(items.map((item) => [item.sessionId, item]))
    expect(byId.get('ms')?.updatedAt).toBe(new Date(1786888290000).toISOString())
    expect(byId.get('sec')?.updatedAt).toBe(new Date(1786888400000).toISOString())
    expect(byId.get('iso')?.updatedAt).toBe('2026-08-16T13:55:00.000Z')
    expect(byId.get('payload')?.updatedAt).toBe('2026-08-16T13:56:00.000Z')
    expect(byId.get('fallback')?.updatedAt).toBe('2026-01-02T03:04:05.000Z')
  })

  it('peer_id 反解项目路径：直接命中、目录名带连字符、无前导横杠三种情况', async () => {
    // 连字符分支依赖「前 N 段都能按斜杠路径命中」，所以临时目录本身不能带横杠
    const root = tempRoot('ovkproj')
    expect(root).not.toContain('-')
    const realDir = join(root, 'realproj')
    mkdirSync(realDir, { recursive: true })
    const hyphenDir = join(root, 'proj-x')
    mkdirSync(hyphenDir, { recursive: true })

    const pending = join(root, 'pending')
    const peerId = `-${root.slice(1).replaceAll('/', '-')}`
    const peerOf = (dir: string): string => `-${dir.slice(1).replaceAll('/', '-')}`
    write(
      join(pending, 'exact.json'),
      JSON.stringify({ sessionId: 'exact', payload: { role: 'user', text: 'a', peer_id: peerOf(realDir) } })
    )
    write(
      join(pending, 'hyphen.json'),
      JSON.stringify({ sessionId: 'hyphen', payload: { role: 'user', text: 'b', peer_id: `${peerId}-proj-x` } })
    )
    write(
      join(pending, 'plain.json'),
      JSON.stringify({ sessionId: 'plain', payload: { role: 'user', text: 'c', peer_id: 'not-a-path' } })
    )

    const items = await new OpenVikingScanner({ storagePath: root }).scan()
    const byId = new Map(items.map((item) => [item.sessionId, item]))
    expect(byId.get('exact')?.projectPath).toBe(realDir)
    expect(byId.get('hyphen')?.projectPath).toBe(hyphenDir)
    expect(byId.get('plain')?.projectPath).toBeNull()
  })

  it('未安装 / 无 pending / 空 pending / 坏文件 / 隐藏文件都按预期处理', async () => {
    const missing = new OpenVikingScanner({ storagePath: join(tempRoot(), 'missing') })
    expect(await missing.scan()).toEqual([])

    const root = tempRoot()
    expect(await new OpenVikingScanner({ storagePath: root }).scan()).toEqual([])

    const pending = join(root, 'pending')
    mkdirSync(pending, { recursive: true })
    expect(await new OpenVikingScanner({ storagePath: root }).scan()).toEqual([])

    write(join(pending, 'ok.json'), JSON.stringify({ sessionId: 'ok' }))
    write(join(pending, 'broken.json'), '{ nope')
    write(join(pending, 'array.json'), '[]')
    write(join(pending, 'no-session.json'), JSON.stringify({ payload: {} }))
    write(join(pending, 'empty-session.json'), JSON.stringify({ sessionId: '' }))
    write(join(pending, 'not-json.txt'), 'ignored')
    write(join(pending, '.hidden.json'), JSON.stringify({ sessionId: 'hidden' }))

    const items = await new OpenVikingScanner({ storagePath: root }).scan()
    expect(items.map((item) => item.sessionId)).toEqual(['ok'])
  })
})

describe('OpenVikingScanner.delete', () => {
  it('删掉该会话的全部分组文件、字节数正确、同组其它会话不受影响', async () => {
    const { root, f1, f2, f3, pending } = buildMockRoot()
    const scanner = new OpenVikingScanner({ storagePath: root })

    const items = await scanner.scan()
    const item1 = items.find((item) => item.sessionId === 'dsh-session-test-0001')!
    const freed = await scanner.delete([item1])
    expect(freed).toBe(item1.sizeInBytes)
    expect(existsSync(f1)).toBe(false)
    expect(existsSync(f2)).toBe(false)
    expect(existsSync(f3)).toBe(true)
    // 还有别的会话在，pending 不该被回收
    expect(existsSync(pending)).toBe(true)

    expect(await scanner.delete([])).toBe(0)
    const remaining = await scanner.scan()
    expect(remaining.map((item) => item.sessionId)).toEqual(['dsh-session-test-0002'])
  })

  it('cleanEmptyProjectFolders 开：pending 清空后整目录被回收', async () => {
    CleanPrefs.patch({ cleanEmptyProjectFolders: true })
    const root = tempRoot()
    const pending = join(root, 'pending')
    write(join(pending, 'only.json'), JSON.stringify({ sessionId: 'only' }))

    const scanner = new OpenVikingScanner({ storagePath: root })
    await scanner.delete(await scanner.scan())
    expect(existsSync(pending)).toBe(false)
  })

  it('cleanEmptyProjectFolders 关：pending 目录保留', async () => {
    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    const root = tempRoot()
    const pending = join(root, 'pending')
    write(join(pending, 'only.json'), JSON.stringify({ sessionId: 'only' }))

    const scanner = new OpenVikingScanner({ storagePath: root })
    await scanner.delete(await scanner.scan())
    expect(existsSync(pending)).toBe(true)
    expect(readdirSync(pending)).toEqual([])
  })

  it('cleanFileHistorySnapshots 关：整条路径都是快照时不删、也不计入释放量', async () => {
    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    // 存储目录本身叫 backups → 按分段匹配，这些文件全部算「快照」
    const base = tempRoot('ovkbackup')
    const root = join(base, 'backups')
    const file = write(join(root, 'pending', 'only.json'), JSON.stringify({ sessionId: 'only' }))

    const scanner = new OpenVikingScanner({ storagePath: root })
    const items = await scanner.scan()
    expect(items).toHaveLength(1)
    expect(await scanner.delete(items)).toBe(0)
    expect(existsSync(file)).toBe(true)
  })

  it('cleanFileHistorySnapshots 开：同样夹具照删不误', async () => {
    CleanPrefs.patch({ cleanFileHistorySnapshots: true })
    const base = tempRoot('ovkbackup')
    const root = join(base, 'backups')
    const file = write(join(root, 'pending', 'only.json'), JSON.stringify({ sessionId: 'only' }))

    const scanner = new OpenVikingScanner({ storagePath: root })
    const items = await scanner.scan()
    expect(await scanner.delete(items)).toBe(items[0]!.sizeInBytes)
    expect(existsSync(file)).toBe(false)
  })
})

describe('OpenVikingScanner.cleanAll', () => {
  it('整个清空 pending/ 并重建空目录，bytes 统计包含所有文件', async () => {
    const { root, f1, f2, f3, pending } = buildMockRoot()
    const scanner = new OpenVikingScanner({ storagePath: root })

    const expected = statSync(f1).size + statSync(f2).size + statSync(f3).size
    const freed = await scanner.cleanAll()
    expect(freed).toBe(expected)
    expect(existsSync(pending)).toBe(true)
    expect(readdirSync(pending)).toEqual([])
    expect(await scanner.scan()).toEqual([])
  })

  it('未安装时返回 0 且不抛错', async () => {
    const scanner = new OpenVikingScanner({ storagePath: join(tempRoot(), 'missing') })
    expect(await scanner.cleanAll()).toBe(0)
  })
})

describe('OpenVikingScanner 本机真实目录（只读）', () => {
  it.skipIf(!existsSync(join(REAL_HOME, '.openviking')))(
    '扫描 ~/.openviking 不抛错且不修改任何文件',
    async () => {
      process.env.HOME = REAL_HOME
      try {
        const scanner = new OpenVikingScanner()
        expect(scanner.isInstalled).toBe(true)
        const before = snapshotTree(scanner.storagePath)
        const items = await scanner.scan()
        expect(snapshotTree(scanner.storagePath)).toEqual(before)
        for (const item of items) {
          expect(item.category).toBe('openViking')
          expect(item.sessionId.length).toBeGreaterThan(0)
          expect(item.associatedPaths.length).toBeGreaterThan(0)
          expect(Number.isNaN(Date.parse(item.updatedAt))).toBe(false)
        }
        const times = items.map((item) => Date.parse(item.updatedAt))
        expect([...times].sort((a, b) => b - a)).toEqual(times)
      } finally {
        process.env.HOME = SANDBOX_HOME
      }
    }
  )
})
