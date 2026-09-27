import { DatabaseSync } from 'node:sqlite'
import { mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, relative } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { CleanPrefs } from '@main/core/prefs'
import { openReadOnly, readItem } from '@main/core/vscdb'
import { WindsurfScanner } from './WindsurfScanner'

/**
 * WindsurfScanner 的自包含测试。
 *
 * 夹具全部现造：`fs.mkdtempSync` 一个临时目录，用 `node:sqlite` 手写一份 mock 的
 * `state.vscdb`（`ItemTable` + 9 个索引 key），不依赖仓库里任何其它测试文件。
 *
 * 覆盖：mock 夹具扫描结果 / 删除后文件消失 + freedBytes + 9 个索引 key 同步 /
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
  const dir = realpathOrSelf(mkdtempSync(join(tmpdir(), 'windsurf-scanner-')))
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

// MARK: - mock state.vscdb

/** 造一份 `state.vscdb`：`ItemTable` + VS Code 系的 8 个索引 key（9 个里 `composer.*` 也在内）。 */
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
      [
        'chat.ChatSessionStore.index',
        JSON.stringify({ version: 1, entries: indexEntries })
      ],
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
    if (out.length >= limit) return
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
  if (pathExistsForSnapshot(root)) walk(root)
  return out.sort()
}

function pathExistsForSnapshot(path: string): boolean {
  try {
    statSync(path)
    return true
  } catch {
    return false
  }
}

// MARK: - 夹具

interface Fixture {
  root: string
  userDir: string
  wsHashDir: string
  chatSessionsDir: string
  editingDir: string
  session1File: string
  codeiumDir: string
  stateDbPath: string
}

function makeFixture(): Fixture {
  const root = makeTempDir()
  const userDir = mkdirp(join(root, 'User'))
  const wsHashDir = mkdirp(join(userDir, 'workspaceStorage', 'wsWindsurf123'))
  const chatSessionsDir = mkdirp(join(wsHashDir, 'chatSessions'))
  const editingDir = mkdirp(join(wsHashDir, 'chatEditingSessions', 'windsurf-chat-001'))
  writeFile(join(wsHashDir, 'workspace.json'), '{"folder":"file:///Users/tester/windsurf-app"}')
  writeFile(join(editingDir, 'state.json'), '{"timeline":{"checkpoints":[]}}')
  writeFile(join(editingDir, 'contents', 'a.ts'), 'export const a = 1\n')

  const session1File = writeFile(
    join(chatSessionsDir, 'windsurf-chat-001.jsonl'),
    [
      '{"kind":0,"v":{"version":3,"creationDate":1789400000000,"sessionId":"windsurf-chat-001","requests":[]}}',
      '{"kind":2,"k":["requests"],"v":[{"requestId":"r1","message":{"text":"Generate Windsurf cascade rule"}}]}',
      ''
    ].join('\n')
  )

  const codeiumDir = mkdirp(join(root, '.codeium', 'windsurf', 'cascades'))
  writeFile(
    join(codeiumDir, 'cascade-session-002', 'meta.json'),
    '{"title":"Optimize React components with memo","cwd":"/Users/tester/react-frontend"}'
  )

  const stateDbPath = join(wsHashDir, 'state.vscdb')
  makeStateDb(stateDbPath, ['windsurf-chat-001', 'windsurf-chat-999'])

  return {
    root,
    userDir,
    wsHashDir,
    chatSessionsDir,
    editingDir,
    session1File,
    codeiumDir,
    stateDbPath
  }
}

function makeBareFixture(): { root: string; chatSessionsDir: string; sessionFile: string } {
  const root = makeTempDir()
  const chatSessionsDir = mkdirp(
    join(root, 'User', 'workspaceStorage', 'wsBare', 'chatSessions')
  )
  const sessionFile = writeFile(
    join(chatSessionsDir, 'bare-001.jsonl'),
    '{"kind":0,"v":{"creationDate":1789400000000,"sessionId":"bare-001","requests":[]}}\n'
  )
  // 建一个空的 Codeium 目录：没有它，扫描器会回落到真实的 `~/.codeium/windsurf`，
  // delete / cleanAll 的 Cascade 兜底就会去碰用户真的目录。
  mkdirp(join(root, '.codeium', 'windsurf', 'cascades'))
  return { root, chatSessionsDir, sessionFile }
}

// MARK: - 用例

describe('WindsurfScanner · mock 夹具', () => {
  it('三个来源合并成列表，字段按兜底顺序解析', async () => {
    const fx = makeFixture()
    const scanner = new WindsurfScanner({ storagePath: fx.root })

    expect(scanner.category).toBe('windsurf')
    expect(scanner.isInstalled).toBe(true)
    expect(scanner.storagePath).toBe(fx.root)

    const items = await scanner.scan()
    expect(items).toHaveLength(2)

    const session = items.find((i) => i.sessionId === 'windsurf-chat-001')
    expect(session).toBeDefined()
    expect(session?.title).toBe('Generate Windsurf cascade rule')
    expect(session?.snippet).toBe('Generate Windsurf cascade rule')
    expect(session?.projectPath).toBe('/Users/tester/windsurf-app')
    expect(session?.messageCount).toBe(1)
    expect(session?.gitBranch).toBeNull()
    expect(session?.category).toBe('windsurf')
    // 时间来自 creationDate，不是文件 mtime
    expect(session?.updatedAt).toBe(new Date(1_789_400_000_000).toISOString())
    // associatedPaths = 正文 + 快照目录，体积是两者之和
    expect(session?.associatedPaths).toEqual([fx.session1File, fx.editingDir])
    const editingBytes = statSync(join(fx.editingDir, 'state.json')).size +
      statSync(join(fx.editingDir, 'contents', 'a.ts')).size
    expect(session?.sizeInBytes).toBe(statSync(fx.session1File).size + editingBytes)

    const cascade = items.find((i) => i.sessionId === 'cascade-session-002')
    expect(cascade).toBeDefined()
    expect(cascade?.title).toBe('Optimize React components with memo')
    expect(cascade?.projectPath).toBe('/Users/tester/react-frontend')
    expect(cascade?.messageCount).toBe(1)
    expect(cascade?.snippet).toBe('Optimize React components with memo')
    expect(cascade?.associatedPaths).toEqual([join(fx.codeiumDir, 'cascade-session-002')])

    // 末尾按 updatedAt 倒序
    const timestamps = items.map((i) => i.updatedAt)
    expect(timestamps).toEqual([...timestamps].sort().reverse())
  })

  it('无请求无标题的会话回落到「Windsurf 对话」，sessionId 回落到文件名', async () => {
    const root = makeTempDir()
    const emptyDir = mkdirp(join(root, 'User', 'globalStorage', 'emptyWindowChatSessions'))
    const file = writeFile(join(emptyDir, 'only-filename.jsonl'), '{ not json\n')

    const scanner = new WindsurfScanner({ storagePath: root })
    const items = await scanner.scan()
    expect(items).toHaveLength(1)
    expect(items[0]?.sessionId).toBe('only-filename')
    expect(items[0]?.title).toBe('Windsurf 对话')
    expect(items[0]?.snippet).toBe('Windsurf 对话')
    expect(items[0]?.projectPath).toBeNull()
    expect(items[0]?.associatedPaths).toEqual([file])
    // 没有 creationDate：回落到文件 mtime
    expect(items[0]?.updatedAt).toBe(new Date(statSync(file).mtimeMs).toISOString())
  })

  it('删会话：文件消失、freedBytes 等于 sizeInBytes、9 个索引 key 同步清干净', async () => {
    const fx = makeFixture()
    // 第二个 workspace + globalStorage 的索引，用来验证「未被关联到的库也按全部 sid 扫一遍」
    const otherWs = mkdirp(join(fx.userDir, 'workspaceStorage', 'wsOther'))
    const otherDb = join(otherWs, 'state.vscdb')
    makeStateDb(otherDb, ['other-003'])
    const globalStorage = mkdirp(join(fx.userDir, 'globalStorage'))
    const globalDb = join(globalStorage, 'state.vscdb')
    makeStateDb(globalDb, ['empty-002'])

    const scanner = new WindsurfScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    const session = items.find((i) => i.sessionId === 'windsurf-chat-001') as
      | (typeof items)[number]
      | undefined
    expect(session).toBeDefined()

    const freed = await scanner.delete([session!])
    expect(freed).toBe(session?.sizeInBytes)
    expect(exists(fx.session1File)).toBe(false)
    expect(exists(fx.editingDir)).toBe(false)
    // 另一个 workspace 的会话没被碰
    expect(snapshotTree(fx.root).some((line) => line.includes('cascade-session-002'))).toBe(true)

    // 1. chat.ChatSessionStore.index
    const index = JSON.parse(readStateDbItem(fx.stateDbPath, 'chat.ChatSessionStore.index') as string)
    expect(index.entries['windsurf-chat-001']).toBeUndefined()
    expect(index.entries['windsurf-chat-999']).toBeDefined()

    // 2. memento（整条删）
    expect(readStateDbItem(fx.stateDbPath, 'memento/interactive-session-view-copilot')).toBeNull()

    // 3. interactive.sessions
    const interactive = JSON.parse(readStateDbItem(fx.stateDbPath, 'interactive.sessions') as string)
    expect(interactive).toEqual(['windsurf-chat-999'])

    // 4. workbench.panel.chat（引用了被删 sid，整条删）
    expect(readStateDbItem(fx.stateDbPath, 'workbench.panel.chat')).toBeNull()

    // 5 / 6. agentSessions 两张缓存
    const encoded = Buffer.from('windsurf-chat-001', 'utf8').toString('base64')
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
      'windsurf-chat-999'
    ])

    // 8. workbench.panel.aichat.view.aichat.chatdata
    const aichat = JSON.parse(
      readStateDbItem(fx.stateDbPath, 'workbench.panel.aichat.view.aichat.chatdata') as string
    )
    expect(aichat.tabs.map((t: { id: string }) => t.id)).toEqual(['windsurf-chat-999'])

    // 未被本条会话关联的另外两个库：只按已删 sid 扫，别的会话必须还在
    expect(stateDbRowCount(otherDb)).toBe(8)
    expect(stateDbRowCount(globalDb)).toBe(8)
  })

  it('delete 会兜底清掉标准 Cascade 存储位置（目录 + <sid>.json）', async () => {
    const root = makeTempDir()
    const cascades = mkdirp(join(root, '.codeium', 'windsurf', 'cascades'))
    writeFile(join(cascades, 'only-cascade', 'meta.json'), '{"title":"cascade only"}')

    const scanner = new WindsurfScanner({ storagePath: root })
    const items = await scanner.scan()
    expect(items).toHaveLength(1)
    expect(items[0]?.sessionId).toBe('only-cascade')

    // 扫描结束后再补出另外两种 Cascade 形态（否则会被当成第二条会话扫出来）
    const chatsDir = mkdirp(join(root, '.codeium', 'windsurf', 'chats', 'only-cascade'))
    writeFile(join(chatsDir, 'inner.json'), '{}')
    const cascadeDir = mkdirp(join(root, '.codeium', 'windsurf', 'cascade', 'only-cascade'))
    writeFile(join(cascadeDir, 'inner.json'), '{}')
    writeFile(join(root, '.codeium', 'windsurf', 'chats', 'only-cascade.json'), '{"title":"x"}')

    const freed = await scanner.delete(items)
    expect(freed).toBe(items[0]?.sizeInBytes)
    for (const path of [
      join(root, '.codeium', 'windsurf', 'cascades', 'only-cascade'),
      chatsDir,
      cascadeDir,
      join(root, '.codeium', 'windsurf', 'chats', 'only-cascade.json')
    ]) {
      expect(exists(path)).toBe(false)
    }
    expect(await scanner.scan()).toHaveLength(0)
  })

  it('没有 state.vscdb 时 delete 依然成功，释放字节数不变', async () => {
    const fx = makeBareFixture()
    expect(exists(join(fx.root, 'User', 'workspaceStorage', 'wsBare', 'state.vscdb'))).toBe(false)

    const scanner = new WindsurfScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    expect(items).toHaveLength(1)

    const freed = await scanner.delete(items)
    expect(freed).toBe(items[0]?.sizeInBytes)
    expect(exists(fx.sessionFile)).toBe(false)
  })

  it('delete 空数组返回 0', async () => {
    const fx = makeFixture()
    const scanner = new WindsurfScanner({ storagePath: fx.root })
    expect(await scanner.delete([])).toBe(0)
  })
})

describe('WindsurfScanner · 清理开关', () => {
  it('cleanFileHistorySnapshots 开：chatEditingSessions 一并删除，freedBytes 全额', async () => {
    setPref('cleanFileHistorySnapshots', true)
    const fx = makeFixture()
    const scanner = new WindsurfScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    const session = items.find((i) => i.sessionId === 'windsurf-chat-001')!

    const freed = await scanner.delete([session])
    expect(freed).toBe(session.sizeInBytes)
    expect(exists(fx.editingDir)).toBe(false)
  })

  it('cleanFileHistorySnapshots 关：快照目录保留，freedBytes 扣掉它', async () => {
    setPref('cleanFileHistorySnapshots', false)
    const fx = makeFixture()
    const scanner = new WindsurfScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    const session = items.find((i) => i.sessionId === 'windsurf-chat-001')!

    const editingBytes =
      statSync(join(fx.editingDir, 'state.json')).size +
      statSync(join(fx.editingDir, 'contents', 'a.ts')).size

    const freed = await scanner.delete([session])
    expect(freed).toBe(session.sizeInBytes - editingBytes)
    expect(exists(fx.session1File)).toBe(false)
    expect(exists(fx.editingDir)).toBe(true)
    // 索引照样清 —— 索引行不属于快照
    const index = JSON.parse(readStateDbItem(fx.stateDbPath, 'chat.ChatSessionStore.index') as string)
    expect(index.entries['windsurf-chat-001']).toBeUndefined()
  })

  it('cleanEmptyProjectFolders 开：删完回收空的 chatSessions 目录', async () => {
    setPref('cleanEmptyProjectFolders', true)
    const fx = makeBareFixture()
    const scanner = new WindsurfScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    await scanner.delete(items)
    expect(exists(fx.chatSessionsDir)).toBe(false)
    // workspace 目录本身还有 workspace.json 之外的东西吗？没有就该只剩它自己
    expect(exists(join(fx.root, 'User', 'workspaceStorage', 'wsBare'))).toBe(true)
  })

  it('cleanEmptyProjectFolders 关：空目录一律保留', async () => {
    setPref('cleanEmptyProjectFolders', false)
    const fx = makeBareFixture()
    const scanner = new WindsurfScanner({ storagePath: fx.root })
    const items = await scanner.scan()
    await scanner.delete(items)
    expect(exists(fx.chatSessionsDir)).toBe(true)
    expect(exists(fx.sessionFile)).toBe(false)
  })
})

describe('WindsurfScanner · cleanAll', () => {
  it('清空全部会话、清空全部索引 key、重建 Codeium 与 emptyWindow 目录，复扫为空', async () => {
    const fx = makeFixture()
    const emptyWindowDir = mkdirp(join(fx.userDir, 'globalStorage', 'emptyWindowChatSessions'))
    writeFile(
      join(emptyWindowDir, 'empty-002.jsonl'),
      '{"kind":0,"v":{"sessionId":"empty-002","customTitle":"Empty window chat"}}\n'
    )
    // 一个非 .jsonl 的杂项：让 delete 的「回收空父目录」不生效，
    // cleanAll 的「删完建回来」分支才走得到。
    writeFile(join(emptyWindowDir, 'notes.txt'), 'x'.repeat(20))
    const globalDb = join(emptyWindowDir, '..', 'state.vscdb')
    makeStateDb(globalDb, ['empty-002'])
    mkdirp(join(fx.root, '.codeium', 'windsurf', 'memories'))
    writeFile(join(fx.root, '.codeium', 'windsurf', 'memories', 'm.txt'), 'x'.repeat(100))

    const scanner = new WindsurfScanner({ storagePath: fx.root })
    expect(await scanner.scan()).not.toHaveLength(0)

    const freed = await scanner.cleanAll()
    expect(freed).toBeGreaterThan(0)

    expect(await scanner.scan()).toEqual([])
    // 索引全空
    expect(stateDbRowCount(fx.stateDbPath)).toBe(0)
    expect(stateDbRowCount(globalDb)).toBe(0)
    // emptyWindowChatSessions 与 Codeium 目录被删后重建（不能留缺口给 IDE）
    expect(exists(emptyWindowDir)).toBe(true)
    expect(readdirSync(emptyWindowDir)).toEqual([])
    for (const sub of ['cascades', 'chats', 'memories', 'cascade']) {
      const dir = join(fx.root, '.codeium', 'windsurf', sub)
      if (exists(dir)) expect(readdirSync(dir)).toEqual([])
    }
  })

  it('emptyWindowChatSessions 已被 delete 回收时，cleanAll 不再重建它', async () => {
    const fx = makeFixture()
    const emptyWindowDir = mkdirp(join(fx.userDir, 'globalStorage', 'emptyWindowChatSessions'))
    writeFile(
      join(emptyWindowDir, 'empty-002.jsonl'),
      '{"kind":0,"v":{"sessionId":"empty-002"}}\n'
    )

    const scanner = new WindsurfScanner({ storagePath: fx.root })
    await scanner.cleanAll()
    // delete 删完最后一条会话时顺手回收了空的 emptyWindowChatSessions
    expect(exists(emptyWindowDir)).toBe(false)
    expect(await scanner.scan()).toEqual([])
  })
})

describe('WindsurfScanner · 未安装', () => {
  it('数据根不存在：isInstalled=false，scan() 返回 []，delete([]) 返回 0', async () => {
    const missing = join(makeTempDir(), 'no-such-windsurf')
    const scanner = new WindsurfScanner({ storagePath: missing })
    expect(scanner.isInstalled).toBe(false)
    expect(scanner.storagePath).toBe(missing)
    expect(await scanner.scan()).toEqual([])
    expect(await scanner.delete([])).toBe(0)
    expect(await scanner.cleanAll()).toBe(0)
  })

  it('WINDSURF_HOME 环境变量覆盖默认目录，且优先于注入目录之外的默认值', async () => {
    const previous = process.env['WINDSURF_HOME']
    const envRoot = makeTempDir()
    const chatDir = mkdirp(join(envRoot, 'User', 'workspaceStorage', 'wsEnv', 'chatSessions'))
    const file = writeFile(
      join(chatDir, 'env-001.jsonl'),
      '{"kind":0,"v":{"sessionId":"env-001","requests":[{"message":{"text":"from env"}}]}}\n'
    )
    process.env['WINDSURF_HOME'] = envRoot
    try {
      const scanner = new WindsurfScanner()
      expect(scanner.storagePath).toBe(envRoot)
      expect(scanner.isInstalled).toBe(true)
      const items = await scanner.scan()
      expect(items).toHaveLength(1)
      expect(items[0]?.sessionId).toBe('env-001')
      expect(items[0]?.title).toBe('from env')
      expect(items[0]?.associatedPaths).toEqual([file])
    } finally {
      if (previous === undefined) delete process.env['WINDSURF_HOME']
      else process.env['WINDSURF_HOME'] = previous
    }
  })
})

describe('WindsurfScanner · 本机真实目录（只读）', () => {
  it('存在才跑：scan() 不抛异常、返回项形状正确、且一个字节都没写', async () => {
    const scanner = new WindsurfScanner()
    expect(scanner.isInstalled).toBe(exists(scanner.storagePath))
    if (!scanner.isInstalled) {
      // 没装 Windsurf：本用例无事可做，但 storagePath 仍要是默认目录
      expect(scanner.storagePath).toContain('Windsurf')
      return
    }

    const codeiumDir = join(process.env.HOME ?? '', '.codeium', 'windsurf')
    const before = snapshotTree(scanner.storagePath)

    const items = await scanner.scan()
    expect(items.every((i) => i.category === 'windsurf')).toBe(true)
    expect(items.every((i) => i.sessionId.length > 0)).toBe(true)
    expect(items.every((i) => i.title.length > 0)).toBe(true)
    const timestamps = items.map((i) => i.updatedAt)
    expect(timestamps).toEqual([...timestamps].sort().reverse())
    for (const item of items) {
      for (const path of item.associatedPaths) expect(exists(path)).toBe(true)
    }

    if (exists(codeiumDir)) expect(snapshotTree(codeiumDir)).toEqual(before)
    else expect(snapshotTree(scanner.storagePath)).toEqual(before)
  })
})

function exists(path: string): boolean {
  try {
    statSync(path)
    return true
  } catch {
    return false
  }
}
