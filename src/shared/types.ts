/**
 * 全应用唯一的数据契约层。
 *
 * 主进程（扫描器 / 清理）、preload（IPC 桥）、渲染进程（React）三方都从这里取类型。
 * 任何一方要改字段，先改这里，再改调用方 —— 不允许在别处另立一份结构相同的 interface。
 *
 * 移植自 Swift 版 `ConversationClean/Models/ConversationItem.swift`。
 * 唯一的结构性差异：`Date` 变成 ISO 8601 字符串（`updatedAt`），
 * 因为 IPC 的结构化克隆不支持 Date 对象，且字符串在 JSON 落盘 / 比较 / 传输上都更省事。
 */

/** 16 个分类 = 15 款 Agent + `all` 汇总项。顺序即侧栏顺序，改这里等于改侧栏。 */
export const AGENT_CATEGORIES = [
  'all',
  'claudeCode',
  'codex',
  'piAgent',
  'cline',
  'rooCode',
  'continueDev',
  'copilotChat',
  'cursor',
  'windsurf',
  'trae',
  'aider',
  'openViking',
  'zed',
  'openHands',
  'antigravity'
] as const

export type AgentCategory = (typeof AGENT_CATEGORIES)[number]

/** 15 款真实 Agent（去掉 `all`）。 */
export const SCANNER_CATEGORIES = AGENT_CATEGORIES.filter(
  (c): c is Exclude<AgentCategory, 'all'> => c !== 'all'
)

/** 分类的显示名。侧栏、确认面板、设置页共用同一份中文名，不再各写各的。 */
export const CATEGORY_LABELS: Record<AgentCategory, string> = {
  all: '全部会话',
  claudeCode: 'Claude Code',
  codex: 'Codex',
  piAgent: 'Pi Agent',
  cline: 'Cline',
  rooCode: 'Roo Code',
  continueDev: 'Continue',
  copilotChat: 'Copilot / VS Code',
  cursor: 'Cursor',
  windsurf: 'Windsurf',
  trae: 'Trae',
  aider: 'Aider',
  openViking: 'OpenViking',
  zed: 'Zed AI',
  openHands: 'OpenHands',
  antigravity: 'Antigravity'
}

/**
 * 该 Agent 可能对应的 `.app` bundle 名，按优先级排列。
 *
 * 15 款**全部**有映射 —— 装没装是运行时的事，不该写进模型里。
 * 解析时取第一个存在的，取不到回退内置字形。
 *
 * 三类情况：
 * · 独立 GUI 应用（Cursor / Zed / Windsurf / Trae / Antigravity…）：产品自己的 .app
 * · VS Code 扩展（Cline / Roo Code / Continue）：它们就跑在 VS Code 里，
 *   显示 VS Code 的图标在语义上是对的，比一个说不清是什么的符号强
 * · 纯 CLI（Codex / Aider / Pi Agent / OpenViking / OpenHands）：
 *   这些**没有**独立 GUI，优先匹配同厂商的桌面应用（Claude Code → Claude，Codex → ChatGPT），
 *   都没有就只剩内置字形
 */
export const CATEGORY_APP_BUNDLES: Record<AgentCategory, string[]> = {
  all: [],
  claudeCode: ['Claude Code.app', 'Claude.app'],
  codex: ['Codex.app', 'ChatGPT.app'],
  piAgent: ['Pi Agent.app', 'Pi.app'],
  cline: ['Cline.app', 'Visual Studio Code.app'],
  rooCode: ['Roo Code.app', 'RooCode.app', 'Visual Studio Code.app'],
  continueDev: ['Continue.app', 'Visual Studio Code.app'],
  copilotChat: ['Visual Studio Code.app'],
  cursor: ['Cursor.app'],
  windsurf: ['Windsurf.app'],
  trae: ['Trae.app'],
  aider: ['Aider.app'],
  openViking: ['OpenViking.app'],
  zed: ['Zed.app'],
  openHands: ['OpenHands.app'],
  antigravity: ['Antigravity.app']
}

/**
 * 字形键。Swift 版指向 SF Symbols，Electron 版指向自绘 SVG 精灵图里的 key。
 *
 * 铁律：一律线性描边，1.6px stroke + `fill: none`。
 * 一旦混入填充变体，侧栏 / 标题行 / 检视器 / 设置路径页会各自用不同粗细的符号。
 * 渲染进程按这个 key 去 `components/AgentGlyph.tsx` 里取 SVG，**不要**在视图里写死图形。
 */
export const CATEGORY_GLYPHS: Record<AgentCategory, string> = {
  all: 'tray',
  claudeCode: 'terminal',
  codex: 'chevronCode',
  piAgent: 'cpu',
  cline: 'bolt',
  rooCode: 'sparkles',
  continueDev: 'play',
  copilotChat: 'chat',
  cursor: 'cursor',
  windsurf: 'wind',
  trae: 'ring',
  aider: 'terminalClock',
  openViking: 'shield',
  zed: 'textbox',
  openHands: 'hand',
  antigravity: 'layers'
}

/** 一条会话。渲染进程拿到的就是这个结构，扫描器产出的也是这个结构。 */
export interface ConversationItem {
  /** 稳定 id。UUID v4 字符串，由扫描器生成；删除与勾选都以它为键。 */
  id: string
  sessionId: string
  title: string
  category: AgentCategory
  projectPath: string | null
  gitBranch: string | null
  messageCount: number
  sizeInBytes: number
  /** ISO 8601 字符串（`new Date().toISOString()`），不用 epoch 毫秒 —— 跨时区可读。 */
  updatedAt: string
  isSelected: boolean
  snippet: string
  /**
   * 这条会话真正占盘的路径。删除时**逐条删这里列出的文件**，
   * 再由 `AgentScanner.delete` 负责同步索引。
   */
  associatedPaths: string[]
}

/** 侧栏一个分类的体检数据。 */
export interface AgentInfo {
  category: AgentCategory
  isInstalled: boolean
  storagePath: string
  sessionCount: number
  totalBytes: number
}

/** 设置面板 4 个开关。键名与 Swift 版 `CleanPrefs.Key` 逐字一致，便于对照。 */
export interface Prefs {
  autoScanOnLaunch: boolean
  confirmBeforeClean: boolean
  cleanFileHistorySnapshots: boolean
  cleanEmptyProjectFolders: boolean
}

export const DEFAULT_PREFS: Prefs = {
  autoScanOnLaunch: true,
  confirmBeforeClean: true,
  cleanFileHistorySnapshots: true,
  cleanEmptyProjectFolders: true
}

/** 单个扫描器的失败信息。扫描不因为一个 Agent 挂掉而整体失败，所以要把原因带回 UI。 */
export interface ScanIssue {
  category: AgentCategory
  message: string
}

/** `scan:all` 的返回体。 */
export interface ScanResult {
  items: ConversationItem[]
  agents: AgentInfo[]
  issues: ScanIssue[]
  /** 扫描耗时（毫秒），给 UI 做「扫描完成 · 耗时 1.2s」这类文案。 */
  durationMs: number
}

/** `clean:delete` / `clean:all` 的返回体。 */
export interface CleanResult {
  /** 实际释放字节数（已扣除被保留的快照），可能为 0。 */
  freedBytes: number
  /** 实际删除的会话条数。 */
  deletedCount: number
}

/** 打开外部程序的意图。主进程统一走 shell，渲染进程不允许直接碰 Node API。 */
export type RevealTarget = { kind: 'path'; path: string } | { kind: 'none' }

/**
 * 宿主卷的容量与已用量。
 *
 * 渲染进程读不到 fs，所以「占卷总容量」这类信息只能由主进程代取。
 * 拿不到真实值时整个通道返回 `null`，UI 整块不渲染 ——
 * 宁可少一节，也不能拿演示数字冒充真实占用。
 */
export interface VolumeInfo {
  /** 卷名，如 `Macintosh HD`。 */
  name: string
  /** 真实挂载点，如 `/` 或 `/System/Volumes/Data`。 */
  mountPath: string
  capacity: number
  used: number
}

export const IPC = {
  scanAll: 'scan:all',
  cleanDelete: 'clean:delete',
  cleanAll: 'clean:all',
  prefsGet: 'prefs:get',
  prefsSet: 'prefs:set',
  appInfo: 'app:info',
  volumeInfo: 'app:volumeInfo',
  revealPath: 'shell:reveal',
  openPath: 'shell:open',
  copyText: 'shell:copy'
} as const

export interface AppInfo {
  version: string
  platform: string
  home: string
  electron: string
  node: string
}

/** 渲染进程通过 `window.api` 拿到的那把伞。preload 负责把实现挂上去。 */
export interface RendererApi {
  scanAll(): Promise<ScanResult>
  cleanDelete(items: ConversationItem[]): Promise<CleanResult>
  cleanAll(category: AgentCategory | null): Promise<CleanResult>
  getPrefs(): Promise<Prefs>
  setPrefs(patch: Partial<Prefs>): Promise<Prefs>
  getAppInfo(): Promise<AppInfo>
  /** 卷容量。读不到时返回 `null`；调用方必须能处理 `null`（整块不渲染）。 */
  getVolumeInfo(): Promise<VolumeInfo | null>
  revealInFinder(path: string): Promise<boolean>
  openPath(path: string): Promise<boolean>
  copyText(text: string): Promise<boolean>
}
