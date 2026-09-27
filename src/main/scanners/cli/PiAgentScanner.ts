import { mkdirSync, realpathSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, extname, join } from 'node:path'
import type { ConversationItem } from '@shared/types'
import type { AgentScanner, ScannerOptions } from '@main/core/scanner'
import {
  deleteItemsWithPaths,
  isDirectory,
  listDirectories,
  listFiles,
  mapLimit,
  pathExists,
  removeIfExists,
  sizeOfPath,
  sortByUpdatedDesc
} from '@main/core/scanner'
import { parseSession, preIndexTasks, type SessionTarget } from './PiAgentScanner+Parsing'
import { jsonlPathsUnder, purgeContextModeArtifacts } from './PiAgentScanner+ContextMode'
import { cleanEmptyProjectDirectories, pruneACPSessionMap } from './PiAgentScanner+ACPSessionMap'

/**
 * Pi Agent（`~/.pi`）会话扫描器。
 *
 * 移植自 `ConversationClean/Scanners/CLIAgents/PiAgentScanner.swift`，
 * 三个 Swift extension 拆到同目录的三个 `+*.ts` 文件，职责一一对应：
 *
 * | Swift | TypeScript | 职责 |
 * |---|---|---|
 * | `PiAgentScanner.swift` | 本文件 | 协议实现、目录枚举、`scan` / `delete` / `cleanAll` |
 * | `+Parsing.swift` | `PiAgentScanner+Parsing.ts` | `tasks/` 预索引 + 单个 `.jsonl` 解析 |
 * | `+ContextMode.swift` | `PiAgentScanner+ContextMode.ts` | context-mode 双层 SQLite 索引同步 |
 * | `+ACPSessionMap.swift` | `PiAgentScanner+ACPSessionMap.ts` | `pi-acp/session-map.json` 裁剪 + 空项目目录回收 |
 *
 * ## 目录布局
 *
 * ```
 * ~/.pi/
 *   agent/
 *     sessions/<--Users-ruanbw-projects-app-->/<时间戳>_<sid>.jsonl   ← 会话正文
 *     sessions/<--Users-ruanbw-projects-app-->/<时间戳>_<sid>/       ← 子代理嵌套会话
 *     run-history.jsonl
 *     web-search-cache/
 *   tasks/<sid>-<pid>/                                               ← 子代理任务产物
 *   context-mode/{sessions,content,stats}/                            ← 索引（SQLite + stats 缓存）
 *   pi-acp/session-map.json                                           ← ACP 客户端会话映射
 *   web-search-cache/
 * ```
 *
 * 删干净一条会话牵动四层东西：会话 `.jsonl`、同名的会话子目录、`tasks/` 产物目录，
 * 以及两层索引（context-mode 的 SQLite 行 + pi-acp 的映射条目）。少删一层就会在
 * Pi 界面留下一条点进去是空的幽灵会话。
 */

/** 解析并发度。Swift 是 `withTaskGroup` 全并发，这里收一档，避免一次几千个文件把 fd 打爆。 */
const PARSE_CONCURRENCY = 16

export class PiAgentScanner implements AgentScanner {
  readonly category = 'piAgent' as const

  /** 构造时注入的数据根目录。`null` 表示按「环境变量 → 默认目录」解析。 */
  private readonly customStoragePath: string | null

  constructor(options: ScannerOptions = {}) {
    this.customStoragePath = options.storagePath ?? null
  }

  /**
   * 数据根目录：注入值 > `PI_HOME` 环境变量 > `~/.pi`，再做一次 realpath 规范化。
   *
   * 规范化不是为了好看：`/var` → `/private/var` 这类别名不解析，
   * 侧栏显示的路径会跟 Finder 里点开的不一致，删除时也会出现「文件明明存在却删不掉」。
   * 目录还不存在时 realpath 会失败，此时退回原样（对应 Swift 的 `?? base.standardized`）。
   */
  get storagePath(): string {
    const env = process.env['PI_HOME']
    const base =
      this.customStoragePath ??
      (env !== undefined && env.length > 0 ? env : join(homedir(), '.pi'))
    return realpathOrSelf(base)
  }

  get isInstalled(): boolean {
    return pathExists(this.storagePath)
  }

  /** `~/.pi/agent/sessions`。 */
  private get sessionsDir(): string {
    return join(this.storagePath, 'agent', 'sessions')
  }

  /** `~/.pi/context-mode`。 */
  private get contextModeDir(): string {
    return join(this.storagePath, 'context-mode')
  }

  /** `~/.pi/pi-acp/session-map.json`。 */
  private get acpSessionMapPath(): string {
    return join(this.storagePath, 'pi-acp', 'session-map.json')
  }

  // MARK: - AgentScanner

  /**
   * 枚举 `agent/sessions/<project>/<时间戳>_<sid>.jsonl` 并逐条解析。
   *
   * 只读：一个字节都不写，mtime 也不碰。
   */
  async scan(): Promise<ConversationItem[]> {
    if (!this.isInstalled) return []

    const sessionsDir = this.sessionsDir
    if (!pathExists(sessionsDir)) return []

    const targets = this.enumerateSessionTargets(sessionsDir)
    if (targets.length === 0) return []

    // 先把 `tasks/` 一次性索引好：几百个会话文件各扫一遍 tasks 目录会慢到不可用。
    const taskArtifacts = preIndexTasks(join(this.storagePath, 'tasks'))

    const items = await mapLimit(targets, PARSE_CONCURRENCY, (target) =>
      parseSession(target, taskArtifacts)
    )
    return sortByUpdatedDesc(items)
  }

  /**
   * 删除一批会话：删文件 → 同步两层索引 → 回收空项目目录。
   *
   * 顺序与 Swift 版逐条对应：
   * 1. 先按**完整** `associatedPaths` 收集 `.jsonl` 路径（含会话子目录里递归找到的
   *    子代理嵌套会话）与「已删路径」集合 —— 这一步必须在物理删除之前做，
   *    因为「某个 associatedPath 是不是目录」这个判断依赖它还在盘上。
   * 2. 再按 `CleanPrefs.deletionPathsFor(item)` 物理删除：快照开关关掉时只删会话正文。
   *    字节数由 `deleteItemsWithPaths` 负责记账（已扣掉被保留的快照）。
   * 3. 用**步骤 1** 的完整路径集合同步 context-mode 索引行 —— 索引行属于「会话存在性」，
   *    不是快照，留着反而会让 Pi 界面列出空会话。
   * 4. 裁剪 `pi-acp/session-map.json`。
   * 5. 回收空项目目录（受 `cleanEmptyProjectFolders` 开关约束）。
   */
  async delete(items: readonly ConversationItem[]): Promise<number> {
    if (items.length === 0) return 0

    const sessionFilePaths = new Set<string>()
    const deletedPaths = new Set<string>()

    for (const item of items) {
      for (const path of item.associatedPaths) {
        deletedPaths.add(path)
        if (path.endsWith('.jsonl')) sessionFilePaths.add(path)
        // 会话子目录（子代理嵌套会话）下面还有 .jsonl，也要算进索引同步。
        if (isDirectory(path)) {
          for (const nested of jsonlPathsUnder(path)) sessionFilePaths.add(nested)
        }
      }
    }

    return deleteItemsWithPaths(items, (deletedSessionIds) => {
      purgeContextModeArtifacts(this.contextModeDir, sessionFilePaths)
      pruneACPSessionMap(this.acpSessionMapPath, deletedSessionIds, deletedPaths)
      cleanEmptyProjectDirectories(this.sessionsDir)
    })
  }

  /**
   * 清空 Pi Agent 的全部会话数据。
   *
   * `scan()` + `delete()` 之后再补删几个扫描器看不见的目录：
   * `tasks/`、`context-mode/`、`pi-acp/`、两个 `web-search-cache/` 与 `run-history.jsonl`。
   * 目录删掉后会**重建**成空目录 —— Pi 自己的代码路径假定它们存在，
   * 删了不建会让它下次启动报错。
   */
  async cleanAll(): Promise<number> {
    const items = await this.scan()
    let freed = await this.delete(items)

    const extraDirsToRecreate = [
      join(this.storagePath, 'agent', 'sessions'),
      join(this.storagePath, 'tasks'),
      join(this.storagePath, 'context-mode'),
      join(this.storagePath, 'pi-acp'),
      join(this.storagePath, 'web-search-cache'),
      join(this.storagePath, 'agent', 'web-search-cache')
    ]

    for (const dir of extraDirsToRecreate) {
      if (!pathExists(dir)) continue
      const size = sizeOfPath(dir)
      if (removeIfExists(dir)) {
        freed += size
        try {
          mkdirSync(dir, { recursive: true })
        } catch (error) {
          console.error(`[piAgent] 重建目录失败 ${dir}:`, error)
        }
      }
    }

    const runHistoryPath = join(this.storagePath, 'agent', 'run-history.jsonl')
    if (pathExists(runHistoryPath)) {
      const size = sizeOfPath(runHistoryPath)
      if (removeIfExists(runHistoryPath)) freed += size
    }

    return freed
  }

  // MARK: - 私有

  /** 列出所有 `.jsonl` 会话文件，并从中切出文件级 sessionId。 */
  private enumerateSessionTargets(sessionsDir: string): SessionTarget[] {
    const targets: SessionTarget[] = []
    for (const projectName of listDirectories(sessionsDir)) {
      const projectDir = join(sessionsDir, projectName)
      for (const file of listJsonlFiles(projectDir)) {
        const baseName = basename(file, extname(file))
        if (baseName.length === 0) continue
        // 文件名是 `<时间戳>_<sid>.jsonl`：取**最后一个**下划线之后的部分作为文件级 id。
        const lastUnderscore = baseName.lastIndexOf('_')
        const fileSessionId = lastUnderscore >= 0 ? baseName.slice(lastUnderscore + 1) : baseName
        targets.push({ filePath: file, projectDir, baseName, fileSessionId })
      }
    }
    return targets
  }
}

// MARK: - 小工具

/**
 * 目录下的 `.jsonl` 文件绝对路径。
 *
 * 不用 `listFiles(dir, '.jsonl')`：那个原语把扩展名转小写再比，
 * 而 Swift 的 `pathExtension == "jsonl"` 是大小写敏感的。
 */
function listJsonlFiles(dir: string): string[] {
  // `listFiles` 内部已经吞掉 readdir 异常，目录不存在时返回 `[]`。
  return listFiles(dir).filter((path) => extname(path) === '.jsonl')
}

function realpathOrSelf(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}
