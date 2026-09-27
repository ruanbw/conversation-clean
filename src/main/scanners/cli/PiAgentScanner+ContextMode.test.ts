import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ConversationItem } from '@shared/types'
import { CleanPrefs, sizeOfPath } from '@main/core/scanner'
import { openReadOnly } from '@main/core/vscdb'
import { PiAgentScanner } from './PiAgentScanner'
import { contextModeSessionIdFor, jsonlPathsUnder } from './PiAgentScanner+ContextMode'
import { pruneACPSessionMap } from './PiAgentScanner+ACPSessionMap'

/**
 * Pi Agent 的 context-mode 双层索引同步测试。
 *
 * 钉住 context-mode 双层索引与会话删除的同步关系：
 * 造真实的 SQLite 索引库（当前 schema / 旧 schema / fts5 内容库）+ `stats-pid-*.json`
 * + `pi-acp/session-map.json`，然后验证删会话时：
 *   · 会话文件与子代理嵌套目录都消失；
 *   · 四张会话表的索引行被清、无关会话的索引行被保留；
 *   · 清空后的 `sessions/*.db` 连文件一起删、还含别的会话的库保留；
 *   · fts5 内容索引里的 chunk 被清、`sources` 表不被误删；
 *   · 命中被删会话的 stats 缓存被清、无关的保留；
 *   · ACP 映射表剪掉幽灵条目、保留有效条目。
 *
 * 库用 `node:sqlite` 现场造，不依赖磁盘上的真实 `~/.pi`。
 */

// `CleanPrefs` 会往 `HOME` 下的 `.conversation-clean/preferences.json` 落盘，
// 这里把 HOME 指向临时目录，别污染真实用户设置。
const prefHome = realpathSync(mkdtempSync(join(tmpdir(), 'pi_cm_home_')))
const originalHome = process.env['HOME']
process.env['HOME'] = prefHome

const SID_1 = '01a0d1cc-4a16-74c5-bfbe-b36a0224af90'
const SID_2 = '01a0d1cc-4a16-74c5-bfbe-b36a0224af91'
const CM_OTHER = 'ffffffffffffffff'

let root = ''
let scanner: PiAgentScanner

function dir(...segments: string[]): string {
  const path = join(root, ...segments)
  mkdirSync(path, { recursive: true })
  return path
}

/** 相对路径按夹具根目录解析；自动建好父目录。 */
function write(path: string, content: string): string {
  const full = path.startsWith('/') ? path : join(root, path)
  mkdirSync(dirname(full), { recursive: true })
  writeFileSync(full, content, 'utf8')
  return full
}

function exists(path: string): boolean {
  return existsSync(path)
}

/** 现场建库并执行 SQL，然后关闭。 */
function withDb(path: string, body: (db: DatabaseSync) => void): void {
  const db = new DatabaseSync(path)
  try {
    body(db)
  } finally {
    db.close()
  }
}

/** 只读打开跑一条标量查询。 */
function scalarCount(dbPath: string, sql: string): number {
  const db = openReadOnly(dbPath)
  if (!db) throw new Error(`打不开 ${dbPath}`)
  try {
    const row = db.prepare(sql).get() as Record<string, unknown> | undefined
    return Number(row?.['c'] ?? 0)
  } finally {
    db.close()
  }
}

function countWhere(dbPath: string, table: string, column: string, value: string): number {
  return scalarCount(dbPath, `SELECT COUNT(*) AS c FROM "${table}" WHERE "${column}" = ?`.replace('?', `'${value}'`))
}

interface Ctx {
  projectDir: string
  cmSessionsDir: string
  cmContentDir: string
  acpDir: string
  jsonl1: string
  jsonl2: string
  nestedSessionDir: string
  nestedJsonl: string
  sessionsDb1: string
  sessionsDb2: string
  contentDb: string
  statsLinked: string
  statsUnlinked: string
  acpMap: string
  unrelatedJsonl: string
}

/** 两条会话 + 旧版布局的子代理嵌套目录 + 各层索引库与 ACP 映射的夹具。 */
function buildContextModeFixture(): Ctx {
  const projectDir = dir('agent', 'sessions', '--Users-mock-cm--')
  const cmSessionsDir = dir('context-mode', 'sessions')
  const cmContentDir = dir('context-mode', 'content')
  const acpDir = dir('pi-acp')

  const jsonl1 = write(
    join(projectDir, `2026-09-10T10-00-00-000Z_${SID_1}.jsonl`),
    [
      `{"type":"session","version":3,"id":"${SID_1}","timestamp":"2026-09-10T10:00:00.000Z","cwd":"/Users/mock/cm"}`,
      `{"type":"message","id":"m1","message":{"role":"user","content":[{"type":"text","text":"context-mode 幽灵会话测试 A"}]}}`,
      ''
    ].join('\n')
  )
  const jsonl2 = write(
    join(projectDir, `2026-09-11T11-00-00-000Z_${SID_2}.jsonl`),
    [
      `{"type":"session","version":3,"id":"${SID_2}","timestamp":"2026-09-11T11:00:00.000Z","cwd":"/Users/mock/cm"}`,
      `{"type":"message","id":"m2","message":{"role":"user","content":[{"type":"text","text":"context-mode 幽灵会话测试 B"}]}}`,
      ''
    ].join('\n')
  )

  // 子代理嵌套会话（旧版 Pi 布局：<sessionDir>/<uuid>/run-0/session.jsonl）
  const nestedSessionDir = dir('agent', 'sessions', '--Users-mock-cm--', `2026-09-10T10-00-00-000Z_${SID_1}`)
  const nestedRunDir = dir(
    'agent', 'sessions', '--Users-mock-cm--', `2026-09-10T10-00-00-000Z_${SID_1}`,
    '4b0172f1-647c-452f-82fd-b53e43777777', 'run-0'
  )
  const nestedJsonl = write(join(nestedRunDir, 'session.jsonl'), `{"type":"session","version":3,"id":"${SID_1}"}\n`)
  expect(exists(nestedSessionDir)).toBe(true)

  // 索引侧 session_id = sha256(会话文件绝对路径) 的前 16 位小写十六进制
  const cmId1 = contextModeSessionIdFor(jsonl1)
  const cmId2 = contextModeSessionIdFor(jsonl2)
  const cmIdNested = contextModeSessionIdFor(nestedJsonl)

  // ── 共享的项目索引库（context-mode 当前 schema，4 张会话表）──
  const sessionsDb1 = join(cmSessionsDir, 'aaaaaaaaaaaaaaaa.db')
  withDb(sessionsDb1, (db) => {
    db.exec('CREATE TABLE session_meta (session_id TEXT PRIMARY KEY, project_dir TEXT NOT NULL, started_at TEXT NOT NULL DEFAULT (datetime(\'now\')), last_event_at TEXT, event_count INTEGER NOT NULL DEFAULT 0, compact_count INTEGER NOT NULL DEFAULT 0, usage_cursor TEXT);')
    db.exec('CREATE TABLE session_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, type TEXT NOT NULL, category TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 2, data TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime(\'now\')));')
    db.exec('CREATE TABLE session_resume (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL UNIQUE, snapshot TEXT NOT NULL, event_count INTEGER NOT NULL, consumed INTEGER NOT NULL DEFAULT 0);')
    db.exec('CREATE TABLE tool_calls (session_id TEXT NOT NULL, tool TEXT NOT NULL, calls INTEGER NOT NULL DEFAULT 0);')
    const insertMeta = db.prepare('INSERT OR REPLACE INTO session_meta (session_id, project_dir, event_count) VALUES (?, ?, ?)')
    const insertEvent = db.prepare('INSERT INTO session_events (session_id, type, category, data) VALUES (?, ?, ?, ?)')
    const insertResume = db.prepare('INSERT OR REPLACE INTO session_resume (session_id, snapshot, event_count) VALUES (?, ?, ?)')
    const insertTool = db.prepare('INSERT INTO tool_calls (session_id, tool, calls) VALUES (?, ?, ?)')
    for (const sid of [cmId1, cmIdNested, CM_OTHER]) {
      insertMeta.run(sid, '/Users/mock/cm', 3)
      insertEvent.run(sid, 'decision', 'decision', 'payload')
      insertResume.run(sid, 'snapshot', 3)
      insertTool.run(sid, 'bash', 2)
    }
  })

  // ── 旧 schema 的独立索引库，仅含 sid2 行：清空后应连带删文件 ──
  const sessionsDb2 = join(cmSessionsDir, 'bbbbbbbbbbbbbbbb.db')
  withDb(sessionsDb2, (db) => {
    db.exec('CREATE TABLE session_meta (session_id TEXT PRIMARY KEY, cwd TEXT, created_at TEXT, updated_at TEXT, event_count INTEGER, is_archived INTEGER, title TEXT);')
    db.exec('CREATE TABLE session_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, data TEXT);')
    db.prepare('INSERT INTO session_meta VALUES (?, ?, ?, ?, ?, ?, ?)').run(
      cmId2, '/Users/mock/cm', '2026-09-11T11:00:00Z', '2026-09-11T11:00:00Z', 1, 0, 'legacy schema'
    )
    db.prepare('INSERT INTO session_events (session_id, data) VALUES (?, ?)').run(cmId2, 'legacy-event')
  })

  // ── content/ 内容索引库（fts5 chunks，与真实环境一致）──
  const contentDb = join(cmContentDir, 'cccccccccccccccc.db')
  withDb(contentDb, (db) => {
    db.exec('CREATE TABLE sources (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT NOT NULL, chunk_count INTEGER NOT NULL DEFAULT 0);')
    db.exec("CREATE VIRTUAL TABLE chunks USING fts5(title, content, source_id UNINDEXED, session_id UNINDEXED, event_id UNINDEXED, tokenize='porter unicode61');")
    db.prepare('INSERT INTO sources (label, chunk_count) VALUES (?, ?)').run('other-source', 1)
    const insertChunk = db.prepare('INSERT INTO chunks (title, content, source_id, session_id, event_id) VALUES (?, ?, ?, ?, ?)')
    insertChunk.run('t1', 'c1', '1', cmId1, 'e1')
    insertChunk.run('t2', 'c2', '1', CM_OTHER, 'e2')
  })

  // ── stats-pid 进程统计缓存 ──
  const statsLinked = write(join(cmSessionsDir, 'stats-pid-4242.json'), `{"schemaVersion":2,"session":"${cmId1}"}`)
  const statsUnlinked = write(join(cmSessionsDir, 'stats-pid-4343.json'), `{"schemaVersion":2,"session":"${CM_OTHER}"}`)

  // ── pi-acp 会话映射表 ──
  const unrelatedJsonl = write(join('unrelated', 'other-session.jsonl'), '{"type":"session","id":"other-session"}')
  const ghostJsonlPath = join(root, 'ghost-dangling.jsonl')
  const acpMap = write(
    join(acpDir, 'session-map.json'),
    `${JSON.stringify(
      {
        version: 1,
        sessions: {
          [SID_1]: { sessionId: SID_1, cwd: '/Users/mock/cm', sessionFile: jsonl1 },
          [SID_2]: { sessionId: SID_2, cwd: '/Users/mock/cm', sessionFile: jsonl2 },
          'other-session': { sessionId: 'other-session', cwd: '/tmp', sessionFile: unrelatedJsonl },
          'ghost-dangling': { sessionId: 'ghost-dangling', cwd: '/tmp', sessionFile: ghostJsonlPath }
        }
      },
      null,
      2
    )}\n`
  )

  return {
    projectDir, cmSessionsDir, cmContentDir, acpDir,
    jsonl1, jsonl2, nestedSessionDir, nestedJsonl,
    sessionsDb1, sessionsDb2, contentDb,
    statsLinked, statsUnlinked, acpMap, unrelatedJsonl
  }
}

beforeEach(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), 'pi_cm_')))
  scanner = new PiAgentScanner({ storagePath: root })
})

afterEach(() => {
  rmSync(root, { recursive: true, force: true })
  CleanPrefs.patch({ cleanFileHistorySnapshots: true, cleanEmptyProjectFolders: true })
})

afterAll(() => {
  if (originalHome === undefined) delete process.env['HOME']
  else process.env['HOME'] = originalHome
  rmSync(prefHome, { recursive: true, force: true })
})

describe('contextModeSessionIdFor · session_id 派生规则', () => {
  it('产出 16 位小写十六进制', () => {
    const id = contextModeSessionIdFor('/tmp/whatever/session.jsonl')
    expect(id).toHaveLength(16)
    expect(id).toBe(id.toLowerCase())
    expect(id).toMatch(/^[0-9a-f]{16}$/)
  })

  it('与 context-mode 的 sha256[:16] 规则一致（回归基线值）', () => {
    expect(
      contextModeSessionIdFor(
        '/tmp/cc-ghost/sessions/--Users-mock-cm--/2026-09-10T10-00-00-000Z_01a0d1cc-4a16-74c5-bfbe-b36a0224af90.jsonl'
      )
    ).toBe('bf05d5e4e506b232')
  })

  it('不同的会话文件推导出不同的索引 id', () => {
    const ids = new Set([
      contextModeSessionIdFor('/a/one.jsonl'),
      contextModeSessionIdFor('/a/two.jsonl'),
      contextModeSessionIdFor('/a/nested/session.jsonl')
    ])
    expect(ids.size).toBe(3)
  })
})

describe('jsonlPathsUnder · 子代理嵌套会话枚举', () => {
  it('递归找出所有 .jsonl，跳过隐藏项，忽略非 jsonl', () => {
    const base = dir('nested')
    write(join(base, 'top.jsonl'), '{}')
    write(join(base, 'notes.txt'), 'x')
    write(join(base, '.hidden.jsonl'), '{}')
    write(join(base, 'uuid', 'run-0', 'session.jsonl'), '{}')
    write(join(base, 'uuid', 'run-1', 'session.jsonl'), '{}')

    const found = jsonlPathsUnder(base)
    expect([...found].sort()).toEqual(
      [
        join(base, 'top.jsonl'),
        join(base, 'uuid', 'run-0', 'session.jsonl'),
        join(base, 'uuid', 'run-1', 'session.jsonl')
      ].sort()
    )
  })

  it('达到 limit 后停止累积', () => {
    const base = dir('limited')
    for (let i = 0; i < 5; i++) write(join(base, `s${i}.jsonl`), '{}')
    expect(jsonlPathsUnder(base, 2).size).toBe(2)
  })

  it('目录不存在时返回空集合', () => {
    expect(jsonlPathsUnder(join(root, 'no-such-dir')).size).toBe(0)
  })
})

describe('PiAgentScanner · context-mode 双层索引同步', () => {
  let ctx: Ctx
  let cmId1: string
  let cmId2: string
  let cmIdNested: string

  beforeEach(() => {
    ctx = buildContextModeFixture()
    cmId1 = contextModeSessionIdFor(ctx.jsonl1)
    cmId2 = contextModeSessionIdFor(ctx.jsonl2)
    cmIdNested = contextModeSessionIdFor(ctx.nestedJsonl)
  })

  it('scan() 检出 2 条会话', async () => {
    const items = await scanner.scan()
    expect(items).toHaveLength(2)
    expect(items.map((i) => i.sessionId).sort()).toEqual([SID_1, SID_2].sort())
  })

  it('删单条会话：文件 + 子代理嵌套目录消失，索引行被清，无关行保留', async () => {
    const items = await scanner.scan()
    const item1 = items.find((i) => i.sessionId === SID_1)
    const item2 = items.find((i) => i.sessionId === SID_2)
    expect(item1).toBeDefined()
    expect(item2).toBeDefined()

    const freed = await scanner.delete([item1!])
    expect(freed).toBe(item1?.sizeInBytes)

    // 物理文件
    expect(exists(ctx.jsonl1)).toBe(false)
    expect(exists(ctx.nestedSessionDir)).toBe(false)
    expect(exists(ctx.jsonl2)).toBe(true)

    // context-mode 当前 schema：4 张表的 sid1 行全清
    expect(countWhere(ctx.sessionsDb1, 'session_meta', 'session_id', cmId1)).toBe(0)
    expect(countWhere(ctx.sessionsDb1, 'session_events', 'session_id', cmId1)).toBe(0)
    expect(countWhere(ctx.sessionsDb1, 'session_resume', 'session_id', cmId1)).toBe(0)
    expect(countWhere(ctx.sessionsDb1, 'tool_calls', 'session_id', cmId1)).toBe(0)
    // 子代理嵌套会话的索引行也清了（它的 .jsonl 在会话子目录里，靠递归枚举拿到）
    expect(countWhere(ctx.sessionsDb1, 'session_meta', 'session_id', cmIdNested)).toBe(0)
    // 别的会话的索引行不动
    expect(countWhere(ctx.sessionsDb1, 'session_meta', 'session_id', CM_OTHER)).toBe(1)
    expect(countWhere(ctx.sessionsDb1, 'tool_calls', 'session_id', CM_OTHER)).toBe(1)
    // 库里还有别人的数据 → 库文件保留
    expect(exists(ctx.sessionsDb1)).toBe(true)

    // content/ 内容索引（fts5）
    expect(countWhere(ctx.contentDb, 'chunks', 'session_id', cmId1)).toBe(0)
    expect(countWhere(ctx.contentDb, 'chunks', 'session_id', CM_OTHER)).toBe(1)
    expect(scalarCount(ctx.contentDb, 'SELECT COUNT(*) AS c FROM sources')).toBe(1)

    // stats 缓存
    expect(exists(ctx.statsLinked)).toBe(false)
    expect(exists(ctx.statsUnlinked)).toBe(true)

    // pi-acp 映射表
    const acpAfter = readFileSync(ctx.acpMap, 'utf8')
    expect(acpAfter).not.toContain(SID_1)
    expect(acpAfter).toContain(SID_2)
    expect(acpAfter).toContain('other-session')
    expect(acpAfter).not.toContain('ghost-dangling')
  })

  it('删最后一条会话：清空后的旧 schema 索引库连带删文件，仍有数据的库保留', async () => {
    // 旧 schema 库在删之前确实带着 sid2 的行
    expect(countWhere(ctx.sessionsDb2, 'session_meta', 'session_id', cmId2)).toBe(1)

    const items = await scanner.scan()
    const item1 = items.find((i) => i.sessionId === SID_1)
    const item2 = items.find((i) => i.sessionId === SID_2)

    await scanner.delete([item1!])
    const freed2 = await scanner.delete([item2!])
    expect(freed2).toBe(item2?.sizeInBytes)

    // 旧 schema 库只有 sid2 的行 → 清空 → 库文件被删（连同 -wal/-shm）
    expect(exists(ctx.sessionsDb2)).toBe(false)
    expect(exists(`${ctx.sessionsDb2}-wal`)).toBe(false)
    expect(exists(`${ctx.sessionsDb2}-shm`)).toBe(false)
    // 共享库还留着别的项目的会话 → 不误删
    expect(exists(ctx.sessionsDb1)).toBe(true)
    expect(countWhere(ctx.sessionsDb1, 'session_meta', 'session_id', CM_OTHER)).toBe(1)

    const acpAfter = readFileSync(ctx.acpMap, 'utf8')
    expect(acpAfter).not.toContain(SID_2)
    expect(acpAfter).toContain('other-session')
    expect(acpAfter).not.toContain('ghost-dangling')
  })

  it('cleanAll：context-mode / pi-acp 全量清理，重扫为 0', async () => {    const allFreed = await scanner.cleanAll()
    expect(allFreed).toBeGreaterThan(0)

    // 整个 context-mode 被删掉重建 → 没有残留索引库与 stats 缓存
    expect(exists(ctx.sessionsDb1)).toBe(false)
    expect(exists(ctx.sessionsDb2)).toBe(false)
    expect(exists(ctx.contentDb)).toBe(false)
    expect(exists(ctx.statsLinked)).toBe(false)
    expect(exists(ctx.statsUnlinked)).toBe(false)
    // pi-acp 目录被重建为空 → session-map.json 没了
    expect(exists(ctx.acpMap)).toBe(false)

    await expect(scanner.scan()).resolves.toEqual([])
  })
})

describe('PiAgentScanner · 快照开关与索引同步的关系', () => {
  /**
   * 关掉快照开关时只删会话文件。删除路径仍按完整的 `associatedPaths` 计算 ——
   * context-mode 索引行属于「会话存在性」而不是快照，
   * 留着反而会让 Pi 界面列出空会话。
   *
   * 真实布局里 `associatedPaths` 装的是会话子目录本身，所以这里手工构造一条
   * `ConversationItem`，让「快照目录」直接出现在 `associatedPaths` 上。
   */
  it('cleanFileHistorySnapshots 关闭时：快照里的 .jsonl 不删，但它的 context-mode 索引行照样清', async () => {
    const projectDir = dir('agent', 'sessions', '--Users-mock-snapidx--')
    const sid = '01a0d1cc-4a16-74c5-bfbe-b36a0224af99'
    const base = `2026-09-12T12-00-00-000Z_${sid}`
    const jsonl = write(
      join(projectDir, `${base}.jsonl`),
      `{"type":"session","id":"${sid}","cwd":"/Users/mock/snapidx"}\n`
    )
    // 「快照」放在 tasks/ 下（不进 agent/sessions/），否则它会被
    // 「回收空项目目录」连带收掉 —— 那是另一条独立的逻辑，这里不混在一起测。
    const snapshotDir = dir('tasks', `${sid}-1`, 'checkpoints')
    const nestedJsonl = write(join(snapshotDir, 'session.jsonl'), `{"type":"session","id":"${sid}"}\n`)

    const cmSessionsDir = dir('context-mode', 'sessions')
    const cmIdNested = contextModeSessionIdFor(nestedJsonl)
    const cmIdMain = contextModeSessionIdFor(jsonl)
    // 混入一条无关会话的行：库不会被判空删掉，断言才有得查。
    const cmIdUnrelated = contextModeSessionIdFor(join(root, 'unrelated', 'other.jsonl'))
    const dbPath = join(cmSessionsDir, 'snapidx.db')
    withDb(dbPath, (db) => {
      db.exec('CREATE TABLE session_meta (session_id TEXT PRIMARY KEY, project_dir TEXT);')
      const insert = db.prepare('INSERT INTO session_meta (session_id, project_dir) VALUES (?, ?)')
      insert.run(cmIdNested, '/Users/mock/snapidx')
      insert.run(cmIdMain, '/Users/mock/snapidx')
      insert.run(cmIdUnrelated, '/Users/mock/other')
    })

    const item: ConversationItem = {
      id: 'snapidx-item',
      sessionId: sid,
      title: 'Pi 会话 01a0d1cc',
      category: 'piAgent',
      projectPath: '/Users/mock/snapidx',
      gitBranch: null,
      messageCount: 1,
      sizeInBytes: sizeOfPath(jsonl) + sizeOfPath(snapshotDir),
      updatedAt: '2026-09-12T12:00:00.000Z',
      isSelected: false,
      snippet: '项目: /Users/mock/snapidx',
      associatedPaths: [jsonl, snapshotDir]
    }

    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const freed = await scanner.delete([item])

    // 快照目录（及其里的 .jsonl）因开关而保留
    expect(exists(snapshotDir)).toBe(true)
    expect(exists(nestedJsonl)).toBe(true)
    // freedBytes 扣掉了被保留的快照
    expect(freed).toBe(item.sizeInBytes - sizeOfPath(snapshotDir))
    // 但索引行属于「会话存在性」，与快照无关 —— 照样清干净，不留幽灵会话
    expect(countWhere(dbPath, 'session_meta', 'session_id', cmIdNested)).toBe(0)
    expect(countWhere(dbPath, 'session_meta', 'session_id', cmIdMain)).toBe(0)
    expect(countWhere(dbPath, 'session_meta', 'session_id', cmIdUnrelated)).toBe(1)
  })
})

describe('pruneACPSessionMap · 映射表裁剪', () => {
  function makeMap(sessions: Record<string, unknown>): string {
    const path = join(root, 'session-map.json')
    write(path, `${JSON.stringify({ version: 1, sessions }, null, 2)}\n`)
    return path
  }

  it('没有 stale 条目时原样保留（不重写文件）', () => {
    const alive = write(join(root, 'alive.jsonl'), '{}')
    const map = makeMap({ k: { sessionId: 'k', sessionFile: alive } })
    const before = readFileSync(map, 'utf8')

    pruneACPSessionMap(map, new Set(['other']), new Set())
    expect(readFileSync(map, 'utf8')).toBe(before)
  })

  it('key 命中 / sessionId 命中 / sessionFile 不存在 —— 三种 stale 都剪掉', () => {
    const alive = write(join(root, 'alive.jsonl'), '{}')
    const dead = join(root, 'dead.jsonl')
    const map = makeMap({
      target: { sessionId: 'unrelated-id', sessionFile: alive },
      bySessionId: { sessionId: 'target', sessionFile: alive },
      dangling: { sessionId: 'y', sessionFile: dead },
      keep: { sessionId: 'keep', sessionFile: alive }
    })

    pruneACPSessionMap(map, new Set(['target']), new Set())

    const result = JSON.parse(readFileSync(map, 'utf8')) as { sessions: Record<string, unknown> }
    expect(Object.keys(result.sessions).sort()).toEqual(['keep'])
  })

  it('sessionFile 在 deletedPaths 里（文件可能因快照开关没被真删）也剪掉', () => {
    const kept = write(join(root, 'kept.jsonl'), '{}')
    const other = write(join(root, 'other.jsonl'), '{}')
    const map = makeMap({
      ghost: { sessionId: 'ghost', sessionFile: kept },
      keep: { sessionId: 'keep', sessionFile: other }
    })

    pruneACPSessionMap(map, new Set(), new Set([kept]))
    const result = JSON.parse(readFileSync(map, 'utf8')) as { sessions: Record<string, unknown> }
    expect(Object.keys(result.sessions).sort()).toEqual(['keep'])
  })

  it('剪空之后整个文件删除', () => {
    const alive = write(join(root, 'alive.jsonl'), '{}')
    const map = makeMap({ only: { sessionId: 'target', sessionFile: alive } })

    pruneACPSessionMap(map, new Set(['target']), new Set())
    expect(exists(map)).toBe(false)
  })

  it('文件缺失 / 结构不认识时静默返回', () => {
    expect(() => pruneACPSessionMap(join(root, 'nope.json'), new Set(['a']), new Set())).not.toThrow()
    const bad = write(join(root, 'bad.json'), '{ not json')
    expect(() => pruneACPSessionMap(bad, new Set(['a']), new Set())).not.toThrow()
    const noSessions = write(join(root, 'no-sessions.json'), '{"version":1}')
    expect(() => pruneACPSessionMap(noSessions, new Set(['a']), new Set())).not.toThrow()
  })
})
