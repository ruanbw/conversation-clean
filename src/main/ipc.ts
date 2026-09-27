import { app, clipboard, ipcMain, shell } from 'electron'
import { existsSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import {
  IPC,
  type AgentCategory,
  type AppInfo,
  type CleanResult,
  type ConversationItem,
  type Prefs,
  type ScanResult,
  type VolumeInfo
} from '@shared/types'
import { CleanPrefs } from './core/prefs'
import { currentVolumeInfo } from './core/volume'
import { allAgentIcons } from './core/agentIcons'
import {
  agentInfosFrom,
  cleanAll,
  deleteItems,
  scanAll,
  validateRegistry
} from './scanners/registry'

/**
 * 主进程 IPC 端：15 个扫描器 + 清理 + 设置 + shell，全部收口在这里。
 *
 * 渲染进程**不允许**直接碰 Node API（`contextIsolation: true` + 无 `nodeIntegration`），
 * 它能做的只有这一层暴露出来的这些方法。新增能力时先在这里加，
 * 再去 `src/shared/types.ts` 的 `RendererApi` 加签名，最后在 preload 挂上。
 */
export function registerIpcHandlers(): void {
  // 注册表完整性：少注册一个分类，启动时立刻能看出来。
  const problems = validateRegistry()
  if (problems.length > 0) {
    console.error('[registry] 扫描器注册表有问题：\n  ' + problems.join('\n  '))
  }

  ipcMain.handle(IPC.scanAll, async (): Promise<ScanResult> => {
    const startedAt = Date.now()
    const { items, issues } = await scanAll()
    if (issues.length > 0) {
      console.warn('[scan] 部分 Agent 扫描失败：', issues)
    }
    return {
      items,
      agents: agentInfosFrom(items),
      issues,
      durationMs: Date.now() - startedAt
    }
  })

  ipcMain.handle(IPC.cleanDelete, async (_event, items: ConversationItem[]): Promise<CleanResult> => {
    if (!Array.isArray(items) || items.length === 0) {
      return { freedBytes: 0, deletedCount: 0 }
    }
    const freedBytes = await deleteItems(items)
    return { freedBytes, deletedCount: items.length }
  })

  ipcMain.handle(
    IPC.cleanAll,
    async (_event, category: AgentCategory | null): Promise<CleanResult> => {
      // 先数清空前的条数：清空后再扫一次拿到的是**剩下**的条数，
      // 拿它当 deletedCount 会让「清空了 N 条」显示成 0。
      const target = category ?? null
      const before = (await scanAll()).items.length
      const freedBytes = await cleanAll(target)
      if (target === null || target === 'all') {
        return { freedBytes, deletedCount: before }
      }
      const after = (await scanAll()).items.length
      return { freedBytes, deletedCount: Math.max(0, before - after) }
    }
  )

  ipcMain.handle(IPC.prefsGet, (): Prefs => CleanPrefs.all())

  ipcMain.handle(IPC.prefsSet, (_event, patch: Partial<Prefs>): Prefs => CleanPrefs.patch(patch ?? {}))

  ipcMain.handle(IPC.appInfo, (): AppInfo => {
    // electron / node 版本在渲染进程里取不到（contextIsolation），由主进程代取。
    return {
      version: app.getVersion(),
      platform: process.platform,
      home: homedir(),
      electron: process.versions.electron,
      node: process.versions.node
    }
  })

  // Agent 品牌图标：主进程解析成 dataURL，渲染进程只管 <img src>。
  ipcMain.handle('app:agentIcons', () => allAgentIcons())

  // 卷容量：渲染进程读不到 fs，由主进程代取。读不到就回 null，
  // 确认弹层会整块不渲染「卷占用」两节，而不是拿假分母编占比。
  ipcMain.handle(IPC.volumeInfo, (): VolumeInfo | null => currentVolumeInfo())

  ipcMain.handle(IPC.revealPath, (_event, path: string): boolean => {
    if (typeof path !== 'string' || path.length === 0) return false
    // 「在 Finder 中显示」：选中该文件而不是只打开父目录。
    // 路径不存在时 shell 也会打开父目录，所以这里照样调用，只是回报 false。
    const exists = pathIsOnDisk(path)
    shell.showItemInFolder(path)
    return exists
  })

  ipcMain.handle(IPC.openPath, async (_event, path: string): Promise<boolean> => {
    if (typeof path !== 'string' || path.length === 0) return false
    // `shell.openPath` 失败时返回一段人类可读的错误串，而不是布尔。
    // 空串 = 成功，这是 Electron 的约定，不要改成 `=== ''` 之外的判断。
    return (await shell.openPath(path)) === ''
  })

  ipcMain.handle(IPC.copyText, (_event, text: string): boolean => {
    clipboard.writeText(typeof text === 'string' ? text : '')
    return true
  })
}

function pathIsOnDisk(path: string): boolean {
  try {
    return statSync(path).isDirectory() || existsSync(path)
  } catch {
    return false
  }
}

/** 暴露给渲染进程的方法表。preload 用它来保证 preload 与主进程签名不会各写一份。 */
export const IPC_CHANNELS = IPC satisfies Record<string, string>
