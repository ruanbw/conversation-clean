/**
 * `core/prefs.ts` 的测试。
 *
 * 覆盖：4 个开关的默认值与合并语义、落盘（先写临时文件再 rename）、
 * 损坏 / 非对象 JSON 的回落、模块级缓存，以及
 * `isSnapshotPath` / `deletionPathsFor` / `freedBytesBeforeDelete` 的快照扣减。
 *
 * ## 为什么整个文件要 mock `electron`
 *
 * `prefs.ts` 顶层 `import { app } from 'electron'`，而 vitest 里没有 Electron 运行时。
 * `resolveCachePath()` 靠 `try { app.getPath('userData') } catch { … }` 兜底到
 * `~/.conversation-clean/preferences.json` —— 那会**真的往用户家目录写文件**。
 * 所以这里用 `vi.mock('electron')` 把 `getPath` 指到临时目录。
 * （`prefs.ts` 也认 `CONVERSATION_CLEAN_DATA_DIR`，指到临时目录同样能隔离。）
 *
 * ## 模块级缓存
 *
 * `prefs.ts` 有模块级 `cache` / `cachePath`，用例之间会互相看到对方的值。
 * `loadPrefs()` 用 `vi.resetModules()` + 动态 `import()` 拿一份全新模块实例，
 * 每个用例都从空缓存开始 —— 这是本文件所有隔离手段的来源。
 */

import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { DEFAULT_PREFS, type Prefs } from '@shared/types'

/** 临时 userData 目录。`vi.mock` 的工厂在模块 import 时才被调用，
 *  所以这里只算路径，目录在 `beforeAll` 里建。 */
const H = vi.hoisted(() => {
  const base = (process.env.TMPDIR ?? '/tmp').replace(/\/+$/, '')
  return { dir: `${base}/cc-prefs-${process.pid}-${Math.random().toString(36).slice(2)}` }
})

vi.mock('electron', () => ({ app: { getPath: () => H.dir } }))

const PREFS_FILE = join(H.dir, 'preferences.json')

/** 拿一份全新的 `prefs` 模块（清掉模块级 cache / cachePath）。 */
async function loadPrefs(): Promise<typeof import('@main/core/prefs')> {
  vi.resetModules()
  return import('@main/core/prefs')
}

beforeAll(() => {
  mkdirSync(H.dir, { recursive: true })
})

afterAll(() => {
  rmSync(H.dir, { recursive: true, force: true })
})

beforeEach(() => {
  rmSync(PREFS_FILE, { force: true })
  rmSync(`${PREFS_FILE}.tmp`, { force: true })
})

// ---------------------------------------------------------------------------

describe('4 个开关的默认值', () => {
  it('键不存在时按 DEFAULT_PREFS 返回', async () => {
    const { CleanPrefs } = await loadPrefs()
    expect(CleanPrefs.all()).toEqual({
      autoScanOnLaunch: true,
      confirmBeforeClean: true,
      cleanFileHistorySnapshots: true,
      cleanEmptyProjectFolders: true
    })
    expect(CleanPrefs.all()).toEqual(DEFAULT_PREFS)
  })

  it('4 个 getter 与 DEFAULT_PREFS 一致', async () => {
    const { CleanPrefs } = await loadPrefs()
    expect(CleanPrefs.autoScanOnLaunch).toBe(DEFAULT_PREFS.autoScanOnLaunch)
    expect(CleanPrefs.confirmBeforeClean).toBe(DEFAULT_PREFS.confirmBeforeClean)
    expect(CleanPrefs.cleanFileHistorySnapshots).toBe(DEFAULT_PREFS.cleanFileHistorySnapshots)
    expect(CleanPrefs.cleanEmptyProjectFolders).toBe(DEFAULT_PREFS.cleanEmptyProjectFolders)
  })

  it('get(key) 与同名 getter 取到同一个值', async () => {
    const { CleanPrefs } = await loadPrefs()
    for (const key of Object.keys(DEFAULT_PREFS) as (keyof Prefs)[]) {
      expect(CleanPrefs.get(key)).toBe(CleanPrefs[key])
    }
  })

  it('读一次不落盘（默认值不是「存在」才生效）', async () => {
    const { CleanPrefs } = await loadPrefs()
    CleanPrefs.all()
    expect(existsSync(PREFS_FILE)).toBe(false)
  })
})

describe('局部更新合并', () => {
  it('patch 只改给定的键，其余保持', async () => {
    const { CleanPrefs } = await loadPrefs()
    const next = CleanPrefs.patch({ confirmBeforeClean: false })
    expect(next).toEqual({
      autoScanOnLaunch: true,
      confirmBeforeClean: false,
      cleanFileHistorySnapshots: true,
      cleanEmptyProjectFolders: true
    })
    expect(CleanPrefs.get('confirmBeforeClean')).toBe(false)
    expect(CleanPrefs.get('autoScanOnLaunch')).toBe(true)
  })

  it('连续 patch 是叠加而不是替换', async () => {
    const { CleanPrefs } = await loadPrefs()
    CleanPrefs.patch({ confirmBeforeClean: false })
    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    expect(CleanPrefs.all()).toEqual({
      autoScanOnLaunch: true,
      confirmBeforeClean: false,
      cleanFileHistorySnapshots: true,
      cleanEmptyProjectFolders: false
    })
  })

  it('非 boolean 的值被忽略（类型不匹配不写盘）', async () => {
    const { CleanPrefs } = await loadPrefs()
    const dirty = { confirmBeforeClean: 'nope' } as unknown as Partial<Prefs>
    expect(CleanPrefs.patch(dirty)).toEqual(DEFAULT_PREFS)
  })

  it('patch 返回的是合并后的完整值，且 getter 立刻生效（无需重启）', async () => {
    const { CleanPrefs } = await loadPrefs()
    expect(CleanPrefs.patch({ autoScanOnLaunch: false }).autoScanOnLaunch).toBe(false)
    expect(CleanPrefs.autoScanOnLaunch).toBe(false)
  })
})

describe('落盘', () => {
  it('先写临时文件再 rename：不会留下 .tmp', async () => {
    const { CleanPrefs } = await loadPrefs()
    CleanPrefs.patch({ confirmBeforeClean: false })
    expect(existsSync(PREFS_FILE)).toBe(true)
    expect(existsSync(`${PREFS_FILE}.tmp`)).toBe(false)
  })

  it('落盘内容是缩进 2 格的 JSON，可直接被下次 read 读回', async () => {
    const { CleanPrefs } = await loadPrefs()
    CleanPrefs.patch({ confirmBeforeClean: false })
    const raw = readFileSync(PREFS_FILE, 'utf8')
    expect(raw).toContain('\n  "confirmBeforeClean": false')
    expect(JSON.parse(raw) as Prefs).toEqual(CleanPrefs.all())
  })

  it('目录不存在时自动创建', async () => {
    rmSync(H.dir, { recursive: true, force: true })
    const { CleanPrefs } = await loadPrefs()
    CleanPrefs.patch({ autoScanOnLaunch: false })
    expect(existsSync(PREFS_FILE)).toBe(true)
  })
})

describe('损坏 JSON 回落默认值', () => {
  // 注意：文件内容是**合法 JSON 但不是对象**的情况要分开写。
  // `[]` / `5` / `"x"` 都能安全回落；字面量 `null` 不能（见下方单独一组）。
  const broken = ['{not json', '', '[]', '{"confirmBeforeClean": ', '5', '"x"', 'true']

  for (const content of broken) {
    it(`回落：${JSON.stringify(content)}`, async () => {
      writeFileSync(PREFS_FILE, content, 'utf8')
      const { CleanPrefs } = await loadPrefs()
      expect(CleanPrefs.all()).toEqual(DEFAULT_PREFS)
    })
  }

  it('文件内容是字面量 null：应回落默认值而不是抛 TypeError', async () => {
    // `JSON.parse('null')` 不抛，所以最初的 `read()` try/catch 拦不住；
    // 随后的 `parsed[key]` 对 `null` 取属性 → TypeError，
    // 现象是只要 `preferences.json` 被写成 `null`（半写入 / 别的工具覆写），
    // 每次 `CleanPrefs.all()` 都抛，整条 `prefs:get` IPC 全挂。
    // 已在 `read()` 里加了一道「解码后必须是非 null 对象」的类型闸门。
    writeFileSync(PREFS_FILE, 'null', 'utf8')
    const { CleanPrefs } = await loadPrefs()
    expect(() => CleanPrefs.all()).not.toThrow()
    expect(CleanPrefs.all()).toEqual(DEFAULT_PREFS)
  })

  it('文件内容是其它合法但非对象的字面量（数字/字符串/数组）也回落默认值', async () => {
    for (const literal of ['42', '"hello"', '[]', 'true']) {
      writeFileSync(PREFS_FILE, literal, 'utf8')
      const { CleanPrefs } = await loadPrefs()
      expect(() => CleanPrefs.all()).not.toThrow()
      expect(CleanPrefs.all()).toEqual(DEFAULT_PREFS)
    }
  })

  it('非 boolean 的字段被丢掉，其余仍生效', async () => {
    writeFileSync(PREFS_FILE, JSON.stringify({ confirmBeforeClean: false, autoScanOnLaunch: 1 }), 'utf8')
    const { CleanPrefs } = await loadPrefs()
    expect(CleanPrefs.all()).toEqual({ ...DEFAULT_PREFS, confirmBeforeClean: false })
  })

  it('未知键被忽略，不会漏进 Prefs', async () => {
    writeFileSync(PREFS_FILE, JSON.stringify({ whoAmI: true, confirmBeforeClean: false }), 'utf8')
    const { CleanPrefs } = await loadPrefs()
    expect(Object.keys(CleanPrefs.all()).sort()).toEqual(Object.keys(DEFAULT_PREFS).sort())
  })
})

describe('缓存', () => {
  it('同一模块实例内反复 patch 会更新缓存（读到的永远是最新值）', async () => {
    const { CleanPrefs } = await loadPrefs()
    CleanPrefs.patch({ confirmBeforeClean: false })
    CleanPrefs.patch({ confirmBeforeClean: true })
    expect(CleanPrefs.confirmBeforeClean).toBe(true)
  })

  it('新模块实例从磁盘重读，能看到上一个实例写下的值', async () => {
    const first = await loadPrefs()
    first.CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const second = await loadPrefs()
    expect(second.CleanPrefs.cleanFileHistorySnapshots).toBe(false)
  })
})

describe('isSnapshotPath —— 5 个快照目录名', () => {
  const kinds = ['file-history', 'shell-snapshots', 'backups', 'checkpoints', 'chatEditingSessions']

  it('命中任一快照目录名', async () => {
    const { CleanPrefs } = await loadPrefs()
    for (const kind of kinds) {
      expect(CleanPrefs.isSnapshotPath(`/root/${kind}/${kind}-sid/state.json`), kind).toBe(true)
      expect(CleanPrefs.isSnapshotPath(`/root/agent/.claude/${kind}/x`), kind).toBe(true)
    }
  })

  it('非快照路径不算', async () => {
    const { CleanPrefs } = await loadPrefs()
    for (const path of [
      '/root/agent/projects/foo/abc.jsonl',
      '/root/agent/chatSessions/abc.json',
      '/root/agent/state.vscdb',
      '/root/agent/backups.json',
      '/root/agent/checkpoints.json'
    ]) {
      expect(CleanPrefs.isSnapshotPath(path), path).toBe(false)
    }
  })
})

describe('deletionPathsFor —— 开关关掉时剔除快照路径', () => {
  const associated = [
    '/root/agent/abc.jsonl',
    '/root/agent/file-history/abc/state.json',
    '/root/agent/shell-snapshots/abc',
    '/root/agent/projects/foo/bar.jsonl'
  ]
  const item = { associatedPaths: associated }

  it('开关开着 → 全部路径都删', async () => {
    const { CleanPrefs } = await loadPrefs()
    CleanPrefs.patch({ cleanFileHistorySnapshots: true })
    expect(CleanPrefs.deletionPathsFor(item)).toEqual(associated)
  })

  it('开关关掉 → 只留会话主文件', async () => {
    const { CleanPrefs } = await loadPrefs()
    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    expect(CleanPrefs.deletionPathsFor(item)).toEqual([
      '/root/agent/abc.jsonl',
      '/root/agent/projects/foo/bar.jsonl'
    ])
  })
})

describe('freedBytesBeforeDelete —— 扣掉被保留的快照', () => {
  it('开关开着 → 原样返回上报值', async () => {
    const { CleanPrefs } = await loadPrefs()
    CleanPrefs.patch({ cleanFileHistorySnapshots: true })
    const item = { associatedPaths: ['/root/agent/abc.jsonl', '/root/agent/file-history/abc'] }
    expect(CleanPrefs.freedBytesBeforeDelete(1000, item)).toBe(1000)
  })

  it('开关关掉 → 扣掉快照目录的实际体积', async () => {
    const { CleanPrefs } = await loadPrefs()
    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    // 现场造一个 12 字节的快照文件，验证扣减用的是真实 size 而不是常量
    const snapshotDir = join(H.dir, 'file-history', 'abc')
    mkdirSync(snapshotDir, { recursive: true })
    writeFileSync(join(snapshotDir, 'state.json'), 'x'.repeat(12), 'utf8')
    const item = { associatedPaths: ['/root/agent/abc.jsonl', snapshotDir] }
    expect(CleanPrefs.freedBytesBeforeDelete(1000, item)).toBe(988)
  })

  it('快照路径不存在时 sizeOf = 0，不扣减', async () => {
    const { CleanPrefs } = await loadPrefs()
    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const item = { associatedPaths: ['/root/agent/abc.jsonl', '/definitely/missing/file-history'] }
    expect(CleanPrefs.freedBytesBeforeDelete(1000, item)).toBe(1000)
  })

  it('保留量超过上报值时夹到 0，不报负数', async () => {
    const { CleanPrefs } = await loadPrefs()
    CleanPrefs.patch({ cleanFileHistorySnapshots: false })
    const item = { associatedPaths: ['/root/agent/file-history/abc'] }
    expect(CleanPrefs.freedBytesBeforeDelete(0, item)).toBe(0)
  })
})
