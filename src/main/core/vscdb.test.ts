/**
 * `core/vscdb.ts` 的索引同步测试。
 *
 * 覆盖 `state.vscdb` 的 8 个索引 key + Copilot `session-store.db` 的关系表：
 * 删掉指定 sessionId 后逐个 key 断言，且未命中的会话必须完好。
 *
 * mock 库用 `node:sqlite` 的 `DatabaseSync` 现场造
 * （建库 / 插入的 SQL 在 `src/test-support/sqliteFixtures.ts`）。
 * VS Code 系扫描器本身由各自的文件测试覆盖，本文件只锁 `vscdb.ts` 的行为。
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { existsSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import {
  clearAllChatSessions,
  clearCopilotSessionStore,
  dbMtimeMs,
  dbSizeBytes,
  openReadOnly,
  openReadWrite,
  readItemJson,
  removeChatSessions,
  removeComposers,
  removeCopilotSessionStore
} from '@main/core/vscdb'
// @ts-ignore -- src/test-support 不在 tsconfig.node.json 的 include 里（composite 项目要求显式列出）
import { createTempDir, removeTempDir } from '../../test-support/fixtures'
// @ts-ignore -- 同上
import {
  b64,
  copilotSessionIds,
  copilotTurnCount,
  createCopilotSessionStore,
  createStateVscdb,
  createStateVscdbRaw,
  readStateJson,
  readStateRaw,
  stateKeys,
  stateRowCount
} from '../../test-support/sqliteFixtures'

const SID1 = 'vsc-sync-001'
const SID2 = 'vsc-sync-002'

let root: string
let stateDb: string
let sessionStoreDb: string

/** 8 个索引 key 的初始载荷。 */
function indexFixture(): Record<string, unknown> {
  const enc1 = b64(SID1)
  const enc2 = b64(SID2)
  return {
    'chat.ChatSessionStore.index': {
      version: 1,
      entries: {
        [SID1]: { sessionId: SID1, title: 'First prompt in session 1', lastMessageDate: 1789000000000 },
        [SID2]: { sessionId: SID2, title: 'Second prompt in session 2', lastMessageDate: 1789100000000 }
      }
    },
    'memento/interactive-session-view-copilot': {
      sessionResource: { external: `vscode-chat-session://local/${enc1}` }
    },
    'interactive.sessions': [SID1, SID2],
    'workbench.panel.chat': { activeSession: SID1 },
    'agentSessions.state.cache': [
      { resource: `vscode-chat-session://local/${enc1}`, read: 1 },
      { resource: `vscode-chat-session://local/${enc2}`, read: 1 }
    ],
    'agentSessions.model.cache': [
      { resource: `vscode-chat-session://local/${enc1}`, label: 'm1' },
      { resource: `vscode-chat-session://local/${enc2}`, label: 'm2' }
    ],
    'composer.composerData': {
      allComposers: [
        { composerId: SID1, name: 'c1' },
        { composerId: SID2, name: 'c2' }
      ]
    },
    'workbench.panel.aichat.view.aichat.chatdata': {
      tabs: [
        { id: SID1, chatTitle: 't1' },
        { id: SID2, chatTitle: 't2' }
      ]
    }
  }
}

beforeEach(() => {
  root = createTempDir('cc-vscdb-')
  stateDb = join(root, 'workspaceStorage', 'mock-ws-hash-123', 'state.vscdb')
  sessionStoreDb = join(root, 'globalStorage', 'github.copilot-chat', 'session-store.db')
  createStateVscdb(stateDb, indexFixture())
  createCopilotSessionStore(sessionStoreDb, [
    { id: SID1, summary: 'summary1', turns: ['msg1'] },
    { id: SID2, summary: 'summary2', turns: ['msg2'] }
  ])
})

afterEach(() => {
  removeTempDir(root)
})

// ---------------------------------------------------------------------------
// 删掉 sid1 之后逐个 key 断言，sid2 必须完好。
// ---------------------------------------------------------------------------

describe('removeChatSessions —— 8 个索引 key 的删除语义', () => {
  it('删 sid1：8 个 key 全部按各自形状裁剪，sid2 完好', () => {
    removeChatSessions(stateDb, [SID1])

    // 1. chat.ChatSessionStore.index
    const index = readStateJson<{ entries: Record<string, unknown> }>(stateDb, 'chat.ChatSessionStore.index')
    expect(index).not.toBeNull()
    expect(index?.entries[SID1]).toBeUndefined()
    expect(index?.entries[SID2]).toBeDefined()

    // 2. memento/interactive-session-view-copilot（整条删）
    expect(readStateRaw(stateDb, 'memento/interactive-session-view-copilot')).toBeNull()

    // 3. interactive.sessions（数组按条目删）
    expect(readStateJson(stateDb, 'interactive.sessions')).toEqual([SID2])

    // 4. workbench.panel.chat（整条删）
    expect(readStateRaw(stateDb, 'workbench.panel.chat')).toBeNull()

    // 5. agentSessions.state.cache（数组按 resource 删）
    const stateCache = readStateJson<{ resource: string }[]>(stateDb, 'agentSessions.state.cache')
    expect(stateCache).toHaveLength(1)
    expect(stateCache?.[0]?.resource).toContain(b64(SID2))

    // 6. agentSessions.model.cache
    const modelCache = readStateJson<{ resource: string }[]>(stateDb, 'agentSessions.model.cache')
    expect(modelCache).toHaveLength(1)
    expect(modelCache?.[0]?.resource).toContain(b64(SID2))

    // 7. composer.composerData → allComposers
    const composers = readStateJson<{ allComposers: { composerId: string }[] }>(
      stateDb,
      'composer.composerData'
    )
    expect(composers?.allComposers.map((c) => c.composerId)).toEqual([SID2])

    // 8. workbench.panel.aichat.view.aichat.chatdata → tabs
    const tabs = readStateJson<{ tabs: { id: string }[] }>(
      stateDb,
      'workbench.panel.aichat.view.aichat.chatdata'
    )
    expect(tabs?.tabs.map((t) => t.id)).toEqual([SID2])
  })

  it('VACUUM 之后表仍可读（SQLite 删行不会自动缩文件，但不缩也能读）', () => {
    const sizeBefore = dbSizeBytes(stateDb)
    removeChatSessions(stateDb, [SID1])
    expect(existsSync(stateDb)).toBe(true)
    expect(dbSizeBytes(stateDb)).toBeGreaterThan(0)
    expect(dbSizeBytes(stateDb)).toBeLessThanOrEqual(sizeBefore)
    // 仍可读，且 sid2 的数据完好
    expect(stateKeys(stateDb)).toContain('interactive.sessions')
    expect(readStateJson(stateDb, 'interactive.sessions')).toEqual([SID2])
    expect(dbMtimeMs(stateDb)).toBeGreaterThan(0)
  })

  it('删两个 id：index 变空对象、interactive.sessions 整条 key 消失', () => {
    removeChatSessions(stateDb, [SID1, SID2])
    expect(readStateJson<{ entries: Record<string, unknown> }>(
      stateDb,
      'chat.ChatSessionStore.index'
    )?.entries).toEqual({})
    // 数组删空 → 整条 key 删掉（不留空数组幽灵）
    expect(readStateRaw(stateDb, 'interactive.sessions')).toBeNull()
    // 两个 agentSessions 缓存都删空 → key 消失（不留空数组幽灵）
    expect(readStateRaw(stateDb, 'agentSessions.state.cache')).toBeNull()
    expect(readStateRaw(stateDb, 'agentSessions.model.cache')).toBeNull()
    expect(readStateRaw(stateDb, 'composer.composerData')).toBeNull()
    expect(readStateRaw(stateDb, 'workbench.panel.aichat.view.aichat.chatdata')).toBeNull()
  })
})

// ---------------------------------------------------------------------------
// 逐 key 的形状 / 边界
// ---------------------------------------------------------------------------

describe('chat.ChatSessionStore.index', () => {
  it('entries 里没有命中 id 时不写回（value 原样）', () => {
    const before = readStateRaw(stateDb, 'chat.ChatSessionStore.index')
    removeChatSessions(stateDb, ['not-in-there'])
    expect(readStateRaw(stateDb, 'chat.ChatSessionStore.index')).toBe(before)
  })

  it('entries 缺字段 / 不是字典时静默不动', () => {
    const db = join(root, 'a.vscdb')
    createStateVscdb(db, { 'chat.ChatSessionStore.index': { version: 1 } })
    removeChatSessions(db, [SID1])
    expect(readStateJson<Record<string, unknown>>(db, 'chat.ChatSessionStore.index')).toEqual({
      version: 1
    })
  })
})

describe('memento/interactive-session% / workbench.panel.chat%', () => {
  it('同前缀的兄弟 key 命中 base64 形态也整条删', () => {
    const db = join(root, 'b.vscdb')
    createStateVscdb(db, {
      'memento/interactive-session-view-copilot:1': { r: b64(SID1) },
      'memento/interactive-session-view-copilot:2': { r: b64(SID2) },
      'workbench.panel.chat.c1': { active: SID1 },
      'workbench.panel.chat.c2': { active: SID2 },
      'workbench.panel.chat.editor': { untouched: true }
    })
    removeChatSessions(db, [SID1])
    expect(readStateRaw(db, 'memento/interactive-session-view-copilot:1')).toBeNull()
    expect(readStateRaw(db, 'memento/interactive-session-view-copilot:2')).not.toBeNull()
    expect(readStateRaw(db, 'workbench.panel.chat.c1')).toBeNull()
    expect(readStateRaw(db, 'workbench.panel.chat.c2')).not.toBeNull()
    expect(readStateRaw(db, 'workbench.panel.chat.editor')).not.toBeNull()
  })

  it('明文 sid 命中同样整条删', () => {
    const db = join(root, 'c.vscdb')
    createStateVscdb(db, { 'workbench.panel.chat': { activeSession: SID1 } })
    removeChatSessions(db, [SID1])
    expect(readStateRaw(db, 'workbench.panel.chat')).toBeNull()
  })
})

describe('interactive.sessions —— 数组 / 对象 / 删空 / 未知形状', () => {
  it('数组里的对象按 id / sessionId / resource 子串命中', () => {
    const db = join(root, 'd.vscdb')
    createStateVscdb(db, {
      'interactive.sessions': [
        { id: SID1 },
        { sessionId: SID2 },
        { resource: `vscode-chat-session://local/${b64(SID1)}` },
        { resource: 'vscode-chat-session://local/other' }
      ]
    })
    removeChatSessions(db, [SID1])
    expect(readStateJson(db, 'interactive.sessions')).toEqual([
      { sessionId: SID2 },
      { resource: 'vscode-chat-session://local/other' }
    ])
  })

  it('对象形状：顶层 key 与 entries 字典都删', () => {
    const db = join(root, 'e.vscdb')
    createStateVscdb(db, {
      'interactive.sessions': { [SID1]: { a: 1 }, [SID2]: { a: 2 }, entries: { [SID1]: {}, [SID2]: {} } }
    })
    removeChatSessions(db, [SID1])
    expect(readStateJson(db, 'interactive.sessions')).toEqual({
      [SID2]: { a: 2 },
      entries: { [SID2]: {} }
    })
  })

  it('对象删到空 → 整条 key 删掉', () => {
    const db = join(root, 'f.vscdb')
    createStateVscdb(db, { 'interactive.sessions': { [SID1]: { a: 1 } } })
    removeChatSessions(db, [SID1])
    expect(readStateRaw(db, 'interactive.sessions')).toBeNull()
  })

  it('value 里一个 id 都没有 → 快速否决，不动', () => {
    const db = join(root, 'g.vscdb')
    createStateVscdb(db, { 'interactive.sessions': [SID2] })
    const before = readStateRaw(db, 'interactive.sessions')
    removeChatSessions(db, [SID1])
    expect(readStateRaw(db, 'interactive.sessions')).toBe(before)
  })

  it('非 JSON → 整条删掉（不留幽灵）', () => {
    const db = join(root, 'h.vscdb')
    createStateVscdbRaw(db, [['interactive.sessions', `half-written ${SID1}`]])
    removeChatSessions(db, [SID1])
    expect(readStateRaw(db, 'interactive.sessions')).toBeNull()
  })

  it('形状不认识（字符串 / 数字）→ 整条删掉', () => {
    const db = join(root, 'i.vscdb')
    createStateVscdbRaw(db, [['interactive.sessions', `"${SID1}"`]])
    removeChatSessions(db, [SID1])
    expect(readStateRaw(db, 'interactive.sessions')).toBeNull()
  })
})

describe('agentSessions.{state,model}.cache', () => {
  it('resource 子串命中 base64 形态', () => {
    const db = join(root, 'j.vscdb')
    createStateVscdb(db, {
      'agentSessions.state.cache': [
        { resource: `vscode-chat-session://local/${b64(SID1)}`, read: 1 },
        { resource: `vscode-chat-session://local/${b64(SID2)}`, read: 0 }
      ]
    })
    removeChatSessions(db, [SID1])
    expect(readStateJson<{ resource: string }[]>(db, 'agentSessions.state.cache')).toEqual([
      { resource: `vscode-chat-session://local/${b64(SID2)}`, read: 0 }
    ])
  })

  it('不是数组时静默不动', () => {
    const db = join(root, 'k.vscdb')
    createStateVscdb(db, { 'agentSessions.model.cache': { [SID1]: true } })
    const before = readStateRaw(db, 'agentSessions.model.cache')
    removeChatSessions(db, [SID1])
    expect(readStateRaw(db, 'agentSessions.model.cache')).toBe(before)
  })
})

describe('composer.composerData / aichat.chatdata（Cursor）', () => {
  it('composerId 与 id 两种字段都能命中', () => {
    const db = join(root, 'l.vscdb')
    createStateVscdb(db, {
      'composer.composerData': {
        allComposers: [{ composerId: SID1 }, { id: SID1 }, { composerId: SID2 }]
      }
    })
    removeChatSessions(db, [SID1])
    expect(
      readStateJson<{ allComposers: unknown[] }>(db, 'composer.composerData')?.allComposers
    ).toEqual([{ composerId: SID2 }])
  })

  it('tabs 的 id / tabId 两种字段都能命中', () => {
    const db = join(root, 'm.vscdb')
    createStateVscdb(db, {
      'workbench.panel.aichat.view.aichat.chatdata': {
        tabs: [{ id: SID1 }, { tabId: SID1 }, { id: SID2 }]
      }
    })
    removeChatSessions(db, [SID1])
    expect(
      readStateJson<{ tabs: unknown[] }>(db, 'workbench.panel.aichat.view.aichat.chatdata')?.tabs
    ).toEqual([{ id: SID2 }])
  })

  it('allComposers / tabs 不是数组时静默不动', () => {
    const db = join(root, 'n.vscdb')
    createStateVscdb(db, {
      'composer.composerData': { allComposers: { [SID1]: true } },
      'workbench.panel.aichat.view.aichat.chatdata': { tabs: 'nope' }
    })
    const a = readStateRaw(db, 'composer.composerData')
    const b = readStateRaw(db, 'workbench.panel.aichat.view.aichat.chatdata')
    removeChatSessions(db, [SID1])
    expect(readStateRaw(db, 'composer.composerData')).toBe(a)
    expect(readStateRaw(db, 'workbench.panel.aichat.view.aichat.chatdata')).toBe(b)
  })
})

// ---------------------------------------------------------------------------
// clearAllChatSessions / removeComposers / 静默返回
// ---------------------------------------------------------------------------

describe('clearAllChatSessions', () => {
  it('purge 了 ItemTable 里的全部索引 key（行数为 0）', () => {
    removeChatSessions(stateDb, [SID1])
    expect(stateRowCount(stateDb)).toBeGreaterThan(0)
    clearAllChatSessions(stateDb)
    expect(stateRowCount(stateDb)).toBe(0)
    expect(stateKeys(stateDb)).toEqual([])
  })

  it('只清白名单里的索引 key，settings.json 这类无关键保留', () => {
    const db = join(root, 'unrelated.vscdb')
    createStateVscdb(db, {
      'workbench.panel.chat': { activeSession: SID1 },
      'settings.json': '{"theme":"dark"}'
    })
    clearAllChatSessions(db)
    expect(stateKeys(db)).toEqual(['settings.json'])
  })

  it('ItemTable 不存在时静默返回，不抛错', () => {
    const notADb = join(root, 'plain.txt')
    writeFileSync(notADb, 'definitely not sqlite')
    expect(() => clearAllChatSessions(notADb)).not.toThrow()
  })
})

describe('removeComposers', () => {
  it('就是 removeChatSessions 的别名：删 composerId 并保留同库其它条目', () => {
    removeComposers(stateDb, [SID1])
    expect(
      readStateJson<{ allComposers: { composerId: string }[] }>(stateDb, 'composer.composerData')
        ?.allComposers.map((c) => c.composerId)
    ).toEqual([SID2])
    expect(readStateJson(stateDb, 'interactive.sessions')).toEqual([SID2])
  })
})

describe('removeChatSessions / removeComposers 的静默返回', () => {
  it('文件不存在 → 什么都不做', () => {
    const missing = join(root, 'nope', 'state.vscdb')
    expect(() => removeChatSessions(missing, [SID1])).not.toThrow()
    expect(() => removeComposers(missing, [SID1])).not.toThrow()
    expect(existsSync(missing)).toBe(false)
  })

  it('空 id 集合 → 直接返回，不开库', () => {
    const before = stateRowCount(stateDb)
    removeChatSessions(stateDb, [])
    removeChatSessions(stateDb, [''])
    expect(stateRowCount(stateDb)).toBe(before)
  })

  it('不是 SQLite 文件 → 静默吞掉错误', () => {
    const junk = join(root, 'junk.vscdb')
    // 用一个普通文件冒充 db
    writeFileSync(junk, 'not a sqlite database')
    expect(() => removeChatSessions(junk, [SID1])).not.toThrow()
  })
})

// ---------------------------------------------------------------------------
// Copilot session-store.db
// ---------------------------------------------------------------------------

describe('removeCopilotSessionStore', () => {
  it('sessions 删 sid1、留 sid2；turns 同步裁剪', () => {
    removeCopilotSessionStore(sessionStoreDb, [SID1])
    expect(copilotSessionIds(sessionStoreDb)).toEqual([SID2])
    expect(copilotTurnCount(sessionStoreDb)).toBe(1)
    expect(copilotTurnCount(sessionStoreDb, SID1)).toBe(0)
    expect(copilotTurnCount(sessionStoreDb, SID2)).toBe(1)
  })

  it('6 张表都存在时逐表清（表缺失只跳该表）', () => {
    const db = join(root, 'full.db')
    createCopilotSessionStore(db, [{ id: SID1, turns: ['a', 'b'] }])
    // 往 4 张附属表塞几行，验证 session_id 维度也被清
    const raw = new DatabaseSync(db)
    raw.exec("INSERT INTO checkpoints (session_id, ref) VALUES ('" + SID1 + "', 'c1');")
    raw.exec("INSERT INTO session_files (session_id, uri) VALUES ('" + SID1 + "', 'file:///a');")
    raw.exec("INSERT INTO session_refs (session_id, ref_uri) VALUES ('" + SID1 + "', 'r1');")
    raw.exec("INSERT INTO search_index (session_id, chunk) VALUES ('" + SID1 + "', 'chunk');")
    raw.close()
    removeCopilotSessionStore(db, [SID1])
    expect(copilotSessionIds(db)).toEqual([])
    expect(copilotTurnCount(db)).toBe(0)
    const remaining = new DatabaseSync(db)
    for (const table of ['checkpoints', 'session_files', 'session_refs', 'search_index'] as const) {
      const row = remaining.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get() as { n: number }
      expect(row.n, table).toBe(0)
    }
    remaining.close()
  })

  it('表结构不同（缺 turns）时静默跳过其余表', () => {
    const db = join(root, 'minimal.db')
    createCopilotSessionStore(db, [{ id: SID1 }])
    // 删掉 turns 表再删一次：不得抛错
    const raw = new DatabaseSync(db)
    raw.exec('DROP TABLE turns;')
    raw.close()
    expect(() => removeCopilotSessionStore(db, [SID1])).not.toThrow()
    expect(copilotSessionIds(db)).toEqual([])
  })

  it('空 id 集合 / 文件不存在 → 什么都不做', () => {
    expect(() => removeCopilotSessionStore(sessionStoreDb, [])).not.toThrow()
    expect(copilotSessionIds(sessionStoreDb)).toEqual([SID1, SID2])
    expect(() =>
      removeCopilotSessionStore(join(root, 'nope.db'), [SID1])
    ).not.toThrow()
  })

  it('clearCopilotSessionStore 清空 6 张表但保留表结构', () => {
    clearCopilotSessionStore(sessionStoreDb)
    expect(copilotSessionIds(sessionStoreDb)).toEqual([])
    expect(copilotTurnCount(sessionStoreDb)).toBe(0)
    // 表还在（第二次调用不得抛错）
    expect(() => clearCopilotSessionStore(sessionStoreDb)).not.toThrow()
  })
})

// ---------------------------------------------------------------------------
// 读侧原语
// ---------------------------------------------------------------------------

describe('读侧原语', () => {
  it('openReadOnly / openReadWrite 对不存在的文件返回 null', () => {
    const missing = join(root, 'nope.vscdb')
    expect(openReadOnly(missing)).toBeNull()
    expect(openReadWrite(missing)).toBeNull()
  })

  it('readItemJson 读得到 key，坏 JSON / 不存在返回 null', () => {
    expect(readItemJson(stateDb, 'interactive.sessions')).toEqual([SID1, SID2])
    expect(readItemJson(stateDb, 'no-such-key')).toBeNull()
    const bad = join(root, 'bad.vscdb')
    createStateVscdbRaw(bad, [['broken', '{not json']])
    expect(readItemJson(bad, 'broken')).toBeNull()
  })

  it('dbMtimeMs / dbSizeBytes：不存在时 undefined / 0', () => {
    const missing = join(root, 'nope.vscdb')
    expect(dbMtimeMs(missing)).toBeUndefined()
    expect(dbSizeBytes(missing)).toBe(0)
    expect(dbSizeBytes(stateDb)).toBeGreaterThan(0)
  })
})
