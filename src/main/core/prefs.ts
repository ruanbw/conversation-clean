import { app } from 'electron'
import { existsSync, readFileSync, writeFileSync, mkdirSync, renameSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { DEFAULT_PREFS, type Prefs } from '@shared/types'
import { sizeOfPath } from './fsutil'

/**
 * 设置面板 4 个开关的**唯一**存储实现：userData 目录下一个 `preferences.json`。
 *
 * 两条约定：
 * 1. 每次读都走 `read()` 拿当前值并缓存，**不缓存成只读属性** ——
 *    设置窗口改动不会通知调用方，缓存下来会让「运行中改开关」要重启才生效。
 * 2. 键不存在时按 `DEFAULT_PREFS` 返回：默认值要先落盘才算存在。
 */
const PREF_KEYS = [
  'autoScanOnLaunch',
  'confirmBeforeClean',
  'cleanFileHistorySnapshots',
  'cleanEmptyProjectFolders'
] as const satisfies readonly (keyof Prefs)[]

let cache: Prefs | null = null
let cachePath: string | null = null

/**
 * 偏好文件所在目录。
 *
 * 优先级：`CONVERSATION_CLEAN_DATA_DIR` 环境变量 > Electron 的 userData > `~/.conversation-clean`。
 *
 * 这个环境变量有两个用途：
 * 1. **测试**：不设它的话，vitest 里 `app` 是 `undefined`，会走到最后一条兜底路径，
 *    把测试期间的偏好读写写进用户真实的 `~/.conversation-clean/preferences.json` ——
 *    测试污染用户配置，而且不同用例会互相干扰。测试在 `beforeAll` 里设一次即可，
 *    不用 `vi.mock('electron')`（那会连带把整个模块的导入链都 mock 掉）。
 * 2. **便携安装**：绿色版 / U 盘版可以把配置放在自己旁边。
 */
function resolveDataDir(): string {
  const override = process.env['CONVERSATION_CLEAN_DATA_DIR']
  if (override && override.length > 0) return override
  try {
    return app.getPath('userData')
  } catch {
    // app 不可用 = 跑在纯 Node 下（vitest / CLI 探针）。
    return join(process.env['HOME'] ?? process.cwd(), '.conversation-clean')
  }
}

function resolveCachePath(): string {
  if (cachePath) return cachePath
  cachePath = join(resolveDataDir(), 'preferences.json')
  return cachePath
}

function read(): Prefs {
  if (cache) return cache
  const file = resolveCachePath()
  let parsed: Partial<Prefs> = {}
  try {
    if (existsSync(file)) {
      const decoded: unknown = JSON.parse(readFileSync(file, 'utf8'))
      // 文件内容**完全合法但是个字面量**（`null` / `42` / `"x"`）时，
      // `decoded[key]` 不会报错而是抛 TypeError —— 那会把整条 `prefs:get` IPC 拖死。
      // 所以这里先卡一道类型，再取字段。
      if (decoded !== null && typeof decoded === 'object' && !Array.isArray(decoded)) {
        parsed = decoded as Partial<Prefs>
      }
    }
  } catch {
    // 文件损坏 / 半写入：回落默认值，不让一个坏 JSON 卡死整个应用。
    parsed = {}
  }
  const next = { ...DEFAULT_PREFS }
  for (const key of PREF_KEYS) {
    const value = parsed[key]
    if (typeof value === 'boolean') next[key] = value
  }
  cache = next
  return next
}

function write(next: Prefs): Prefs {
  const file = resolveCachePath()
  try {
    mkdirSync(dirname(file), { recursive: true })
    // 先写临时文件再 rename：断电 / 崩溃时不会留下半截 JSON。
    const tmp = `${file}.tmp`
    writeFileSync(tmp, JSON.stringify(next, null, 2), 'utf8')
    renameSync(tmp, file)
  } catch (error) {
    console.error('[prefs] 写入失败：', error)
  }
  cache = next
  return next
}

/** 设置面板 4 个开关在服务层的**唯一**读取入口。 */
export const CleanPrefs = {
  /** 全部 4 个开关的当前值。 */
  all(): Prefs {
    return read()
  },
  get(key: keyof Prefs): boolean {
    return read()[key]
  },
  /** 局部更新，返回合并后的完整值。 */
  patch(patch: Partial<Prefs>): Prefs {
    const next = { ...read() }
    for (const key of PREF_KEYS) {
      const value = patch[key]
      if (typeof value === 'boolean') next[key] = value
    }
    return write(next)
  },
  /** 启动扫描：只在启动那一刻读一次。 */
  get autoScanOnLaunch(): boolean {
    return this.get('autoScanOnLaunch')
  },
  /** 清理前是否弹确认面板。 */
  get confirmBeforeClean(): boolean {
    return this.get('confirmBeforeClean')
  },
  /** 清理时是否连带删除文件改动快照。 */
  get cleanFileHistorySnapshots(): boolean {
    return this.get('cleanFileHistorySnapshots')
  },
  /** 删除会话后是否回收遗留的空目录。 */
  get cleanEmptyProjectFolders(): boolean {
    return this.get('cleanEmptyProjectFolders')
  },

  /**
   * 丢弃内存缓存并重算偏好文件路径。
   *
   * 专供测试：模块级缓存在用例之间是活的，测试想换一个临时目录就必须能把它清掉。
   * 生产代码不该调它 —— 一次进程生命周期内偏好只应落盘一次。
   */
  __resetForTests(dataDir?: string): void {
    if (dataDir !== undefined) process.env['CONVERSATION_CLEAN_DATA_DIR'] = dataDir
    cache = null
    cachePath = null
  },

  /**
   * 会话「文件改动快照」的落盘目录名。
   *
   * 这些是 Agent 写文件前后留的回滚副本，与会话正文是两回事：
   *   · `file-history`        Claude Code `~/.claude/file-history/<sessionId>/`
   *   · `shell-snapshots`     Claude Code `~/.claude/shell-snapshots/`
   *   · `backups`             Claude Code `~/.claude/backups/`
   *   · `checkpoints`         Cline / Roo Code `…/checkpoints/<taskId>/`
   *   · `chatEditingSessions` VS Code 系 `workspaceStorage/<hash>/chatEditingSessions/<sessionId>/`
   *     （内含 `state.json` 的 `timeline.checkpoints` 与 `contents/` 里的文件版本）
   *
   * 反过来，`state.vscdb` / `session-store.db` 里的索引行、`chatSessions`、
   * transcripts、subagent 目录都算「会话本体」，不受这个开关管 —— 删了正文却留着
   * 索引行，只会在 Agent 侧留下永远查不到的幽灵会话。
   */
  isSnapshotPath(path: string): boolean {
    return path
      .split('/')
      .filter(Boolean)
      .some((segment) => SNAPSHOT_DIR_NAMES.has(segment))
  },

  /**
   * 一条会话本次真正要删的路径：开关关掉时剔除快照路径，只留会话主文件。
   * 扫描器调用它拿到最终删除清单，不要自己再判一次快照。
   */
  deletionPathsFor(item: { associatedPaths: string[] }): string[] {
    if (this.cleanFileHistorySnapshots) return item.associatedPaths
    return item.associatedPaths.filter((p) => !this.isSnapshotPath(p))
  },

  /**
   * 被保留的快照并没有真的释放空间，从统计里扣掉，
   * 否则确认面板的「预计释放」和成功横幅都会报一个比实际释放量更大的数。
   * 必须在物理删除**之前**调用，否则路径已不存在、`sizeOf` 恒为 0。
   */
  freedBytesBeforeDelete(reported: number, item: { associatedPaths: string[] }): number {
    if (this.cleanFileHistorySnapshots) return reported
    // `fsutil` 也 import 了这个模块（`removeIfEmptyDirectory` 要读同一个开关），
    // 构成循环引用；ESM 的 live binding 允许这么写，前提是**只在调用时**取对方 ——
    // 两边都在函数体内用对方的导出，没有任何模块在顶层求值时读它。
    const kept = item.associatedPaths
      .filter((p) => this.isSnapshotPath(p))
      .reduce<number>((sum, p) => sum + sizeOfPath(p), 0)
    return Math.max(0, reported - kept)
  }
}

const SNAPSHOT_DIR_NAMES = new Set([
  'file-history',
  'shell-snapshots',
  'backups',
  'checkpoints',
  'chatEditingSessions'
])
