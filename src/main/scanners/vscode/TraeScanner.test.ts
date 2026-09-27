import { DatabaseSync } from 'node:sqlite'
import { mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, relative } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { CleanPrefs } from '@main/core/prefs'
import { openReadOnly, readItem } from '@main/core/vscdb'
import { TraeScanner } from './TraeScanner'

/**
 * TraeScanner 的自包含测试。
 *
 * 夹具全部现造：`fs.mkdtempSync` 一个临时目录，用 `node:sqlite` 手写一份 mock 的
 * `state.vscdb`（`ItemTable` + 8 个索引 key），不依赖仓库里任何其它测试文件。
 *
 * 覆盖：mock 夹具扫描结果 / 删除后文件消失 + freedBytes + 索引 key 同步 /
 * 索引文件不存在时删除不失败 / `cleanFileHistorySnapshots` 与 `cleanEmptyProjectFolders`
 * 两个开关的相反分支 / 未安装时返回 `[]` / 本机真实目录的只读扫描。
 */

const PREF_KEYS = ['cleanFileHistorySnapshots', 'cleanEmptyProjectFolders'] as const
type PrefKey = (typeof PREF_KEYS)[number]

const originalPrefs = CleanPrefs.all()
const created: string[] = []

afterEach(() => {
  CleanPrefs.patch(originalPrefs)
  while (created.length > 0) {
    rmSync(created.pop() as string, { recursive: true, force: true })
  }
})

function setPref(key: PrefKey, value: boolean): void {
  CleanPrefs.patch({ [key]: value })
}

function makeTempDir(): string {
  const dir = realpathOrSelf(mkdtempSync(join(tmpdir(), 'trae-scanner-')))
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

// MARK: - mock state.vscdb

/** 造一份 `state.vscdb`：`ItemTable` + VS Code 系的 8 个索引 key。 */
function makeStateDb(dbPath: string, sessionIds: string[]): void {
  mkdirp(join(dbPath, '..'))
  const db = new DatabaseSync(dbPath)
  try {
    db.exec('CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);')
    const encode = (sid: string): string => Buffer.from(sid, 'utf8').toString('base64')

    const indexEntries: Record<string, unknown> = {}
    for (const sid of sessionIds) {
      indexEntries[sid] = { sessionId: sid, title: `title-${sid}`, lastMessageDate: 1_789_000_000_000 }
    }
    const insert = 'INSERT INTO ItemTable (key, value) VALUES (?, ?);'
    const rows: Array<[string, string]> = [
      ['chat.ChatSessionStore.index', JSON.stringify({ version: 1, entries: indexEntries })],
      [
        'memento/interactive-session-view-copilot',
        JSON.stringify({
          sessionResource: { external: `vscode-chat-session://local/${encode(sessionIds[0] as string)}` }
        })
      ],
      ['interactive.sessions', JSON.stringify(sessionIds)],
      ['workbench.panel.chat', JSON.stringify({ activeSession: sessionIds[0] })],
      [
        'agentSessions.state.cache',
        JSON.stringify(
          sessionIds.map((sid) => ({ resource: `vscode-chat-session://local/${encode(sid)}`, read: 1 }))
        )
      ],
      [
        'agentSessions.model.cache',
        JSON.stringify(
          sessionIds.map((sid) => ({ resource: `vscode-chat-session://local/${encode(sid)}`, label: 'm' }))
        )
      ],
      [
        'composer.composerData',
        JSON.stringify({ allComposers: sessionIds.map((sid) => ({ composerId: sid, name: 'c' })) })
      ],
      [
        'workbench.panel.aichat.view.aichat.chatdata',
        JSON.stringify({ tabs: sessionIds.map((sid) => ({ id: sid, chatTitle: 't' })) })
      ]
    ]
    for (const [key, value] of rows) db.prepare(insert).run(key, value)
  } finally {
    db.close()
  }
}

function readStateDbItem(dbPath: string, key: string): string | null {
  const db = openReadOnly(dbPath)
  if (db === null) return null
  try {
    return readItem(db, key)
  } finally {
    db.close()
  }
}

function stateDbRowCount(dbPath: string): number {
  const db = openReadOnly(dbPath)
  if (db === null) return -1
  try {
    const row = db.prepare('SELECT COUNT(*) AS n FROM ItemTable;').get() as { n: number }
    return Number(row.n)
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

interface Fixture {
  root: string
  userDir: string
  wsHashDir: string
  chatSessionsDir: string
  editingDir: string
  session1File: string
  emptyWindowDir: string
  stateDbPath: string
  globalStateDbPath: string
}

function makeFixture(): Fixture {
  const root = makeTempDir()
  const userDir = mkdirp(join(root, 'User'))
  const wsHashDir = mkdirp(join(userDir, 'workspaceStorage', 'wsTrae123'))
  const chatSessionsDir = mkdirp(join(wsHashDir, 'chatSessions'))
  const editingDir = mkdirp(join(wsHashDir, 'chatEditingSessions', 'trae-chat-001'))
  writeFile(join(wsHashDir, 'workspace.json'), '{"folder":"file:///Users/tester/trae-project"}')
  writeFile(join(editingDir, 'state.json'), '{"timeline":{"checkpoints":[]}}')
  writeFile(join(editingDir, 'contents', 'a.ts'), 'export const a = 1\n')

  const session1File = writeFile(
    join(chatSessionsDir, 'trae-chat-001.jsonl'),
    [
      '{"kind":0,"v":{"version":3,"creationDate":1789500000000,"sessionId":"trae-chat-001","requests":[]}}',
      '{"kind":2,"k":["requests"],"v":[{"requestId":"r1","message":{"text":"Trae create microservice"}},{"requestId":"r2","message":{"text":"Next prompt"}}]}',
      ''
    ].join('\n')
  )

  const emptyWindowDir = mkdirp(join(userDir, 'globalStorage', 'emptyWindowChatSessions'))
  writeFile(
    join(emptyWindowDir, 'trae-empty-002.jsonl'),
    '{"kind":0,"v":{"version":3,"creationDate":1789600000000,"sessionId":"trae-empty-002","requests":[]}}\n'
  )

  const stateDbPath = join(wsHashDir, 'state.vscdb')
  makeStateDb(stateDbPath, ['trae-chat-001', 'trae-chat-999'])
  const globalStateDbPath = join(userDir, 'globalStorage', 'state.vscdb')
  makeStateDb(globalStateDbPath, ['trae-empty-002'])

  return {
    root,
    userDir,
    wsHashDir,
    chatSessionsDir,
    editingDir,
    session1File,
    emptyWindowDir,
    stateDbPath,
    globalStateDbPath
  }
}

function makeBareFixture(): { root: string; chatSessionsDir: string; sessionFile: string } {
  const root = makeTempDir()
  const chatSessionsDir = mkdirp(join(root, 'User', 'workspaceStorage', 'wsBare', 'chatSessions'))
  const sessionFile = writeFile(
    join(chatSessionsDir, 'bare-001.jsonl'),
    '{"kind":0,"v":{"creationDate":1789400000000,"sessionId":"bare-001","requests":[]}}\n'
  )
  return { root, chatSessionsDir, sessionFile }
}

// MARK: - 用例

describe('TraeScanner · mock 夹具', () => {
  it('工作区会话 + 空窗口会话合并，字段按 Swift 版的兜底顺序解析', async () => {
    const fx = makeFixture()
    const scanner = new TraeScanner({ storagePath: fx.root })

    expect(scanner.category).toBe('trae')
    expect(scanner.isInstalled).toBe(true)
    expect(scanner.storagePath).toBe(fx.root)

    const items = await scanner.scan()
    expect(items).toHaveLength(2)

    const session = items.find((i) => i.sessionId === 'trae-chat-001')
    expect(session).toBeDefined()
    expect(session?.title).toBe('Trae create microservice')
    expect(session?.snippet).toBe('Trae create microservice')
    expect(session?.messageCount).toBe(2)
    expect(session?.projectPath).toBe('/Users/tester/trae-project')
    expect(session?.gitBranch).toBeNull()
    expect(session?.category).toBe('trae')
    expect(session?.updatedAt).toBe(new Date(1_789_500_000_000).toISOString())
    expect(session?.associatedPaths).toEqual([fx.session1File, fx.editingDir])
    const editingBytes =
      statSync(join(fx.editingDir, 'state.json')).size +
      statSync(join(fx.editingDir, 'contents', 'a.ts')).size
    expect(session?.sizeInBytes).toBe(statSync(fx.session1File).size + editingBytes)

    const empty = items.find((i) => i.sessionId === 'trae-empty-002')
    expect(empty).toBeDefined()
    expect(empty?.title).toBe('Trae 对话')
    expect(empty?.snippet).toBe('Trae 对话')
    expect(empty?.projectPath).toBeNull()
    expect(empty?.messageCount).toBe(0)
    expect(empty?.updatedAt).toBe(new Date(1_789_600_000_000).toISOString())
    expect(empty?.associatedPaths).toEqual([join(fx.emptyWindowDir, 'trae-empty-002.jsonl')])

    // 末尾按 updatedAt 倒序
    const timestamps = items.map((i) => i.updatedAt)
    expect(timestamps).toEqual([...timestamps].sort().reverse())
  })

  it('kind:1 的 customTitle 作为标题兜底', async () => {
    const root = makeTempDir()
    const dir = mkdirp(join(root, 'User', 'workspaceStorage', 'wsT', 'chatSessions'))
    const file = writeFile(
      join(dir, 'titled.jsonl'),
      [
        '{"kind":0,"v":{"sessionId":"titled","requests":[]}}',
        '{"kind":1,"k":["customTitle"],"v":"  给模型起个名字  \\n第二行"}',
        ''
      ].join('\n')
    )

    const scanner = new TraeScanner({ storagePath: root })
    const items = await scanner.scan()
    expect(items).toHaveLength(1)
    expect(items[0]?.title).toBe('给模型起个名字')
    expect(items[0]?.snippet).toBe('给模型起个名字')
    expect(items[0]?.associatedPaths).toEqual([file])
  })

  it('没有 User/ 一层、数据直接摊在根上时也能扫到（新版布局）', async () => {
    const root = makeTempDir()
    const dir = mkdirp(join(root, 'workspaceStorage', 'wsFlat', 'chatSessions'))
    const file = writeFile(
      join(dir, 'flat-001.jsonl'),
      '{"kind":0,"v":{"sessionId":"flat-001","requests":[{"message":{"parts":[{"text":"flat layout"}]}}]}}\n'
    )

    const scanner = new TraeScanner({ storagePath: root })
    const items = await scanner.scan()
    expect(items).toHaveLength(1)
    expect(items[0]?.sessionId).toBe('flat-001')
    expect(items[0]?.title).toBe('flat layout')
    expect(items[0]?.associatedPaths).toEqual([file])
  })

  it('删会话：文件消失、freedBytes 等于 sizeInBytes、8 个索引 key 同步清干净', async () => {
    const fx = makeFixture()
    // 另一个 workspace 的索引：未被本条会话关联，应按「全部已删 sid」扫一遍而保持不变
    const otherWs = mkdirp(join(fx.userDir, 'workspaceStorage', 'wsOther'))
    const otherDb = join(otherWs, 'state.vscdb')
    makeStateDb(otherDb, ['other-003'])

    const scanner = new TraeScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    const session = items.find((i) => i.sessionId === 'trae-chat-001')!

    const freed = await scanner.delete([session])
    expect(freed).toBe(session.sizeInBytes)
    expect(exists(fx.session1File)).toBe(false)
    expect(exists(fx.editingDir)).toBe(false)
    // 另一条会话没被碰
    expect(exists(join(fx.emptyWindowDir, 'trae-empty-002.jsonl'))).toBe(true)

    // 1. chat.ChatSessionStore.index
    const index = JSON.parse(readStateDbItem(fx.stateDbPath, 'chat.ChatSessionStore.index') as string)
    expect(index.entries['trae-chat-001']).toBeUndefined()
    expect(index.entries['trae-chat-999']).toBeDefined()

    // 2. memento（整条删）
    expect(readStateDbItem(fx.stateDbPath, 'memento/interactive-session-view-copilot')).toBeNull()

    // 3. interactive.sessions
    const interactive = JSON.parse(readStateDbItem(fx.stateDbPath, 'interactive.sessions') as string)
    expect(interactive).toEqual(['trae-chat-999'])

    // 4. workbench.panel.chat
    expect(readStateDbItem(fx.stateDbPath, 'workbench.panel.chat')).toBeNull()

    // 5 / 6. agentSessions 两张缓存
    const encoded = Buffer.from('trae-chat-001', 'utf8').toString('base64')
    for (const key of ['agentSessions.state.cache', 'agentSessions.model.cache']) {
      const cache = JSON.parse(readStateDbItem(fx.stateDbPath, key) as string) as Array<{
        resource: string
      }>
      expect(cache.some((e) => e.resource.includes(encoded))).toBe(false)
      expect(cache).toHaveLength(1)
    }

    // 7. composer.composerData
    const composer = JSON.parse(readStateDbItem(fx.stateDbPath, 'composer.composerData') as string)
    expect(composer.allComposers.map((c: { composerId: string }) => c.composerId)).toEqual([
      'trae-chat-999'
    ])

    // 8. workbench.panel.aichat.view.aichat.chatdata
    const aichat = JSON.parse(
      readStateDbItem(fx.stateDbPath, 'workbench.panel.aichat.view.aichat.chatdata') as string
    )
    expect(aichat.tabs.map((t: { id: string }) => t.id)).toEqual(['trae-chat-999'])

    // 无关的库与 globalStorage 库：内容不涉及被删 sid，行数不变
    expect(stateDbRowCount(otherDb)).toBe(8)
    expect(stateDbRowCount(fx.globalStateDbPath)).toBe(8)
  })

  it('删除空窗口会话时同步 globalStorage/state.vscdb', async () => {
    const fx = makeFixture()
    const scanner = new TraeScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    const empty = items.find((i) => i.sessionId === 'trae-empty-002')!

    const freed = await scanner.delete([empty])
    expect(freed).toBe(empty.sizeInBytes)
    expect(exists(join(fx.emptyWindowDir, 'trae-empty-002.jsonl'))).toBe(false)
    // globalStorage 库里唯一那条就是它：索引 key 清空成 `entries:{}` 后仍然保留，
    // 其余 7 个 key 整条消失（与 Swift 版 `removeValue` + UPDATE 的行为一致）
    const index = JSON.parse(readStateDbItem(fx.globalStateDbPath, 'chat.ChatSessionStore.index') as string)
    expect(index.entries).toEqual({})
    expect(stateDbRowCount(fx.globalStateDbPath)).toBe(1)
    for (const key of [
      'memento/interactive-session-view-copilot',
      'interactive.sessions',
      'workbench.panel.chat',
      'agentSessions.state.cache',
      'agentSessions.model.cache',
      'composer.composerData',
      'workbench.panel.aichat.view.aichat.chatdata'
    ]) {
      expect(readStateDbItem(fx.globalStateDbPath, key)).toBeNull()
    }
    // 顺带按全部已删 sid 扫过工作区的库
    expect(stateDbRowCount(fx.stateDbPath)).toBe(8)
  })

  it('没有 state.vscdb 时 delete 依然成功，释放字节数不变', async () => {
    const fx = makeBareFixture()
    expect(exists(join(fx.root, 'User', 'workspaceStorage', 'wsBare', 'state.vscdb'))).toBe(false)

    const scanner = new TraeScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    expect(items).toHaveLength(1)

    const freed = await scanner.delete(items)
    expect(freed).toBe(items[0]?.sizeInBytes)
    expect(exists(fx.sessionFile)).toBe(false)
  })

  it('delete 空数组返回 0', async () => {
    const fx = makeFixture()
    const scanner = new TraeScanner({ storagePath: fx.root })
    expect(await scanner.delete([])).toBe(0)
  })
})

describe('TraeScanner · 清理开关', () => {
  it('cleanFileHistorySnapshots 开：chatEditingSessions 一并删除，freedBytes 全额', async () => {
    setPref('cleanFileHistorySnapshots', true)
    const fx = makeFixture()
    const scanner = new TraeScanner({ storagePath: fx.root })
    const session = (await scanner.scan()).find((i) => i.sessionId === 'trae-chat-001')!

    const freed = await scanner.delete([session])
    expect(freed).toBe(session.sizeInBytes)
    expect(exists(fx.editingDir)).toBe(false)
  })

  it('cleanFileHistorySnapshots 关：快照目录保留，freedBytes 扣掉它', async () => {
    setPref('cleanFileHistorySnapshots', false)
    const fx = makeFixture()
    const scanner = new TraeScanner({ storagePath: fx.root })
    const session = (await scanner.scan()).find((i) => i.sessionId === 'trae-chat-001')!
    const editingBytes =
      statSync(join(fx.editingDir, 'state.json')).size +
      statSync(join(fx.editingDir, 'contents', 'a.ts')).size

    const freed = await scanner.delete([session])
    expect(freed).toBe(session.sizeInBytes - editingBytes)
    expect(exists(fx.session1File)).toBe(false)
    expect(exists(fx.editingDir)).toBe(true)
    // 索引照样清 —— 索引行不属于快照
    const index = JSON.parse(readStateDbItem(fx.stateDbPath, 'chat.ChatSessionStore.index') as string)
    expect(index.entries['trae-chat-001']).toBeUndefined()
  })

  it('cleanEmptyProjectFolders 开：删完回收空的 chatSessions 目录', async () => {
    setPref('cleanEmptyProjectFolders', true)
    const fx = makeBareFixture()
    const scanner = new TraeScanner({ storagePath: fx.root })
    await scanner.delete(await scanner.scan())
    expect(exists(fx.chatSessionsDir)).toBe(false)
  })

  it('cleanEmptyProjectFolders 关：空目录一律保留', async () => {
    setPref('cleanEmptyProjectFolders', false)
    const fx = makeBareFixture()
    const scanner = new TraeScanner({ storagePath: fx.root })
    await scanner.delete(await scanner.scan())
    expect(exists(fx.chatSessionsDir)).toBe(true)
    expect(exists(fx.sessionFile)).toBe(false)
  })
})

describe('TraeScanner · cleanAll', () => {
  it('清空全部会话与索引、重建 emptyWindowChatSessions、顺带清 globalStorage 里的 trae/chat 缓存', async () => {
    const fx = makeFixture()
    // 放一个非会话的杂项，让 delete 不回收 emptyWindowChatSessions，cleanAll 的重建分支才走得到
    writeFile(join(fx.emptyWindowDir, 'notes.txt'), 'x'.repeat(20))
    // Trae 扩展自己的缓存目录：名字里带 trae
    const cacheDir = mkdirp(join(fx.userDir, 'globalStorage', 'trae.caches'))
    writeFile(join(cacheDir, 'blob.bin'), 'x'.repeat(50))
    // 不该被动：名字里既没有 trae 也没有 chat
    const keepDir = mkdirp(join(fx.userDir, 'globalStorage', 'other.extension'))
    writeFile(join(keepDir, 'keep.bin'), 'x'.repeat(30))

    const scanner = new TraeScanner({ storagePath: fx.root })
    expect(await scanner.scan()).not.toHaveLength(0)

    const freed = await scanner.cleanAll()
    expect(freed).toBeGreaterThan(0)

    expect(await scanner.scan()).toEqual([])
    expect(stateDbRowCount(fx.stateDbPath)).toBe(0)
    expect(stateDbRowCount(fx.globalStateDbPath)).toBe(0)
    // emptyWindowChatSessions 删完建回来
    expect(exists(fx.emptyWindowDir)).toBe(true)
    expect(readdirSync(fx.emptyWindowDir)).toEqual([])
    // trae 缓存目录被清空（删了又建回来），无关目录原样保留
    expect(exists(cacheDir)).toBe(true)
    expect(readdirSync(cacheDir)).toEqual([])
    expect(readdirSync(keepDir)).toEqual(['keep.bin'])
  })

  it('cleanFileHistorySnapshots 关：cleanAll 保留 chatEditingSessions 目录', async () => {
    setPref('cleanFileHistorySnapshots', false)
    const fx = makeFixture()
    const scanner = new TraeScanner({ storagePath: fx.root })
    await scanner.cleanAll()
    expect(exists(fx.editingDir)).toBe(true)
    expect(exists(fx.session1File)).toBe(false)
  })
})

describe('TraeScanner · 未安装', () => {
  it('数据根不存在：isInstalled=false，scan() 返回 []，delete([]) 返回 0', async () => {
    const missing = join(makeTempDir(), 'no-such-trae')
    const scanner = new TraeScanner({ storagePath: missing })
    expect(scanner.isInstalled).toBe(false)
    expect(scanner.storagePath).toBe(missing)
    expect(await scanner.scan()).toEqual([])
    expect(await scanner.delete([])).toBe(0)
    expect(await scanner.cleanAll()).toBe(0)
  })

  it('TRAE_HOME 环境变量覆盖默认目录', async () => {
    const previous = process.env['TRAE_HOME']
    const envRoot = makeTempDir()
    const chatDir = mkdirp(join(envRoot, 'User', 'workspaceStorage', 'wsEnv', 'chatSessions'))
    const file = writeFile(
      join(chatDir, 'env-001.jsonl'),
      '{"kind":0,"v":{"sessionId":"env-001","requests":[{"message":{"text":"from env"}}]}}\n'
    )
    process.env['TRAE_HOME'] = envRoot
    try {
      const scanner = new TraeScanner()
      expect(scanner.storagePath).toBe(envRoot)
      expect(scanner.isInstalled).toBe(true)
      const items = await scanner.scan()
      expect(items).toHaveLength(1)
      expect(items[0]?.sessionId).toBe('env-001')
      expect(items[0]?.associatedPaths).toEqual([file])
    } finally {
      if (previous === undefined) delete process.env['TRAE_HOME']
      else process.env['TRAE_HOME'] = previous
    }
  })
})

describe('TraeScanner · 本机真实目录（只读）', () => {
  it('存在才跑：scan() 不抛异常、返回项形状正确、且一个字节都没写', async () => {
    const scanner = new TraeScanner()
    expect(scanner.isInstalled).toBe(exists(scanner.storagePath))
    if (!scanner.isInstalled) {
      expect(scanner.storagePath).toContain('Trae')
      return
    }

    const before = snapshotTree(scanner.storagePath)
    const items = await scanner.scan()
    expect(items.every((i) => i.category === 'trae')).toBe(true)
    expect(items.every((i) => i.sessionId.length > 0)).toBe(true)
    const timestamps = items.map((i) => i.updatedAt)
    expect(timestamps).toEqual([...timestamps].sort().reverse())
    for (const item of items) {
      for (const path of item.associatedPaths) expect(exists(path)).toBe(true)
    }
    expect(snapshotTree(scanner.storagePath)).toEqual(before)
  })
})
