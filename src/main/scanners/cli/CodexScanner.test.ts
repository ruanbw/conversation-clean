import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import { CleanPrefs } from '@main/core/prefs'
import { sizeOfPath } from '@main/core/scanner'
import { CodexScanner } from './CodexScanner'

/**
 * CodexScanner 验收用例：storagePath 的解析、scan 的字段抽取、delete 的索引同步、
 * cleanAll 的清理范围。
 *
 * 盖住的行为：4 个会话（sessions 三层日期目录 + archived_sessions）、
 * `session_index.jsonl` 索引匹配、标题 / 项目路径 / 体积 / associatedPaths / updatedAt 倒序；
 * 另外还钉住了删除后的索引同步与两个开关的相反分支。
 *
 * 本文件自包含：`$HOME` 指向一次性临时目录（prefs 与 `~/.codex-global-state.json`
 * 都写到那里），夹具全部在 `os.tmpdir()` 下现场造，不依赖任何其它测试文件。
 */

const FAKE_HOME = mkdtempSync(join(tmpdir(), 'cc-codex-home-'))
const REAL_HOME = process.env.HOME
process.env.HOME = FAKE_HOME

const ENV_KEYS = ['CODEX_HOME'] as const
const temps: string[] = []

function makeTempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix))
  temps.push(dir)
  return dir
}

function makeDir(path: string): void {
  mkdirSync(path, { recursive: true })
}

function writeFixture(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content, 'utf8')
}

function canon(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

function readText(path: string): string {
  return readFileSync(path, 'utf8')
}

function readJsonFile(path: string): Record<string, unknown> {
  return JSON.parse(readText(path)) as Record<string, unknown>
}

// 夹具里的四个会话
const SID1 = 'session-codex-001'
const SID2 = 'session-codex-002'
const SID3 = 'session-codex-003'
const SID4 = 'session-codex-archived'

/** 搭出完整的 `~/.codex` 夹具。 */
function buildCodexFixture(root: string): void {
  const day1 = join(root, 'sessions', '2026', '09', '20')
  const day2 = join(root, 'sessions', '2026', '09', '25')
  const day3 = join(root, 'sessions', '2026', '09', '26')
  const archiveDay = join(root, 'archived_sessions', '2026', '08', '15')
  for (const dir of [day1, day2, day3, archiveDay]) makeDir(dir)

  writeFixture(
    join(day1, `${SID1}.jsonl`),
    [
      '{"cwd":"/Users/tester/backend","role":"user","content":"Optimize SQL database query indexing"}',
      '{"role":"assistant","content":"I have analyzed the query plan and added indexes."}',
      ''
    ].join('\n')
  )

  writeFixture(
    join(day2, `${SID2}.jsonl`),
    [
      `{"project":"/Users/tester/auth-service","messages":[{"role":"user","content":"Implement JWT token expiration check"}]}`,
      '{"role":"assistant","content":"Added expiration validation logic."}',
      ''
    ].join('\n')
  )

  writeFixture(
    join(day3, `${SID3}.jsonl`),
    '{"working_directory":"/Users/tester/ios-cleaner","prompt":"Add dark mode support to SwiftUI sidebar"}\n'
  )

  writeFixture(
    join(archiveDay, `${SID4}.jsonl`),
    '{"role":"user","content":"Initial project scaffolding"}\n'
  )

  // 隐藏文件与非 .jsonl 文件都不该被枚举到（隐藏文件守卫 + 扩展名守卫）
  const decoyDay = join(root, 'sessions', '2026', '09', '21')
  makeDir(decoyDay)
  writeFixture(join(decoyDay, '.hidden.jsonl'), '{"role":"user","content":"hidden"}\n')
  writeFixture(join(decoyDay, 'notes.txt'), 'not a session\n')

  writeFixture(
    join(root, 'session_index.jsonl'),
    [
      `{"id":"${SID1}","title":"SQL Index Optimization","cwd":"/Users/tester/backend","updated_at":1789900000000}`,
      `{"id":"${SID2}","filename":"${SID2}.jsonl","title":"Auth Service JWT Refresh","project":"/Users/tester/auth-service","timestamp":1790300000000}`,
      `{"id":"${SID3}","filename":"2026/09/26/${SID3}.jsonl","title":"SwiftUI Dark Mode","cwd":"/Users/tester/ios-cleaner","updated_at":1790400000000}`,
      ''
    ].join('\n')
  )
}

beforeEach(() => {
  for (const key of ENV_KEYS) delete process.env[key]
  CleanPrefs.patch({ cleanFileHistorySnapshots: true, cleanEmptyProjectFolders: true })
})

afterEach(() => {
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true })
  for (const key of ENV_KEYS) delete process.env[key]
})

afterAll(() => {
  if (REAL_HOME === undefined) delete process.env.HOME
  else process.env.HOME = REAL_HOME
  rmSync(FAKE_HOME, { recursive: true, force: true })
})

describe('CodexScanner · storagePath / isInstalled', () => {
  it('默认指向 $HOME/.codex', () => {
    expect(new CodexScanner().storagePath).toBe(join(FAKE_HOME, '.codex'))
  })

  it('CODEX_HOME 覆盖默认目录，并做 realpath 规范化', () => {
    const envRoot = makeTempDir('cc-codex-env-')
    process.env.CODEX_HOME = envRoot
    expect(new CodexScanner().storagePath).toBe(canon(envRoot))
  })

  it('注入的 storagePath 优先于环境变量', () => {
    const envRoot = makeTempDir('cc-codex-env-')
    const injected = makeTempDir('cc-codex-injected-')
    process.env.CODEX_HOME = envRoot
    expect(new CodexScanner({ storagePath: injected }).storagePath).toBe(canon(injected))
  })

  it('目录不存在时 isInstalled 为 false，scan() 返回空数组', async () => {
    const missing = join(makeTempDir('cc-codex-missing-'), 'not-there')
    const scanner = new CodexScanner({ storagePath: missing })
    expect(scanner.isInstalled).toBe(false)
    await expect(scanner.scan()).resolves.toEqual([])
  })

  it('目录存在但没有 sessions 目录时返回空数组', async () => {
    const root = makeTempDir('cc-codex-empty-')
    const scanner = new CodexScanner({ storagePath: root })
    expect(scanner.isInstalled).toBe(true)
    await expect(scanner.scan()).resolves.toEqual([])
  })
})

describe('CodexScanner · scan', () => {
  it('枚举 sessions 与 archived_sessions，索引命中标题 / cwd / 时间', async () => {
    const root = makeTempDir('cc-codex-scan-')
    buildCodexFixture(root)
    const scanner = new CodexScanner({ storagePath: root })

    expect(scanner.category).toBe('codex')
    expect(scanner.isInstalled).toBe(true)

    const items = await scanner.scan()
    expect(items).toHaveLength(4)
    for (const item of items) expect(item.category).toBe('codex')

    const byId = new Map(items.map((item) => [item.sessionId, item]))

    // 1. 按 id 命中索引
    const s1File = join(root, 'sessions', '2026', '09', '20', `${SID1}.jsonl`)
    const item1 = byId.get(SID1)
    expect(item1).toBeDefined()
    expect(item1?.title).toBe('SQL Index Optimization')
    expect(item1?.projectPath).toBe('/Users/tester/backend')
    expect(item1?.associatedPaths).toEqual([canon(s1File)])
    expect(item1?.sizeInBytes).toBe(sizeOfPath(canon(s1File)))
    expect(item1?.messageCount).toBe(2)
    expect(item1?.snippet).toBe('Optimize SQL database query indexing')
    expect(item1?.gitBranch).toBeNull()
    // 索引里的 updated_at（毫秒）优先于文件 mtime
    expect(item1?.updatedAt).toBe(new Date(1789900000000).toISOString())

    // 2. 按 filename 命中索引，`project` 作为 cwd 的别名
    const item2 = byId.get(SID2)
    expect(item2?.title).toBe('Auth Service JWT Refresh')
    expect(item2?.projectPath).toBe('/Users/tester/auth-service')
    expect(item2?.updatedAt).toBe(new Date(1790300000000).toISOString())
    // messages[].role == "user" 的 content 也算首条 prompt
    expect(item2?.snippet).toBe('Implement JWT token expiration check')

    // 3. 索引里 filename 带日期相对路径，靠 id 命中；cwd 来自文件头的 working_directory
    const item3 = byId.get(SID3)
    expect(item3?.title).toBe('SwiftUI Dark Mode')
    expect(item3?.projectPath).toBe('/Users/tester/ios-cleaner')
    expect(item3?.messageCount).toBe(1)

    // 4. archived_sessions 里没有索引条目的会话，标题来自 role == "user" 的 content
    const item4 = byId.get(SID4)
    expect(item4?.title).toContain('Initial project scaffolding')
    expect(item4?.projectPath).toBeNull()
    expect(item4?.snippet).toBe('Initial project scaffolding') // role == "user" 的 content 就是首条 prompt

    // 末尾按 updatedAt 倒序
    const timestamps = items.map((item) => new Date(item.updatedAt).getTime())
    expect(timestamps).toEqual([...timestamps].sort((a, b) => b - a))
  })

  it('无索引、无 prompt、只有 cwd 时按兜底顺序生成标题与摘要', async () => {
    const root = makeTempDir('cc-codex-fallback-')
    const file = join(root, 'sessions', '2026', '09', '26', 'abcdefghijklmnop.jsonl')
    writeFixture(file, '{"cwd":"/Users/tester/only-cwd"}\n')
    const items = await new CodexScanner({ storagePath: root }).scan()
    expect(items).toHaveLength(1)
    expect(items[0]?.sessionId).toBe('abcdefghijklmnop')
    expect(items[0]?.title).toBe('Codex 会话 abcdefgh')
    expect(items[0]?.snippet).toBe('项目: /Users/tester/only-cwd')
    expect(items[0]?.projectPath).toBe('/Users/tester/only-cwd')
  })

  it('空文件也出一条会话，messageCount 下限为 1', async () => {
    const root = makeTempDir('cc-codex-blank-')
    writeFixture(join(root, 'sessions', 'empty.jsonl'), '')
    const items = await new CodexScanner({ storagePath: root }).scan()
    expect(items).toHaveLength(1)
    expect(items[0]?.messageCount).toBe(1)
    expect(items[0]?.title).toBe('Codex 会话 empty')
    expect(items[0]?.sizeInBytes).toBe(0)
  })
})

describe('CodexScanner · delete', () => {
  it('删文件、按条目记账，并同步 session_index.jsonl 与全局状态', async () => {
    const root = makeTempDir('cc-codex-delete-')
    buildCodexFixture(root)
    writeFileSync(
      join(FAKE_HOME, '.codex-global-state.json'),
      JSON.stringify(
        {
          activeSessionId: SID1,
          recentSessions: [SID1, SID2],
          sessions: { [SID1]: { title: 'a' }, [SID2]: { title: 'b' } },
          history: [{ id: SID1 }, { sessionId: SID2 }],
          [SID1]: { note: '顶层以 sessionId 为键的条目' },
          untouched: 42
        },
        null,
        2
      ),
      'utf8'
    )
    writeFileSync(
      join(root, '.codex-global-state.json'),
      JSON.stringify({ active_session_id: SID1, currentSessionId: SID2 }, null, 2),
      'utf8'
    )

    const scanner = new CodexScanner({ storagePath: root })
    const items = await scanner.scan()
    const target = items.find((item) => item.sessionId === SID1)
    expect(target).toBeDefined()

    const freed = await scanner.delete([target!])
    expect(freed).toBe(target!.sizeInBytes)
    expect(existsSync(join(root, 'sessions', '2026', '09', '20', `${SID1}.jsonl`))).toBe(false)

    // 其余会话还在
    expect(existsSync(join(root, 'sessions', '2026', '09', '25', `${SID2}.jsonl`))).toBe(true)
    expect(existsSync(join(root, 'archived_sessions', '2026', '08', '15', `${SID4}.jsonl`))).toBe(true)

    // session_index.jsonl：被删的 id 与它那一行都没了，别人的行按原样保留
    const indexText = readText(join(root, 'session_index.jsonl'))
    expect(indexText).not.toContain(SID1)
    expect(indexText).toContain(SID2)
    expect(indexText).toContain(SID3)
    expect(indexText.endsWith('\n')).toBe(true)

    // 全局状态：活跃指针置 null，数组 / 字典 / 顶层键里的痕迹都清掉
    const homeState = readJsonFile(join(FAKE_HOME, '.codex-global-state.json'))
    expect(homeState.activeSessionId).toBeNull()
    expect(homeState.recentSessions).toEqual([SID2])
    expect(homeState.sessions).toEqual({ [SID2]: { title: 'b' } })
    expect(homeState.history).toEqual([{ sessionId: SID2 }])
    expect(homeState[SID1]).toBeUndefined()
    expect(homeState.untouched).toBe(42)

    // 数据根目录下的那一份也同步处理
    const rootState = readJsonFile(join(root, '.codex-global-state.json'))
    expect(rootState.active_session_id).toBeNull()
    expect(rootState.currentSessionId).toBe(SID2)

    // 会话被删空后重扫不到
    const after = await scanner.scan()
    expect(after.map((item) => item.sessionId).sort()).toEqual([SID2, SID3, SID4].sort())
  })

  it('cleanEmptyProjectFolders 打开时回收空的日期目录', async () => {
    const root = makeTempDir('cc-codex-reclaim-on-')
    buildCodexFixture(root)
    const scanner = new CodexScanner({ storagePath: root })
    const items = await scanner.scan()
    const target = items.find((item) => item.sessionId === SID1)!
    await scanner.delete([target])
    expect(existsSync(join(root, 'sessions', '2026', '09', '20'))).toBe(false)
    expect(existsSync(join(root, 'sessions', '2026', '09', '25'))).toBe(true)
    // 非会话文件所在的目录不算空，不会被回收
    expect(existsSync(join(root, 'sessions', '2026', '09', '21', 'notes.txt'))).toBe(true)
  })

  it('cleanEmptyProjectFolders 关闭时保留空目录', async () => {
    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    const root = makeTempDir('cc-codex-reclaim-off-')
    buildCodexFixture(root)
    const scanner = new CodexScanner({ storagePath: root })
    const items = await scanner.scan()
    const target = items.find((item) => item.sessionId === SID1)!
    await scanner.delete([target])
    expect(existsSync(join(root, 'sessions', '2026', '09', '20', `${SID1}.jsonl`))).toBe(false)
    expect(existsSync(join(root, 'sessions', '2026', '09', '20'))).toBe(true)
  })

  it('cleanFileHistorySnapshots 对 Codex 无影响（没有快照目录，两个分支结果一致）', async () => {
    for (const flag of [true, false]) {
      CleanPrefs.patch({ cleanFileHistorySnapshots: flag })
      const root = makeTempDir(`cc-codex-snap-${flag ? 'on' : 'off'}-`)
      buildCodexFixture(root)
      const scanner = new CodexScanner({ storagePath: root })
      const items = await scanner.scan()
      const target = items.find((item) => item.sessionId === SID1)!
      const freed = await scanner.delete([target])
      expect(freed).toBe(target.sizeInBytes)
      expect(existsSync(join(root, 'sessions', '2026', '09', '20', `${SID1}.jsonl`))).toBe(false)
    }
  })

  it('空列表直接返回 0，不做任何索引写入', async () => {
    const root = makeTempDir('cc-codex-delete-none-')
    buildCodexFixture(root)
    const indexPath = join(root, 'session_index.jsonl')
    const before = readText(indexPath)
    const freed = await new CodexScanner({ storagePath: root }).delete([])
    expect(freed).toBe(0)
    expect(readText(indexPath)).toBe(before)
  })
})

describe('CodexScanner · cleanAll', () => {
  it('清空会话并补删 history.jsonl / cache / tmp', async () => {
    const root = makeTempDir('cc-codex-cleanall-')
    buildCodexFixture(root)
    writeFixture(join(root, 'history.jsonl'), 'x'.repeat(64))
    writeFixture(join(root, 'cache', 'a.json'), 'y'.repeat(32))
    writeFixture(join(root, 'tmp', 'b.bin'), 'z'.repeat(16))
    writeFileSync(
      join(FAKE_HOME, '.codex-global-state.json'),
      JSON.stringify({ recent_sessions: [SID1, SID2, SID3, SID4] }),
      'utf8'
    )

    const scanner = new CodexScanner({ storagePath: root })
    const totalFreed = await scanner.cleanAll()
    expect(totalFreed).toBeGreaterThan(0)

    await expect(scanner.scan()).resolves.toEqual([])
    expect(existsSync(join(root, 'history.jsonl'))).toBe(false)
    expect(existsSync(join(root, 'cache'))).toBe(false)
    expect(existsSync(join(root, 'tmp'))).toBe(false)
    expect(existsSync(join(root, 'sessions', '2026', '09', '20'))).toBe(false)
    // 根目录本身不进回收列表（cleanEmptyDirectories 只处理子目录）
    expect(existsSync(join(root, 'archived_sessions', '2026', '08', '15'))).toBe(false)

    const state = readJsonFile(join(FAKE_HOME, '.codex-global-state.json'))
    expect(state.recent_sessions).toEqual([])
  })

  it('cleanEmptyProjectFolders 关闭时 cleanAll 保留空目录', async () => {
    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    const root = makeTempDir('cc-codex-cleanall-keep-')
    buildCodexFixture(root)
    await new CodexScanner({ storagePath: root }).cleanAll()
    expect(existsSync(join(root, 'sessions', '2026', '09', '20'))).toBe(true)
    expect(existsSync(join(root, 'sessions', '2026', '09', '20', `${SID1}.jsonl`))).toBe(false)
  })
})
