import { afterAll, beforeEach, describe, expect, it } from 'vitest'
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
import { DEFAULT_PREFS } from '@shared/types'
import type { ConversationItem } from '@shared/types'
import { CleanPrefs } from '@main/core/scanner'
import { AiderScanner } from './AiderScanner'

/**
 * 移植自 `scripts/tests/AiderTests.swift` 的 `testMockAiderScanner`
 * 与 `testRealAiderScannerReadOnly`，并补上 Swift 测试没覆盖到的分支
 * （全局会话、深度/跳过目录、`.aider.conf.yml` 护栏、两个开关的正反两面）。
 *
 * `HOME` 指向一个沙箱目录：Aider 的全局扫描与 `cleanAll` 都会去动 home 下的
 * `.aider.*` 文件，测试绝不能碰用户真实的 home，也绝不能把偏好写进
 * 真实的 `~/.conversation-clean/preferences.json`。
 */

const REAL_HOME = homedir()
const SANDBOX_HOME = realpathSync(mkdtempSync(join(tmpdir(), 'aiderhome')))
const ORIGINAL_HOME = process.env.HOME
const ORIGINAL_AIDER_HOME = process.env.AIDER_HOME
process.env.HOME = SANDBOX_HOME
delete process.env.AIDER_HOME

const created: string[] = []

function tempRoot(prefix = 'aider'): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), prefix)))
  created.push(dir)
  return dir
}

function write(path: string, content: string): string {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content, 'utf8')
  return path
}

function canonicalOrSelf(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

/** 只清沙箱 home 里的夹具，保留 `preferences.json`（`CleanPrefs` 的落盘位置）。 */
function resetSandboxHome(): void {
  for (const entry of readdirSync(SANDBOX_HOME)) {
    if (entry === 'preferences.json') continue
    rmSync(join(SANDBOX_HOME, entry), { recursive: true, force: true })
  }
}

/** 递归快照目录内容（相对路径 + mtimeMs + size），用来验证 `scan()` 一个字节都没写。 */
function snapshotTree(root: string): string[] {
  const out: string[] = []
  const walk = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const child = join(dir, entry.name)
      if (entry.isDirectory()) {
        out.push(`${child}/`)
        walk(child)
      } else {
        const stats = statSync(child)
        out.push(`${child}:${stats.size}:${stats.mtimeMs}`)
      }
    }
  }
  if (existsSync(root)) walk(root)
  return out.sort()
}

afterAll(() => {
  process.env.HOME = ORIGINAL_HOME
  if (ORIGINAL_AIDER_HOME === undefined) delete process.env.AIDER_HOME
  else process.env.AIDER_HOME = ORIGINAL_AIDER_HOME
  for (const dir of created) rmSync(dir, { recursive: true, force: true })
  rmSync(SANDBOX_HOME, { recursive: true, force: true })
})

beforeEach(() => {
  resetSandboxHome()
  CleanPrefs.patch({ ...DEFAULT_PREFS })
})

/** Swift `testMockAiderScanner` 的夹具：`projects/my-web-app` 里的 Aider 历史 + 配置文件 + 源码。 */
interface MockRoot {
  root: string
  projDir: string
  chat: string
  input: string
  tags: string
  conf: string
  source: string
}

function buildMockRoot(): MockRoot {
  const root = tempRoot()
  const projDir = join(root, 'projects', 'my-web-app')
  mkdirSync(projDir, { recursive: true })

  const chat = write(
    join(projDir, '.aider.chat.history.md'),
    '# aider chat started at 2026-09-20 10:00:00\n\n#### Add user authentication middleware with JWT tokens\n> Applied edit to Auth.swift\n'
  )
  const input = write(join(projDir, '.aider.input.history'), 'git status\nadd auth middleware\n')
  const tags = write(join(projDir, '.aider.tags.cache.v3'), 'ctags-cache-v3-binary-data')
  const conf = write(join(projDir, '.aider.conf.yml'), 'model: gpt-4o\nauto-commits: false\n')
  const source = write(join(projDir, 'App.swift'), 'import SwiftUI\nstruct App {}\n')

  return { root, projDir, chat, input, tags, conf, source }
}

describe('AiderScanner.storagePath', () => {
  it('默认指向 ~/.aider，AIDER_HOME 优先', () => {
    delete process.env.AIDER_HOME
    expect(new AiderScanner().storagePath).toBe(canonicalOrSelf(join(SANDBOX_HOME, '.aider')))

    const custom = tempRoot('aiderenv')
    process.env.AIDER_HOME = custom
    try {
      const scanner = new AiderScanner()
      expect(scanner.storagePath).toBe(custom)
      expect(scanner.isInstalled).toBe(true)
    } finally {
      delete process.env.AIDER_HOME
    }
  })

  it('isInstalled：存储目录不存在时，认 home 下的指示文件', async () => {
    const scanner = new AiderScanner()
    expect(scanner.isInstalled).toBe(false)
    expect(await scanner.scan()).toEqual([])
    expect(await scanner.cleanAll()).toBe(0)

    write(join(SANDBOX_HOME, '.aider.conf.yml'), 'model: gpt-4o\n')
    expect(new AiderScanner().isInstalled).toBe(true)
    // 只有配置文件的用户没有任何会话可扫（配置永不删、也不计入体积）
    expect(await new AiderScanner().scan()).toEqual([])
  })
})

describe('AiderScanner.scan 项目级', () => {
  it('夹具目录：只认 Aider 自己的文件，配置文件与源码一律不认', async () => {
    const { root, projDir, chat, input, tags, conf, source } = buildMockRoot()
    const scanner = new AiderScanner({ storagePath: root })
    expect(scanner.isInstalled).toBe(true)
    expect(scanner.category).toBe('aider')

    const before = snapshotTree(root)
    const items = await scanner.scan()
    expect(snapshotTree(root)).toEqual(before)

    // 注入的存储目录本身有内容，所以 Swift 还会额外产出一条「全局」会话
    expect(items.map((item) => item.sessionId)).toContain('aider-global')

    const item = items.find((entry) => entry.projectPath === projDir)
    expect(item).toBeDefined()
    expect(item!.title).toBe('Add user authentication middleware with JWT tokens')
    expect(item!.snippet).toBe('Add user authentication middleware with JWT tokens')
    // 聊天记录 2 条 + 输入历史 2 行
    expect(item!.messageCount).toBe(4)
    expect(item!.gitBranch).toBeNull()
    expect(item!.sessionId.startsWith('aider-my-web-app-')).toBe(true)
    expect(item!.sizeInBytes).toBe(
      statSync(chat).size + statSync(input).size + statSync(tags).size
    )
    expect(item!.associatedPaths).toEqual(expect.arrayContaining([chat, input, tags]))
    expect(item!.associatedPaths).not.toContain(conf)
    expect(item!.associatedPaths).not.toContain(source)
  })

  it('目录搜索：深度 3 以内命中，超过深度或在被跳过的目录里都不认', async () => {
    const root = tempRoot()
    // 深度 1（projects 本身）、2、3 命中
    write(join(root, 'projects', '.aider.input.history'), 'a\n')
    write(join(root, 'projects', 'level2', '.aider.input.history'), 'b\n')
    write(join(root, 'projects', 'l3', 'l4', '.aider.input.history'), 'c\n')
    // 深度 4：projects/l3/l4 已经是第 4 层，扫不到
    write(join(root, 'projects', 'l3', 'l4', 'l5', '.aider.input.history'), 'd\n')
    // node_modules 被跳过
    write(join(root, 'projects', 'pkg', 'node_modules', 'dep', '.aider.input.history'), 'e\n')
    // 隐藏目录被跳过
    write(join(root, 'projects', '.hidden', '.aider.input.history'), 'f\n')

    const items = await new AiderScanner({ storagePath: root }).scan()
    const projectPaths = items.map((item) => item.projectPath).filter((value) => value !== null)
    expect(projectPaths).toContain(join(root, 'projects'))
    expect(projectPaths).toContain(join(root, 'projects', 'level2'))
    expect(projectPaths).toContain(join(root, 'projects', 'l3', 'l4'))
    expect(projectPaths).not.toContain(join(root, 'projects', 'l3', 'l4', 'l5'))
    expect(projectPaths).not.toContain(join(root, 'projects', 'pkg', 'node_modules', 'dep'))
    expect(projectPaths).not.toContain(join(root, 'projects', '.hidden'))
  })

  it('没有聊天/输入记录时，标题与摘要回落到项目名与路径', async () => {
    const root = tempRoot()
    const projDir = join(root, 'projects', 'no-history')
    write(join(projDir, '.aider.tags.cache.v4'), 'cache')

    const items = await new AiderScanner({ storagePath: root }).scan()
    const item = items.find((entry) => entry.projectPath === projDir)
    expect(item?.title).toBe('Aider: no-history')
    expect(item?.snippet).toBe(`项目: ${projDir}`)
    expect(item?.messageCount).toBe(1)
  })

  it('聊天记录只读前 64KB，且 > 64KB 时按剩余体积粗估条数', async () => {
    const root = tempRoot()
    const projDir = join(root, 'projects', 'big')
    let content = '#### big file prompt\n'
    while (Buffer.byteLength(content) < 69632) content += 'x'
    content += '\n'
    const chat = write(join(projDir, '.aider.chat.history.md'), content)
    expect(statSync(chat).size).toBe(69633)

    const items = await new AiderScanner({ storagePath: root }).scan()
    const item = items.find((entry) => entry.projectPath === projDir)
    // 1 条真实 prompt + max(1, (69633-65536)/1024/4 → 0) = 2
    expect(item?.title).toBe('big file prompt')
    expect(item?.messageCount).toBe(2)
  })
})

describe('AiderScanner.scan 全局', () => {
  it('把 ~/.aider 目录 + home 下的三个全局文件合成一条 aider-global 会话', async () => {
    write(join(SANDBOX_HOME, '.aider.chat.history.md'), '#### global prompt\n> did something\n')
    write(join(SANDBOX_HOME, '.aider.input.history'), 'one\ntwo\nthree\n')
    write(join(SANDBOX_HOME, '.aider.tags.cache.v3'), 'v3')
    write(join(SANDBOX_HOME, '.aider.tags.cache.v4'), 'v4')
    const aiderDir = write(join(SANDBOX_HOME, '.aider', 'models.cache'), 'cached model data')

    const scanner = new AiderScanner()
    expect(scanner.isInstalled).toBe(true)
    const items = await scanner.scan()
    expect(items).toHaveLength(1)

    const item = items[0]!
    expect(item.sessionId).toBe('aider-global')
    expect(item.title).toBe('global prompt')
    expect(item.snippet).toBe('global prompt')
    expect(item.projectPath).toBe(SANDBOX_HOME)
    // 聊天 2 条 + 输入历史 3 行
    expect(item.messageCount).toBe(5)
    expect(item.associatedPaths).toEqual([
      join(SANDBOX_HOME, '.aider'),
      join(SANDBOX_HOME, '.aider.chat.history.md'),
      join(SANDBOX_HOME, '.aider.input.history'),
      join(SANDBOX_HOME, '.aider.tags.cache.v3'),
      join(SANDBOX_HOME, '.aider.tags.cache.v4')
    ])
    expect(item.sizeInBytes).toBe(
      statSync(aiderDir).size +
        statSync(join(SANDBOX_HOME, '.aider.chat.history.md')).size +
        statSync(join(SANDBOX_HOME, '.aider.input.history')).size +
        statSync(join(SANDBOX_HOME, '.aider.tags.cache.v3')).size +
        statSync(join(SANDBOX_HOME, '.aider.tags.cache.v4')).size
    )
  })

  it('删全局会话：三个全局文件与 ~/.aider 一起消失，配置文件保留', async () => {
    write(join(SANDBOX_HOME, '.aider.chat.history.md'), '#### global prompt\n')
    write(join(SANDBOX_HOME, '.aider.input.history'), 'one\n')
    write(join(SANDBOX_HOME, '.aider.conf.yml'), 'model: gpt-4o\n')
    const cached = write(join(SANDBOX_HOME, '.aider', 'models.cache'), 'cached model data')

    const scanner = new AiderScanner()
    const items = await scanner.scan()
    const freed = await scanner.delete(items)
    expect(freed).toBe(items[0]!.sizeInBytes)
    expect(existsSync(join(SANDBOX_HOME, '.aider'))).toBe(false)
    expect(existsSync(join(SANDBOX_HOME, '.aider.chat.history.md'))).toBe(false)
    expect(existsSync(join(SANDBOX_HOME, '.aider.input.history'))).toBe(false)
    expect(existsSync(cached)).toBe(false)
    expect(existsSync(join(SANDBOX_HOME, '.aider.conf.yml'))).toBe(true)
    expect(await scanner.scan()).toEqual([])
  })
})

describe('AiderScanner.delete', () => {
  it('项目会话：删掉三个 Aider 文件，配置与源码必须保留', async () => {
    const { root, projDir, chat, input, tags, conf, source } = buildMockRoot()
    const scanner = new AiderScanner({ storagePath: root })

    const items = await scanner.scan()
    const item = items.find((entry) => entry.projectPath === projDir)!
    const freed = await scanner.delete([item])
    expect(freed).toBe(item.sizeInBytes)
    expect(existsSync(chat)).toBe(false)
    expect(existsSync(input)).toBe(false)
    expect(existsSync(tags)).toBe(false)
    expect(existsSync(conf)).toBe(true)
    expect(existsSync(source)).toBe(true)

    expect(await scanner.delete([])).toBe(0)
  })

  it('护栏：存储目录之外的路径，只有 Aider 自己的文件名会被删', async () => {
    const { root, projDir } = buildMockRoot()
    const outside = tempRoot('aideroutside')
    const chat = write(join(outside, '.aider.chat.history.md'), '#### outside prompt\n')
    const conf = write(join(outside, '.aider.conf.yml'), 'model: gpt-4o\n')
    const source = write(join(outside, 'App.swift'), 'import SwiftUI\n')

    const scanner = new AiderScanner({ storagePath: root })
    const item = (await scanner.scan()).find((entry) => entry.projectPath === projDir)!
    const poisoned: ConversationItem = {
      ...item,
      associatedPaths: [chat, conf, source]
    }
    const freed = await scanner.delete([poisoned])
    // 记账仍按 `sizeInBytes`（Swift 也是先记账再逐条过滤）
    expect(freed).toBe(poisoned.sizeInBytes)
    expect(existsSync(chat)).toBe(false)
    expect(existsSync(conf)).toBe(true)
    expect(existsSync(source)).toBe(true)
  })

  it('已知怪癖：存储目录之内的任意文件名都算可删（Swift 的前缀比较，照抄）', async () => {
    const { root, projDir } = buildMockRoot()
    // 项目目录就在注入的存储目录之下，所以 Swift 的「Inside ~/.aider 就安全」规则
    // 会放行这里的普通源码文件 —— 真实运行时这些路径不会进 associatedPaths，
    // 但这个规则本身的宽松性要照抄。
    const notes = write(join(projDir, 'NOTES.md'), 'notes\n')
    const scanner = new AiderScanner({ storagePath: root })
    const item = (await scanner.scan()).find((entry) => entry.projectPath === projDir)!
    await scanner.delete([{ ...item, associatedPaths: [notes] }])
    expect(existsSync(notes)).toBe(false)
  })

  it('cleanEmptyProjectFolders 开关对 Aider 无影响：两个分支都不回收项目目录', async () => {
    for (const enabled of [true, false]) {
      CleanPrefs.patch({ cleanEmptyProjectFolders: enabled })
      const { root, projDir, chat } = buildMockRoot()
      const scanner = new AiderScanner({ storagePath: root })
      const items = await scanner.scan()
      await scanner.delete(items.filter((item) => item.projectPath === projDir))
      expect(existsSync(chat)).toBe(false)
      expect(existsSync(projDir)).toBe(true)
    }
  })

  it('cleanFileHistorySnapshots 关：路径落在快照目录名下时整条不删、不计释放量', async () => {
    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const base = tempRoot('aidercheck')
    const root = join(base, 'checkpoints')
    const chat = write(join(root, 'projects', 'app', '.aider.chat.history.md'), '#### hi\n')

    const scanner = new AiderScanner({ storagePath: root })
    const items = await scanner.scan()
    const item = items.find((entry) => entry.projectPath === join(root, 'projects', 'app'))!
    expect(await scanner.delete([item])).toBe(0)
    expect(existsSync(chat)).toBe(true)
  })

  it('cleanFileHistorySnapshots 开：同样夹具照删不误', async () => {
    CleanPrefs.patch({ cleanFileHistorySnapshots: true })
    const base = tempRoot('aidercheck')
    const root = join(base, 'checkpoints')
    const chat = write(join(root, 'projects', 'app', '.aider.chat.history.md'), '#### hi\n')

    const scanner = new AiderScanner({ storagePath: root })
    const items = await scanner.scan()
    const item = items.find((entry) => entry.projectPath === join(root, 'projects', 'app'))!
    expect(await scanner.delete([item])).toBe(item.sizeInBytes)
    expect(existsSync(chat)).toBe(false)
  })
})

describe('AiderScanner.cleanAll', () => {
  it('清空 ~/.aider（重建空目录）与 home 下的全局文件，配置保留', async () => {
    // `~/.aider` 里只放隐藏文件：`sizeOf` 跳过隐藏项 → 全局会话不会诞生，
    // 于是 cleanAll 里 `~/.aider` 还存在 → 删掉后被重建
    write(join(SANDBOX_HOME, '.aider', '.models.cache'), 'cached model data')
    write(join(SANDBOX_HOME, '.aider.chat.history.md'), '#### global prompt\n')
    write(join(SANDBOX_HOME, '.aider.input.history'), 'one\n')
    write(join(SANDBOX_HOME, '.aider.tags.cache.v3'), 'v3')
    write(join(SANDBOX_HOME, '.aider.conf.yml'), 'model: gpt-4o\n')
    write(join(SANDBOX_HOME, 'projects', 'app', '.aider.input.history'), 'cmd\n')

    const scanner = new AiderScanner()
    const freed = await scanner.cleanAll()
    expect(freed).toBeGreaterThan(0)

    expect(existsSync(join(SANDBOX_HOME, '.aider'))).toBe(true)
    expect(readdirSync(join(SANDBOX_HOME, '.aider'))).toEqual([])
    expect(existsSync(join(SANDBOX_HOME, '.aider.chat.history.md'))).toBe(false)
    expect(existsSync(join(SANDBOX_HOME, '.aider.input.history'))).toBe(false)
    expect(existsSync(join(SANDBOX_HOME, '.aider.tags.cache.v3'))).toBe(false)
    expect(existsSync(join(SANDBOX_HOME, '.aider.conf.yml'))).toBe(true)
    // ~/projects 里的项目级历史也会被扫到并删掉
    expect(existsSync(join(SANDBOX_HOME, 'projects', 'app', '.aider.input.history'))).toBe(false)
    expect(await scanner.scan()).toEqual([])
  })

  it('已知行为：`~/.aider` 有内容时它自己就在 associatedPaths 里，cleanAll 不会再重建', async () => {
    write(join(SANDBOX_HOME, '.aider', 'cache.bin'), 'non hidden so sizeOf counts it')
    const scanner = new AiderScanner()
    expect((await scanner.scan()).some((item) => item.sessionId === 'aider-global')).toBe(true)

    expect(await scanner.cleanAll()).toBeGreaterThan(0)
    expect(existsSync(join(SANDBOX_HOME, '.aider'))).toBe(false)
    expect(await scanner.scan()).toEqual([])
  })
})

describe('AiderScanner 本机真实目录（只读）', () => {
  it.skipIf(
    !existsSync(join(REAL_HOME, '.aider')) &&
      !existsSync(join(REAL_HOME, '.aider.conf.yml')) &&
      !existsSync(join(REAL_HOME, '.aider.input.history')) &&
      !existsSync(join(REAL_HOME, '.aider.chat.history.md')) &&
      !existsSync(join(REAL_HOME, '.aider.tags.cache.v3'))
  )('扫描本机 Aider 目录不抛错且不修改任何文件', async () => {
    process.env.HOME = REAL_HOME
    try {
      const scanner = new AiderScanner()
      const before = existsSync(scanner.storagePath) ? snapshotTree(scanner.storagePath) : []
      const items = await scanner.scan()
      expect(Array.isArray(items)).toBe(true)
      if (existsSync(scanner.storagePath)) {
        expect(snapshotTree(scanner.storagePath)).toEqual(before)
      }
      for (const item of items) {
        expect(item.category).toBe('aider')
        expect(item.sessionId.length).toBeGreaterThan(0)
        expect(item.associatedPaths.length).toBeGreaterThan(0)
        expect(Number.isNaN(Date.parse(item.updatedAt))).toBe(false)
      }
      const times = items.map((item) => Date.parse(item.updatedAt))
      expect([...times].sort((a, b) => b - a)).toEqual(times)
    } finally {
      process.env.HOME = SANDBOX_HOME
    }
  })
})
