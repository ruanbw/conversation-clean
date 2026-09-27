import { DatabaseSync } from 'node:sqlite'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join, relative } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ConversationItem } from '@shared/types'
import { CleanPrefs, sizeOfPath } from '@main/core/scanner'
import { ZedScanner } from './ZedScanner'

/**
 * Zed 扫描器用例。
 *
 * 自包含：夹具全部现造在 `os.tmpdir()` 下（`mkdtempSync`），不依赖任何其它测试文件；
 * 只有最后一个只读用例会碰本机真实的 `~/Library/Application Support/Zed`（且只读）。
 */

interface ThreadFixture {
  id: string
  summary: string
  updatedAt: string
  data: string
  folderPaths: string
  createdAt: string
}

/** 与 Swift 测试 `testMockZedScanner` 逐条对齐的两条线程。 */
const THREADS: ThreadFixture[] = [
  {
    id: 'zed-th-001',
    summary: 'Build AST Parser in Rust',
    updatedAt: '2026-09-26T17:00:00Z',
    data: 'dummyblob',
    folderPaths: '["/Users/tester/ast-parser"]',
    createdAt: '2026-09-26T16:00:00Z'
  },
  {
    id: 'zed-th-002',
    summary: 'Optimize Metal rendering backend',
    updatedAt: '2026-09-26T17:30:00Z',
    data: 'dummyblob2',
    folderPaths: '["/Users/tester/metal-engine"]',
    createdAt: '2026-09-26T17:15:00Z'
  }
]

const CONV_BODY = {
  id: 'conv-001',
  title: 'Fix tree-sitter syntax highlighting',
  messages: [{}, {}]
}

let rawRoot = ''
let scanner: ZedScanner
/** realpath 规范化之后的数据根；断言里的路径都以它为准。 */
let root = ''
const extraRoots: string[] = []

function createThreadsDb(dbPath: string, rows: readonly ThreadFixture[]): void {
  const db = new DatabaseSync(dbPath)
  try {
    db.exec(`CREATE TABLE threads (
      id TEXT PRIMARY KEY,
      summary TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      data_type TEXT NOT NULL,
      data BLOB NOT NULL,
      parent_id TEXT,
      folder_paths TEXT,
      folder_paths_order TEXT,
      created_at TEXT
    );`)
    const insert = db.prepare(
      `INSERT INTO threads (id, summary, updated_at, data_type, data, folder_paths, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`
    )
    for (const row of rows) {
      insert.run(row.id, row.summary, row.updatedAt, 'text', row.data, row.folderPaths, row.createdAt)
    }
  } finally {
    db.close()
  }
}

function threadRowCount(dbPath: string, id: string): number {
  const db = new DatabaseSync(dbPath, { readOnly: true })
  try {
    const row = db.prepare('SELECT count(*) AS c FROM threads WHERE id = ?').get(id) as
      | { c: number }
      | undefined
    return row?.c ?? -1
  } finally {
    db.close()
  }
}

function writeJson(path: string, value: unknown): void {
  writeFileSync(path, JSON.stringify(value), 'utf8')
}

/** 造一个与 Swift 夹具等价的数据根：2 条 DB 线程 + 1 个会话存档 + 1 个挂起转储。 */
function buildFixture(base: string, rows: readonly ThreadFixture[] = THREADS): void {
  mkdirSync(join(base, 'threads'), { recursive: true })
  mkdirSync(join(base, 'conversations'), { recursive: true })
  mkdirSync(join(base, 'hang_traces'), { recursive: true })

  createThreadsDb(join(base, 'threads', 'threads.db'), rows)
  writeJson(join(base, 'conversations', 'conv-001.json'), CONV_BODY)
  writeJson(join(base, 'hang_traces', 'hang-2026-09-26_17-47-36.miniprof.json'), [
    { thread_name: 'main', timings: [] }
  ])
}

/** 额外再造一份完整夹具，供「两个开关各跑一次」的双分支用例使用。 */
function freshFixture(): { scanner: ZedScanner; root: string } {
  const base = mkdtempSync(join(tmpdir(), 'mock_zed_'))
  extraRoots.push(base)
  buildFixture(base)
  const created = new ZedScanner({ storagePath: base })
  return { scanner: created, root: created.storagePath }
}

function find(items: readonly ConversationItem[], sessionId: string): ConversationItem {
  const item = items.find((candidate) => candidate.sessionId === sessionId)
  expect(item, `应当能找到会话 ${sessionId}`).toBeDefined()
  return item as ConversationItem
}

/** 目录树快照；用于「只读」与「双分支行为一致」两类断言。 */
function treeSnapshot(dir: string, skip: (rel: string) => boolean): Map<string, string> {
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
      if (skip(rel)) continue
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

/** 正在运行的 Zed 会写 threads.db（VACUUM 也会动它），比对文件树时把它排除。 */
const skipThreadsDb = (rel: string): boolean =>
  rel === 'threads.db' || rel.endsWith('/threads.db') || /(^|\/)threads\.db-/.test(rel)

/** 只给删除用例用的条目构造（不依赖 makeItem，保持测试独立）。 */
function testItem(input: {
  sessionId: string
  sizeInBytes: number
  associatedPaths: string[]
}): ConversationItem {
  return {
    id: `${input.sessionId}-test`,
    sessionId: input.sessionId,
    title: 'test',
    category: 'zed',
    projectPath: null,
    gitBranch: null,
    messageCount: 1,
    sizeInBytes: input.sizeInBytes,
    updatedAt: new Date().toISOString(),
    isSelected: false,
    snippet: '',
    associatedPaths: input.associatedPaths
  }
}

beforeEach(() => {
  rawRoot = mkdtempSync(join(tmpdir(), 'mock_zed_'))
  buildFixture(rawRoot)
  scanner = new ZedScanner({ storagePath: rawRoot })
  root = scanner.storagePath
  CleanPrefs.patch({ cleanFileHistorySnapshots: true, cleanEmptyProjectFolders: true })
})

afterEach(() => {
  for (const dir of [rawRoot, ...extraRoots]) {
    rmSync(dir, { recursive: true, force: true })
  }
  extraRoots.length = 0
  // 还原成默认开关，别把偏好写坏给后面的测试文件。
  CleanPrefs.patch({ cleanFileHistorySnapshots: true, cleanEmptyProjectFolders: true })
})

describe('ZedScanner · storagePath', () => {
  it('ZED_HOME 优先于默认目录', () => {
    const previous = process.env.ZED_HOME
    process.env.ZED_HOME = rawRoot
    try {
      expect(new ZedScanner().storagePath).toBe(scanner.storagePath)
    } finally {
      if (previous === undefined) delete process.env.ZED_HOME
      else process.env.ZED_HOME = previous
    }
  })

  it('没有 ZED_HOME 时指向 ~/Library/Application Support/Zed', () => {
    const previous = process.env.ZED_HOME
    delete process.env.ZED_HOME
    try {
      expect(new ZedScanner().storagePath.endsWith('Library/Application Support/Zed')).toBe(true)
    } finally {
      if (previous !== undefined) process.env.ZED_HOME = previous
    }
  })

  it('未安装时 isInstalled=false 且 scan() 返回空数组', async () => {
    const missing = new ZedScanner({ storagePath: join(rawRoot, 'no-such-dir') })
    expect(missing.isInstalled).toBe(false)
    await expect(missing.scan()).resolves.toEqual([])
    await expect(missing.delete([])).resolves.toBe(0)
  })
})

describe('ZedScanner · 夹具扫描', () => {
  it('三类来源各出一条：2 线程 + 1 会话存档 + 1 组转储', async () => {
    const items = await scanner.scan()

    expect(items).toHaveLength(4)
    expect(items.every((item) => item.category === 'zed')).toBe(true)
    // updatedAt 倒序：两条 DB 线程的时间戳是固定的历史时间，必然排在刚生成的文件之后。
    expect(items.slice(2).map((item) => item.sessionId)).toEqual(['zed-th-002', 'zed-th-001'])
    expect(items.slice(0, 2).map((item) => item.sessionId).sort()).toEqual([
      'conv-001',
      'zed-hang-traces'
    ])
  })

  it('DB 线程：标题取 summary、项目路径取 folder_paths、体积按 length(data) 估算', async () => {
    const thread = find(await scanner.scan(), 'zed-th-001')

    expect(thread.title).toBe('Build AST Parser in Rust')
    expect(thread.snippet).toBe('Build AST Parser in Rust')
    expect(thread.projectPath).toBe('/Users/tester/ast-parser')
    expect(thread.gitBranch).toBeNull()
    expect(thread.sizeInBytes).toBe(Math.max('dummyblob'.length + 256, 512))
    expect(thread.messageCount).toBe(1)
    expect(thread.updatedAt).toBe('2026-09-26T17:00:00.000Z')
    expect(thread.associatedPaths).toEqual([
      'zed-thread:zed-th-001',
      join(root, 'threads', 'threads.db')
    ])
  })

  it('会话存档：标题取 title、messageCount 取 messages 长度', async () => {
    const conv = find(await scanner.scan(), 'conv-001')

    expect(conv.title).toBe('Fix tree-sitter syntax highlighting')
    expect(conv.messageCount).toBe(2)
    expect(conv.associatedPaths).toEqual([join(root, 'conversations', 'conv-001.json')])
    expect(conv.sizeInBytes).toBe(sizeOfPath(join(root, 'conversations', 'conv-001.json')))
  })

  it('挂起转储：整个 hang_traces/ 聚合成一条', async () => {
    const traces = find(await scanner.scan(), 'zed-hang-traces')
    const tracePath = join(root, 'hang_traces', 'hang-2026-09-26_17-47-36.miniprof.json')

    expect(traces.title).toContain('1 个文件')
    expect(traces.messageCount).toBe(1)
    expect(traces.sizeInBytes).toBe(sizeOfPath(tracePath))
    expect(traces.associatedPaths).toEqual([tracePath])
  })

  it('summary 为空时标题回落成「Zed 会话 + id」', async () => {
    writeJson(join(rawRoot, 'conversations', 'zed-empty.json'), { summary: '' })
    const item = find(await scanner.scan(), 'zed-empty')
    // 回退标题里的 sessionId 只取前 8 位（Swift 的 `id.prefix(8)`）。
    expect(item.title).toBe('Zed 会话 zed-empt')
    expect(item.snippet).toBe('Zed 会话存档')
    expect(item.messageCount).toBe(1)
  })

  it('DB 行会 trim summary，文件标题不会 —— 两处口径不同，保持照抄', async () => {
    const base = mkdtempSync(join(tmpdir(), 'mock_zed_'))
    extraRoots.push(base)
    buildFixture(base, [
      { ...THREADS[0], id: 'zed-th-003', summary: '   ' },
      { ...THREADS[1], id: 'zed-th-004', summary: '   ' }
    ])
    const blank = new ZedScanner({ storagePath: base })
    writeJson(join(base, 'conversations', 'blank.json'), { summary: '   ' })

    const items = await blank.scan()
    // threads.db 行：trim 后为空 → 「Zed AI 会话 + id 前 8 位」，摘要走默认文案。
    expect(find(items, 'zed-th-003').title).toBe('Zed AI 会话 zed-th-0')
    expect(find(items, 'zed-th-003').snippet).toBe('Zed 助手对话记录')
    // conversations/*.json：只判 isEmpty、不 trim → 空白原样进标题。
    expect(find(items, 'blank').title).toBe('   ')
  })

  it('threads/ 下的旧版 json 也能列成会话（summary 优先于 title，换行压成空格）', async () => {
    writeJson(join(rawRoot, 'threads', 'zed-th-777.json'), {
      title: 'ignored title',
      summary: '线程摘要\n换行'
    })
    const item = find(await scanner.scan(), 'zed-th-777')
    expect(item.title).toBe('线程摘要 换行')
    expect(item.snippet).toBe('线程摘要 换行')
    expect(item.associatedPaths).toEqual([join(root, 'threads', 'zed-th-777.json')])
  })

  it('坏 JSON / 目录缺失都只降级，不抛错', async () => {
    writeFileSync(join(rawRoot, 'conversations', 'broken.json'), '{ not json', 'utf8')
    rmSync(join(rawRoot, 'hang_traces'), { recursive: true, force: true })
    const items = await scanner.scan()
    expect(find(items, 'broken').title).toBe('Zed 会话 broken')
  })
})

describe('ZedScanner · 删除', () => {
  it('删除 DB 线程：物理文件一个没动，freedBytes 等于体积，索引行同步删掉', async () => {
    const dbPath = join(root, 'threads', 'threads.db')
    const thread = find(await scanner.scan(), 'zed-th-001')

    const freed = await scanner.delete([thread])

    expect(freed).toBe(thread.sizeInBytes)
    // 关键：threads.db 是所有线程共用的索引文件，绝不能被删掉。
    expect(existsSync(dbPath)).toBe(true)
    expect(threadRowCount(dbPath, 'zed-th-001')).toBe(0)
    expect(threadRowCount(dbPath, 'zed-th-002')).toBe(1)
  })

  it('删除物理文件：文件真的消失', async () => {
    const convPath = join(root, 'conversations', 'conv-001.json')
    const conv = find(await scanner.scan(), 'conv-001')

    const freed = await scanner.delete([conv])

    expect(freed).toBe(conv.sizeInBytes)
    expect(existsSync(convPath)).toBe(false)
  })

  it('与库内线程同名的纯文件会话：删完后索引行仍在（hasPhysicalFile 保护）', async () => {
    const dbPath = join(root, 'threads', 'threads.db')
    const filePath = join(root, 'conversations', 'zed-th-002.json')
    writeJson(filePath, { title: '同名存档' })

    const item = (await scanner.scan()).find((candidate) =>
      candidate.associatedPaths.includes(filePath)
    ) as ConversationItem
    expect(item.sessionId).toBe('zed-th-002')

    await scanner.delete([item])

    expect(existsSync(filePath)).toBe(false)
    expect(threadRowCount(dbPath, 'zed-th-002')).toBe(1)
  })

  it('cleanFileHistorySnapshots 开：快照路径一起删，freedBytes 全额记账', async () => {
    const snapshotDir = join(root, 'backups', 'zed-th-001')
    mkdirSync(snapshotDir, { recursive: true })
    writeFileSync(join(snapshotDir, 'v1.json'), 'x'.repeat(300), 'utf8')
    const convPath = join(root, 'conversations', 'conv-001.json')
    const item = testItem({
      sessionId: 'zed-th-001',
      sizeInBytes: 1000,
      associatedPaths: [convPath, snapshotDir]
    })

    const freed = await scanner.delete([item])

    expect(freed).toBe(1000)
    expect(existsSync(convPath)).toBe(false)
    expect(existsSync(snapshotDir)).toBe(false)
  })

  it('cleanFileHistorySnapshots 关：快照路径保留，freedBytes 扣掉它占的字节', async () => {
    const snapshotDir = join(root, 'backups', 'zed-th-001')
    mkdirSync(snapshotDir, { recursive: true })
    writeFileSync(join(snapshotDir, 'v1.json'), 'x'.repeat(300), 'utf8')
    const convPath = join(root, 'conversations', 'conv-001.json')
    const item = testItem({
      sessionId: 'zed-th-001',
      sizeInBytes: 1000,
      associatedPaths: [convPath, snapshotDir]
    })

    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const freed = await scanner.delete([item])

    expect(freed).toBe(1000 - sizeOfPath(snapshotDir))
    expect(existsSync(convPath)).toBe(false)
    expect(existsSync(snapshotDir)).toBe(true)
  })

  it('删除空列表返回 0', async () => {
    await expect(scanner.delete([])).resolves.toBe(0)
  })
})

describe('ZedScanner · cleanAll', () => {
  it('清空索引与目录后重扫为 0；conversations/ hang_traces/ 重建为空目录', async () => {
    const freed = await scanner.cleanAll()

    expect(freed).toBeGreaterThan(0)
    await expect(scanner.scan()).resolves.toEqual([])

    const dbPath = join(root, 'threads', 'threads.db')
    expect(existsSync(dbPath)).toBe(true) // 索引文件本身留着给 Zed 重用
    expect(threadRowCount(dbPath, 'zed-th-001')).toBe(0)
    expect(threadRowCount(dbPath, 'zed-th-002')).toBe(0)
    expect(statSync(join(root, 'conversations')).isDirectory()).toBe(true)
    expect(statSync(join(root, 'hang_traces')).isDirectory()).toBe(true)
  })

  it('cleanEmptyProjectFolders 开与关行为一致：Zed 从不回收空目录', async () => {
    const on = freshFixture()
    CleanPrefs.patch({ cleanEmptyProjectFolders: true })
    const freedOn = await on.scanner.cleanAll()
    const stateOn = treeSnapshot(on.root, skipThreadsDb)

    const off = freshFixture()
    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    const freedOff = await off.scanner.cleanAll()
    const stateOff = treeSnapshot(off.root, skipThreadsDb)

    expect(freedOff).toBe(freedOn)
    expect(stateOff).toEqual(stateOn)
    expect(stateOff.get('conversations')).toBe('dir')
    expect(stateOff.get('hang_traces')).toBe('dir')
  })

  it('cleanAll 把 threads/ 里的旧版 json 一并清掉，但保留 threads.db', async () => {
    const legacy = join(root, 'threads', 'zed-th-888.json')
    writeJson(legacy, { summary: 'legacy' })

    await scanner.cleanAll()

    expect(existsSync(legacy)).toBe(false)
    expect(existsSync(join(root, 'threads', 'threads.db'))).toBe(true)
  })
})

describe('ZedScanner · 本机真实目录（只读）', () => {
  it('存在时扫描不抛错，且一个文件都没动', async () => {
    const real = process.env.ZED_HOME ?? join(homedir(), 'Library', 'Application Support', 'Zed')
    if (!existsSync(real)) return

    const realScanner = new ZedScanner()
    expect(realScanner.isInstalled).toBe(true)
    expect(realScanner.storagePath.endsWith('Zed')).toBe(true)

    const before = treeSnapshot(realScanner.storagePath, skipThreadsDb)
    const items = await realScanner.scan()
    const after = treeSnapshot(realScanner.storagePath, skipThreadsDb)

    expect(Array.isArray(items)).toBe(true)
    expect(items.every((item) => item.category === 'zed')).toBe(true)
    expect(after).toEqual(before)
  })
})
