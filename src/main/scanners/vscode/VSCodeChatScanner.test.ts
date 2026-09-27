import type { Dirent } from 'node:fs'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync
} from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { ConversationItem } from '@shared/types'
import { CleanPrefs } from '@main/core/prefs'
import { sizeOfPath } from '@main/core/fsutil'
import { readItem } from '@main/core/vscdb'
import { VSCodeChatScanner } from '@main/scanners/vscode/VSCodeChatScanner'

/**
 * `VSCodeChatScanner` 的自包含用例。
 *
 * 夹具全部在 `os.tmpdir()` 下现造，`state.vscdb` / `session-store.db`
 * 用 `node:sqlite` 现建，不依赖任何其它测试文件。
 */

/** 两条夹具会话的 id。与 `vscdb.test.ts` 的标准载荷刻意取同值，便于交叉对照。 */
const SID1 = 'vsc-sync-001'
const SID2 = 'vsc-sync-002'

const ROOT_TEMP_DIRS: string[] = []

/** 在 tmpdir 下造一个夹具根目录（`realpath` 抹掉 macOS 的 `/var` → `/private/var` 别名）。 */
function makeRoot(): string {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'mock_vscode_chat_')))
  ROOT_TEMP_DIRS.push(root)
  return root
}

function writeFile(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content, 'utf8')
}

function writeJsonlFixture(path: string, sessionId: string, creationDateMs: number, prompt: string): void {
  writeFile(
    path,
    [
      JSON.stringify({ kind: 0, v: { version: 3, creationDate: creationDateMs, sessionId, requests: [] } }),
      JSON.stringify({ kind: 2, k: ['requests'], v: [{ requestId: 'r1', message: { text: prompt } }] }),
      ''
    ].join('\n')
  )
}

/** 造一个带全部 9 类索引 key 的 `state.vscdb`。 */
function createStateVscDb(path: string): void {
  mkdirSync(dirname(path), { recursive: true })
  const db = new DatabaseSync(path)
  db.exec('CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);')
  const encoded1 = Buffer.from(SID1, 'utf8').toString('base64')
  const encoded2 = Buffer.from(SID2, 'utf8').toString('base64')
  const insert = db.prepare('INSERT INTO ItemTable (key, value) VALUES (?, ?);')
  const items: [string, string][] = [
    [
      'chat.ChatSessionStore.index',
      JSON.stringify({
        version: 1,
        entries: {
          [SID1]: { sessionId: SID1, title: 'First prompt', lastMessageDate: 1789000000000 },
          [SID2]: { sessionId: SID2, title: 'Second prompt', lastMessageDate: 1789100000000 }
        }
      })
    ],
    [
      'memento/interactive-session-view-copilot',
      JSON.stringify({ sessionResource: { external: `vscode-chat-session://local/${encoded1}` } })
    ],
    ['interactive.sessions', JSON.stringify([SID1, SID2])],
    ['workbench.panel.chat', JSON.stringify({ activeSession: SID1 })],
    [
      'agentSessions.state.cache',
      JSON.stringify([
        { resource: `vscode-chat-session://local/${encoded1}`, read: 1 },
        { resource: `vscode-chat-session://local/${encoded2}`, read: 1 }
      ])
    ],
    [
      'agentSessions.model.cache',
      JSON.stringify([
        { resource: `vscode-chat-session://local/${encoded1}`, label: 'm1' },
        { resource: `vscode-chat-session://local/${encoded2}`, label: 'm2' }
      ])
    ],
    [
      'composer.composerData',
      JSON.stringify({ allComposers: [{ composerId: SID1, name: 'c1' }, { composerId: SID2, name: 'c2' }] })
    ],
    [
      'workbench.panel.aichat.view.aichat.chatdata',
      JSON.stringify({ tabs: [{ id: SID1, chatTitle: 't1' }, { id: SID2, chatTitle: 't2' }] })
    ],
    // 与会话无关的 key：清理时必须原样保留
    ['workbench.activityBar', JSON.stringify({ 'workbench.panel.chat.view.copilot': true })]
  ]
  for (const [key, value] of items) insert.run(key, value)
  db.close()
}

/** 造一个带全部 6 张会话表的 Copilot `session-store.db`。 */
function createSessionStoreDb(path: string): void {
  mkdirSync(dirname(path), { recursive: true })
  const db = new DatabaseSync(path)
  db.exec('CREATE TABLE sessions (id TEXT PRIMARY KEY, summary TEXT);')
  db.exec('CREATE TABLE turns (id INTEGER PRIMARY KEY, session_id TEXT, user_message TEXT);')
  db.exec('CREATE TABLE checkpoints (id INTEGER PRIMARY KEY, session_id TEXT, data TEXT);')
  db.exec('CREATE TABLE session_files (id INTEGER PRIMARY KEY, session_id TEXT, uri TEXT);')
  db.exec('CREATE TABLE session_refs (id INTEGER PRIMARY KEY, session_id TEXT, ref TEXT);')
  db.exec('CREATE TABLE search_index (id INTEGER PRIMARY KEY, session_id TEXT, term TEXT);')
  for (const [sid, summary] of [
    [SID1, 'summary1'],
    [SID2, 'summary2']
  ]) {
    db.prepare('INSERT INTO sessions (id, summary) VALUES (?, ?);').run(sid, summary)
    db.prepare('INSERT INTO turns (session_id, user_message) VALUES (?, ?);').run(sid, 'msg')
    db.prepare('INSERT INTO checkpoints (session_id, data) VALUES (?, ?);').run(sid, 'cp')
    db.prepare('INSERT INTO session_files (session_id, uri) VALUES (?, ?);').run(sid, 'file:///a')
    db.prepare('INSERT INTO session_refs (session_id, ref) VALUES (?, ?);').run(sid, 'ref')
    db.prepare('INSERT INTO search_index (session_id, term) VALUES (?, ?);').run(sid, 'term')
  }
  db.close()
}

/** 只读打开夹具库取一个 key 的原始值。 */
function readKey(dbPath: string, key: string): string | null {
  const db = new DatabaseSync(dbPath, { readOnly: true })
  try {
    return readItem(db, key)
  } finally {
    db.close()
  }
}

function countRows(dbPath: string, table: string, column: string, value: string): number {
  const db = new DatabaseSync(dbPath, { readOnly: true })
  try {
    const row = db.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE ${column} = ?`).get(value) as
      | { n: number }
      | undefined
    return row?.n ?? 0
  } finally {
    db.close()
  }
}

function totalRows(dbPath: string, table: string): number {
  const db = new DatabaseSync(dbPath, { readOnly: true })
  try {
    const row = db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get() as { n: number } | undefined
    return row?.n ?? 0
  } finally {
    db.close()
  }
}

function parseJson(text: string | null): Record<string, unknown> {
  expect(text).not.toBeNull()
  return JSON.parse(text as string) as Record<string, unknown>
}

function base64(sid: string): string {
  return Buffer.from(sid, 'utf8').toString('base64')
}

/** 完整的 Copilot 夹具：workspace 会话 + 空窗口会话 + 快照 + 扩展产物 + 两个索引库。 */
function buildFullFixture(): {
  root: string
  wsDir: string
  sessionFile: string
  editingDir: string
  transcriptFile: string
  debugDir: string
  emptyWindowFile: string
  stateDb: string
  sessionStoreDb: string
} {
  const root = makeRoot()
  const wsDir = join(root, 'workspaceStorage', 'mock-ws-hash-123')
  const sessionFile = join(wsDir, 'chatSessions', `${SID1}.jsonl`)
  const editingDir = join(wsDir, 'chatEditingSessions', SID1)
  const transcriptFile = join(wsDir, 'GitHub.copilot-chat', 'transcripts', `${SID1}.jsonl`)
  const debugDir = join(wsDir, 'GitHub.copilot-chat', 'debug-logs', SID1)
  const emptyWindowFile = join(root, 'globalStorage', 'emptyWindowChatSessions', `${SID2}.jsonl`)
  const stateDb = join(wsDir, 'state.vscdb')
  const sessionStoreDb = join(root, 'globalStorage', 'github.copilot-chat', 'session-store.db')

  writeFile(join(wsDir, 'workspace.json'), JSON.stringify({ folder: 'file:///Users/tester/synced-vsc-project' }))
  writeJsonlFixture(sessionFile, SID1, 1789000000000, 'First prompt in session 1')
  writeFile(join(editingDir, 'state.json'), 'x'.repeat(100))
  writeFile(join(editingDir, 'contents', 'a.ts'), 'y'.repeat(50))
  writeFile(transcriptFile, 'transcript body\n')
  writeFile(join(debugDir, 'debug.log'), 'log body\n')
  writeJsonlFixture(emptyWindowFile, SID2, 1789100000000, 'Second prompt in session 2')
  createStateVscDb(stateDb)
  createSessionStoreDb(sessionStoreDb)

  return {
    root,
    wsDir,
    sessionFile,
    editingDir,
    transcriptFile,
    debugDir,
    emptyWindowFile,
    stateDb,
    sessionStoreDb
  }
}

function findItem(items: ConversationItem[], sessionId: string): ConversationItem {
  const item = items.find((i) => i.sessionId === sessionId)
  expect(item, `会话 ${sessionId} 应被扫到`).toBeDefined()
  return item as ConversationItem
}

describe('VSCodeChatScanner', () => {
  let snapshots = true
  let emptyFolders = true

  beforeEach(() => {
    snapshots = true
    emptyFolders = true
    // 只拦两个清理开关，逻辑仍走真实的 CleanPrefs 实现
    vi.spyOn(CleanPrefs, 'cleanFileHistorySnapshots', 'get').mockImplementation(() => snapshots)
    vi.spyOn(CleanPrefs, 'cleanEmptyProjectFolders', 'get').mockImplementation(() => emptyFolders)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  afterAll(() => {
    for (const dir of ROOT_TEMP_DIRS) {
      try {
        rmSync(dir, { recursive: true, force: true })
      } catch {
        /* ignore */
      }
    }
  })

  describe('扫描', () => {
    it('扫出 workspaceStorage 与 emptyWindowChatSessions 两条会话，字段与关联路径齐全', async () => {
      const fixture = buildFullFixture()
      const scanner = new VSCodeChatScanner({ storagePath: fixture.root })

      expect(scanner.category).toBe('copilotChat')
      expect(scanner.isInstalled).toBe(true)
      // 注入目录的 realpath 规范化（macOS 上 tmpdir 是 /var → /private/var 的符号链接）
      expect(scanner.storagePath).toBe(fixture.root)

      const items = await scanner.scan()
      expect(items).toHaveLength(2)

      // updatedAt 倒序：SID2 的 creationDate 更晚
      expect(items.map((i) => i.sessionId)).toEqual([SID2, SID1])

      const item1 = findItem(items, SID1)
      expect(item1.title).toBe('First prompt in session 1')
      expect(item1.snippet).toBe('First prompt in session 1')
      expect(item1.projectPath).toBe('/Users/tester/synced-vsc-project')
      expect(item1.messageCount).toBe(1)
      expect(item1.updatedAt).toBe(new Date(1789000000000).toISOString())
      expect(item1.associatedPaths).toEqual([
        fixture.sessionFile,
        fixture.editingDir,
        fixture.transcriptFile,
        fixture.debugDir
      ])
      expect(item1.sizeInBytes).toBe(
        statSync(fixture.sessionFile).size +
          sizeOfPath(fixture.editingDir) +
          statSync(fixture.transcriptFile).size +
          sizeOfPath(fixture.debugDir)
      )

      const item2 = findItem(items, SID2)
      expect(item2.title).toBe('Second prompt in session 2')
      expect(item2.projectPath).toBeNull()
      expect(item2.associatedPaths).toEqual([fixture.emptyWindowFile])
    })

    it('会话为空 / 只有 kind:0 时落到「GitHub Copilot 对话」兜底标题', async () => {
      const root = makeRoot()
      const file = join(root, 'workspaceStorage', 'ws1', 'chatSessions', 'empty-session.jsonl')
      writeFile(
        file,
        JSON.stringify({ kind: 0, v: { sessionId: 'empty-session', creationDate: 1789000000000, requests: [] } }) + '\n'
      )
      const items = await new VSCodeChatScanner({ storagePath: root }).scan()
      expect(items).toHaveLength(1)
      expect(items[0]?.title).toBe('GitHub Copilot 对话')
      expect(items[0]?.messageCount).toBe(0)
      expect(items[0]?.snippet).toBe('GitHub Copilot 对话')
    })

    it('没有 workspace.json 时 projectPath 为 null，坏行直接跳过', async () => {
      const root = makeRoot()
      const file = join(root, 'workspaceStorage', 'ws1', 'chatSessions', 'broken.jsonl')
      writeFile(file, 'not json\n\n{"kind":0,"v":{"sessionId":"ok-sid"}}\n')
      const items = await new VSCodeChatScanner({ storagePath: root }).scan()
      expect(items).toHaveLength(1)
      expect(items[0]?.sessionId).toBe('ok-sid')
      expect(items[0]?.projectPath).toBeNull()
    })

    it('未安装时 scan() 返回空数组', async () => {
      const root = makeRoot()
      const scanner = new VSCodeChatScanner({ storagePath: join(root, 'never-created') })
      expect(scanner.isInstalled).toBe(false)
      expect(await scanner.scan()).toEqual([])
      expect(await scanner.delete([])).toBe(0)
      expect(await scanner.cleanAll()).toBe(0)
    })

    it('scan() 绝不落盘：文件与索引的 mtime / 体积都不变', async () => {
      const fixture = buildFullFixture()
      const paths = [fixture.sessionFile, fixture.emptyWindowFile, fixture.stateDb, fixture.sessionStoreDb]
      const before = paths.map((p) => {
        const st = statSync(p)
        return `${st.size}:${st.mtimeMs}`
      })
      await new VSCodeChatScanner({ storagePath: fixture.root }).scan()
      const after = paths.map((p) => {
        const st = statSync(p)
        return `${st.size}:${st.mtimeMs}`
      })
      expect(after).toEqual(before)
    })
  })

  describe('删除 + 索引同步', () => {
    it('删文件、算对 freedBytes，并把 state.vscdb 的 9 个索引 key 逐个清干净', async () => {
      const fixture = buildFullFixture()
      const scanner = new VSCodeChatScanner({ storagePath: fixture.root })
      const items = await scanner.scan()
      const item1 = findItem(items, SID1)

      const freed = await scanner.delete([item1])
      expect(freed).toBe(item1.sizeInBytes)

      expect(existsSync(fixture.sessionFile)).toBe(false)
      expect(existsSync(fixture.editingDir)).toBe(false)
      expect(existsSync(fixture.transcriptFile)).toBe(false)
      expect(existsSync(fixture.debugDir)).toBe(false)
      // 只删了一条，另一条必须还在
      expect(existsSync(fixture.emptyWindowFile)).toBe(true)

      // 1. chat.ChatSessionStore.index
      const index = parseJson(readKey(fixture.stateDb, 'chat.ChatSessionStore.index'))
      const entries = index['entries'] as Record<string, unknown>
      expect(entries[SID1]).toBeUndefined()
      expect(entries[SID2]).toBeDefined()

      // 2. memento/interactive-session% —— 值里含 sid 的整条删掉
      expect(readKey(fixture.stateDb, 'memento/interactive-session-view-copilot')).toBeNull()

      // 3. interactive.sessions
      const sessions = JSON.parse(readKey(fixture.stateDb, 'interactive.sessions') as string) as string[]
      expect(sessions).not.toContain(SID1)
      expect(sessions).toContain(SID2)

      // 4. workbench.panel.chat%
      expect(readKey(fixture.stateDb, 'workbench.panel.chat')).toBeNull()

      // 5. agentSessions.state.cache
      const stateCache = JSON.parse(readKey(fixture.stateDb, 'agentSessions.state.cache') as string) as {
        resource: string
      }[]
      expect(stateCache.some((e) => e.resource.includes(base64(SID1)))).toBe(false)
      expect(stateCache.some((e) => e.resource.includes(base64(SID2)))).toBe(true)

      // 6. agentSessions.model.cache
      const modelCache = JSON.parse(readKey(fixture.stateDb, 'agentSessions.model.cache') as string) as {
        resource: string
      }[]
      expect(modelCache.some((e) => e.resource.includes(base64(SID1)))).toBe(false)
      expect(modelCache.some((e) => e.resource.includes(base64(SID2)))).toBe(true)

      // 7. composer.composerData
      const composer = parseJson(readKey(fixture.stateDb, 'composer.composerData'))
      const composers = composer['allComposers'] as { composerId: string }[]
      expect(composers.some((c) => c.composerId === SID1)).toBe(false)
      expect(composers.some((c) => c.composerId === SID2)).toBe(true)

      // 8. workbench.panel.aichat.view.aichat.chatdata
      const aichat = parseJson(readKey(fixture.stateDb, 'workbench.panel.aichat.view.aichat.chatdata'))
      const tabs = aichat['tabs'] as { id: string }[]
      expect(tabs.some((t) => t.id === SID1)).toBe(false)
      expect(tabs.some((t) => t.id === SID2)).toBe(true)

      // 9. 与会话无关的 key 一律不动
      expect(readKey(fixture.stateDb, 'workbench.activityBar')).not.toBeNull()
    })

    it('Copilot session-store.db 的 6 张表都按 session_id 清干净', async () => {
      const fixture = buildFullFixture()
      const scanner = new VSCodeChatScanner({ storagePath: fixture.root })
      const item1 = findItem(await scanner.scan(), SID1)
      await scanner.delete([item1])

      expect(totalRows(fixture.sessionStoreDb, 'sessions')).toBe(1)
      for (const table of ['turns', 'checkpoints', 'session_files', 'session_refs', 'search_index']) {
        expect(totalRows(fixture.sessionStoreDb, table), table).toBe(1)
        expect(countRows(fixture.sessionStoreDb, table, 'session_id', SID1), `${table}/${SID1}`).toBe(0)
        expect(countRows(fixture.sessionStoreDb, table, 'session_id', SID2), `${table}/${SID2}`).toBe(1)
      }
      expect(countRows(fixture.sessionStoreDb, 'sessions', 'id', SID1)).toBe(0)
      expect(countRows(fixture.sessionStoreDb, 'sessions', 'id', SID2)).toBe(1)
    })

    it('emptyWindowChatSessions 的会话同步到 globalStorage/state.vscdb', async () => {
      const fixture = buildFullFixture()
      const globalDb = join(fixture.root, 'globalStorage', 'state.vscdb')
      const db = new DatabaseSync(globalDb)
      db.exec('CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);')
      db.prepare('INSERT INTO ItemTable (key, value) VALUES (?, ?)').run(
        'chat.ChatSessionStore.index',
        JSON.stringify({ version: 1, entries: { [SID1]: {}, [SID2]: {} } })
      )
      db.close()

      const scanner = new VSCodeChatScanner({ storagePath: fixture.root })
      const item2 = findItem(await scanner.scan(), SID2)
      await scanner.delete([item2])

      expect(existsSync(fixture.emptyWindowFile)).toBe(false)
      const index = parseJson(readKey(globalDb, 'chat.ChatSessionStore.index'))
      const entries = index['entries'] as Record<string, unknown>
      expect(entries[SID2]).toBeUndefined()
      expect(entries[SID1]).toBeDefined()
    })

    it('索引文件不存在时删除不能失败：文件照样删掉，返回值不受影响', async () => {
      const root = makeRoot()
      const file = join(root, 'workspaceStorage', 'ws1', 'chatSessions', `${SID1}.jsonl`)
      writeJsonlFixture(file, SID1, 1789000000000, 'no index around')
      const scanner = new VSCodeChatScanner({ storagePath: root })
      const item = findItem(await scanner.scan(), SID1)

      const freed = await scanner.delete([item])
      expect(freed).toBe(item.sizeInBytes)
      expect(existsSync(file)).toBe(false)
    })

    it('空的 items 列表返回 0', async () => {
      const fixture = buildFullFixture()
      expect(await new VSCodeChatScanner({ storagePath: fixture.root }).delete([])).toBe(0)
    })
  })

  describe('开关', () => {
    it('cleanFileHistorySnapshots 关掉时保留 chatEditingSessions 快照并扣掉它的体积', async () => {
      const fixture = buildFullFixture()
      const scanner = new VSCodeChatScanner({ storagePath: fixture.root })
      const item1 = findItem(await scanner.scan(), SID1)
      const editingSize = sizeOfPath(fixture.editingDir)

      snapshots = false
      const freed = await scanner.delete([item1])

      expect(freed).toBe(item1.sizeInBytes - editingSize)
      expect(existsSync(fixture.sessionFile)).toBe(false)
      expect(existsSync(fixture.editingDir)).toBe(true)
      // 索引行不受开关影响，照样清干净
      const index = parseJson(readKey(fixture.stateDb, 'chat.ChatSessionStore.index'))
      expect((index['entries'] as Record<string, unknown>)[SID1]).toBeUndefined()
    })

    it('cleanFileHistorySnapshots 开着时快照目录一起删', async () => {
      const fixture = buildFullFixture()
      const scanner = new VSCodeChatScanner({ storagePath: fixture.root })
      const item1 = findItem(await scanner.scan(), SID1)

      snapshots = true
      const freed = await scanner.delete([item1])
      expect(freed).toBe(item1.sizeInBytes)
      expect(existsSync(fixture.editingDir)).toBe(false)
    })

    it('cleanEmptyProjectFolders 关掉时残留的空 chatSessions 目录不回收', async () => {
      const root = makeRoot()
      const chatSessions = join(root, 'workspaceStorage', 'ws1', 'chatSessions')
      const scanner = new VSCodeChatScanner({ storagePath: root })

      writeJsonlFixture(join(chatSessions, `${SID1}.jsonl`), SID1, 1789000000000, 'first')
      emptyFolders = false
      await scanner.delete([findItem(await scanner.scan(), SID1)])
      expect(existsSync(chatSessions)).toBe(true)

      writeJsonlFixture(join(chatSessions, `${SID2}.jsonl`), SID2, 1789100000000, 'second')
      emptyFolders = true
      await scanner.delete([findItem(await scanner.scan(), SID2)])
      expect(existsSync(chatSessions)).toBe(false)
    })
  })

  describe('cleanAll', () => {
    it('清空后重扫为 0，chatSessions / 扩展目录 / 索引库全部处理', async () => {
      const fixture = buildFullFixture()
      const scanner = new VSCodeChatScanner({ storagePath: fixture.root })
      const before = await scanner.scan()
      expect(before).toHaveLength(2)

      const freed = await scanner.cleanAll()
      expect(freed).toBeGreaterThan(0)

      expect(await scanner.scan()).toEqual([])
      expect(existsSync(fixture.sessionFile)).toBe(false)
      expect(existsSync(fixture.emptyWindowFile)).toBe(false)
      expect(existsSync(join(fixture.wsDir, 'GitHub.copilot-chat'))).toBe(false)
      // emptyWindowChatSessions 删掉后会原样建回来
      expect(existsSync(join(fixture.root, 'globalStorage', 'emptyWindowChatSessions'))).toBe(true)
      // 索引里的会话条目全没了
      expect(readKey(fixture.stateDb, 'chat.ChatSessionStore.index')).toBeNull()
      expect(readKey(fixture.stateDb, 'composer.composerData')).toBeNull()
      // session-store.db：先清空索引，再整个删掉（它自己就是缓存）
      expect(existsSync(fixture.sessionStoreDb)).toBe(false)
      // state.vscdb 本身保留（只清索引）
      expect(existsSync(fixture.stateDb)).toBe(true)
    })

    it('连 vscode-sessions-* 与 toolEmbeddingsCache.bin 一并清掉', async () => {
      const root = makeRoot()
      const copilotGlobal = join(root, 'globalStorage', 'GitHub.copilot-chat')
      writeFile(join(copilotGlobal, 'vscode-sessions-abc123', 'a.bin'), 'x'.repeat(64))
      writeFile(join(copilotGlobal, 'copilot-cli-images', 'b.png'), 'y'.repeat(32))
      writeFile(join(copilotGlobal, 'toolEmbeddingsCache.bin'), 'z'.repeat(16))
      writeFile(join(copilotGlobal, 'keep-me.txt'), 'w'.repeat(8))

      const freed = await new VSCodeChatScanner({ storagePath: root }).cleanAll()
      expect(freed).toBeGreaterThan(0)
      expect(existsSync(join(copilotGlobal, 'vscode-sessions-abc123'))).toBe(false)
      expect(existsSync(join(copilotGlobal, 'copilot-cli-images'))).toBe(false)
      expect(existsSync(join(copilotGlobal, 'toolEmbeddingsCache.bin'))).toBe(false)
      expect(existsSync(join(copilotGlobal, 'keep-me.txt'))).toBe(true)
    })
  })

  describe('本机真实目录（只读，存在才跑）', () => {
    const realRoot = join(homedir(), 'Library/Application Support/Code/User')
    const itReal = existsSync(realRoot) ? it : it.skip

    itReal('扫真实 VS Code 目录不抛异常，且不修改任何文件', async () => {
      const scanner = new VSCodeChatScanner()
      expect(scanner.isInstalled).toBe(true)
      expect(scanner.storagePath).toBe(realpathSync(realRoot))

      const watched = collectSignature(realRoot)
      const items = await scanner.scan()
      expect(items.every((item) => item.category === 'copilotChat')).toBe(true)
      // 关联路径必须真的在盘上，不允许扫出幽灵条目
      for (const item of items.slice(0, 20)) {
        for (const path of item.associatedPaths) {
          expect(existsSync(path), path).toBe(true)
        }
      }
      expect(collectSignature(realRoot)).toEqual(watched)
    })
  })
})

/** 收集真实目录里扫描相关文件的 (路径, 体积, mtime) 签名，用来证明 scan() 没落盘。 */
function collectSignature(userDir: string): string[] {
  const signature: string[] = []
  const walk = (dir: string, depth: number): void => {
    if (depth > 3 || signature.length > 400) return
    let entries: Dirent[]
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      if (entry.name.startsWith('.')) continue
      const child = join(dir, entry.name)
      if (entry.isDirectory()) {
        walk(child, depth + 1)
        continue
      }
      if (!entry.name.endsWith('.jsonl') && entry.name !== 'state.vscdb') continue
      try {
        const st = statSync(child)
        signature.push(`${child}:${st.size}:${st.mtimeMs}`)
      } catch {
        /* 文件刚好被 IDE 换掉，跳过 */
      }
    }
  }
  walk(join(userDir, 'workspaceStorage'), 0)
  return signature
}
