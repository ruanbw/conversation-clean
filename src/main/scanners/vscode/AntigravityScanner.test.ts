import { DatabaseSync } from 'node:sqlite'
import { mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join, relative } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { CleanPrefs } from '@main/core/prefs'
import { openReadOnly } from '@main/core/vscdb'
import { AntigravityScanner } from './AntigravityScanner'

/**
 * AntigravityScanner 的自包含测试。
 *
 * 夹具全部现造：`fs.mkdtempSync` 一个临时目录，用 `node:sqlite` 手写一份 mock 的
 * `conversation_summaries.db`，不依赖仓库里任何其它测试文件。
 *
 * 覆盖：mock 夹具扫描结果（索引行 + brain 孤儿目录）/ 删除后文件消失 + freedBytes +
 * 索引行确实被物理删除 / 索引文件不存在时删除不失败 / `cleanFileHistorySnapshots`
 * 与 `cleanEmptyProjectFolders` 两个开关的相反分支 / 活跃会话保护 /
 * 未安装时返回 `[]` / 本机真实目录的只读扫描。
 */

const PREF_KEYS = ['cleanFileHistorySnapshots', 'cleanEmptyProjectFolders'] as const
type PrefKey = (typeof PREF_KEYS)[number]

const originalPrefs = CleanPrefs.all()
const originalActiveId = process.env['ANTIGRAVITY_CONVERSATION_ID']
const created: string[] = []

afterEach(() => {
  CleanPrefs.patch(originalPrefs)
  if (originalActiveId === undefined) delete process.env['ANTIGRAVITY_CONVERSATION_ID']
  else process.env['ANTIGRAVITY_CONVERSATION_ID'] = originalActiveId
  while (created.length > 0) {
    rmSync(created.pop() as string, { recursive: true, force: true })
  }
})

function setPref(key: PrefKey, value: boolean): void {
  CleanPrefs.patch({ [key]: value })
}

function makeTempDir(): string {
  const dir = realpathOrSelf(mkdtempSync(join(tmpdir(), 'antigravity-scanner-')))
  created.push(dir)
  return dir
}

function realpathOrSelf(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

function mkdirp(path: string): string {
  mkdirSync(path, { recursive: true })
  return path
}

function writeFile(path: string, content: string): string {
  mkdirSync(join(path, '..'), { recursive: true })
  writeFileSync(path, content, 'utf8')
  return path
}

function exists(path: string): boolean {
  try {
    statSync(path)
    return true
  } catch {
    return false
  }
}

// MARK: - mock conversation_summaries.db

interface SummaryRow {
  id: string
  title?: string
  preview?: string
  stepCount?: number
  lastModified?: string
  workspaceUris?: string
}

/** 造一份 `conversation_summaries.db`，表结构与 Swift 版测试里的一字不差。 */
function makeSummariesDb(dbPath: string, rows: SummaryRow[]): void {
  mkdirp(join(dbPath, '..'))
  const db = new DatabaseSync(dbPath)
  try {
    db.exec(`CREATE TABLE conversation_summaries (
      conversation_id TEXT PRIMARY KEY,
      title TEXT NOT NULL DEFAULT '',
      preview TEXT NOT NULL DEFAULT '',
      step_count INTEGER NOT NULL DEFAULT 0,
      last_modified_time DATETIME NOT NULL,
      workspace_uris TEXT NOT NULL DEFAULT ''
    );`)
    const stmt = db.prepare(
      'INSERT INTO conversation_summaries (conversation_id, title, preview, step_count, last_modified_time, workspace_uris) VALUES (?, ?, ?, ?, ?, ?);'
    )
    for (const row of rows) {
      stmt.run(
        row.id,
        row.title ?? '',
        row.preview ?? '',
        row.stepCount ?? 0,
        row.lastModified ?? '2026-09-26T10:00:00.000Z',
        row.workspaceUris ?? ''
      )
    }
  } finally {
    db.close()
  }
}

function countSummaryRows(dbPath: string): number {
  const db = openReadOnly(dbPath)
  if (db === null) return -1
  try {
    const row = db.prepare('SELECT COUNT(*) AS n FROM conversation_summaries;').get() as { n: number }
    return Number(row.n)
  } finally {
    db.close()
  }
}

function summaryIds(dbPath: string): string[] {
  const db = openReadOnly(dbPath)
  if (db === null) return []
  try {
    const rows = db
      .prepare('SELECT conversation_id FROM conversation_summaries ORDER BY conversation_id;')
      .all() as Array<{ conversation_id: string }>
    return rows.map((r) => r.conversation_id)
  } finally {
    db.close()
  }
}

// MARK: - 只读快照

/** 目录树的 `path:size:mtimeMs` 快照，用来证明 scan() 一个字节都没写。 */
function snapshotTree(root: string, limit = 5000): string[] {
  const out: string[] = []
  const walk = (dir: string): void => {
    if (out.length >= limit || !exists(dir)) return
    let entries: string[]
    try {
      entries = readdirSync(dir)
    } catch {
      return
    }
    for (const name of entries) {
      const child = join(dir, name)
      let stats
      try {
        stats = statSync(child)
      } catch {
        continue
      }
      // `-shm` / `-wal` 是 SQLite 的易变边车文件，由**正在运行的 IDE** 维护，
      // 不是 scan() 写的，比较它们只会得到假阳性。
      if (!name.endsWith('-shm') && !name.endsWith('-wal')) {
        out.push(`${relative(root, child)}:${stats.size}:${stats.mtimeMs}`)
      }
      if (stats.isDirectory()) walk(child)
      if (out.length >= limit) return
    }
  }
  walk(root)
  return out.sort()
}

// MARK: - 夹具

const SID1 = 'mock-antigravity-001'
const SID2 = 'mock-antigravity-002'
const SID_ORPHAN = 'mock-antigravity-orphan-003'

interface Fixture {
  root: string
  brainDir: string
  conversationsDir: string
  annotationsDir: string
  dbPath: string
  brain1: string
  conv1: string
  conv1Wal: string
  conv1Shm: string
  annot1: string
  brain2: string
  conv2: string
  brainOrphan: string
}

function makeFixture(): Fixture {
  const root = makeTempDir()
  const brainDir = mkdirp(join(root, 'brain'))
  const conversationsDir = mkdirp(join(root, 'conversations'))
  const annotationsDir = mkdirp(join(root, 'annotations'))
  const dbPath = join(root, 'conversation_summaries.db')

  const brain1 = mkdirp(join(brainDir, SID1))
  writeFile(join(brain1, 'artifact.txt'), 'brain artifact s1')
  const conv1 = writeFile(join(conversationsDir, `${SID1}.db`), 'mock sqlite s1 db')
  const conv1Wal = writeFile(join(conversationsDir, `${SID1}.db-wal`), 'mock sqlite s1 wal')
  const conv1Shm = writeFile(join(conversationsDir, `${SID1}.db-shm`), 'mock sqlite s1 shm')
  const annot1 = writeFile(join(annotationsDir, `${SID1}.pbtxt`), 'annotations: { id: 1 }')

  const brain2 = mkdirp(join(brainDir, SID2))
  writeFile(join(brain2, 'notes.md'), 'brain artifact s2')
  const conv2 = writeFile(join(conversationsDir, `${SID2}.db`), 'mock sqlite s2 db')

  const brainOrphan = mkdirp(join(brainDir, SID_ORPHAN))
  writeFile(join(brainOrphan, 'data.bin'), 'orphan brain artifact')

  makeSummariesDb(dbPath, [
    {
      id: SID1,
      title: 'Antigravity Code Generation',
      preview: 'Implement unit tests in Swift',
      stepCount: 12,
      lastModified: '2026-09-26T10:00:00.000Z',
      workspaceUris: 'file:///Users/tester/antigravity-project'
    },
    {
      id: SID2,
      title: 'Refactor Database Service',
      preview: 'Sync VSCDB state keys',
      stepCount: 6,
      lastModified: '2026-09-26T11:00:00.000Z',
      workspaceUris: '["file:///Users/tester/vscdb-project"]'
    }
  ])

  return {
    root,
    brainDir,
    conversationsDir,
    annotationsDir,
    dbPath,
    brain1,
    conv1,
    conv1Wal,
    conv1Shm,
    annot1,
    brain2,
    conv2,
    brainOrphan
  }
}

// MARK: - 用例

describe('AntigravityScanner · mock 夹具', () => {
  it('索引行 + brain 孤儿目录合并，字段按 Swift 版的兜底顺序解析', async () => {
    const fx = makeFixture()
    const scanner = new AntigravityScanner({ storagePath: fx.root })

    expect(scanner.category).toBe('antigravity')
    expect(scanner.isInstalled).toBe(true)
    expect(scanner.storagePath).toBe(fx.root)

    const items = await scanner.scan()
    expect(items).toHaveLength(3)

    // 1. 索引行
    const one = items.find((i) => i.sessionId === SID1)
    expect(one).toBeDefined()
    expect(one?.title).toBe('Antigravity Code Generation')
    expect(one?.snippet).toBe('Implement unit tests in Swift')
    expect(one?.projectPath).toBe('/Users/tester/antigravity-project')
    expect(one?.messageCount).toBe(12)
    expect(one?.gitBranch).toBeNull()
    expect(one?.updatedAt).toBe(new Date('2026-09-26T10:00:00.000Z').toISOString())
    expect(one?.associatedPaths).toEqual([fx.brain1, fx.conv1, fx.conv1Wal, fx.conv1Shm, fx.annot1])
    const expectedSize =
      statSync(join(fx.brain1, 'artifact.txt')).size +
      statSync(fx.conv1).size +
      statSync(fx.conv1Wal).size +
      statSync(fx.conv1Shm).size +
      statSync(fx.annot1).size
    expect(one?.sizeInBytes).toBe(expectedSize)

    // 2. JSON 数组形态的 workspace_uris
    const two = items.find((i) => i.sessionId === SID2)
    expect(two?.title).toBe('Refactor Database Service')
    expect(two?.projectPath).toBe('/Users/tester/vscdb-project')
    expect(two?.messageCount).toBe(6)
    // 没有 -wal / -shm / pbtxt 就只挂上实际存在的两条
    expect(two?.associatedPaths).toEqual([fx.brain2, fx.conv2])

    // 3. brain 孤儿目录
    const orphan = items.find((i) => i.sessionId === SID_ORPHAN)
    expect(orphan?.title).toBe('孤立的 Antigravity 记忆工件 (mock-ant)')
    expect(orphan?.title).toContain('孤立的 Antigravity 记忆工件')
    expect(orphan?.snippet).toBe('未被会话数据库索引的本地残留工件')
    expect(orphan?.projectPath).toBeNull()
    expect(orphan?.messageCount).toBe(1)
    expect(orphan?.associatedPaths).toEqual([fx.brainOrphan])
    expect(orphan?.sizeInBytes).toBe(statSync(join(fx.brainOrphan, 'data.bin')).size)

    // 末尾按 updatedAt 倒序
    const timestamps = items.map((i) => i.updatedAt)
    expect(timestamps).toEqual([...timestamps].sort().reverse())
  })

  it('title / preview 都为空时回落到「Antigravity 对话 (<id 前 8 位>)」，step_count 至少按 1 算', async () => {
    const root = makeTempDir()
    const dbPath = join(root, 'conversation_summaries.db')
    makeSummariesDb(dbPath, [
      { id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', stepCount: 0, lastModified: '2026-09-26T10:00:00Z' }
    ])

    const scanner = new AntigravityScanner({ storagePath: root })
    const items = await scanner.scan()
    expect(items).toHaveLength(1)
    expect(items[0]?.title).toBe('Antigravity 对话 (aaaaaaaa)')
    expect(items[0]?.snippet).toBe('Antigravity 对话 (aaaaaaaa)')
    expect(items[0]?.messageCount).toBe(1)
    expect(items[0]?.projectPath).toBeNull()
    expect(items[0]?.associatedPaths).toEqual([])
    expect(items[0]?.sizeInBytes).toBe(0)
    // 不带小数秒的 ISO 串也能解析
    expect(items[0]?.updatedAt).toBe(new Date('2026-09-26T10:00:00Z').toISOString())
  })

  it('删会话：四类文件全消失、freedBytes 等于 sizeInBytes、索引行被物理删除', async () => {
    const fx = makeFixture()
    const scanner = new AntigravityScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    const one = items.find((i) => i.sessionId === SID1)!

    const freed = await scanner.delete([one])
    expect(freed).toBe(one.sizeInBytes)
    expect(exists(fx.brain1)).toBe(false)
    expect(exists(fx.conv1)).toBe(false)
    expect(exists(fx.conv1Wal)).toBe(false)
    expect(exists(fx.conv1Shm)).toBe(false)
    expect(exists(fx.annot1)).toBe(false)
    // 别的会话不动
    expect(exists(fx.brain2)).toBe(true)
    expect(exists(fx.conv2)).toBe(true)
    expect(exists(fx.brainOrphan)).toBe(true)
    // 索引：sid1 没了，sid2 还在
    expect(summaryIds(fx.dbPath)).toEqual([SID2])
  })

  it('删空窗口孤儿：索引里本来就没有，只删文件', async () => {
    const fx = makeFixture()
    const scanner = new AntigravityScanner({ storagePath: fx.root })
    const orphan = (await scanner.scan()).find((i) => i.sessionId === SID_ORPHAN)!

    const freed = await scanner.delete([orphan])
    expect(freed).toBe(orphan.sizeInBytes)
    expect(exists(fx.brainOrphan)).toBe(false)
    expect(countSummaryRows(fx.dbPath)).toBe(2)
  })

  it('没有 conversation_summaries.db 时 delete 依然成功，索引库不会被创建出来', async () => {
    const root = makeTempDir()
    const brain = mkdirp(join(root, 'brain', 'no-db-session'))
    writeFile(join(brain, 'a.txt'), 'x')

    const scanner = new AntigravityScanner({ storagePath: root })
    const items = await scanner.scan()
    expect(items).toHaveLength(1)
    expect(items[0]?.sessionId).toBe('no-db-session')

    const freed = await scanner.delete(items)
    expect(freed).toBe(items[0]?.sizeInBytes)
    expect(exists(brain)).toBe(false)
    expect(exists(join(root, 'conversation_summaries.db'))).toBe(false)
  })

  it('活跃会话受保护：文件与索引行都不动，freedBytes 为 0', async () => {
    const fx = makeFixture()
    process.env['ANTIGRAVITY_CONVERSATION_ID'] = SID1
    const scanner = new AntigravityScanner({ storagePath: fx.root })
    expect(scanner.activeConversationId).toBe(SID1)

    const one = (await scanner.scan()).find((i) => i.sessionId === SID1)!
    const freed = await scanner.delete([one])
    expect(freed).toBe(0)
    expect(exists(fx.brain1)).toBe(true)
    expect(exists(fx.conv1)).toBe(true)
    expect(exists(fx.annot1)).toBe(true)
    expect(summaryIds(fx.dbPath)).toEqual([SID1, SID2])
  })

  it('没设环境变量时活跃 id 回落到内置常量', () => {
    delete process.env['ANTIGRAVITY_CONVERSATION_ID']
    const scanner = new AntigravityScanner({ storagePath: makeTempDir() })
    expect(scanner.activeConversationId).toBe('d72aac4b-eb6f-4cdc-af17-bb25a2d18e19')
  })

  it('delete 空数组返回 0', async () => {
    const scanner = new AntigravityScanner({ storagePath: makeFixture().root })
    expect(await scanner.delete([])).toBe(0)
  })
})

describe('AntigravityScanner · 清理开关', () => {
  it('cleanFileHistorySnapshots 开：关联路径全删，freedBytes 全额', async () => {
    setPref('cleanFileHistorySnapshots', true)
    const fx = makeFixture()
    const scanner = new AntigravityScanner({ storagePath: fx.root })
    const one = (await scanner.scan()).find((i) => i.sessionId === SID1)!

    const freed = await scanner.delete([one])
    expect(freed).toBe(one.sizeInBytes)
    expect(exists(fx.brain1)).toBe(false)
    expect(exists(fx.conv1)).toBe(false)
  })

  it('cleanFileHistorySnapshots 关：associatedPaths 里没有快照段，行为与开关开时一致', async () => {
    setPref('cleanFileHistorySnapshots', false)
    const fx = makeFixture()
    const scanner = new AntigravityScanner({ storagePath: fx.root })
    const one = (await scanner.scan()).find((i) => i.sessionId === SID1)!

    // brain / conversations / annotations 都不是快照目录名 —— 开关对它没有影响
    const freed = await scanner.delete([one])
    expect(freed).toBe(one.sizeInBytes)
    expect(exists(fx.brain1)).toBe(false)
    expect(exists(fx.conv1)).toBe(false)
    expect(exists(fx.annot1)).toBe(false)
    expect(summaryIds(fx.dbPath)).toEqual([SID2])
  })

  it('cleanEmptyProjectFolders 关：会话照删，但空的 brain 目录不回收', async () => {
    setPref('cleanEmptyProjectFolders', false)
    const fx = makeFixture()
    const scanner = new AntigravityScanner({ storagePath: fx.root })
    const orphan = (await scanner.scan()).find((i) => i.sessionId === SID_ORPHAN)!

    await scanner.delete([orphan])
    // 孤儿会话本体是 brain 目录本身，删了就没了；空目录回收开关在这里是空转
    expect(exists(fx.brainOrphan)).toBe(false)
    expect(exists(fx.brainDir)).toBe(true)
  })

  it('cleanEmptyProjectFolders 开：会话照删，brain 目录结构保持不变', async () => {
    setPref('cleanEmptyProjectFolders', true)
    const fx = makeFixture()
    const scanner = new AntigravityScanner({ storagePath: fx.root })
    const orphan = (await scanner.scan()).find((i) => i.sessionId === SID_ORPHAN)!

    await scanner.delete([orphan])
    expect(exists(fx.brainOrphan)).toBe(false)
    // Antigravity 不用 workspaceStorage 布局，空目录回收对它没有额外作用
    expect(readdirSync(fx.brainDir).sort()).toEqual([SID1, SID2])
  })
})

describe('AntigravityScanner · cleanAll', () => {
  it('清空索引与全部工件，复扫为空', async () => {
    const fx = makeFixture()
    const scanner = new AntigravityScanner({ storagePath: fx.root })
    expect(await scanner.scan()).toHaveLength(3)

    const freed = await scanner.cleanAll()
    expect(freed).toBeGreaterThan(0)

    expect(await scanner.scan()).toEqual([])
    expect(countSummaryRows(fx.dbPath)).toBe(0)
    expect(exists(fx.brain1)).toBe(false)
    expect(exists(fx.brainOrphan)).toBe(false)
    expect(exists(fx.conv2)).toBe(false)
  })

  it('活跃会话被 cleanAll 保留', async () => {
    const fx = makeFixture()
    process.env['ANTIGRAVITY_CONVERSATION_ID'] = SID1
    const scanner = new AntigravityScanner({ storagePath: fx.root })

    const freed = await scanner.cleanAll()
    expect(freed).toBeGreaterThan(0)

    const items = await scanner.scan()
    expect(items.map((i) => i.sessionId)).toEqual([SID1])
    expect(exists(fx.brain1)).toBe(true)
    expect(exists(fx.conv1)).toBe(true)
    expect(summaryIds(fx.dbPath)).toEqual([SID1])
  })
})

describe('AntigravityScanner · 未安装', () => {
  it('数据根不存在：isInstalled=false，scan() 返回 []，delete([]) 返回 0', async () => {
    const missing = join(makeTempDir(), 'no-such-antigravity')
    const scanner = new AntigravityScanner({ storagePath: missing })
    expect(scanner.isInstalled).toBe(false)
    expect(scanner.storagePath).toBe(missing)
    expect(await scanner.scan()).toEqual([])
    expect(await scanner.delete([])).toBe(0)
    expect(await scanner.cleanAll()).toBe(0)
  })

  it('storagePath 默认指向 ~/.gemini/antigravity 并做 realpath 规范化', () => {
    delete process.env['ANTIGRAVITY_HOME']
    const scanner = new AntigravityScanner()
    const expected = (() => {
      try {
        return realpathSync(join(homedir(), '.gemini', 'antigravity'))
      } catch {
        return join(homedir(), '.gemini', 'antigravity')
      }
    })()
    expect(scanner.storagePath).toBe(expected)
    expect(scanner.isInstalled).toBe(exists(expected))
  })

  it('ANTIGRAVITY_HOME 环境变量覆盖默认目录', async () => {
    const previous = process.env['ANTIGRAVITY_HOME']
    const envRoot = makeTempDir()
    const dbPath = join(envRoot, 'conversation_summaries.db')
    makeSummariesDb(dbPath, [
      { id: 'env-conv-001', title: 'From env', lastModified: '2026-09-26T10:00:00.000Z' }
    ])
    process.env['ANTIGRAVITY_HOME'] = envRoot
    try {
      const scanner = new AntigravityScanner()
      expect(scanner.storagePath).toBe(envRoot)
      expect(scanner.isInstalled).toBe(true)
      const items = await scanner.scan()
      expect(items).toHaveLength(1)
      expect(items[0]?.sessionId).toBe('env-conv-001')
      expect(items[0]?.title).toBe('From env')
    } finally {
      if (previous === undefined) delete process.env['ANTIGRAVITY_HOME']
      else process.env['ANTIGRAVITY_HOME'] = previous
    }
  })
})

describe('AntigravityScanner · 本机真实目录（只读）', () => {
  it('存在才跑：scan() 不抛异常、返回项形状正确、删活跃会话被拒、且一个字节都没写', async () => {
    const scanner = new AntigravityScanner()
    expect(scanner.isInstalled).toBe(exists(scanner.storagePath))
    expect(scanner.activeConversationId.length).toBeGreaterThan(0)
    if (!scanner.isInstalled) {
      expect(scanner.storagePath).toContain('antigravity')
      return
    }

    const before = snapshotTree(scanner.storagePath)
    const items = await scanner.scan()
    expect(items.every((i) => i.category === 'antigravity')).toBe(true)
    expect(items.every((i) => i.sessionId.length > 0)).toBe(true)
    const timestamps = items.map((i) => i.updatedAt)
    expect(timestamps).toEqual([...timestamps].sort().reverse())
    for (const item of items) {
      for (const path of item.associatedPaths) expect(exists(path)).toBe(true)
    }

    // 活跃会话的删除必须被静默拒绝
    const active = items.find((i) => i.sessionId === scanner.activeConversationId)
    if (active !== undefined) {
      const freed = await scanner.delete([active])
      expect(freed).toBe(0)
      for (const path of active.associatedPaths) expect(exists(path)).toBe(true)
    }

    expect(snapshotTree(scanner.storagePath)).toEqual(before)
  })
})
