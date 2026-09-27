import { mkdirSync, mkdtempSync, realpathSync, rmSync, statSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ConversationItem } from '@shared/types'
import { CleanPrefs, sizeOfPath } from '@main/core/scanner'
import { PiAgentScanner } from './PiAgentScanner'

/**
 * Pi Agent 扫描器的 mock 夹具测试。
 *
 * 钉住 Pi Agent 扫描的行为：`agent/sessions/<项目>` 三层目录布局的解析，
 * 标题 / 项目路径 / 消息数 / associatedPaths 各字段，
 * 「删掉一条 → 文件消失 + freedBytes 相等 → 空项目目录被回收」，
 * 以及 `cleanAll()` 把扫描器看不见的目录一并清掉并重建。
 *
 * 夹具全部造在 `os.tmpdir()` 下，不碰真实的 `~/.pi`。
 * `CleanPrefs` 的落盘位置也一并重定向到临时 HOME，避免污染真实用户设置。
 */

const prefHome = realpathSync(mkdtempSync(join(tmpdir(), 'pi_home_')))
const originalHome = process.env['HOME']
process.env['HOME'] = prefHome

let root = ''
let scanner: PiAgentScanner

function dir(...segments: string[]): string {
  const path = join(root, ...segments)
  mkdirSync(path, { recursive: true })
  return path
}

/** 相对路径按夹具根目录解析，绝对路径原样使用。 */
function resolve(path: string): string {
  return path.startsWith('/') ? path : join(root, path)
}

function write(path: string, content: string): string {
  const full = resolve(path)
  writeFileSync(full, content, 'utf8')
  return full
}

function exists(path: string): boolean {
  try {
    statSync(path)
    return true
  } catch {
    return false
  }
}

const SID_A = '01a00000-0000-7000-8000-000000000001'
const SID_B = '01a00000-0000-7000-8000-000000000002'

const FILE_BASE_A = `2026-09-01T10-00-00-000Z_${SID_A}`
const FILE_BASE_B = `2026-09-02T12-00-00-000Z_${SID_B}`

const SESSION_A = [
  `{"type":"session","version":3,"id":"${SID_A}","timestamp":"2026-09-01T10:00:00.000Z","cwd":"/Users/mock/projectA"}`,
  `{"type":"model_change","id":"m1","parentId":null,"timestamp":"2026-09-01T10:00:01.000Z","provider":"cli-proxy","modelId":"gemini"}`,
  `{"type":"message","id":"msg1","parentId":"m1","timestamp":"2026-09-01T10:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"Implement Pi Agent Scanner feature"}]}}`,
  `{"type":"message","id":"msg2","parentId":"msg1","timestamp":"2026-09-01T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Feature implemented."}]}}`,
  ''
].join('\n')

const SESSION_B = [
  `{"type":"session","version":3,"id":"${SID_B}","timestamp":"2026-09-02T12:00:00.000Z","cwd":"/Users/mock/projectB"}`,
  `{"type":"message","id":"msg2_1","parentId":null,"timestamp":"2026-09-02T12:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"Fix bug in project B"}]}}`,
  ''
].join('\n')

interface Fixture {
  projA: string
  projB: string
  tasksDir: string
  contextModeDir: string
  webCacheDir: string
  jsonlA: string
  jsonlB: string
  subfolderA: string
  taskADir: string
  unmatchedTaskDir: string
  runHistory: string
}

/** 两个项目 + tasks / context-mode / web-search-cache 的完整夹具。 */
function buildFixture(): Fixture {
  const projA = dir('agent', 'sessions', '--Users-mock-projectA--')
  const projB = dir('agent', 'sessions', '--Users-mock-projectB--')
  const tasksDir = dir('tasks')
  const contextModeDir = dir('context-mode')
  const webCacheDir = dir('web-search-cache')

  // 会话 1：同名子目录 + 命中的任务目录
  const subfolderA = dir('agent', 'sessions', '--Users-mock-projectA--', FILE_BASE_A)
  write(join(subfolderA, 'subdata.txt'), 'subfolder-data-bytes-123456789')
  const jsonlA = write(join(projA, `${FILE_BASE_A}.jsonl`), SESSION_A)
  const taskADir = dir('tasks', `${SID_A}-99999`)
  write(join(taskADir, 'task.json'), '{"id":"t1","status":"completed"}')

  // 会话 2：无子目录、无命中任务
  const jsonlB = write(join(projB, `${FILE_BASE_B}.jsonl`), SESSION_B)

  // 前缀不足 36 位 → 不该被预索引命中
  const unmatchedTaskDir = dir('tasks', 'session-12345-12345')
  write(join(unmatchedTaskDir, 'out.txt'), 'unmatched-task-content')

  write(join(contextModeDir, 'context.db'), 'mock-sqlite-db')
  write(join(webCacheDir, 'cached.json'), '{}')
  const runHistory = write(
    join('agent', 'run-history.jsonl'),
    '{"agent":"worker","status":"ok"}\n'
  )

  // 固定 mtime，让 updatedAt 排序断言可复现
  utimesSync(jsonlA, new Date('2026-09-01T10:00:00Z'), new Date('2026-09-01T10:00:00Z'))
  utimesSync(jsonlB, new Date('2026-09-02T12:00:00Z'), new Date('2026-09-02T12:00:00Z'))

  return {
    projA,
    projB,
    tasksDir,
    contextModeDir,
    webCacheDir,
    jsonlA,
    jsonlB,
    subfolderA,
    taskADir,
    unmatchedTaskDir,
    runHistory
  }
}

beforeEach(() => {
  // `mkdtempSync` 在 macOS 上落在 `/var/...`（`/private/var/...` 的软链）。
  // 扫描器会做 realpath 规范化，这里也先解析一次，断言里的路径才一致。
  root = realpathSync(mkdtempSync(join(tmpdir(), 'pi_mock_')))
  scanner = new PiAgentScanner({ storagePath: root })
})

afterEach(() => {
  rmSync(root, { recursive: true, force: true })
  // 复位开关，避免用例之间的偏好泄漏
  CleanPrefs.patch({ cleanFileHistorySnapshots: true, cleanEmptyProjectFolders: true })
})

afterAll(() => {
  if (originalHome === undefined) delete process.env['HOME']
  else process.env['HOME'] = originalHome
  rmSync(prefHome, { recursive: true, force: true })
})

describe('PiAgentScanner · 路径解析与安装检测', () => {
  it('storagePath 指向注入的夹具目录并完成 realpath 规范化', () => {
    expect(scanner.storagePath).toBe(root)
    expect(scanner.isInstalled).toBe(true)
    expect(scanner.category).toBe('piAgent')
  })

  it('未安装（目录不存在）时 isInstalled 为 false 且 scan() 返回空数组', async () => {
    const bare = new PiAgentScanner({ storagePath: join(root, 'does-not-exist') })
    expect(bare.isInstalled).toBe(false)
    await expect(bare.scan()).resolves.toEqual([])
  })

  it('装了根目录但没有 agent/sessions 时 scan() 返回空数组', async () => {
    const emptyRoot = join(root, 'empty-pi')
    mkdirSync(emptyRoot)
    const bare = new PiAgentScanner({ storagePath: emptyRoot })
    expect(bare.isInstalled).toBe(true)
    await expect(bare.scan()).resolves.toEqual([])
  })

  it('PI_HOME 环境变量优先于默认目录', () => {
    const envRoot = join(root, 'env-pi')
    mkdirSync(envRoot)
    const previous = process.env['PI_HOME']
    process.env['PI_HOME'] = envRoot
    try {
      expect(new PiAgentScanner().storagePath).toBe(realpathSync(envRoot))
    } finally {
      if (previous === undefined) delete process.env['PI_HOME']
      else process.env['PI_HOME'] = previous
    }
  })

  it('delete() 传空数组返回 0', async () => {
    await expect(scanner.delete([])).resolves.toBe(0)
  })
})

describe('PiAgentScanner · scan 解析', () => {
  let fixture: Fixture

  beforeEach(() => {
    fixture = buildFixture()
  })

  it('解析出 2 条会话，基础字段齐备', async () => {
    const items = await scanner.scan()
    expect(items).toHaveLength(2)
    expect(items.every((i) => i.category === 'piAgent')).toBe(true)
    expect(items.every((i) => i.sessionId.length > 0)).toBe(true)
    expect(items.every((i) => i.title.length > 0)).toBe(true)
    expect(items.every((i) => i.messageCount > 0)).toBe(true)
    expect(items.every((i) => i.isSelected === false)).toBe(true)
  })

  it('会话 1：标题取首条用户提问、项目路径取 cwd、消息数与 associatedPaths 正确', async () => {
    const items = await scanner.scan()
    const item1 = items.find((i) => i.sessionId === SID_A)
    expect(item1).toBeDefined()
    expect(item1?.title).toBe('Implement Pi Agent Scanner feature')
    expect(item1?.snippet).toBe('Implement Pi Agent Scanner feature')
    expect(item1?.projectPath).toBe('/Users/mock/projectA')
    expect(item1?.gitBranch).toBeNull()
    expect(item1?.messageCount).toBe(2)
    expect(item1?.associatedPaths).toContain(fixture.jsonlA)
    expect(item1?.associatedPaths).toContain(fixture.subfolderA)
    expect(item1?.associatedPaths).toContain(fixture.taskADir)
    // 前缀不足 36 位的任务目录不该被关联
    expect(item1?.associatedPaths).not.toContain(fixture.unmatchedTaskDir)
  })

  it('会话 2：无子目录、无任务目录，体积只有 jsonl 本身', async () => {
    const items = await scanner.scan()
    const item2 = items.find((i) => i.sessionId === SID_B)
    expect(item2?.projectPath).toBe('/Users/mock/projectB')
    expect(item2?.associatedPaths).toEqual([fixture.jsonlB])
    expect(item2?.sizeInBytes).toBe(sizeOfPath(fixture.jsonlB))
  })

  it('sizeInBytes = jsonl + 同名子目录 + 任务目录', async () => {
    const items = await scanner.scan()
    const item1 = items.find((i) => i.sessionId === SID_A)
    const expected =
      sizeOfPath(fixture.jsonlA) + sizeOfPath(fixture.subfolderA) + sizeOfPath(fixture.taskADir)
    expect(item1?.sizeInBytes).toBe(expected)
  })

  it('updatedAt 优先用文件 mtime，且结果按倒序返回', async () => {
    const items = await scanner.scan()
    expect(items[0]?.sessionId).toBe(SID_B)
    expect(items[0]?.updatedAt).toBe('2026-09-02T12:00:00.000Z')
    const timestamps = items.map((i) => i.updatedAt)
    expect(timestamps).toEqual([...timestamps].sort().reverse())
  })

  it('scan() 只读：不改任何文件的体积与 mtime', async () => {
    const before = snapshot(fixture.jsonlA, fixture.jsonlB, fixture.subfolderA)
    await scanner.scan()
    expect(snapshot(fixture.jsonlA, fixture.jsonlB, fixture.subfolderA)).toEqual(before)
  })

  it('cwd 缺失时从项目目录名反解（--a-b-- → /a/b），标题摘要走兜底', async () => {
    const projC = dir('agent', 'sessions', '--Users-mock-deep-project--')
    const sid = '01a00000-0000-7000-8000-000000000003'
    const base = `2026-09-03T09-00-00-000Z_${sid}`
    write(join(projC, `${base}.jsonl`), `{"type":"session","id":"${sid}"}\n`)

    const item = (await scanner.scan()).find((i) => i.sessionId === sid)
    expect(item?.projectPath).toBe('/Users/mock/deep/project')
    expect(item?.title).toBe(`Pi 会话 ${sid.slice(0, 8)}`)
    expect(item?.snippet).toBe('项目: /Users/mock/deep/project')
  })

  it('忽略隐藏文件与非 .jsonl 文件', async () => {
    const projD = dir('agent', 'sessions', '--Users-mock-noise--')
    const sid = '01a00000-0000-7000-8000-000000000004'
    write(join(projD, `.hidden_${sid}.jsonl`), '{"type":"session","id":"hidden-sid"}\n')
    write(join(projD, `notes_${sid}.json`), '{"type":"session"}\n')

    const items = await scanner.scan()
    expect(items.map((i) => i.sessionId)).not.toContain('hidden-sid')
  })
})

describe('PiAgentScanner · delete', () => {
  let fixture: Fixture

  beforeEach(() => {
    fixture = buildFixture()
  })

  it('删单条会话：释放字节数相等、文件消失、空项目目录被回收', async () => {
    const items = await scanner.scan()
    const item1 = items.find((i) => i.sessionId === SID_A)
    expect(item1).toBeDefined()

    const freed = await scanner.delete([item1 as ConversationItem])
    expect(freed).toBe(item1?.sizeInBytes)

    expect(exists(fixture.jsonlA)).toBe(false)
    expect(exists(fixture.subfolderA)).toBe(false)
    expect(exists(fixture.taskADir)).toBe(false)
    // 会话走光后 projectA 目录被回收，projectB 不受影响
    expect(exists(fixture.projA)).toBe(false)
    expect(exists(fixture.projB)).toBe(true)

    expect((await scanner.scan()).map((i) => i.sessionId)).toEqual([SID_B])
  })

  it('cleanEmptyProjectFolders 关闭时：文件仍删除，但保留空项目目录', async () => {
    const items = await scanner.scan()
    const item1 = items.find((i) => i.sessionId === SID_A)

    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    await scanner.delete([item1 as ConversationItem])

    expect(exists(fixture.jsonlA)).toBe(false)
    expect(exists(fixture.projA)).toBe(true)
  })
})

describe('PiAgentScanner · cleanFileHistorySnapshots 的相反分支', () => {
  /**
   * Pi 的 `associatedPaths` 天然不带 `checkpoints` 这类快照目录名，
   * 所以这里手工构造一条 `ConversationItem` 来精确压这两个分支。
   */
  function buildSnapshotItem(): { item: ConversationItem; jsonl: string; snapshots: string } {
    const base = join(root, 'snap', 'session')
    mkdirSync(base, { recursive: true })
    const sid = '01a00000-0000-7000-8000-000000000007'
    const jsonl = write(join(base, `${sid}.jsonl`), `{"type":"session","id":"${sid}"}\n`)
    const snapshotDir = join(base, 'checkpoints')
    mkdirSync(snapshotDir, { recursive: true })
    const snapshots = write(join(snapshotDir, 'a.txt'), 'checkpoint-bytes')

    const item: ConversationItem = {
      id: 'fixed-id',
      sessionId: sid,
      title: 'Pi 会话 01a00000',
      category: 'piAgent',
      projectPath: '/Users/mock/snap',
      gitBranch: null,
      messageCount: 1,
      sizeInBytes: sizeOfPath(jsonl) + sizeOfPath(snapshotDir),
      updatedAt: '2026-09-06T10:00:00.000Z',
      isSelected: false,
      snippet: '项目: /Users/mock/snap',
      associatedPaths: [jsonl, snapshotDir]
    }
    return { item, jsonl, snapshots }
  }

  it('开关打开：快照路径一并删除，freedBytes == 报告体积', async () => {
    const { item, jsonl, snapshots } = buildSnapshotItem()
    const freed = await scanner.delete([item])

    expect(freed).toBe(item.sizeInBytes)
    expect(exists(jsonl)).toBe(false)
    expect(exists(snapshots)).toBe(false)
  })

  it('开关关闭：快照留在盘上，freedBytes 扣掉它（不会虚报释放量）', async () => {
    const { item, jsonl, snapshots } = buildSnapshotItem()
    const keptBytes = sizeOfPath(join(root, 'snap', 'session', 'checkpoints'))

    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const freed = await scanner.delete([item])

    expect(freed).toBe(item.sizeInBytes - keptBytes)
    expect(exists(jsonl)).toBe(false)
    expect(exists(snapshots)).toBe(true)
  })
})

describe('PiAgentScanner · cleanAll', () => {
  let fixture: Fixture

  beforeEach(() => {
    fixture = buildFixture()
  })

  it('清空全部会话、任务目录、上下文索引与运行历史，并重建空目录', async () => {
    const allFreed = await scanner.cleanAll()
    expect(allFreed).toBeGreaterThan(0)

    await expect(scanner.scan()).resolves.toEqual([])

    expect(exists(fixture.jsonlB)).toBe(false)
    expect(exists(fixture.unmatchedTaskDir)).toBe(false)
    expect(exists(fixture.runHistory)).toBe(false)
    // 目录删掉后重建为空目录（Pi 自身假定它们存在）
    expect(exists(fixture.tasksDir)).toBe(true)
    expect(exists(fixture.contextModeDir)).toBe(true)
  })

  it('清空 web-search-cache 的内容', async () => {
    await scanner.cleanAll()
    expect(exists(join(fixture.webCacheDir, 'cached.json'))).toBe(false)
  })

  it('未安装时 cleanAll 返回 0 且不抛错', async () => {
    const missing = new PiAgentScanner({ storagePath: join(root, 'nope') })
    await expect(missing.cleanAll()).resolves.toBe(0)
  })
})

function snapshot(...paths: string[]): { path: string; size: number; mtimeMs: number }[] {
  return paths.map((path) => {
    const stats = statSync(path)
    return { path, size: stats.size, mtimeMs: stats.mtimeMs }
  })
}
