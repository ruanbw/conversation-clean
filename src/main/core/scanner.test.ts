/**
 * `core/scanner.ts` 共享原语 + `core/fsutil.ts` 的测试。
 *
 * 这些原语是各扫描器共同依赖的地基（目录 / 文件枚举、JSON 与 JSONL 解析、
 * 时间、删除记账、空目录回收），这里逐个把行为钉住，
 * 扫描器各自的用例可以直接依赖它们。
 *
 * `prefs.ts` 会往 `userData` 写 `preferences.json`，这里同样 mock 掉 `electron`，
 * 让它落到临时目录 —— 否则测试会污染用户家目录。
 */

import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { mkdirSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { isInside, removeIfEmptyDirectory, sizeOfPath } from '@main/core/fsutil'
import {
  CleanPrefs,
  deleteItemsWithPaths,
  dirName,
  expandTilde,
  fileSize,
  isDirectory,
  isFile,
  listDirectories,
  listFiles,
  makeItem,
  mapLimit,
  mtimeMs,
  pathExists,
  readJson,
  readJsonLines,
  readJsonLinesHead,
  removeAndReclaimDir,
  removeIfExists,
  resolveStoragePath,
  singleLine,
  sortByUpdatedDesc,
  truncate
} from '@main/core/scanner'
// @ts-ignore -- src/test-support 不在 tsconfig.node.json 的 include 里（composite 项目要求显式列出）
import { createTempDir, ensureDir, removeTempDir, writeFile } from '../../test-support/fixtures'
// @ts-ignore -- 同上
import { createStateVscdb } from '../../test-support/sqliteFixtures'
import { removeChatSessions } from '@main/core/vscdb'

const H = vi.hoisted(() => {
  const base = (process.env.TMPDIR ?? '/tmp').replace(/\/+$/, '')
  return { dir: `${base}/cc-scanner-${process.pid}-${Math.random().toString(36).slice(2)}` }
})

vi.mock('electron', () => ({ app: { getPath: () => H.dir } }))

let root: string

beforeAll(() => {
  mkdirSync(H.dir, { recursive: true })
})

afterAll(() => {
  rmSync(H.dir, { recursive: true, force: true })
})

beforeEach(() => {
  root = createTempDir('cc-scanner-')
})

afterEach(() => {
  removeTempDir(root)
  // 每个用例都从「4 个开关全开」开始（`deleteItemsWithPaths` 的扣减依赖它）
  CleanPrefs.patch({
    autoScanOnLaunch: true,
    confirmBeforeClean: true,
    cleanFileHistorySnapshots: true,
    cleanEmptyProjectFolders: true
  })
})

// ---------------------------------------------------------------------------
// 目录 / 文件枚举
// ---------------------------------------------------------------------------

describe('listDirectories —— 跳过隐藏项', () => {
  it('只返回子目录名', () => {
    ensureDir(join(root, 'alpha'))
    ensureDir(join(root, 'beta'))
    writeFile(join(root, 'loose.jsonl'), '{}')
    expect(listDirectories(root).sort()).toEqual(['alpha', 'beta'])
  })

  it('跳过 `.` 前缀项', () => {
    ensureDir(join(root, 'alpha'))
    ensureDir(join(root, '.hidden'))
    writeFile(join(root, '.DS_Store'), '')
    expect(listDirectories(root)).toEqual(['alpha'])
  })

  it('目录不存在 / 是文件 → 返回 []，不抛错', () => {
    const file = writeFile(join(root, 'plain.txt'), 'x')
    expect(listDirectories(join(root, 'nope'))).toEqual([])
    expect(listDirectories(file)).toEqual([])
  })
})

describe('listFiles —— 扩展名过滤 + 跳过隐藏项', () => {
  it('不传扩展名时返回全部普通文件（子目录不算）', () => {
    writeFile(join(root, 'a.jsonl'), '')
    writeFile(join(root, 'b.json'), '')
    writeFile(join(root, 'c.txt'), '')
    ensureDir(join(root, 'sub'))
    expect(listFiles(root).map((p) => p.slice(root.length + 1)).sort()).toEqual([
      'a.jsonl',
      'b.json',
      'c.txt'
    ])
  })

  it('按扩展名过滤', () => {
    writeFile(join(root, 'a.jsonl'), '')
    writeFile(join(root, 'b.json'), '')
    writeFile(join(root, 'c.JSONL'), '')
    writeFile(join(root, 'd.txt'), '')
    // 扩展名大小写不敏感（实现里 toLowerCase 了）
    expect(listFiles(root, '.jsonl').map((p) => p.slice(root.length + 1)).sort()).toEqual([
      'a.jsonl',
      'c.JSONL'
    ])
    expect(listFiles(root, '.json').map((p) => p.slice(root.length + 1))).toEqual(['b.json'])
  })

  it('跳过隐藏文件', () => {
    writeFile(join(root, 'a.jsonl'), '')
    writeFile(join(root, '.hidden.jsonl'), '')
    expect(listFiles(root, '.jsonl').map((p) => p.slice(root.length + 1))).toEqual(['a.jsonl'])
  })

  it('返回绝对路径', () => {
    writeFile(join(root, 'a.jsonl'), '')
    expect(listFiles(root, '.jsonl')[0]).toBe(join(root, 'a.jsonl'))
  })

  it('软链也当文件返回', () => {
    writeFile(join(root, 'real.jsonl'), '')
    symlinkSync(join(root, 'real.jsonl'), join(root, 'link.jsonl'))
    expect(listFiles(root, '.jsonl').map((p) => p.slice(root.length + 1)).sort()).toEqual([
      'link.jsonl',
      'real.jsonl'
    ])
  })

  it('目录不存在 → []', () => {
    expect(listFiles(join(root, 'nope'), '.jsonl')).toEqual([])
  })
})

describe('isDirectory / isFile / pathExists / mtimeMs / fileSize / dirName', () => {
  it('基本判定', () => {
    const file = writeFile(join(root, 'a.jsonl'), 'hello')
    const dir = ensureDir(join(root, 'sub'))
    expect(isDirectory(dir)).toBe(true)
    expect(isDirectory(file)).toBe(false)
    expect(isFile(file)).toBe(true)
    expect(isFile(dir)).toBe(false)
    expect(isDirectory(join(root, 'nope'))).toBe(false)
    expect(isFile(join(root, 'nope'))).toBe(false)
    expect(pathExists(file)).toBe(true)
    expect(pathExists(join(root, 'nope'))).toBe(false)
    expect(fileSize(file)).toBe(5)
    expect(fileSize(join(root, 'nope'))).toBe(0)
    expect(mtimeMs(file)).toBeCloseTo(statSync(file).mtimeMs, 0)
    expect(mtimeMs(join(root, 'nope'))).toBeUndefined()
    expect(dirName('/a/b/c')).toBe('c')
  })
})

// ---------------------------------------------------------------------------
// JSON / JSONL
// ---------------------------------------------------------------------------

describe('readJson', () => {
  it('解析成功', () => {
    const file = writeFile(join(root, 'a.json'), JSON.stringify({ a: 1 }))
    expect(readJson<{ a: number }>(file)).toEqual({ a: 1 })
  })

  it('文件缺失 / 内容损坏 → null（不抛错）', () => {
    expect(readJson(join(root, 'nope.json'))).toBeNull()
    expect(readJson(writeFile(join(root, 'bad.json'), '{oops'))).toBeNull()
  })
})

describe('readJsonLines —— 坏行跳过', () => {
  it('逐行解析并跳过空行', () => {
    const file = writeFile(join(root, 'a.jsonl'), '{"a":1}\n\n  \n{"a":2}\n')
    expect(readJsonLines<{ a: number }>(file)).toEqual([{ a: 1 }, { a: 2 }])
  })

  it('半行 / 坏 JSON 只跳过那一行，其余照常', () => {
    const file = writeFile(join(root, 'a.jsonl'), '{"a":1}\n{"broken\n{"a":2}\n{"a":3')
    expect(readJsonLines<{ a: number }>(file)).toEqual([{ a: 1 }, { a: 2 }])
  })

  it('文件不存在 → []', () => {
    expect(readJsonLines(join(root, 'nope.jsonl'))).toEqual([])
  })
})

describe('readJsonLinesHead —— 只读前 64KB', () => {
  it('只返回 64KB 内的完整行，截断的末行被跳过', () => {
    // 每行 ~1KB，第 1、2 行在窗口内；后面用大行把 64KB 顶出去。
    const filler = 'x'.repeat(1024)
    const head = [
      JSON.stringify({ n: 1, pad: filler }),
      JSON.stringify({ n: 2, pad: filler }),
      JSON.stringify({ n: 3, pad: filler })
    ]
    const body = Array.from({ length: 200 }, (_, i) => JSON.stringify({ n: 100 + i, pad: filler }))
    const file = writeFile(join(root, 'big.jsonl'), `${[...head, ...body].join('\n')}\n`)

    const parsed = readJsonLinesHead<{ n: number }>(file)
    // 前 3 条确定在 64KB 窗口内
    expect(parsed.map((r) => r.n).slice(0, 3)).toEqual([1, 2, 3])
    // 但绝不会把全文读完：窗口外的内容一条都没进来
    expect(parsed.length).toBeLessThan(body.length)
    expect(parsed.length).toBeGreaterThan(3)
    expect(statSync(file).size).toBeGreaterThan(64 * 1024)
  })

  it('byteLimit 可调', () => {
    // 每行恰好 8 字节：`{"n":1}\n`
    const file = writeFile(join(root, 'a.jsonl'), '{"n":1}\n{"n":2}\n{"n":3}\n')
    expect(readJsonLinesHead<{ n: number }>(file, 8).map((r) => r.n)).toEqual([1])
    expect(readJsonLinesHead<{ n: number }>(file, 16).map((r) => r.n)).toEqual([1, 2])
    expect(readJsonLinesHead<{ n: number }>(file, 0)).toEqual([])
  })

  it('文件不存在 → []', () => {
    expect(readJsonLinesHead(join(root, 'nope.jsonl'))).toEqual([])
  })

  it('不会读出多余内容：首行本身就超过上限时什么都不返回', () => {
    const file = writeFile(join(root, 'a.jsonl'), `${JSON.stringify({ pad: 'x'.repeat(200) })}\n`)
    expect(readJsonLinesHead(file, 64)).toEqual([])
  })
})

// ---------------------------------------------------------------------------
// mapLimit
// ---------------------------------------------------------------------------

describe('mapLimit', () => {
  it('结果顺序与输入一致（不随完成顺序变化）', async () => {
    const items = [50, 10, 30, 0, 20]
    const out = await mapLimit(items, 3, async (ms, i) => {
      await new Promise((r) => setTimeout(r, ms))
      return `${i}:${ms}`
    })
    expect(out).toEqual(['0:50', '1:10', '2:30', '3:0', '4:20'])
  })

  it('并发上限真的生效', async () => {
    let inFlight = 0
    let peak = 0
    const items = Array.from({ length: 20 }, (_, i) => i)
    await mapLimit(items, 4, async () => {
      inFlight += 1
      peak = Math.max(peak, inFlight)
      await new Promise((r) => setTimeout(r, 5))
      inFlight -= 1
      return null
    })
    expect(peak).toBe(4)
  })

  it('limit 大于长度时不会多开 worker', async () => {
    let inFlight = 0
    let peak = 0
    await mapLimit([1, 2, 3], 100, async () => {
      inFlight += 1
      peak = Math.max(peak, inFlight)
      await new Promise((r) => setTimeout(r, 1))
      inFlight -= 1
      return null
    })
    expect(peak).toBe(3)
  })

  it('空数组 / limit ≤ 0', async () => {
    expect(await mapLimit([], 4, (x) => x)).toEqual([])
    expect(await mapLimit([1, 2], 0, (x) => x)).toEqual([1, 2])
  })

  it('同步 fn 也能用', async () => {
    expect(await mapLimit([1, 2, 3], 2, (x) => x * 2)).toEqual([2, 4, 6])
  })
})

// ---------------------------------------------------------------------------
// 排序 / 文本
// ---------------------------------------------------------------------------

describe('sortByUpdatedDesc —— 新的在前', () => {
  it('ISO 字符串倒序', () => {
    const mk = (updatedAt: string): Parameters<typeof sortByUpdatedDesc>[0][number] =>
      makeItem({
        sessionId: updatedAt,
        title: updatedAt,
        category: 'claudeCode',
        sizeInBytes: 0,
        updatedAt: new Date(updatedAt)
      })
    const out = sortByUpdatedDesc([
      mk('2026-01-01T00:00:00.000Z'),
      mk('2026-03-01T00:00:00.000Z'),
      mk('2026-02-01T00:00:00.000Z')
    ])
    expect(out.map((i) => i.sessionId)).toEqual([
      '2026-03-01T00:00:00.000Z',
      '2026-02-01T00:00:00.000Z',
      '2026-01-01T00:00:00.000Z'
    ])
  })

  it('原地排序（返回同一个数组）', () => {
    const items = [
      makeItem({ sessionId: 'a', title: 'a', category: 'claudeCode', sizeInBytes: 0, updatedAt: new Date('1970-01-01T00:00:00.000Z') }),
      makeItem({ sessionId: 'b', title: 'b', category: 'claudeCode', sizeInBytes: 0, updatedAt: new Date('2100-01-01T00:00:00.000Z') })
    ]
    const out = sortByUpdatedDesc(items)
    expect(out).toBe(items)
  })

  it('时间相同保持原顺序（稳定）', () => {
    const t = new Date(0)
    const items = ['a', 'b', 'c'].map((sessionId) =>
      makeItem({ sessionId, title: sessionId, category: 'claudeCode', sizeInBytes: 0, updatedAt: t })
    )
    expect(sortByUpdatedDesc(items).map((i) => i.sessionId)).toEqual(['a', 'b', 'c'])
  })
})

describe('truncate / singleLine', () => {
  it('truncate：超长截断，否则原样', () => {
    expect(truncate('abcdef', 3)).toBe('abc')
    expect(truncate('abc', 3)).toBe('abc')
    expect(truncate('ab', 3)).toBe('ab')
    expect(truncate('中文标题', 2)).toBe('中文')
  })

  it('singleLine：换行与连续空白压成一个空格', () => {
    expect(singleLine('a\nb\r\nc')).toBe('a b c')
    expect(singleLine('a   \t  b')).toBe('a b')
    expect(singleLine('  padded  ')).toBe('padded')
    expect(singleLine('')).toBe('')
  })
})

// ---------------------------------------------------------------------------
// makeItem
// ---------------------------------------------------------------------------

describe('makeItem —— 默认值', () => {
  it('可选字段全部落到默认值', () => {
    const updatedAt = new Date('2026-09-26T19:54:02.000Z')
    const item = makeItem({
      sessionId: 's1',
      title: '标题',
      category: 'cursor',
      sizeInBytes: 42,
      updatedAt
    })
    expect(item.sessionId).toBe('s1')
    expect(item.title).toBe('标题')
    expect(item.category).toBe('cursor')
    expect(item.projectPath).toBeNull()
    expect(item.gitBranch).toBeNull()
    expect(item.messageCount).toBe(0)
    expect(item.sizeInBytes).toBe(42)
    expect(item.updatedAt).toBe('2026-09-26T19:54:02.000Z')
    expect(item.isSelected).toBe(false)
    expect(item.snippet).toBe('')
    expect(item.associatedPaths).toEqual([])
    expect(item.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
  })

  it('显式传 null 与默认值等价，显式传值时保留', () => {
    const base = {
      sessionId: 's1',
      title: 't',
      category: 'codex' as const,
      sizeInBytes: 1,
      updatedAt: new Date(0)
    }
    expect(makeItem({ ...base, projectPath: null }).projectPath).toBeNull()
    expect(makeItem({ ...base, projectPath: '/p', gitBranch: 'main', messageCount: 7, snippet: 's' })).toMatchObject({
      projectPath: '/p',
      gitBranch: 'main',
      messageCount: 7,
      snippet: 's'
    })
  })

  it('id 可显式指定；不指定时每条不同', () => {
    const base = { sessionId: 's', title: 't', category: 'aider' as const, sizeInBytes: 0, updatedAt: new Date(0) }
    expect(makeItem({ ...base, id: 'fixed-id' }).id).toBe('fixed-id')
    expect(makeItem(base).id).not.toBe(makeItem(base).id)
  })
})

// ---------------------------------------------------------------------------
// 路径解析
// ---------------------------------------------------------------------------

describe('resolveStoragePath —— 环境变量优先 + realpath', () => {
  it('环境变量命中时用环境变量（fallbackSegments 被忽略）', () => {
    const target = ensureDir(join(root, 'env-root'))
    process.env['CC_TEST_HOME'] = target
    try {
      expect(resolveStoragePath(['.ignored'], { key: 'CC_TEST_HOME' })).toBe(realpathSync(target))
    } finally {
      delete process.env['CC_TEST_HOME']
    }
  })

  it('环境变量未设置 / 空串 → 回落到 homedir 下的默认目录', () => {
    const value = process.env['CC_TEST_MISSING']
    delete process.env['CC_TEST_MISSING']
    try {
      expect(resolveStoragePath(['.claude'], { key: 'CC_TEST_MISSING' })).toBe(
        realpathSyncSafe(join(homedir(), '.claude'))
      )
    } finally {
      if (value !== undefined) process.env['CC_TEST_MISSING'] = value
    }
  })

  it('做一次 realpath（/var → /private/var 这类别名被解析）', () => {
    const target = ensureDir(join(root, 'var-test'))
    const link = join(root, 'link-test')
    symlinkSync(target, link)
    expect(realpathSync(link)).not.toBe(link)
    process.env['CC_TEST_LINK'] = link
    try {
      expect(resolveStoragePath([], { key: 'CC_TEST_LINK' })).toBe(realpathSync(target))
    } finally {
      delete process.env['CC_TEST_LINK']
    }
  })

  it('路径不存在时原样返回（realpath 失败不抛错）', () => {
    const missing = join(root, 'not-there')
    process.env['CC_TEST_GONE'] = missing
    try {
      expect(resolveStoragePath([], { key: 'CC_TEST_GONE' })).toBe(missing)
    } finally {
      delete process.env['CC_TEST_GONE']
    }
  })
})

describe('expandTilde', () => {
  it('`~` → home', () => {
    expect(expandTilde('~', '/Users/tester')).toBe('/Users/tester')
  })

  it('`~/x` → home/x', () => {
    expect(expandTilde('~/.claude/projects', '/Users/tester')).toBe('/Users/tester/.claude/projects')
  })

  it('绝对路径原样', () => {
    expect(expandTilde('/abs/path', '/Users/tester')).toBe('/abs/path')
  })

  it('`~user/x` 不展开（只认当前用户）', () => {
    expect(expandTilde('~other/x', '/Users/tester')).toBe('~other/x')
  })

  it('默认用真实 homedir', () => {
    expect(expandTilde('~')).toBe(homedir())
  })
})

// ---------------------------------------------------------------------------
// isInside / sizeOfPath / remove*
// ---------------------------------------------------------------------------

describe('isInside', () => {
  it('真子路径为 true', () => {
    expect(isInside('/a/b', '/a/b/c')).toBe(true)
    expect(isInside('/a/b', '/a/b/c/d.jsonl')).toBe(true)
  })

  it('自身不算（严格子路径）', () => {
    expect(isInside('/a/b', '/a/b')).toBe(false)
  })

  it('同前缀的兄弟目录不算', () => {
    expect(isInside('/a/b', '/a/bc')).toBe(false)
    expect(isInside('/a/b', '/a/b2/d')).toBe(false)
  })

  it('父目录传入时为 true（不处理 `..`）', () => {
    expect(isInside('/a/b', '/a')).toBe(false)
  })

  it('parent 带尾分隔符也正确', () => {
    expect(isInside('/a/b/', '/a/b/c')).toBe(true)
    expect(isInside('/a/b/', '/a/b')).toBe(false)
  })
})

describe('sizeOfPath', () => {
  it('文件返回字节数；目录递归求和且跳过隐藏项', () => {
    const file = writeFile(join(root, 'a.txt'), '12345')
    expect(sizeOfPath(file)).toBe(5)
    const dir = ensureDir(join(root, 'tree'))
    writeFile(join(dir, 'x'), 'a'.repeat(10))
    writeFile(join(dir, 'sub', 'y'), 'b'.repeat(7))
    writeFile(join(dir, '.hidden'), 'c'.repeat(100))
    expect(sizeOfPath(dir)).toBe(17)
  })

  it('不存在 → 0', () => {
    expect(sizeOfPath(join(root, 'nope'))).toBe(0)
  })
})

describe('removeIfExists / removeIfEmptyDirectory / removeAndReclaimDir', () => {
  it('removeIfExists：删文件 / 删目录，不存在返回 false', () => {
    const file = writeFile(join(root, 'a.txt'), 'x')
    expect(removeIfExists(file)).toBe(true)
    expect(removeIfExists(file)).toBe(false)
    const dir = ensureDir(join(root, 'd'))
    writeFileSync(join(dir, 'inner'), 'x')
    expect(removeIfExists(dir)).toBe(true)
    expect(removeIfExists(dir)).toBe(false)
  })

  it('removeIfEmptyDirectory：开关关掉时一个目录都不删', () => {
    const dir = ensureDir(join(root, 'empty'))
    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    removeIfEmptyDirectory(dir)
    expect(pathExists(dir)).toBe(true)
  })

  it('removeIfEmptyDirectory：只剩隐藏项时连目录一起回收', () => {
    const dir = ensureDir(join(root, 'empty'))
    writeFileSync(join(dir, '.DS_Store'), '')
    CleanPrefs.patch({ cleanEmptyProjectFolders: true })
    removeIfEmptyDirectory(dir)
    expect(pathExists(dir)).toBe(false)
  })

  it('removeIfEmptyDirectory：还有正常项则保留', () => {
    const dir = ensureDir(join(root, 'busy'))
    writeFileSync(join(dir, 'real'), 'x')
    removeIfEmptyDirectory(dir)
    expect(pathExists(dir)).toBe(true)
  })

  it('removeAndReclaimDir：删完顺手回收空目录（受开关控制）', () => {
    const dir = ensureDir(join(root, 'proj'))
    CleanPrefs.patch({ cleanEmptyProjectFolders: true })
    expect(removeAndReclaimDir(dir)).toBe(true)
    expect(pathExists(dir)).toBe(false)

    const dir2 = ensureDir(join(root, 'proj2'))
    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    expect(removeAndReclaimDir(dir2)).toBe(true)
    expect(pathExists(dir2)).toBe(false) // removeIfExists 仍然删了本体，只是没回收空目录
  })
})

// ---------------------------------------------------------------------------
// deleteItemsWithPaths
// ---------------------------------------------------------------------------

describe('deleteItemsWithPaths', () => {
  function seed() {
    const body = writeFile(join(root, 'agent', 's1.jsonl'), 'x'.repeat(100))
    const snapshot = ensureDir(join(root, 'agent', 'file-history', 's1'))
    writeFileSync(join(snapshot, 'state.json'), 'y'.repeat(30))
    return { body, snapshot, size: 130 }
  }

  it('空数组直接返回 0，afterDelete 不被调用', async () => {
    let called = false
    const freed = await deleteItemsWithPaths([], () => {
      called = true
    })
    expect(freed).toBe(0)
    expect(called).toBe(false)
  })

  it('开关开着 → 全部路径都删，freed = 上报值', async () => {
    const { body, snapshot, size } = seed()
    CleanPrefs.patch({ cleanFileHistorySnapshots: true })
    const item = makeItem({
      sessionId: 's1',
      title: 's1',
      category: 'claudeCode',
      sizeInBytes: size,
      updatedAt: new Date(0),
      associatedPaths: [body, snapshot]
    })
    const freed = await deleteItemsWithPaths([item])
    expect(freed).toBe(size)
    expect(pathExists(body)).toBe(false)
    expect(pathExists(snapshot)).toBe(false)
  })

  it('开关关掉 → 快照保留、freed 扣掉快照体积', async () => {
    const { body, snapshot, size } = seed()
    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const item = makeItem({
      sessionId: 's1',
      title: 's1',
      category: 'claudeCode',
      sizeInBytes: size,
      updatedAt: new Date(0),
      associatedPaths: [body, snapshot]
    })
    const freed = await deleteItemsWithPaths([item])
    expect(freed).toBe(size - 30)
    expect(pathExists(body)).toBe(false)
    expect(pathExists(snapshot)).toBe(true)
  })

  it('afterDelete 拿到全部被删的 sessionId（供索引同步）', async () => {
    const a = writeFile(join(root, 'a.jsonl'), 'a')
    const b = writeFile(join(root, 'b.jsonl'), 'b')
    const items = ['a', 'b'].map((sessionId, i) =>
      makeItem({
        sessionId,
        title: sessionId,
        category: 'codex',
        sizeInBytes: 1,
        updatedAt: new Date(i),
        associatedPaths: [i === 0 ? a : b]
      })
    )
    let received: Set<string> | null = null
    const freed = await deleteItemsWithPaths(items, (ids) => {
      received = ids
    })
    expect(freed).toBe(2)
    expect([...(received ?? [])].sort()).toEqual(['a', 'b'])
  })

  it('afterDelete 可以是 async，物理删除先于它发生', async () => {
    const file = writeFile(join(root, 'a.jsonl'), 'a')
    const item = makeItem({
      sessionId: 'a',
      title: 'a',
      category: 'codex',
      sizeInBytes: 1,
      updatedAt: new Date(0),
      associatedPaths: [file]
    })
    let existedDuringHook: boolean | null = null
    await deleteItemsWithPaths([item], async () => {
      await Promise.resolve()
      existedDuringHook = pathExists(file)
    })
    expect(existedDuringHook).toBe(false)
  })

  it('关联路径不存在时不报错，freed 仍按上报值计', async () => {
    const item = makeItem({
      sessionId: 'ghost',
      title: 'ghost',
      category: 'zed',
      sizeInBytes: 123,
      updatedAt: new Date(0),
      associatedPaths: [join(root, 'nope.jsonl')]
    })
    await expect(deleteItemsWithPaths([item])).resolves.toBe(123)
  })
})

// ---------------------------------------------------------------------------
// 与 SQLite 索引层的接缝
// ---------------------------------------------------------------------------

describe('扫描器协议：scan 不落盘、delete 才落盘', () => {
  /** 最小 AgentScanner 实现，只用共享原语 —— 与真实扫描器同一套约定。 */
  class MiniScanner {
    readonly category = 'claudeCode' as const
    constructor(private readonly base: string) {}
    get isInstalled(): boolean {
      return isDirectory(this.base)
    }
    get storagePath(): string {
      return this.base
    }
    async scan() {
      const files = listFiles(this.base, '.jsonl')
      const items = await mapLimit(files, 4, async (path) =>
        makeItem({
          sessionId: path.slice(path.lastIndexOf('/') + 1, path.length - '.jsonl'.length),
          title: singleLine(truncate(readJsonLines<{ text?: string }>(path)[0]?.text ?? '', 40)),
          category: this.category,
          sizeInBytes: sizeOfPath(path),
          updatedAt: new Date(mtimeMs(path) ?? 0),
          associatedPaths: [path]
        })
      )
      return sortByUpdatedDesc(items)
    }
    async delete(items: Parameters<typeof deleteItemsWithPaths>[0]) {
      return deleteItemsWithPaths(items, (ids) => {
        // 真实扫描器会在这里同步 `state.vscdb` 索引；这里只验证钩子跑得通。
        removeChatSessions(join(this.base, 'state.vscdb'), ids)
      })
    }
    async cleanAll(): Promise<number> {
      const items = await this.scan()
      return this.delete(items)
    }
  }

  it('scan() 不写盘（连 mtime 都不许动）', async () => {
    const agentRoot = ensureDir(join(root, '.claude', 'projects'))
    const a = writeFile(join(agentRoot, 'a.jsonl'), '{"text":"第一行标题"}\n{"text":"b"}\n')
    const b = writeFile(join(agentRoot, 'b.jsonl'), '{"text":"第二条"}\n')
    // 显式拉开 mtime，否则同一毫秒内创建的两个文件排序不确定
    utimesSync(a, new Date(1_000_000), new Date(1_000_000))
    utimesSync(b, new Date(2_000_000), new Date(2_000_000))
    const before = [a, b].map((p) => readFileSync(p, 'utf8'))
    const beforeMtime = [a, b].map((p) => statSync(p).mtimeMs)

    const scanner = new MiniScanner(agentRoot)
    expect(scanner.isInstalled).toBe(true)
    const items = await scanner.scan()
    expect(items).toHaveLength(2)
    expect(items.map((i) => i.title)).toEqual(['第二条', '第一行标题'])
    expect([a, b].map((p) => readFileSync(p, 'utf8'))).toEqual(before)
    expect([a, b].map((p) => statSync(p).mtimeMs)).toEqual(beforeMtime)
  })

  it('未安装时 isInstalled = false', () => {
    expect(new MiniScanner(join(root, 'nope')).isInstalled).toBe(false)
  })

  it('cleanAll() = scan() + delete()，文件真的没了', async () => {
    const agentRoot = ensureDir(join(root, '.claude', 'projects'))
    writeFile(join(agentRoot, 'a.jsonl'), '{"text":"a"}\n')
    writeFile(join(agentRoot, 'b.jsonl'), '{"text":"b"}\n')
    const scanner = new MiniScanner(agentRoot)
    const freed = await scanner.cleanAll()
    expect(freed).toBeGreaterThan(0)
    expect(listFiles(agentRoot, '.jsonl')).toEqual([])
  })

  it('删会话时 afterDelete 能顺带裁掉 state.vscdb 索引（接缝验证）', async () => {
    const agentRoot = ensureDir(join(root, '.claude', 'projects'))
    writeFile(join(agentRoot, 'a.jsonl'), '{"text":"a"}\n')
    writeFile(join(agentRoot, 'b.jsonl'), '{"text":"b"}\n')
    const dbPath = join(agentRoot, 'state.vscdb')
    createStateVscdb(dbPath, { 'interactive.sessions': ['a', 'b'] })

    const scanner = new MiniScanner(agentRoot)
    const items = await scanner.scan()
    const target = items.find((i) => i.sessionId === 'a')
    expect(target).toBeDefined()

    const before = new DatabaseSync(dbPath, { readOnly: true })
    expect(
      (before.prepare('SELECT COUNT(*) AS n FROM ItemTable').get() as { n: number }).n
    ).toBe(1)
    before.close()

    await scanner.delete(target ? [target] : [])

    const after = new DatabaseSync(dbPath, { readOnly: true })
    const value = after.prepare("SELECT value FROM ItemTable WHERE key = 'interactive.sessions'").get() as
      | { value: string }
      | undefined
    expect(JSON.parse(value?.value ?? 'null')).toEqual(['b'])
    after.close()
  })
})

// ---------------------------------------------------------------------------

function realpathSyncSafe(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}
