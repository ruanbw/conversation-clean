import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative } from 'node:path'
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'

// `core/prefs` 顶层 `import { app } from 'electron'` 在纯 Node 下会炸
// （electron 的入口是一个 CJS 字符串，没有具名导出）。
// 这里把 `app.getPath('userData')` 指到临时目录，prefs 就完全不会碰用户真实的
// `~/.conversation-clean/preferences.json`。
const electronHolder = vi.hoisted(() => ({ userDataDir: '' }))
vi.mock('electron', () => ({
  app: {
    getPath: (_name: string) => electronHolder.userDataDir
  }
}))

import { ClaudeCodeScanner } from './ClaudeCodeScanner'
import { CleanPrefs } from '@main/core/scanner'

// ---------------------------------------------------------------------------
// 夹具工具
// ---------------------------------------------------------------------------

const roots: string[] = []

/** 建一个全新的空夹具根目录（已 realpath 规范化，与扫描器的规范化口径一致）。 */
function makeRoot(tag: string): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), `claude-code-${tag}-`)))
  roots.push(dir)
  return dir
}

function writeFile(path: string, content: string): string {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content, 'utf8')
  return path
}

function setMtime(path: string, iso: string): void {
  const time = new Date(iso)
  utimesSync(path, time, time)
}

/** 独立实现的递归体积统计（跳过隐藏项），用来跟扫描器对着算账。 */
function sizeOf(path: string): number {
  let stats
  try {
    stats = statSync(path)
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
    total += sizeOf(join(path, entry))
  }
  return total
}

/** 目录快照：相对路径 → `{ size, mtimeMs }`，用于证明 `scan()` 一个字节都没写。 */
function snapshotTree(root: string): Map<string, string> {
  const out = new Map<string, string>()
  const walk = (dir: string): void => {
    let entries: string[]
    try {
      entries = readdirSync(dir)
    } catch {
      return
    }
    for (const entry of entries) {
      const full = join(dir, entry)
      const stats = statSync(full)
      out.set(relative(root, full), `${stats.isDirectory() ? 'd' : 'f'}:${stats.size}:${stats.mtimeMs}`)
      if (stats.isDirectory()) walk(full)
    }
  }
  walk(root)
  return out
}

// ---------------------------------------------------------------------------
// 夹具内容
// ---------------------------------------------------------------------------

const SID1 = '11111111-1111-1111-1111-111111111111'
const SID2 = '22222222-2222-2222-2222-222222222222'
const SID3 = '33333333-3333-3333-3333-333333333333'
const SID4 = '44444444-4444-4444-4444-444444444444'
const SID5 = '55555555-5555-5555-5555-555555555555'
const SID6 = '66666666-6666-6666-6666-666666666666'

interface Fixture {
  root: string
  /** sid → 主 jsonl 绝对路径 */
  jsonl: Record<string, string>
  /** sid → 快照目录（`file-history` / `plans` / `session-env`）绝对路径 */
  snapshot: Record<string, string>
  /** sid → project 目录里的 subagent 会话子目录 */
  subagent: Record<string, string>
  /** sid → 磁盘 mtime（ISO），测试据此断言倒序 */
  mtime: Record<string, string>
}

function buildFixture(tag: string): Fixture {
  const root = makeRoot(tag)
  const projects = join(root, 'projects')
  const alpha = join(projects, '-Users-me-alpha')
  const beta = join(projects, '-Users-me-beta')
  const gamma = join(projects, '-Users-me-gamma')
  const delta = join(projects, '-Users-me-delta')
  const direct = join(root, 'sessions')

  const jsonl: Record<string, string> = {}
  const snapshot: Record<string, string> = {}
  const subagent: Record<string, string> = {}
  const mtime: Record<string, string> = {}

  // S1：cwd / gitBranch / 首条 user prompt 全在 JSON 头里；带 subagent 子目录与两份快照。
  const s1Lines = [
    JSON.stringify({
      type: 'user',
      cwd: '/Users/me/alpha',
      gitBranch: 'feature/fix-crash',
      message: { content: '修复扫描器崩溃\n顺带清理索引' }
    }),
    JSON.stringify({ type: 'assistant', message: { content: '好的' } })
  ].join('\n')
  jsonl[SID1] = writeFile(join(alpha, `${SID1}.jsonl`), `${s1Lines}\n`)
  subagent[SID1] = join(alpha, SID1)
  writeFile(join(subagent[SID1], 'subagent.json'), 'x'.repeat(37))
  // S6 与 S1 同在 alpha：删掉 S1 之后 alpha 目录仍然有活着的会话，
  // sessions-index.json 才有机会被读到（否则整个目录会被当空目录回收）。
  jsonl[SID6] = writeFile(
    join(alpha, `${SID6}.jsonl`),
    `${JSON.stringify({ type: 'user', cwd: '/Users/me/alpha', message: { content: 'alpha 里的另一场会话' } })}\n`
  )
  mtime[SID6] = '2026-01-06T00:00:00.000Z'
  const fh1 = join(root, 'file-history', SID1)
  writeFile(join(fh1, 'a.bin'), 'a'.repeat(8))
  writeFile(join(fh1, 'b.bin'), 'b'.repeat(16))
  const plans1 = join(root, 'plans', SID1)
  writeFile(join(plans1, 'plan.md'), 'p'.repeat(23))
  snapshot[SID1] = fh1
  mtime[SID1] = '2026-01-01T00:00:00.000Z'

  // S2：content 是数组；JSON 里没有 cwd → 从目录名 `-Users-me-beta` 反推。
  const s2Lines = [
    JSON.stringify({
      type: 'user',
      message: { content: [{ type: 'text', text: '  用数组 content 的首条 prompt  ' }] }
    })
  ].join('\n')
  jsonl[SID2] = writeFile(join(beta, `${SID2}.jsonl`), `${s2Lines}\n`)
  const env2 = join(root, 'session-env', SID2)
  writeFile(join(env2, 'env.json'), 'e'.repeat(11))
  snapshot[SID2] = env2
  mtime[SID2] = '2026-01-03T00:00:00.000Z'

  // S3：history.jsonl 提供 project / display，JSON 里的 cwd 必须被它压过。
  const s3Lines = [
    JSON.stringify({ type: 'user', cwd: '/Users/me/wrong', message: { content: 'JSON 里的 prompt' } })
  ].join('\n')
  jsonl[SID3] = writeFile(join(gamma, `${SID3}.jsonl`), `${s3Lines}\n`)
  mtime[SID3] = '2026-01-02T00:00:00.000Z'

  // S4：没有 user 消息 → 标题回落到 slug，摘要回落到「项目: cwd」。
  const s4Lines = [
    JSON.stringify({ type: 'user', cwd: '/Users/me/delta', slug: '重构清理流程', message: { content: '   ' } })
  ].join('\n')
  jsonl[SID4] = writeFile(join(delta, `${SID4}.jsonl`), `${s4Lines}\n`)
  mtime[SID4] = '2026-01-05T00:00:00.000Z'

  // S5：顶层 `sessions/`，没有 cwd 也没有 history → projectPath 为 null。
  const s5Lines = [JSON.stringify({ type: 'user', message: { content: '顶层会话的直接 prompt' } })].join('\n')
  jsonl[SID5] = writeFile(join(direct, `${SID5}.jsonl`), `${s5Lines}\n`)
  mtime[SID5] = '2026-01-04T00:00:00.000Z'

  // sessionId 去重：sessions/ 下放一份与 alpha 同 id 的文件，应该被忽略。
  writeFile(join(direct, `${SID1}.jsonl`), `${JSON.stringify({ type: 'user', message: { content: '重复 id' } })}\n`)

  const history = [
    JSON.stringify({ sessionId: SID3, display: '第一条历史', project: '/Users/me/gamma-real', timestamp: 1769398442123 }),
    JSON.stringify({ sessionId: SID3, display: '最后一条历史', timestamp: 1769398442999 }),
    JSON.stringify({ display: '没有 sessionId 的行' }),
    JSON.stringify({ sessionId: 'ghost', display: '磁盘上不存在的会话' }),
    '<<< 这行不是 JSON >>>'
  ].join('\n')
  writeFile(join(root, 'history.jsonl'), `${history}\n`)

  // 四种形状的 sessions-index.json，清空后都该被删掉。
  writeFile(join(alpha, 'sessions-index.json'), JSON.stringify({ entries: [{ id: SID1 }, { id: SID6 }] }))
  writeFile(join(beta, 'sessions-index.json'), JSON.stringify({ sessions: [{ sessionId: SID2 }] }))
  writeFile(join(gamma, 'sessions-index.json'), JSON.stringify({ sessions: { [SID3]: { title: 'x' } } }))
  writeFile(join(delta, 'sessions-index.json'), JSON.stringify({ [SID4]: { title: 'y' } }))
  writeFile(join(root, 'sessions-index.json'), JSON.stringify([{ sessionId: SID1 }, { sessionId: SID5 }]))

  for (const sid of Object.keys(jsonl)) setMtime(jsonl[sid] as string, mtime[sid] as string)

  return { root, jsonl, snapshot, subagent, mtime }
}

function expectedS1Size(fx: Fixture): number {
  return (
    sizeOf(fx.jsonl[SID1] as string) +
    sizeOf(fx.subagent[SID1] as string) +
    sizeOf(join(fx.root, 'file-history', SID1)) +
    sizeOf(join(fx.root, 'plans', SID1))
  )
}

function readJsonlIndex(path: string): unknown {
  return JSON.parse(readFileSync(path, 'utf8'))
}

function readJsonlLines(path: string): string[] {
  const content = readFileSync(path, 'utf8')
  const lines = content.split('\n')
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop()
  return lines
}

function byId<T extends { sessionId: string }>(items: T[], sessionId: string): T {
  const found = items.find((item) => item.sessionId === sessionId)
  if (!found) throw new Error(`夹具里找不到会话 ${sessionId}`)
  return found
}

// ---------------------------------------------------------------------------

beforeAll(() => {
  electronHolder.userDataDir = makeRoot('prefs')
})

beforeEach(() => {
  // 每个用例都从默认开关开始（默认两个开关都是 true）。
  CleanPrefs.patch({
    autoScanOnLaunch: true,
    confirmBeforeClean: true,
    cleanFileHistorySnapshots: true,
    cleanEmptyProjectFolders: true
  })
})

afterAll(() => {
  for (const dir of roots) rmSync(dir, { recursive: true, force: true })
})

// ---------------------------------------------------------------------------

describe('storagePath / isInstalled', () => {
  it('storagePath 指向注入的目录并做 realpath 规范化', () => {
    const root = makeRoot('storage')
    const scanner = new ClaudeCodeScanner({ storagePath: root })
    expect(scanner.storagePath).toBe(root)
    expect(scanner.isInstalled).toBe(true)
    expect(scanner.category).toBe('claudeCode')
  })

  it('目录不存在时 isInstalled === false 且 scan() 返回 []', async () => {
    const missing = join(makeRoot('missing'), 'no-such-dir')
    const scanner = new ClaudeCodeScanner({ storagePath: missing })
    expect(scanner.isInstalled).toBe(false)
    await expect(scanner.scan()).resolves.toEqual([])
  })

  it('默认走 CLAUDE_HOME / ~/.claude', () => {
    const previous = process.env.CLAUDE_HOME
    try {
      const envRoot = makeRoot('env')
      process.env.CLAUDE_HOME = envRoot
      expect(new ClaudeCodeScanner().storagePath).toBe(realpathSync(envRoot))
      expect(new ClaudeCodeScanner().isInstalled).toBe(true)
    } finally {
      if (previous === undefined) delete process.env.CLAUDE_HOME
      else process.env.CLAUDE_HOME = previous
    }
  })
})

describe('scan', () => {
  it('枚举 projects / sessions，字段、倒序与 associatedPaths 都按既定口径', async () => {
    const fx = buildFixture('scan')
    const items = await new ClaudeCodeScanner({ storagePath: fx.root }).scan()

    // 去重后 6 条（sessions/ 下重复的 sid1 不算），按 mtime 倒序。
    expect(items).toHaveLength(6)
    expect(items.map((i) => i.sessionId)).toEqual([SID6, SID4, SID5, SID2, SID3, SID1])

    // S1：cwd / gitBranch / 首条 user prompt，标题里的换行压成空格。
    const s1 = byId(items, SID1)
    expect(s1.title).toBe('修复扫描器崩溃 顺带清理索引')
    expect(s1.snippet).toBe('修复扫描器崩溃 顺带清理索引')
    expect(s1.projectPath).toBe('/Users/me/alpha')
    expect(s1.gitBranch).toBe('feature/fix-crash')
    expect(s1.category).toBe('claudeCode')
    expect(s1.isSelected).toBe(false)
    expect(s1.sizeInBytes).toBe(expectedS1Size(fx))
    expect(s1.updatedAt).toBe(new Date(fx.mtime[SID1] as string).toISOString())

    // associatedPaths：主文件 → subagent 子目录 → file-history/<sid> → plans/<sid>。
    // 预索引层枚举的是这三个目录的**直接子项**（即每个会话一个目录），
    // 不是目录里的文件 —— 预索引层只收子目录，文件交给扩展名守卫处理。
    const [main, subagent, ...rest] = s1.associatedPaths
    expect(main).toBe(fx.jsonl[SID1])
    expect(subagent).toBe(fx.subagent[SID1])
    expect(rest).toEqual([join(fx.root, 'file-history', SID1), join(fx.root, 'plans', SID1)])

    // S2：数组 content；cwd 从目录名反推。
    const s2 = byId(items, SID2)
    expect(s2.title).toBe('用数组 content 的首条 prompt')
    expect(s2.projectPath).toBe('/Users/me/beta')
    expect(s2.gitBranch).toBeNull()
    expect(s2.associatedPaths).toEqual([
      fx.jsonl[SID2],
      join(fx.root, 'session-env', SID2)
    ])
    // 没有 history → messageCount 由体积估算。
    expect(s2.messageCount).toBe(Math.max(1, Math.floor(s2.sizeInBytes / 1024 / 20)))

    // S3：history.jsonl 的 project 压过 JSON 里的 cwd，标题取第一条 display，摘要取最后一条。
    const s3 = byId(items, SID3)
    expect(s3.title).toBe('第一条历史')
    expect(s3.snippet).toBe('最后一条历史')
    expect(s3.projectPath).toBe('/Users/me/gamma-real')
    expect(s3.messageCount).toBe(2)
    expect(s3.sizeInBytes).toBe(sizeOf(fx.jsonl[SID3] as string))

    // S4：user content 全是空白 → 标题回落到 slug，摘要回落到「项目: cwd」。
    const s4 = byId(items, SID4)
    expect(s4.title).toBe('重构清理流程')
    expect(s4.snippet).toBe('项目: /Users/me/delta')
    expect(s4.projectPath).toBe('/Users/me/delta')

    // S5：sessions/ 下的直接会话，没有 cwd 也没有 history。
    const s5 = byId(items, SID5)
    expect(s5.title).toBe('顶层会话的直接 prompt')
    expect(s5.snippet).toBe('顶层会话的直接 prompt')
    expect(s5.projectPath).toBeNull()
    expect(s5.associatedPaths).toEqual([fx.jsonl[SID5]])

    // 去重：sessions/ 下那份同 id 的文件不是任何一条会话的 associatedPaths。
    expect(items.flatMap((i) => i.associatedPaths)).not.toContain(join(fx.root, 'sessions', `${SID1}.jsonl`))

    // 没有 history / slug / prompt 时标题兜底为「会话 <前 8 位>」。
    const bareRoot = makeRoot('bare')
    writeFile(join(bareRoot, 'projects', '-a', 'abcdefgh-9999.jsonl'), '{}\n')
    const bare = await new ClaudeCodeScanner({ storagePath: bareRoot }).scan()
    expect(bare).toHaveLength(1)
    expect(byId(bare, 'abcdefgh-9999').title).toBe('会话 abcdefgh')
    expect(byId(bare, 'abcdefgh-9999').snippet).toBe('项目: /a')
  })

  it('history.jsonl 缺失 / 坏行都不会让扫描失败', async () => {
    const root = makeRoot('badhistory')
    writeFile(join(root, 'history.jsonl'), 'not json\n{"display":"没有 sessionId"}\n')
    writeFile(join(root, 'projects', '-a', `${SID1}.jsonl`), '{}\n')
    const items = await new ClaudeCodeScanner({ storagePath: root }).scan()
    expect(items).toHaveLength(1)
    expect(items[0]?.sessionId).toBe(SID1)
    expect(items[0]?.projectPath).toBe('/a')
  })

  it('scan() 一个字节都不写（含 mtime）', async () => {
    const fx = buildFixture('readonly')
    const scanner = new ClaudeCodeScanner({ storagePath: fx.root })
    const before = snapshotTree(fx.root)
    await scanner.scan()
    await scanner.scan()
    expect(snapshotTree(fx.root)).toEqual(before)
  })
})

describe('delete', () => {
  it('删空数组返回 0', async () => {
    const fx = buildFixture('delete-empty')
    await expect(new ClaudeCodeScanner({ storagePath: fx.root }).delete([])).resolves.toBe(0)
  })

  it('删掉会话文件与全部 associatedPaths，按上报体积记账', async () => {
    const fx = buildFixture('delete-one')
    const scanner = new ClaudeCodeScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    const s1 = byId(items, SID1)
    const expected = expectedS1Size(fx)

    const freed = await scanner.delete([s1])
    expect(freed).toBe(expected)

    for (const path of s1.associatedPaths) {
      expect(existsSync(path)).toBe(false)
    }
    // 其它会话没被误伤。
    expect(existsSync(fx.jsonl[SID2] as string)).toBe(true)
    expect(existsSync(fx.jsonl[SID3] as string)).toBe(true)
  })

  it('history.jsonl 只剔除被删 sessionId 的行，坏行原样保留', async () => {
    const fx = buildFixture('delete-history')
    const scanner = new ClaudeCodeScanner({ storagePath: fx.root })
    const items = await scanner.scan()

    await scanner.delete([byId(items, SID3)])
    expect(readJsonlLines(join(fx.root, 'history.jsonl'))).toEqual([
      JSON.stringify({ display: '没有 sessionId 的行' }),
      JSON.stringify({ sessionId: 'ghost', display: '磁盘上不存在的会话' }),
      '<<< 这行不是 JSON >>>'
    ])

    // 全部删完后文件仍然存在，且内容就是那三行 + 结尾换行。
    const rest = (await scanner.scan()).filter((i) => i.sessionId !== SID3)
    await scanner.delete(rest)
    const content = readFileSync(join(fx.root, 'history.jsonl'), 'utf8')
    expect(content).toBe(
      `${[
        JSON.stringify({ display: '没有 sessionId 的行' }),
        JSON.stringify({ sessionId: 'ghost', display: '磁盘上不存在的会话' }),
        '<<< 这行不是 JSON >>>'
      ].join('\n')}\n`
    )
  })

  it('裁剪 sessions-index.json 的四种形状，清空后删文件', async () => {
    const fx = buildFixture('delete-index')
    const scanner = new ClaudeCodeScanner({ storagePath: fx.root })
    const items = await scanner.scan()

    // 第一刀：只删 S1。alpha 的 entries 剩一条、根数组剩一条；
    // beta / gamma / delta 三个索引里没有 S1，内容不变
    // （但会被重新 pretty-print 写回 —— 总是重写，这里只比结构）。
    const untouched = {
      beta: readJsonlIndex(join(fx.root, 'projects', '-Users-me-beta', 'sessions-index.json')),
      gamma: readJsonlIndex(join(fx.root, 'projects', '-Users-me-gamma', 'sessions-index.json')),
      delta: readJsonlIndex(join(fx.root, 'projects', '-Users-me-delta', 'sessions-index.json'))
    }
    await scanner.delete([byId(items, SID1)])
    expect(readJsonlIndex(join(fx.root, 'projects', '-Users-me-alpha', 'sessions-index.json'))).toEqual({ entries: [{ id: SID6 }] })
    expect(readJsonlIndex(join(fx.root, 'sessions-index.json'))).toEqual([{ sessionId: SID5 }])
    expect(readJsonlIndex(join(fx.root, 'projects', '-Users-me-beta', 'sessions-index.json'))).toEqual(untouched.beta)
    expect(readJsonlIndex(join(fx.root, 'projects', '-Users-me-gamma', 'sessions-index.json'))).toEqual(untouched.gamma)
    expect(readJsonlIndex(join(fx.root, 'projects', '-Users-me-delta', 'sessions-index.json'))).toEqual(untouched.delta)

    // 第二刀：剩下的全删光，5 个索引文件都该被删掉。
    // 注意 SID1 又出现了：alpha 里那份删掉后，sessions/ 下那份同 id 的文件
    // 不再被去重掉，会作为独立会话被扫出来。
    const rest = await scanner.scan()
    expect(rest.map((i) => i.sessionId).sort()).toEqual([SID1, SID2, SID3, SID4, SID5, SID6].sort())
    await scanner.delete(rest)

    for (const name of ['-Users-me-alpha', '-Users-me-beta', '-Users-me-gamma', '-Users-me-delta']) {
      expect(existsSync(join(fx.root, 'projects', name, 'sessions-index.json'))).toBe(false)
    }
    expect(existsSync(join(fx.root, 'sessions-index.json'))).toBe(false)
  })

  it('解析失败的 sessions-index.json 直接删掉', async () => {
    const fx = buildFixture('delete-badindex')
    writeFile(join(fx.root, 'projects', '-Users-me-alpha', 'sessions-index.json'), '{ this is not json')
    const scanner = new ClaudeCodeScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    await scanner.delete([byId(items, SID1)])
    expect(existsSync(join(fx.root, 'projects', '-Users-me-alpha', 'sessions-index.json'))).toBe(false)
  })

  it('默认设置下回收空 project 目录', async () => {
    const fx = buildFixture('delete-reclaim')
    const scanner = new ClaudeCodeScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    await scanner.delete(items)
    expect(existsSync(join(fx.root, 'projects', '-Users-me-alpha'))).toBe(false)
    expect(existsSync(join(fx.root, 'projects', '-Users-me-beta'))).toBe(false)
    // `sessions/` 里还有 S5 的副本（与 S1 同 id），所以目录本身还在但内容已被删空。
    expect(existsSync(join(fx.root, 'sessions'))).toBe(true)
  })
})

describe('delete 开关', () => {
  it('cleanEmptyProjectFolders=false 时空 project 目录保留在磁盘上', async () => {
    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    const fx = buildFixture('keep-empty')
    const scanner = new ClaudeCodeScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    await scanner.delete(items)

    for (const name of ['-Users-me-alpha', '-Users-me-beta', '-Users-me-gamma', '-Users-me-delta']) {
      const dir = join(fx.root, 'projects', name)
      expect(existsSync(dir)).toBe(true)
      expect(readdirSync(dir)).toEqual([])
    }
    // 会话文件本身还是删掉了。
    expect(existsSync(fx.jsonl[SID1] as string)).toBe(false)
  })

  it('cleanFileHistorySnapshots=false 时保留 file-history 快照并从 freedBytes 扣减', async () => {
    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const fx = buildFixture('keep-snapshot')
    const scanner = new ClaudeCodeScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    const s1 = byId(items, SID1)
    const reported = expectedS1Size(fx)
    const keptSnapshotBytes = sizeOf(join(fx.root, 'file-history', SID1))

    const freed = await scanner.delete([s1])
    expect(freed).toBe(reported - keptSnapshotBytes)

    // 快照文件原样保留。
    expect(existsSync(join(fx.root, 'file-history', SID1, 'a.bin'))).toBe(true)
    expect(existsSync(join(fx.root, 'file-history', SID1, 'b.bin'))).toBe(true)
    // `plans` 不在快照目录名单里，照删不误。
    expect(existsSync(join(fx.root, 'plans', SID1))).toBe(false)
    // 会话本体照删。
    expect(existsSync(fx.jsonl[SID1] as string)).toBe(false)
    expect(existsSync(fx.subagent[SID1] as string)).toBe(false)
  })
})

describe('cleanAll', () => {
  it('清空会话 + cache/backups/shell-snapshots，并删掉全部 sessions-index', async () => {
    const fx = buildFixture('cleanall')
    writeFile(join(fx.root, 'cache', 'x.bin'), 'c'.repeat(19))
    writeFile(join(fx.root, 'backups', 'y.bin'), 'b'.repeat(23))
    writeFile(join(fx.root, 'shell-snapshots', 'z.sh'), 's'.repeat(29))

    const scanner = new ClaudeCodeScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    const expectedFreed =
      items.reduce((sum, item) => sum + item.sizeInBytes, 0) + 19 + 23 + 29

    const freed = await scanner.cleanAll()
    expect(freed).toBe(expectedFreed)

    // 三个目录被删后立刻重建成空目录。
    for (const name of ['cache', 'backups', 'shell-snapshots']) {
      expect(existsSync(join(fx.root, name))).toBe(true)
      expect(readdirSync(join(fx.root, name))).toEqual([])
    }
    // 会话与索引都没了。
    for (const path of Object.values(fx.jsonl)) expect(existsSync(path)).toBe(false)
    expect(existsSync(join(fx.root, 'sessions-index.json'))).toBe(false)
    for (const name of ['-Users-me-alpha', '-Users-me-beta', '-Users-me-gamma', '-Users-me-delta']) {
      expect(existsSync(join(fx.root, 'projects', name, 'sessions-index.json'))).toBe(false)
    }
    expect(existsSync(join(fx.root, 'file-history', SID1))).toBe(false)
  })

  it('cleanFileHistorySnapshots=false 时保留 backups / shell-snapshots，只清 cache', async () => {
    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const fx = buildFixture('cleanall-keep')
    writeFile(join(fx.root, 'cache', 'x.bin'), 'c'.repeat(19))
    writeFile(join(fx.root, 'backups', 'y.bin'), 'b'.repeat(23))
    writeFile(join(fx.root, 'shell-snapshots', 'z.sh'), 's'.repeat(29))

    const scanner = new ClaudeCodeScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    const kept = items
      .flatMap((item) => item.associatedPaths)
      .filter((path) => path.includes('/file-history/'))
    const keptBytes = kept.reduce((sum, path) => sum + sizeOf(path), 0)
    const expectedFreed =
      items.reduce((sum, item) => sum + item.sizeInBytes, 0) - keptBytes + 19

    const freed = await scanner.cleanAll()
    expect(freed).toBe(expectedFreed)

    expect(readdirSync(join(fx.root, 'cache'))).toEqual([])
    expect(readFileSync(join(fx.root, 'backups', 'y.bin'), 'utf8')).toBe('b'.repeat(23))
    expect(readFileSync(join(fx.root, 'shell-snapshots', 'z.sh'), 'utf8')).toBe('s'.repeat(29))
  })
})

describe('本机真实 ~/.claude（只读冒烟）', () => {
  it('扫真实目录不抛异常、结果 updatedAt 倒序、磁盘不变', async () => {
    const scanner = new ClaudeCodeScanner()
    if (!scanner.isInstalled) {
      await expect(scanner.scan()).resolves.toEqual([])
      return
    }

    const before = snapshotTree(scanner.storagePath)
    const items = await scanner.scan()

    for (let i = 1; i < items.length; i += 1) {
      const previous = items[i - 1]
      const current = items[i]
      if (!previous || !current) continue
      expect(previous.updatedAt >= current.updatedAt).toBe(true)
    }
    for (const item of items) {
      expect(item.category).toBe('claudeCode')
      expect(item.sizeInBytes).toBeGreaterThan(0)
      expect(item.associatedPaths[0]).toBeTypeOf('string')
    }
    expect(snapshotTree(scanner.storagePath)).toEqual(before)
  })
})
