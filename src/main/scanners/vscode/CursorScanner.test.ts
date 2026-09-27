import type { Dirent } from 'node:fs'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
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
import { CursorScanner } from '@main/scanners/vscode/CursorScanner'

/**
 * `CursorScanner` 的自包含用例。
 *
 * 夹具全部在 `os.tmpdir()` 下现造，`state.vscdb` 用 `node:sqlite` 现建，
 * 不依赖任何其它测试文件。
 */

const CHAT_SID = 'cursor-chat-001'
const EMPTY_WINDOW_SID = 'cursor-ew-001'
const COMPOSER_ID = 'composer-001'
const AICHAT_TAB_ID = 'tab-001'
const EXT_SID = 'ext-composer-001'
const DOT_SID = 'cursor-dot-001'

const TEMP_DIRS: string[] = []

/** 在 tmpdir 下造夹具根（`realpath` 抹掉 macOS 的 `/var` → `/private/var` 别名）。 */
function makeRoot(): string {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'mock_cursor_')))
  TEMP_DIRS.push(root)
  return root
}

function writeFile(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content, 'utf8')
}

function writeJsonlSession(
  path: string,
  sessionId: string,
  creationDateMs: number,
  prompt: string
): void {
  writeFile(
    path,
    [
      JSON.stringify({ kind: 0, v: { version: 3, creationDate: creationDateMs, sessionId, requests: [] } }),
      JSON.stringify({ kind: 2, k: ['requests'], v: [{ requestId: 'r1', message: { text: prompt } }] }),
      ''
    ].join('\n')
  )
}

interface StateDbFixture {
  composerIds: string[]
  tabIds: string[]
}

function createStateVscDb(path: string, fixture: StateDbFixture): void {
  mkdirSync(dirname(path), { recursive: true })
  const db = new DatabaseSync(path)
  db.exec('CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);')
  db.prepare('INSERT INTO ItemTable (key, value) VALUES (?, ?)').run(
    'composer.composerData',
    JSON.stringify({
      allComposers: fixture.composerIds.map((composerId, index) => ({
        composerId,
        name: `Implement Cursor Composer Feature ${index}`,
        createdAt: 1789300000000 + index,
        conversation: [{ role: 'user', text: 'Implement feature' }]
      }))
    })
  )
  db.prepare('INSERT INTO ItemTable (key, value) VALUES (?, ?)').run(
    'workbench.panel.aichat.view.aichat.chatdata',
    JSON.stringify({
      tabs: fixture.tabIds.map((id, index) => ({
        id,
        chatTitle: `Panel tab ${index}`,
        bubbles: [{ text: 'hi' }]
      }))
    })
  )
  db.prepare('INSERT INTO ItemTable (key, value) VALUES (?, ?)').run(
    'workbench.activityBar',
    JSON.stringify({ keep: true })
  )
  db.close()
}

function readKey(dbPath: string, key: string): string | null {
  const db = new DatabaseSync(dbPath, { readOnly: true })
  try {
    return readItem(db, key)
  } finally {
    db.close()
  }
}

function findItem(items: ConversationItem[], sessionId: string): ConversationItem {
  const item = items.find((i) => i.sessionId === sessionId)
  expect(item, `会话 ${sessionId} 应被扫到`).toBeDefined()
  return item as ConversationItem
}

interface FullFixture {
  root: string
  wsDir: string
  chatFile: string
  editingDir: string
  emptyWindowFile: string
  stateDb: string
  extFile: string
  extChatsFile: string
  dotFile: string
}

/** 三个来源齐全的夹具：workspace jsonl + state.vscdb + globalStorage/cursor.cursor + ~/.cursor。 */
function buildFullFixture(): FullFixture {
  const root = makeRoot()
  const userDir = join(root, 'User')
  const wsDir = join(userDir, 'workspaceStorage', 'wsCursor123')
  const chatFile = join(wsDir, 'chatSessions', `${CHAT_SID}.jsonl`)
  const editingDir = join(wsDir, 'chatEditingSessions', CHAT_SID)
  const emptyWindowFile = join(userDir, 'globalStorage', 'emptyWindowChatSessions', `${EMPTY_WINDOW_SID}.jsonl`)
  const stateDb = join(wsDir, 'state.vscdb')
  const extFile = join(userDir, 'globalStorage', 'cursor.cursor', 'composer', `${EXT_SID}.json`)
  const extChatsFile = join(userDir, 'globalStorage', 'cursor.cursor', 'chats', 'ext-chat-001.jsonl')
  const dotFile = join(root, '.cursor', 'chats', `${DOT_SID}.json`)

  writeFile(join(wsDir, 'workspace.json'), JSON.stringify({ folder: 'file:///Users/tester/cursor-project' }))
  writeJsonlSession(chatFile, CHAT_SID, 1789200000000, 'Cursor compose prompt 1')
  writeFile(join(editingDir, 'state.json'), 'x'.repeat(120))
  writeJsonlSession(emptyWindowFile, EMPTY_WINDOW_SID, 1789250000000, 'Empty window prompt')
  createStateVscDb(stateDb, { composerIds: [COMPOSER_ID], tabIds: [AICHAT_TAB_ID] })
  writeFile(extFile, JSON.stringify({ composerId: EXT_SID }))
  writeFile(extChatsFile, JSON.stringify({ id: 'ext-chat-001' }))
  writeFile(dotFile, JSON.stringify({ id: DOT_SID }))

  return { root, wsDir, chatFile, editingDir, emptyWindowFile, stateDb, extFile, extChatsFile, dotFile }
}

describe('CursorScanner', () => {
  let snapshots = true
  let emptyFolders = true

  beforeEach(() => {
    snapshots = true
    emptyFolders = true
    vi.spyOn(CleanPrefs, 'cleanFileHistorySnapshots', 'get').mockImplementation(() => snapshots)
    vi.spyOn(CleanPrefs, 'cleanEmptyProjectFolders', 'get').mockImplementation(() => emptyFolders)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  afterAll(() => {
    for (const dir of TEMP_DIRS) {
      try {
        rmSync(dir, { recursive: true, force: true })
      } catch {
        /* ignore */
      }
    }
  })

  describe('存储路径', () => {
    it('userDirectory 优先取 <root>/User，老布局下退回 <root>', () => {
      const modern = makeRoot()
      mkdirSync(join(modern, 'User'), { recursive: true })
      expect(new CursorScanner({ storagePath: modern }).userDirectoryPath).toBe(join(modern, 'User'))

      const legacy = makeRoot()
      mkdirSync(join(legacy, 'workspaceStorage'), { recursive: true })
      expect(new CursorScanner({ storagePath: legacy }).userDirectoryPath).toBe(legacy)

      const empty = makeRoot()
      expect(new CursorScanner({ storagePath: empty }).userDirectoryPath).toBe(join(empty, 'User'))
    })

    it('注入目录下带 .cursor 就用它，否则取真实 home（不扫用户的 ~/.cursor）', () => {
      const withDot = buildFullFixture()
      expect(new CursorScanner({ storagePath: withDot.root }).dotCursorPath).toBe(
        join(withDot.root, '.cursor')
      )

      const withoutDot = makeRoot()
      const fallback = new CursorScanner({ storagePath: withoutDot }).dotCursorPath
      expect(fallback).toBe(join(homedir(), '.cursor'))
      expect(fallback.startsWith(withoutDot)).toBe(false)
    })
  })

  describe('扫描：文件 + 索引双来源合并', () => {
    it('四个来源的会话全部扫到，字段与关联路径符合各来源的形状', async () => {
      const fixture = buildFullFixture()
      const scanner = new CursorScanner({ storagePath: fixture.root })
      expect(scanner.category).toBe('cursor')
      expect(scanner.isInstalled).toBe(true)
      expect(scanner.storagePath).toBe(fixture.root)

      const dbSize = sizeOfPath(fixture.stateDb)
      const items = await scanner.scan()
      expect(items).toHaveLength(7)

      // 1. chatSessions/*.jsonl
      const chat = findItem(items, CHAT_SID)
      expect(chat.title).toBe('Cursor compose prompt 1')
      expect(chat.projectPath).toBe('/Users/tester/cursor-project')
      expect(chat.messageCount).toBe(1)
      expect(chat.updatedAt).toBe(new Date(1789200000000).toISOString())
      expect(chat.associatedPaths).toEqual([fixture.chatFile, fixture.editingDir])
      expect(chat.sizeInBytes).toBe(statSync(fixture.chatFile).size + sizeOfPath(fixture.editingDir))

      // 2. state.vscdb 的 composer
      const composer = findItem(items, COMPOSER_ID)
      expect(composer.title).toBe('Implement Cursor Composer Feature 0')
      expect(composer.projectPath).toBe('/Users/tester/cursor-project')
      expect(composer.messageCount).toBe(1)
      expect(composer.associatedPaths).toEqual([fixture.stateDb])
      // 索引条目没有独立文件，体积按「库大小 ÷ 条目数」摊派
      expect(composer.sizeInBytes).toBe(Math.max(1, Math.floor(dbSize / 1)))
      expect(composer.updatedAt).toBe(new Date(1789300000000).toISOString())

      // 3. state.vscdb 的 aichat tab
      const tab = findItem(items, AICHAT_TAB_ID)
      expect(tab.title).toBe('Panel tab 0')
      expect(tab.messageCount).toBe(1)
      expect(tab.associatedPaths).toEqual([fixture.stateDb])
      // tab 的时间只能取库文件 mtime
      expect(tab.updatedAt).toBe(new Date(statSync(fixture.stateDb).mtimeMs).toISOString())

      // 4. emptyWindowChatSessions
      const emptyWindow = findItem(items, EMPTY_WINDOW_SID)
      expect(emptyWindow.projectPath).toBeNull()
      expect(emptyWindow.associatedPaths).toEqual([fixture.emptyWindowFile])

      // 5. globalStorage/cursor.cursor 的目录扫描
      const ext = findItem(items, EXT_SID)
      expect(ext.title).toBe(`Cursor 对话 ${EXT_SID.slice(0, 8)}`)
      expect(ext.messageCount).toBe(1)
      expect(ext.snippet).toBe('Cursor 扩展历史会话')
      expect(ext.associatedPaths).toEqual([fixture.extFile])
      expect(findItem(items, 'ext-chat-001').title).toBe('Cursor 对话 ext-chat')

      // 6. ~/.cursor/chats
      const dot = findItem(items, DOT_SID)
      expect(dot.title).toBe(`Cursor 会话 ${DOT_SID.slice(0, 8)}`)
      expect(dot.snippet).toBe('Cursor 用户目录会话')
      expect(dot.associatedPaths).toEqual([fixture.dotFile])

      // 全局按 updatedAt 倒序
      const times = items.map((i) => new Date(i.updatedAt).getTime())
      expect([...times].sort((a, b) => b - a)).toEqual(times)
    })

    it('同一个 id 同时存在于 jsonl 与索引时不合并（照抄 Swift 行为，界面上就是两条）', async () => {
      const root = makeRoot()
      const wsDir = join(root, 'User', 'workspaceStorage', 'ws1')
      writeJsonlSession(join(wsDir, 'chatSessions', 'dupe.jsonl'), 'dupe', 1789000000000, 'from file')
      createStateVscDb(join(wsDir, 'state.vscdb'), { composerIds: ['dupe'], tabIds: [] })

      const items = await new CursorScanner({ storagePath: root }).scan()
      const dupes = items.filter((i) => i.sessionId === 'dupe')
      expect(dupes).toHaveLength(2)
      expect(dupes.map((i) => i.title).sort()).toEqual(['Implement Cursor Composer Feature 0', 'from file'])
    })

    it('state.vscdb 是纯 JSON 夹具时走「当 JSON 读」的兜底分支', async () => {
      const root = makeRoot()
      const wsDir = join(root, 'User', 'workspaceStorage', 'ws1')
      writeFile(
        join(wsDir, 'state.vscdb'),
        JSON.stringify({
          allComposers: [
            { composerId: 'plain-composer', name: 'Plain JSON composer', createdAt: 1789400000000 }
          ]
        })
      )
      const items = await new CursorScanner({ storagePath: root }).scan()
      expect(items).toHaveLength(1)
      expect(items[0]?.sessionId).toBe('plain-composer')
      expect(items[0]?.title).toBe('Plain JSON composer')
      expect(items[0]?.projectPath).toBeNull()
    })

    it('unreadable / 缺 ItemTable 的 state.vscdb 不会让整个分类消失', async () => {
      const root = makeRoot()
      const wsDir = join(root, 'User', 'workspaceStorage', 'ws1')
      writeFile(join(wsDir, 'state.vscdb'), 'this is not a database at all')
      writeJsonlSession(join(wsDir, 'chatSessions', `${CHAT_SID}.jsonl`), CHAT_SID, 1789200000000, 'still here')

      const items = await new CursorScanner({ storagePath: root }).scan()
      expect(items).toHaveLength(1)
      expect(items[0]?.sessionId).toBe(CHAT_SID)
    })

    it('未安装时 scan() 返回空数组', async () => {
      const root = makeRoot()
      const scanner = new CursorScanner({ storagePath: join(root, 'nope') })
      expect(scanner.isInstalled).toBe(false)
      expect(await scanner.scan()).toEqual([])
      expect(await scanner.delete([])).toBe(0)
      expect(await scanner.cleanAll()).toBe(0)
    })

    it('scan() 绝不落盘：会话文件与 state.vscdb 的 mtime / 体积都不变', async () => {
      const fixture = buildFullFixture()
      const watched = [fixture.chatFile, fixture.emptyWindowFile, fixture.stateDb, fixture.dotFile]
      const before = watched.map((p) => `${statSync(p).size}:${statSync(p).mtimeMs}`)
      await new CursorScanner({ storagePath: fixture.root }).scan()
      expect(watched.map((p) => `${statSync(p).size}:${statSync(p).mtimeMs}`)).toEqual(before)
    })
  })

  describe('删除 + 索引同步', () => {
    it('删 jsonl 时算对 freedBytes，并同步该 workspace 的 state.vscdb', async () => {
      const fixture = buildFullFixture()
      const scanner = new CursorScanner({ storagePath: fixture.root })
      const chat = findItem(await scanner.scan(), CHAT_SID)

      const freed = await scanner.delete([chat])
      expect(freed).toBe(chat.sizeInBytes)
      expect(existsSync(fixture.chatFile)).toBe(false)
      expect(existsSync(fixture.editingDir)).toBe(false)
      // 别的来源不受影响
      expect(existsSync(fixture.emptyWindowFile)).toBe(true)
      expect(existsSync(fixture.dotFile)).toBe(true)

      // 索引行被裁掉（删的是 chatSessions 里的 sid）
      const composerData = JSON.parse(readKey(fixture.stateDb, 'composer.composerData') as string) as {
        allComposers: { composerId: string }[]
      }
      expect(composerData.allComposers.some((c) => c.composerId === CHAT_SID)).toBe(false)
      expect(composerData.allComposers.some((c) => c.composerId === COMPOSER_ID)).toBe(true)
      // 库文件本身不删
      expect(existsSync(fixture.stateDb)).toBe(true)
      // 无关的 key 不动
      expect(readKey(fixture.stateDb, 'workbench.activityBar')).not.toBeNull()
    })

    it('删索引条目时只清索引，绝不删掉 state.vscdb 本身', async () => {
      const fixture = buildFullFixture()
      const scanner = new CursorScanner({ storagePath: fixture.root })
      const composer = findItem(await scanner.scan(), COMPOSER_ID)
      const tab = findItem(await scanner.scan(), AICHAT_TAB_ID)

      await scanner.delete([composer, tab])
      expect(existsSync(fixture.stateDb)).toBe(true)
      expect(readKey(fixture.stateDb, 'composer.composerData')).toBeNull()
      expect(readKey(fixture.stateDb, 'workbench.panel.aichat.view.aichat.chatdata')).toBeNull()
    })

    it('emptyWindowChatSessions 的会话同步到 globalStorage/state.vscdb', async () => {
      const root = makeRoot()
      const userDir = join(root, 'User')
      const emptyWindowFile = join(userDir, 'globalStorage', 'emptyWindowChatSessions', `${CHAT_SID}.jsonl`)
      writeJsonlSession(emptyWindowFile, CHAT_SID, 1789200000000, 'empty window')
      const globalDb = join(userDir, 'globalStorage', 'state.vscdb')
      const db = new DatabaseSync(globalDb)
      db.exec('CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);')
      db.prepare('INSERT INTO ItemTable (key, value) VALUES (?, ?)').run(
        'composer.composerData',
        JSON.stringify({ allComposers: [{ composerId: CHAT_SID }, { composerId: 'keep-me' }] })
      )
      db.close()

      const scanner = new CursorScanner({ storagePath: root })
      await scanner.delete([findItem(await scanner.scan(), CHAT_SID)])

      expect(existsSync(emptyWindowFile)).toBe(false)
      const composerData = JSON.parse(readKey(globalDb, 'composer.composerData') as string) as {
        allComposers: { composerId: string }[]
      }
      expect(composerData.allComposers.map((c) => c.composerId)).toEqual(['keep-me'])
    })

    it('索引文件不存在时删除不能失败', async () => {
      const root = makeRoot()
      const file = join(root, 'User', 'workspaceStorage', 'ws1', 'chatSessions', `${CHAT_SID}.jsonl`)
      writeJsonlSession(file, CHAT_SID, 1789200000000, 'no index around')
      const scanner = new CursorScanner({ storagePath: root })
      const item = findItem(await scanner.scan(), CHAT_SID)

      const freed = await scanner.delete([item])
      expect(freed).toBe(item.sizeInBytes)
      expect(existsSync(file)).toBe(false)
    })

    it('纯 JSON 夹具的 state.vscdb：删光 composer 就整个删掉文件', async () => {
      const root = makeRoot()
      const stateDb = join(root, 'User', 'workspaceStorage', 'ws1', 'state.vscdb')
      writeFile(
        stateDb,
        JSON.stringify({ allComposers: [{ composerId: 'a' }, { composerId: 'b' }], keep: 'other keys' })
      )
      const scanner = new CursorScanner({ storagePath: root })

      await scanner.delete([findItem(await scanner.scan(), 'a')])
      const afterOne = JSON.parse(readFileText(stateDb)) as {
        allComposers: { composerId: string }[]
        keep: string
      }
      expect(afterOne.allComposers.map((c) => c.composerId)).toEqual(['b'])
      expect(afterOne.keep).toBe('other keys')

      await scanner.delete([findItem(await scanner.scan(), 'b')])
      expect(existsSync(stateDb)).toBe(false)
    })
  })

  describe('开关', () => {
    it('cleanFileHistorySnapshots 关掉时保留 chatEditingSessions 并扣掉体积', async () => {
      const root = makeRoot()
      const chatFile = join(root, 'User', 'workspaceStorage', 'ws1', 'chatSessions', `${CHAT_SID}.jsonl`)
      const editingDir = join(root, 'User', 'workspaceStorage', 'ws1', 'chatEditingSessions', CHAT_SID)
      writeJsonlSession(chatFile, CHAT_SID, 1789200000000, 'snapshot test')
      writeFile(join(editingDir, 'state.json'), 'x'.repeat(200))
      const scanner = new CursorScanner({ storagePath: root })
      const item = findItem(await scanner.scan(), CHAT_SID)

      snapshots = false
      const freed = await scanner.delete([item])
      expect(freed).toBe(item.sizeInBytes - sizeOfPath(editingDir))
      expect(existsSync(chatFile)).toBe(false)
      expect(existsSync(editingDir)).toBe(true)
    })

    it('cleanFileHistorySnapshots 开着时快照目录一起删', async () => {
      const root = makeRoot()
      const chatFile = join(root, 'User', 'workspaceStorage', 'ws1', 'chatSessions', `${CHAT_SID}.jsonl`)
      const editingDir = join(root, 'User', 'workspaceStorage', 'ws1', 'chatEditingSessions', CHAT_SID)
      writeJsonlSession(chatFile, CHAT_SID, 1789200000000, 'snapshot test')
      writeFile(join(editingDir, 'state.json'), 'x'.repeat(200))
      const scanner = new CursorScanner({ storagePath: root })
      const item = findItem(await scanner.scan(), CHAT_SID)

      snapshots = true
      expect(await scanner.delete([item])).toBe(item.sizeInBytes)
      expect(existsSync(editingDir)).toBe(false)
    })

    it('cleanEmptyProjectFolders 关掉时空 chatSessions 目录保留，打开时回收', async () => {
      const root = makeRoot()
      const chatSessions = join(root, 'User', 'workspaceStorage', 'ws1', 'chatSessions')
      const scanner = new CursorScanner({ storagePath: root })

      writeJsonlSession(join(chatSessions, 'a.jsonl'), 'a', 1789000000000, 'first')
      emptyFolders = false
      await scanner.delete([findItem(await scanner.scan(), 'a')])
      expect(existsSync(chatSessions)).toBe(true)

      writeJsonlSession(join(chatSessions, 'b.jsonl'), 'b', 1789100000000, 'second')
      emptyFolders = true
      await scanner.delete([findItem(await scanner.scan(), 'b')])
      expect(existsSync(chatSessions)).toBe(false)
    })
  })

  describe('clearStateDatabase（Swift 版同样未被调用的旁路）', () => {
    it('只清两个聊天索引 key，与聊天无关的 key 与库文件都保留', () => {
      const root = makeRoot()
      const stateDb = join(root, 'User', 'workspaceStorage', 'ws1', 'state.vscdb')
      createStateVscDb(stateDb, { composerIds: ['a'], tabIds: ['t'] })
      const before = statSync(stateDb).size

      new CursorScanner({ storagePath: root }).clearStateDatabase(stateDb)

      expect(existsSync(stateDb)).toBe(true)
      expect(readKey(stateDb, 'composer.composerData')).toBeNull()
      expect(readKey(stateDb, 'workbench.panel.aichat.view.aichat.chatdata')).toBeNull()
      expect(readKey(stateDb, 'workbench.activityBar')).not.toBeNull()
      // VACUUM 之后库文件应该更小或持平
      expect(statSync(stateDb).size).toBeLessThanOrEqual(before)
    })

    it('库文件打不开时退化为删掉整个文件', () => {
      const root = makeRoot()
      const stateDb = join(root, 'User', 'workspaceStorage', 'ws1', 'state.vscdb')
      writeFile(stateDb, 'not a database')
      new CursorScanner({ storagePath: root }).clearStateDatabase(stateDb)
      expect(existsSync(stateDb)).toBe(false)
    })
  })

  describe('cleanAll', () => {
    it('清空后重扫为 0，索引与三个目录全部处理', async () => {
      const fixture = buildFullFixture()
      const scanner = new CursorScanner({ storagePath: fixture.root })
      expect(await scanner.scan()).toHaveLength(7)

      const freed = await scanner.cleanAll()
      expect(freed).toBeGreaterThan(0)
      expect(await scanner.scan()).toEqual([])

      expect(existsSync(fixture.chatFile)).toBe(false)
      expect(existsSync(fixture.dotFile)).toBe(false)
      expect(existsSync(join(fixture.root, 'User', 'globalStorage', 'cursor.cursor'))).toBe(true)
      expect(existsSync(join(fixture.root, 'User', 'globalStorage', 'emptyWindowChatSessions'))).toBe(true)
      expect(existsSync(join(fixture.root, '.cursor', 'chats'))).toBe(true)
      // 索引清空，库文件保留
      expect(existsSync(fixture.stateDb)).toBe(true)
      expect(readKey(fixture.stateDb, 'composer.composerData')).toBeNull()
      expect(readKey(fixture.stateDb, 'workbench.panel.aichat.view.aichat.chatdata')).toBeNull()
      // 与聊天无关的 key 保留
      expect(readKey(fixture.stateDb, 'workbench.activityBar')).not.toBeNull()
    })

    it('cleanFileHistorySnapshots 关掉时 cleanAll 也不动 chatEditingSessions', async () => {
      const root = makeRoot()
      const wsDir = join(root, 'User', 'workspaceStorage', 'ws1')
      writeJsonlSession(join(wsDir, 'chatSessions', `${CHAT_SID}.jsonl`), CHAT_SID, 1789200000000, 'keep')
      writeFile(join(wsDir, 'chatEditingSessions', CHAT_SID, 'state.json'), 'x'.repeat(64))

      snapshots = false
      const freed = await new CursorScanner({ storagePath: root }).cleanAll()
      expect(freed).toBeGreaterThan(0)
      expect(existsSync(join(wsDir, 'chatEditingSessions', CHAT_SID, 'state.json'))).toBe(true)
      expect(existsSync(join(wsDir, 'chatSessions', `${CHAT_SID}.jsonl`))).toBe(false)
    })
  })

  describe('本机真实目录（只读，存在才跑）', () => {
    const cursorRoot = join(homedir(), 'Library/Application Support/Cursor')
    const dotCursor = join(homedir(), '.cursor')
    const installed = existsSync(cursorRoot) || existsSync(dotCursor)
    const itReal = installed ? it : it.skip

    itReal('扫真实 Cursor 目录不抛异常，且不修改任何文件', async () => {
      const scanner = new CursorScanner()
      expect(scanner.isInstalled).toBe(true)
      const watched = collectSignature(cursorRoot, dotCursor)

      const items = await scanner.scan()
      expect(items.every((item) => item.category === 'cursor')).toBe(true)
      for (const item of items.slice(0, 20)) {
        for (const path of item.associatedPaths) {
          expect(existsSync(path), path).toBe(true)
        }
      }
      expect(collectSignature(cursorRoot, dotCursor)).toEqual(watched)
    })
  })
})

function readFileText(path: string): string {
  return readFileSync(path, 'utf8')
}

/** 收集真实目录里扫描相关文件的 (路径, 体积, mtime) 签名，用来证明 scan() 没落盘。 */
function collectSignature(...roots: string[]): string[] {
  const signature: string[] = []
  const walk = (dir: string, depth: number): void => {
    if (depth > 4 || signature.length > 400) return
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
  for (const root of roots) walk(root, 0)
  return signature
}
