import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import { CleanPrefs } from '@main/core/prefs'
import { sizeOfPath } from '@main/core/scanner'
import { RooCodeScanner } from './RooCodeScanner'

/**
 * RooCodeScanner 的移植验收用例。
 *
 * 验收标准来自 `scripts/tests/RooContinueTests.swift`（MockRooCodeScan）：
 * 1 个任务、分类 `.rooCode`、标题取 `say == "task"` 的 text、
 * cwd 从正文里的 `Current Working Directory (...)` 抠出、messageCount、删除后重扫为空。
 * 另外补上 Swift 用例没覆盖但端口必须保证的：Roo 自己的环境变量 / 默认目录、
 * taskHistory 索引同步、两个开关的相反分支。
 *
 * 本文件自包含：`$HOME` 指向一次性临时目录，夹具全部在 `os.tmpdir()` 下现场造。
 */

const FAKE_HOME = mkdtempSync(join(tmpdir(), 'cc-roo-home-'))
const REAL_HOME = process.env.HOME
process.env.HOME = FAKE_HOME

// `CLINE_HOME` 也列进来：它是 Cline 的环境变量，**不该**影响 Roo Code。
const ENV_KEYS = ['ROO_CODE_HOME', 'CLINE_HOME'] as const
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

const ROO_TASK = 'roo-task-001'

/** 复刻 `RooContinueTests.swift` 的 Roo Code 夹具（多了 checkpoints / taskHistory / cache）。 */
function buildRooFixture(root: string, options: { withCheckpoints?: boolean } = {}): void {
  const tasksDir = join(root, 'tasks')
  const stateDir = join(root, 'state')
  makeDir(tasksDir)
  makeDir(stateDir)
  makeDir(join(root, 'cache'))

  const taskDir = join(tasksDir, ROO_TASK)
  makeDir(taskDir)
  writeFixture(
    join(taskDir, 'ui_messages.json'),
    JSON.stringify([
      { ts: 1789200000000, type: 'say', say: 'task', text: 'Migrate database schema to PostgreSQL' },
      {
        ts: 1789200005000,
        type: 'say',
        say: 'text',
        text: 'Generated migrations in # Current Working Directory (/Users/tester/data-store) Files'
      }
    ])
  )

  if (options.withCheckpoints) {
    const cpDir = join(root, 'checkpoints', ROO_TASK)
    makeDir(cpDir)
    writeFixture(join(cpDir, 'snapshot.txt'), 'roo checkpoint payload')
  }

  writeFixture(
    join(stateDir, 'taskHistory.json'),
    JSON.stringify([
      { id: ROO_TASK, task: 'Migrate database schema to PostgreSQL', ts: 1789200005000, size: 777 }
    ])
  )
  writeFixture(join(root, 'cache', 'models.json'), 'roo cache')
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

describe('RooCodeScanner · storagePath / isInstalled', () => {
  it('默认指向 roo-cline 扩展目录', () => {
    expect(new RooCodeScanner().storagePath).toBe(
      join(
        FAKE_HOME,
        'Library',
        'Application Support',
        'Code',
        'User',
        'globalStorage',
        'rooveterinaryinc.roo-cline'
      )
    )
  })

  it('ROO_CODE_HOME 覆盖默认目录，并做 realpath 规范化', () => {
    const envRoot = makeTempDir('cc-roo-env-')
    process.env.ROO_CODE_HOME = envRoot
    expect(new RooCodeScanner().storagePath).toBe(canon(envRoot))
  })

  it('CLINE_HOME 不影响 Roo Code 的目录解析', () => {
    const clineRoot = makeTempDir('cc-roo-wrong-env-')
    process.env.CLINE_HOME = clineRoot
    expect(new RooCodeScanner().storagePath).toBe(
      join(
        FAKE_HOME,
        'Library',
        'Application Support',
        'Code',
        'User',
        'globalStorage',
        'rooveterinaryinc.roo-cline'
      )
    )
  })

  it('注入的 storagePath 优先于环境变量', () => {
    const envRoot = makeTempDir('cc-roo-env-')
    const injected = makeTempDir('cc-roo-injected-')
    process.env.ROO_CODE_HOME = envRoot
    expect(new RooCodeScanner({ storagePath: injected }).storagePath).toBe(canon(injected))
  })

  it('目录不存在时 isInstalled 为 false，scan() 返回空数组', async () => {
    const missing = join(makeTempDir('cc-roo-missing-'), 'not-there')
    const scanner = new RooCodeScanner({ storagePath: missing })
    expect(scanner.isInstalled).toBe(false)
    await expect(scanner.scan()).resolves.toEqual([])
  })

  it('目录存在但没有 tasks 目录时返回空数组', async () => {
    const root = makeTempDir('cc-roo-empty-')
    makeDir(join(root, 'state'))
    const scanner = new RooCodeScanner({ storagePath: root })
    expect(scanner.isInstalled).toBe(true)
    await expect(scanner.scan()).resolves.toEqual([])
  })
})

describe('RooCodeScanner · scan（对应 RooContinueTests.swift 的 MockRooCodeScan）', () => {
  it('解析任务、抠出 cwd、带上快照目录', async () => {
    const root = makeTempDir('cc-roo-scan-')
    buildRooFixture(root)
    const scanner = new RooCodeScanner({ storagePath: root })

    expect(scanner.category).toBe('rooCode')
    expect(scanner.isInstalled).toBe(true)

    const items = await scanner.scan()
    expect(items).toHaveLength(1)
    const item = items[0]!
    expect(item.category).toBe('rooCode')
    expect(item.sessionId).toBe(ROO_TASK)
    expect(item.title).toBe('Migrate database schema to PostgreSQL')
    expect(item.projectPath).toBe('/Users/tester/data-store')
    expect(item.messageCount).toBe(2)
    expect(item.gitBranch).toBeNull()
    expect(item.updatedAt).toBe(new Date(1789200005000).toISOString())
    expect(item.associatedPaths).toEqual([canon(join(root, 'tasks', ROO_TASK))])
    expect(item.sizeInBytes).toBe(sizeOfPath(canon(join(root, 'tasks', ROO_TASK))))

    // taskHistory 里有条目时的体积兜底（本例目录非空，用不到）
    expect(item.sizeInBytes).toBeGreaterThan(0)
  })

  it('存在 checkpoints/<taskId> 时进 associatedPaths 并计入体积', async () => {
    const root = makeTempDir('cc-roo-scan-cp-')
    buildRooFixture(root, { withCheckpoints: true })
    const items = await new RooCodeScanner({ storagePath: root }).scan()
    const taskDir = canon(join(root, 'tasks', ROO_TASK))
    const cpDir = canon(join(root, 'checkpoints', ROO_TASK))
    expect(new Set(items[0]!.associatedPaths)).toEqual(new Set([taskDir, cpDir]))
    expect(items[0]!.sizeInBytes).toBe(sizeOfPath(taskDir) + sizeOfPath(cpDir))
  })
})

describe('RooCodeScanner · delete', () => {
  it('删任务目录、同步 taskHistory.json，重扫为空', async () => {
    const root = makeTempDir('cc-roo-delete-')
    buildRooFixture(root)
    const scanner = new RooCodeScanner({ storagePath: root })
    const items = await scanner.scan()

    const freed = await scanner.delete(items)
    expect(freed).toBe(items[0]!.sizeInBytes)
    expect(freed).toBeGreaterThan(0)
    expect(existsSync(join(root, 'tasks', ROO_TASK))).toBe(false)
    expect(readText(join(root, 'state', 'taskHistory.json'))).not.toContain(ROO_TASK)
    await expect(scanner.scan()).resolves.toEqual([])
  })

  it('cleanFileHistorySnapshots 关闭时保留 checkpoints/<taskId>', async () => {
    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const root = makeTempDir('cc-roo-keep-snapshot-')
    buildRooFixture(root, { withCheckpoints: true })
    const scanner = new RooCodeScanner({ storagePath: root })
    const items = await scanner.scan()
    const cpDir = canon(join(root, 'checkpoints', ROO_TASK))

    const freed = await scanner.delete(items)
    expect(freed).toBe(items[0]!.sizeInBytes - sizeOfPath(cpDir))
    expect(existsSync(join(root, 'tasks', ROO_TASK))).toBe(false)
    expect(existsSync(join(root, 'checkpoints', ROO_TASK, 'snapshot.txt'))).toBe(true)
  })

  it('cleanEmptyProjectFolders 打开时回收 tasks 目录，关闭时保留', async () => {
    const on = makeTempDir('cc-roo-reclaim-on-')
    buildRooFixture(on)
    const onItems = await new RooCodeScanner({ storagePath: on }).scan()
    await new RooCodeScanner({ storagePath: on }).delete(onItems)
    expect(existsSync(join(on, 'tasks'))).toBe(false)

    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    const off = makeTempDir('cc-roo-reclaim-off-')
    buildRooFixture(off)
    const offItems = await new RooCodeScanner({ storagePath: off }).scan()
    await new RooCodeScanner({ storagePath: off }).delete(offItems)
    expect(existsSync(join(off, 'tasks'))).toBe(true)
  })

  it('空列表返回 0，taskHistory.json 原样不动', async () => {
    const root = makeTempDir('cc-roo-delete-none-')
    buildRooFixture(root)
    const historyPath = join(root, 'state', 'taskHistory.json')
    const before = readText(historyPath)
    const freed = await new RooCodeScanner({ storagePath: root }).delete([])
    expect(freed).toBe(0)
    expect(readText(historyPath)).toBe(before)
  })
})

describe('RooCodeScanner · cleanAll', () => {
  it('清空任务、清 cache、整目录重建 checkpoints 并重置索引', async () => {
    const root = makeTempDir('cc-roo-cleanall-')
    buildRooFixture(root, { withCheckpoints: true })
    const scanner = new RooCodeScanner({ storagePath: root })

    const freed = await scanner.cleanAll()
    expect(freed).toBeGreaterThan(0)
    await expect(scanner.scan()).resolves.toEqual([])

    expect(existsSync(join(root, 'checkpoints'))).toBe(true)
    expect(readdirSync(join(root, 'checkpoints'))).toEqual([])
    expect(existsSync(join(root, 'cache'))).toBe(true)
    expect(readdirSync(join(root, 'cache'))).toEqual([])
    expect(readText(join(root, 'state', 'taskHistory.json'))).toBe('[]\n')
    expect(existsSync(join(root, 'tasks'))).toBe(false)
  })

  it('cleanFileHistorySnapshots 关闭时 checkpoints 原样保留', async () => {
    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const root = makeTempDir('cc-roo-cleanall-keep-')
    buildRooFixture(root, { withCheckpoints: true })
    const freed = await new RooCodeScanner({ storagePath: root }).cleanAll()

    expect(freed).toBeGreaterThan(0)
    expect(existsSync(join(root, 'checkpoints', ROO_TASK, 'snapshot.txt'))).toBe(true)
    expect(readText(join(root, 'state', 'taskHistory.json'))).toBe('[]\n')
    await expect(new RooCodeScanner({ storagePath: root }).scan()).resolves.toEqual([])
  })

  it('cleanEmptyProjectFolders 关闭时 tasks 目录保留', async () => {
    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    const root = makeTempDir('cc-roo-cleanall-keep-tasks-')
    buildRooFixture(root)
    await new RooCodeScanner({ storagePath: root }).cleanAll()
    expect(existsSync(join(root, 'tasks'))).toBe(true)
    expect(readdirSync(join(root, 'tasks'))).toEqual([])
  })
})
