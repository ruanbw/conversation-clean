import { contextBridge, ipcRenderer } from 'electron'
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

/**
 * 预加载桥：把主进程能力以**白名单函数**的形式挂到 `window.api`。
 *
 * 渲染进程开着 `contextIsolation`，拿不到 `ipcRenderer` 本身 ——
 * 这是刻意的：渲染进程里跑的是 React 代码，它只该有「扫 / 删 / 读设置」这几个动作，
 * 不该有任意 channel 的调用能力（`ipcRenderer.send('anything:else')` 会是提权路径）。
 */

const api = {
  scanAll: (): Promise<ScanResult> => ipcRenderer.invoke(IPC.scanAll),

  cleanDelete: (items: ConversationItem[]): Promise<CleanResult> =>
    ipcRenderer.invoke(IPC.cleanDelete, items),

  cleanAll: (category: AgentCategory | null): Promise<CleanResult> =>
    ipcRenderer.invoke(IPC.cleanAll, category),

  getPrefs: (): Promise<Prefs> => ipcRenderer.invoke(IPC.prefsGet),

  setPrefs: (patch: Partial<Prefs>): Promise<Prefs> =>
    ipcRenderer.invoke(IPC.prefsSet, patch),

  getAppInfo: (): Promise<AppInfo> => ipcRenderer.invoke(IPC.appInfo),

  /** 卷容量。读不到时返回 `null`，UI 整块不渲染。 */
  getVolumeInfo: (): Promise<VolumeInfo | null> => ipcRenderer.invoke(IPC.volumeInfo),

  getAgentIcons: (): Promise<Record<string, string | null>> =>
    ipcRenderer.invoke('app:agentIcons'),

  revealInFinder: (path: string): Promise<boolean> =>
    ipcRenderer.invoke(IPC.revealPath, path),

  openPath: (path: string): Promise<boolean> => ipcRenderer.invoke(IPC.openPath, path),

  copyText: (text: string): Promise<boolean> => ipcRenderer.invoke(IPC.copyText, text)
}

export type PreloadApi = typeof api

if (process.contextIsolated) {
  contextBridge.exposeInMainWorld('api', api)
} else {
  // contextIsolation 被关掉时的兜底（只在测试 / 特殊调试环境会走到）。
  ;(globalThis as unknown as { api: PreloadApi }).api = api
}
