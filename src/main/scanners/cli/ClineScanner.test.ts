import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import { CleanPrefs } from '@main/core/prefs'
import { sizeOfPath } from '@main/core/scanner'
import { ClineScanner } from './ClineScanner'

/**
 * ClineScanner 的移植验收用例。
 *
 * 验收标准来自 `scripts/tests/ClineTests.swift`（MockClineScan）：
 * 两个任务（一个带 checkpoints / task_metadata / api_conversation_history，一个只带 ui_messages）、
 * 标题与 cwd 的四层兜底、messageCount、associatedPaths（任务目录 + 快照目录）、体积求和，
 * 删除后 taskHistory.json 同步、重扫只剩一条、cleanAll 后清空；
 * 另外补上 Swift 用例没覆盖但端口必须保证的行为：两个开关的相反分支、cwd 正则、api 兜底。
 *
 * 本文件自包含：`$HOME` 指向一次性临时目录，夹具全部在 `os.tmpdir()` 下现场造。
 */

const FAKE_HOME = mkdtempSync(join(tmpdir(), 'cc-cline-home-'))
const REAL_HOME = process.env.HOME
process.env.HOME = FAKE_HOME

const ENV_KEYS = ['CLINE_HOME'] as const
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

const T1 = 'cline-task-001'
const T2 = 'cline-task-002'

/** 复刻 `ClineTests.swift` 的 Cline 夹具。 */
function buildClineFixture(root: string): void {
  const tasksDir = join(root, 'tasks')
  const checkpointsDir = join(root, 'checkpoints')
  makeDir(tasksDir)
  makeDir(checkpointsDir)
  makeDir(join(root, 'state'))
  makeDir(join(root, 'cache'))

  const t1Dir = join(tasksDir, T1)
  const t1CpDir = join(checkpointsDir, T1)
  makeDir(t1Dir)
  makeDir(t1CpDir)
  writeFixture(join(t1CpDir, 'commit.dat'), 'checkpoint git commit data')

  writeFixture(
    join(t1Dir, 'ui_messages.json'),
    JSON.stringify([
      { ts: 1789000000000, type: 'say', say: 'task', text: 'Refactor Swift Concurrency Actors' },
      { ts: 1789000005000, type: 'say', say: 'text', text: 'Analyzing codebase actors...' },
      { ts: 1789000010000, type: 'say', say: 'completion_result', text: 'Refactor completed.' }
    ])
  )
  writeFixture(
    join(t1Dir, 'task_metadata.json'),
    JSON.stringify({
      files_in_context: ['/Users/tester/actor-demo/Sources/Actor.swift'],
      model_usage: [{ ts: 1789000000000, model_id: 'claude-3-5-sonnet', mode: 'act' }]
    })
  )
  writeFixture(
    join(t1Dir, 'api_conversation_history.json'),
    JSON.stringify([
      {
        role: 'user',
        content: '# Current Working Directory (/Users/tester/actor-demo) Files\nRefactor actors'
      },
      { role: 'assistant', content: 'I will update Actor.swift' }
    ])
  )

  const t2Dir = join(tasksDir, T2)
  makeDir(t2Dir)
  writeFixture(
    join(t2Dir, 'ui_messages.json'),
    JSON.stringify([{ ts: 1789100000000, type: 'say', say: 'task', text: 'Build REST API Client in Go' }])
  )

  // 隐藏目录不是任务
  makeDir(join(tasksDir, '.hidden-task'))

  writeFixture(
    join(root, 'state', 'taskHistory.json'),
    JSON.stringify([
      {
        id: T1,
        task: 'Refactor Swift Concurrency Actors',
        cwdOnTaskInitialization: '/Users/tester/actor-demo',
        ts: 1789000010000,
        size: 500
      },
      {
        id: T2,
        task: 'Build REST API Client in Go',
        cwdOnTaskInitialization: '/Users/tester/go-api',
        ts: 1789100000000,
        size: 250
      }
    ])
  )

  writeFixture(join(root, 'cache', 'catalog.json'), 'catalog data')
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

describe('ClineScanner · storagePath / isInstalled', () => {
  it('默认指向 VS Code 扩展目录', () => {
    expect(new ClineScanner().storagePath).toBe(
      join(
        FAKE_HOME,
        'Library',
        'Application Support',
        'Code',
        'User',
        'globalStorage',
        'saoudrizwan.claude-dev'
      )
    )
  })

  it('CLINE_HOME 覆盖默认目录，并做 realpath 规范化', () => {
    const envRoot = makeTempDir('cc-cline-env-')
    process.env.CLINE_HOME = envRoot
    expect(new ClineScanner().storagePath).toBe(canon(envRoot))
  })

  it('注入的 storagePath 优先于环境变量', () => {
    const envRoot = makeTempDir('cc-cline-env-')
    const injected = makeTempDir('cc-cline-injected-')
    process.env.CLINE_HOME = envRoot
    expect(new ClineScanner({ storagePath: injected }).storagePath).toBe(canon(injected))
  })

  it('目录不存在时 isInstalled 为 false，scan() 返回空数组', async () => {
    const missing = join(makeTempDir('cc-cline-missing-'), 'not-there')
    const scanner = new ClineScanner({ storagePath: missing })
    expect(scanner.isInstalled).toBe(false)
    await expect(scanner.scan()).resolves.toEqual([])
  })

  it('目录存在但没有 tasks 目录时返回空数组', async () => {
    const root = makeTempDir('cc-cline-empty-')
    makeDir(join(root, 'state'))
    const scanner = new ClineScanner({ storagePath: root })
    expect(scanner.isInstalled).toBe(true)
    await expect(scanner.scan()).resolves.toEqual([])
  })
})

describe('ClineScanner · scan（对应 ClineTests.swift 的 MockClineScan）', () => {
  it('解析任务目录，标题 / cwd / 体积与 associatedPaths 对齐', async () => {
    const root = makeTempDir('cc-cline-scan-')
    buildClineFixture(root)
    const scanner = new ClineScanner({ storagePath: root })

    expect(scanner.category).toBe('cline')
    expect(scanner.isInstalled).toBe(true)

    const items = await scanner.scan()
    expect(items).toHaveLength(2)
    for (const item of items) expect(item.category).toBe('cline')

    const byId = new Map(items.map((item) => [item.sessionId, item]))
    const t1Dir = canon(join(root, 'tasks', T1))
    const t1CpDir = canon(join(root, 'checkpoints', T1))

    const item1 = byId.get(T1)
    expect(item1?.title).toBe('Refactor Swift Concurrency Actors')
    expect(item1?.projectPath).toBe('/Users/tester/actor-demo')
    expect(item1?.messageCount).toBe(3)
    expect(item1?.snippet).toBe('Refactor Swift Concurrency Actors')
    expect(item1?.gitBranch).toBeNull()
    expect(new Set(item1?.associatedPaths)).toEqual(new Set([t1Dir, t1CpDir]))
    expect(item1?.sizeInBytes).toBe(sizeOfPath(t1Dir) + sizeOfPath(t1CpDir))
    // ts 取所有消息里的最大值
    expect(item1?.updatedAt).toBe(new Date(1789000010000).toISOString()) // ts 已是 epoch 毫秒

    const item2 = byId.get(T2)
    expect(item2?.title).toBe('Build REST API Client in Go')
    expect(item2?.projectPath).toBe('/Users/tester/go-api')
    // 没有快照目录 → associatedPaths 只有任务目录
    expect(item2?.associatedPaths).toEqual([canon(join(root, 'tasks', T2))])
    expect(item2?.messageCount).toBe(1)

    // 末尾按 updatedAt 倒序
    const timestamps = items.map((item) => new Date(item.updatedAt).getTime())
    expect(timestamps).toEqual([...timestamps].sort((a, b) => b - a))
  })

  it('无 taskHistory 时从 ui_messages / api 历史 / task_metadata 逐层兜底', async () => {
    const root = makeTempDir('cc-cline-fallback-')
    // 只有 api_conversation_history：messageCount 与 cwd 都从这里来
    const aDir = join(root, 'tasks', 'task-a')
    makeDir(aDir)
    writeFixture(
      join(aDir, 'api_conversation_history.json'),
      JSON.stringify([
        { role: 'assistant', content: 'no cwd here' },
        { role: 'user', content: 'context block: "cwd": "/Users/tester/from-api-history"' }
      ])
    )
    // 只有 task_metadata：cwd 从 files_in_context[0] 的父目录来，标题退回 taskId
    const bDir = join(root, 'tasks', 'task-b')
    makeDir(bDir)
    writeFixture(
      join(bDir, 'task_metadata.json'),
      JSON.stringify({ files_in_context: ['/Users/tester/meta-project/src/main.ts'] })
    )

    const items = await new ClineScanner({ storagePath: root }).scan()
    const byId = new Map(items.map((item) => [item.sessionId, item]))

    expect(byId.get('task-a')?.projectPath).toBe('/Users/tester/from-api-history')
    expect(byId.get('task-a')?.title).toBe('task-a')
    expect(byId.get('task-a')?.messageCount).toBe(2)
    expect(byId.get('task-a')?.snippet).toBe('task-a')

    expect(byId.get('task-b')?.projectPath).toBe('/Users/tester/meta-project/src')
    expect(byId.get('task-b')?.messageCount).toBe(0)
  })

  it('标题只取第一行，摘要取首条非空 text', async () => {
    const root = makeTempDir('cc-cline-title-')
    const dir = join(root, 'tasks', 'task-multi')
    makeDir(dir)
    writeFixture(
      join(dir, 'ui_messages.json'),
      JSON.stringify([{ ts: 1789000000000, say: 'text', text: 'first line\nsecond line' }])
    )
    const items = await new ClineScanner({ storagePath: root }).scan()
    expect(items[0]?.title).toBe('first line')
    expect(items[0]?.snippet).toBe('first line\nsecond line')
  })

  it('消息里的 workspace 字段作为 cwd 的第二兜底', async () => {
    const root = makeTempDir('cc-cline-workspace-')
    const dir = join(root, 'tasks', 'task-ws')
    makeDir(dir)
    writeFixture(
      join(dir, 'ui_messages.json'),
      JSON.stringify([
        { ts: 1789000000000, say: 'task', text: 'do it', workspace: '/Users/tester/workspace-dir' }
      ])
    )
    const items = await new ClineScanner({ storagePath: root }).scan()
    expect(items[0]?.projectPath).toBe('/Users/tester/workspace-dir')
  })
})

describe('ClineScanner · delete', () => {
  it('删任务目录与快照目录，并同步 taskHistory.json', async () => {
    const root = makeTempDir('cc-cline-delete-')
    buildClineFixture(root)
    const scanner = new ClineScanner({ storagePath: root })
    const items = await scanner.scan()
    const item1 = items.find((item) => item.sessionId === T1)
    expect(item1).toBeDefined()

    const freed = await scanner.delete([item1!])
    expect(freed).toBe(item1!.sizeInBytes)
    expect(existsSync(join(root, 'tasks', T1))).toBe(false)
    expect(existsSync(join(root, 'checkpoints', T1))).toBe(false)
    expect(existsSync(join(root, 'tasks', T2))).toBe(true)

    const historyText = readText(join(root, 'state', 'taskHistory.json'))
    expect(historyText).not.toContain(T1)
    expect(historyText).toContain(T2)

    const after = await scanner.scan()
    expect(after).toHaveLength(1)
    expect(after[0]?.sessionId).toBe(T2)
  })

  it('cleanFileHistorySnapshots 关闭时保留快照目录，并从释放量里扣掉它', async () => {
    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const root = makeTempDir('cc-cline-keep-snapshot-')
    buildClineFixture(root)
    const scanner = new ClineScanner({ storagePath: root })
    const items = await scanner.scan()
    const item1 = items.find((item) => item.sessionId === T1)!

    const freed = await scanner.delete([item1])
    expect(freed).toBe(item1.sizeInBytes - sizeOfPath(canon(join(root, 'checkpoints', T1))))
    expect(freed).toBeGreaterThan(0)
    expect(existsSync(join(root, 'tasks', T1))).toBe(false)
    expect(existsSync(join(root, 'checkpoints', T1, 'commit.dat'))).toBe(true)
  })

  it('cleanEmptyProjectFolders 打开时回收清空的 tasks 目录', async () => {
    const root = makeTempDir('cc-cline-reclaim-on-')
    buildClineFixture(root)
    const scanner = new ClineScanner({ storagePath: root })
    const items = await scanner.scan()
    await scanner.delete([items.find((item) => item.sessionId === T1)!])
    expect(existsSync(join(root, 'tasks'))).toBe(true)
    await scanner.delete([items.find((item) => item.sessionId === T2)!])
    expect(existsSync(join(root, 'tasks'))).toBe(false)
  })

  it('cleanEmptyProjectFolders 关闭时保留 tasks 目录', async () => {
    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    const root = makeTempDir('cc-cline-reclaim-off-')
    buildClineFixture(root)
    const scanner = new ClineScanner({ storagePath: root })
    const items = await scanner.scan()
    await scanner.delete(items)
    await expect(scanner.scan()).resolves.toEqual([])
    expect(existsSync(join(root, 'tasks'))).toBe(true)
  })

  it('空列表返回 0，taskHistory.json 原样不动', async () => {
    const root = makeTempDir('cc-cline-delete-none-')
    buildClineFixture(root)
    const historyPath = join(root, 'state', 'taskHistory.json')
    const before = readText(historyPath)
    const freed = await new ClineScanner({ storagePath: root }).delete([])
    expect(freed).toBe(0)
    expect(readText(historyPath)).toBe(before)
  })
})

describe('ClineScanner · cleanAll', () => {
  it('清空任务、清 cache、重建 checkpoints 目录并重置 taskHistory', async () => {
    const root = makeTempDir('cc-cline-cleanall-')
    buildClineFixture(root)
    const scanner = new ClineScanner({ storagePath: root })

    const freed = await scanner.cleanAll()
    expect(freed).toBeGreaterThan(0)
    await expect(scanner.scan()).resolves.toEqual([])

    // checkpoints 整目录删掉后重建为空目录
    const checkpointsDir = join(root, 'checkpoints')
    expect(existsSync(checkpointsDir)).toBe(true)
    expect(readdirSync(checkpointsDir)).toEqual([])

    // cache 同样删掉重建
    const cacheDir = join(root, 'cache')
    expect(existsSync(cacheDir)).toBe(true)
    expect(readdirSync(cacheDir)).toEqual([])

    expect(readText(join(root, 'state', 'taskHistory.json'))).toBe('[]\n')
    expect(existsSync(join(root, 'tasks'))).toBe(false)
  })

  it('cleanFileHistorySnapshots 关闭时整个 checkpoints 目录原样保留', async () => {
    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const root = makeTempDir('cc-cline-cleanall-keep-')
    buildClineFixture(root)
    const scanner = new ClineScanner({ storagePath: root })

    const freed = await scanner.cleanAll()
    expect(freed).toBeGreaterThan(0)
    expect(existsSync(join(root, 'checkpoints', T1, 'commit.dat'))).toBe(true)
    // cache 与任务索引照常清空
    expect(readdirSync(join(root, 'cache'))).toEqual([])
    expect(readText(join(root, 'state', 'taskHistory.json'))).toBe('[]\n')
    await expect(scanner.scan()).resolves.toEqual([])
  })

  it('cleanEmptyProjectFolders 关闭时 tasks 目录保留为空目录', async () => {
    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    const root = makeTempDir('cc-cline-cleanall-keep-tasks-')
    buildClineFixture(root)
    await new ClineScanner({ storagePath: root }).cleanAll()
    expect(existsSync(join(root, 'tasks'))).toBe(true)
    // 只剩那个「不是任务」的隐藏目录
    expect(readdirSync(join(root, 'tasks'))).toEqual(['.hidden-task'])
  })
})
