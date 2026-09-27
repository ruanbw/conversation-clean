import { useCallback, useSyncExternalStore } from 'react'
import type {
  AgentCategory,
  AgentInfo,
  ConversationItem,
  Prefs,
  ScanIssue
} from '@shared/types'
import { DEFAULT_PREFS } from '@shared/types'

/**
 * 全应用唯一的状态中枢。
 *
 * 这里用 `useSyncExternalStore` 订阅一个外部 store：`getSnapshot` 返回不可变快照，
 * React 拿 `Object.is` 比对两次快照、自己决定要不要重渲染。
 *
 * 三条不变量（改动时不要破坏）：
 *
 * 1. **不缓存派生数据。** `filteredConversations` / `categoryStats` / `totalSize`
 *    在 `getSnapshot()` 里现算 —— 连「同步重算」这一步都没有，
 *    不存在两个状态不同步的中间帧。
 *
 * 2. **`selectedConversation` 现取。** 它不是状态而是 selector：
 *    会话被清理后自动变 `null`，视图侧不需要写任何同步代码。
 *
 * 3. **焦点请求用自增计数而不是 boolean。** ⌘F 的语义是「请把搜索框拉到焦点」，
 *    不是「当前是否聚焦」—— 用户已经在搜索框里时按 ⌘F，boolean 不会变化，
 *    视图收不到通知，光标也不会重新全选。所以它必须是自增计数，不是 boolean。
 */

export type CleanTarget = 'selected' | 'allInCurrentCategory'

export interface CategoryStats {
  count: number
  sizeInBytes: number
}

export interface ColumnWidths {
  sidebar: number
  list: number
}

/** 三栏列宽的记忆键。记在 localStorage（渲染进程侧，主进程不参与）。 */
const LS_COLUMN_WIDTHS = 'cc.columnWidths'
/** 当前分类的记忆键。扫描完会做一次「未安装则回落 all」的校正。 */
const LS_SELECTED_CATEGORY = 'cc.selectedCategory'

export const DEFAULT_COLUMN_WIDTHS: ColumnWidths = { sidebar: 208, list: 460 }

/** 分类统计的初值：每个分类先给一份零值，侧栏才不会在扫描前闪烁。 */
function emptyStats(): Map<AgentCategory, CategoryStats> {
  const map = new Map<AgentCategory, CategoryStats>()
  for (const category of ALL_CATEGORIES) {
    map.set(category, { count: 0, sizeInBytes: 0 })
  }
  return map
}

const ALL_CATEGORIES: AgentCategory[] = [
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
  'openViking',
  'aider',
  'zed',
  'openHands',
  'antigravity'
]

export interface CleanState {
  // 数据
  conversations: ConversationItem[]
  agentInfos: AgentInfo[]
  scanIssues: ScanIssue[]
  hasScanned: boolean

  // 筛选
  selectedCategory: AgentCategory
  searchText: string
  /**
   * 防抖后的搜索词。
   *
   * 必须是 **state** 而不是 store 的私有字段：`useSyncExternalStore` 用
   * `Object.is` 比较快照，只 notify listener 而不换快照，React 会直接跳过重渲染
   * （这是官方文档明写的行为，不是优化）。
   * 第一版把它放在私有字段里，只在防抖落地时 emit 一次 —— 结果是慢速输入时
   * 列表停在旧查询上，得靠视图层再补一个定时器踢一下重渲染才能动。
   * 那是把 store 的缺陷甩给视图，现在改在源头。
   */
  debouncedSearchText: string
  searchFocusRequest: number

  // 焦点
  selectedConversationId: string | null

  // 忙碌态
  isScanning: boolean
  isCleaning: boolean

  // 横幅
  showScanSuccessAlert: boolean
  scanSuccessCount: number
  scanSuccessBytes: number
  showCleanSuccessAlert: boolean
  lastCleanedBytes: number
  lastCleanedCount: number

  // 二次确认面板
  showCleanConfirmAlert: boolean
  cleanTarget: CleanTarget
  estimateToken: number
  estimateCategory: AgentCategory
  estimateCount: number

  // 设置 / 环境
  prefs: Prefs
  homeDir: string
  agentIcons: Record<string, string | null>
  columnWidths: ColumnWidths
}

type Listener = () => void

class CleanStore {
  private state: CleanState
  private listeners = new Set<Listener>()
  private debounceTimer: ReturnType<typeof setTimeout> | null = null
  private hasAttemptedLaunchScan = false

  constructor() {
    this.state = {
      conversations: [],
      agentInfos: [],
      scanIssues: [],
      hasScanned: false,
      selectedCategory: readSelectedCategory(),
      searchText: '',
      debouncedSearchText: '',
      searchFocusRequest: 0,
      selectedConversationId: null,
      isScanning: false,
      isCleaning: false,
      showScanSuccessAlert: false,
      scanSuccessCount: 0,
      scanSuccessBytes: 0,
      showCleanSuccessAlert: false,
      lastCleanedBytes: 0,
      lastCleanedCount: 0,
      showCleanConfirmAlert: false,
      cleanTarget: 'selected',
      estimateToken: 0,
      estimateCategory: 'all',
      estimateCount: 0,
      prefs: { ...DEFAULT_PREFS },
      homeDir: '',
      agentIcons: {},
      columnWidths: readColumnWidths()
    }
  }

  // MARK: - 订阅

  subscribe = (listener: Listener): (() => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  getSnapshot = (): CleanState => this.state

  private set(patch: Partial<CleanState>): void {
    this.state = { ...this.state, ...patch }
    for (const listener of this.listeners) listener()
  }

  // MARK: - 派生数据（selector，不进 state）

  /**
   * 当前可见的会话列表。
   *
   * 搜索词有 120ms 防抖：
   * 一次全盘扫描可能有上万条会话，每敲一个键就重算全量过滤会明显掉帧。
   * 注意口径：防抖值优先，无防抖值时才用即时值 —— 所以「按 Esc 立刻清空搜索」
   * 不会因为防抖还在跑而慢半拍。
   */
  getFilteredConversations(state: CleanState = this.state): ConversationItem[] {
    const query = (state.debouncedSearchText || state.searchText).trim()
    const category = state.selectedCategory

    if (query.length === 0) {
      if (category === 'all') return state.conversations
      return state.conversations.filter((item) => item.category === category)
    }
    const lower = query.toLowerCase()
    return state.conversations.filter((item) => {
      if (category !== 'all' && item.category !== category) return false
      return (
        item.title.toLowerCase().includes(lower) ||
        item.snippet.toLowerCase().includes(lower) ||
        (item.projectPath?.toLowerCase().includes(lower) ?? false) ||
        item.sessionId.toLowerCase().includes(lower)
      )
    })
  }

  /** 每个分类的会话数与字节数，外加 `all` 的汇总。侧栏与确认面板共用。 */
  getCategoryStats(state: CleanState = this.state): Map<AgentCategory, CategoryStats> {
    const stats = emptyStats()
    for (const item of state.conversations) {
      const own = stats.get(item.category) ?? { count: 0, sizeInBytes: 0 }
      stats.set(item.category, {
        count: own.count + 1,
        sizeInBytes: own.sizeInBytes + item.sizeInBytes
      })
      const all = stats.get('all') as CategoryStats
      stats.set('all', { count: all.count + 1, sizeInBytes: all.sizeInBytes + item.sizeInBytes })
    }
    return stats
  }

  getTotalSize(state: CleanState = this.state): number {
    let total = 0
    for (const item of state.conversations) total += item.sizeInBytes
    return total
  }

  getSelectedConversation(state: CleanState = this.state): ConversationItem | null {
    if (state.selectedConversationId === null) return null
    return state.conversations.find((item) => item.id === state.selectedConversationId) ?? null
  }

  getSelectedItems(state: CleanState = this.state): ConversationItem[] {
    return state.conversations.filter((item) => item.isSelected)
  }

  getSelectedSize(state: CleanState = this.state): number {
    let total = 0
    for (const item of state.conversations) if (item.isSelected) total += item.sizeInBytes
    return total
  }

  getCurrentCategorySize(state: CleanState = this.state): number {
    let total = 0
    for (const item of this.getFilteredConversations(state)) total += item.sizeInBytes
    return total
  }

  /** 待清理目标集合。面板、确认前记账、执行三处共用，避免各自 reduce。 */
  getCleanTargets(state: CleanState = this.state): ConversationItem[] {
    return state.cleanTarget === 'selected'
      ? this.getSelectedItems(state)
      : this.getFilteredConversations(state)
  }

  // MARK: - 动作

  async bootstrap(): Promise<void> {
    const [prefs, info, icons] = await Promise.all([
      window.api.getPrefs(),
      window.api.getAppInfo(),
      window.api.getAgentIcons()
    ])
    this.set({ prefs, homeDir: info.home, agentIcons: icons })
    await this.scanOnLaunchIfEnabled()
  }

  /**
   * 启动扫描的唯一入口。
   * 幂等：后续新开的窗口也会调它，谁先到谁扫，后到的直接退出 ——
   * 不把全盘扫描重复几遍。
   */
  async scanOnLaunchIfEnabled(): Promise<void> {
    if (this.hasAttemptedLaunchScan) return
    this.hasAttemptedLaunchScan = true
    if (!this.state.prefs.autoScanOnLaunch) return
    await this.scanConversations()
  }

  async scanConversations(): Promise<void> {
    if (this.state.isScanning) return
    this.set({ isScanning: true, showScanSuccessAlert: false, showCleanSuccessAlert: false })
    try {
      const result = await window.api.scanAll()
      this.set({
        conversations: result.items,
        agentInfos: result.agents,
        scanIssues: result.issues,
        isScanning: false,
        hasScanned: true,
        // 原型 `flashOk("扫描完成 · 命中 N 个会话，合计 X。")`
        scanSuccessCount: result.items.length,
        scanSuccessBytes: result.items.reduce((sum, item) => sum + item.sizeInBytes, 0),
        showScanSuccessAlert: true
      })
      this.reconcileSelectedCategory()
    } catch (error) {
      this.set({ isScanning: false, hasScanned: true })
      console.error('[scan] 扫描失败：', error)
    }
  }

  /**
   * 扫描完成后校正 `selectedCategory`。
   *
   * 分类是从 localStorage 恢复的，而可见分类取决于**本机装了什么**。
   * 上一台机器装过 Cursor、这台没装时，恢复出来的 `cursor` 在侧栏里根本不存在，
   * 列表却按它过滤 —— 结果是「选了个看不见的分类，右边空空如也」。
   */
  private reconcileSelectedCategory(): void {
    const current = this.state.selectedCategory
    if (current === 'all') return
    const installed = new Set(
      this.state.agentInfos.filter((info) => info.isInstalled).map((info) => info.category)
    )
    if (installed.has(current)) return
    this.setSelectedCategory('all')
  }

  setSelectedCategory(category: AgentCategory): void {
    writeSelectedCategory(category)
    this.set({ selectedCategory: category })
  }

  setSearchText(text: string): void {
    // 即时字段先变（搜索框受控，字符不能等 120ms 才出现）。
    this.set({ searchText: text })
    if (this.debounceTimer !== null) clearTimeout(this.debounceTimer)
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = null
      // 换新快照 → React 才会重渲染 → 过滤结果真的刷新。
      this.set({ debouncedSearchText: text })
    }, 120)
  }

  /** 立即把防抖后的搜索词也清掉（Esc 逐级清空时用，不等 120ms）。 */
  flushSearchText(): void {
    if (this.debounceTimer !== null) {
      clearTimeout(this.debounceTimer)
      this.debounceTimer = null
    }
    this.set({ searchText: '', debouncedSearchText: '' })
  }

  /** ⌘F：请求搜索框获得焦点。自增计数，见文件头不变量 3。 */
  requestSearchFocus(): void {
    this.set({ searchFocusRequest: this.state.searchFocusRequest + 1 })
  }

  setSelectedConversationId(id: string | null): void {
    this.set({ selectedConversationId: id })
  }

  /** 移动选中项到当前可见列表的上一条 / 下一条。`delta` 为 -1 / +1。 */
  moveSelection(delta: -1 | 1): void {
    const visible = this.getFilteredConversations()
    if (visible.length === 0) return
    const currentIndex = visible.findIndex(
      (item) => item.id === this.state.selectedConversationId
    )
    const nextIndex =
      currentIndex === -1
        ? delta === 1
          ? 0
          : visible.length - 1
        : Math.min(visible.length - 1, Math.max(0, currentIndex + delta))
    this.set({ selectedConversationId: (visible[nextIndex] as ConversationItem).id })
  }

  /** 全选 / 取消全选。只作用于**当前可见**（已筛选）的集合。 */
  selectAll(select: boolean): void {
    const visibleIds = new Set(this.getFilteredConversations().map((item) => item.id))
    this.set({
      conversations: this.state.conversations.map((item) =>
        visibleIds.has(item.id) ? { ...item, isSelected: select } : item
      )
    })
  }

  setItemSelected(id: string, selected: boolean): void {
    this.set({
      conversations: this.state.conversations.map((item) =>
        item.id === id ? { ...item, isSelected: selected } : item
      )
    })
  }

  // MARK: - 清理流程

  requestCleanSelected(): void {
    if (this.getSelectedItems().length === 0) return
    this.presentCleanConfirm('selected')
  }

  requestCleanAll(): void {
    if (this.getFilteredConversations().length === 0) return
    this.presentCleanConfirm('allInCurrentCategory')
  }

  private presentCleanConfirm(target: CleanTarget): void {
    // 钉住打开时的分类：面板是「整类清理」语义，期间切分类不该改它的目标集合。
    this.set({ cleanTarget: target, estimateCategory: this.state.selectedCategory })
    this.refreshEstimate()

    if (!this.state.prefs.confirmBeforeClean) {
      void this.executeClean()
      return
    }
    this.set({ showCleanConfirmAlert: true })
  }

  /**
   * 预览面板在清单改动后重建。
   * 用自增 token 而不是直接算在 render 里：后者每次重绘都会新建滚动状态、
   * 把滚动位置弹回顶部。
   */
  refreshEstimate(): void {
    this.set({
      estimateToken: this.state.estimateToken + 1,
      estimateCount: this.getCleanTargets().length
    })
  }

  cancelClean(): void {
    this.set({ showCleanConfirmAlert: false })
  }

  async executeClean(): Promise<void> {
    if (this.state.isCleaning) return
    const targets = this.getCleanTargets()
    if (targets.length === 0) {
      this.set({ isCleaning: false, showCleanConfirmAlert: false })
      return
    }

    this.set({ isCleaning: true, showScanSuccessAlert: false, showCleanConfirmAlert: false })
    try {
      const result = await window.api.cleanDelete(targets)
      const deletedIds = new Set(targets.map((item) => item.id))
      const conversations = this.state.conversations.filter((item) => !deletedIds.has(item.id))
      this.set({
        conversations,
        agentInfos: recomputeAgentInfos(conversations, this.state.agentInfos),
        lastCleanedBytes: result.freedBytes > 0 ? result.freedBytes : sumSizes(targets),
        lastCleanedCount: targets.length,
        isCleaning: false,
        showCleanSuccessAlert: true
      })
    } catch (error) {
      this.set({ isCleaning: false })
      console.error('[clean] 清理失败：', error)
    }
  }

  async deleteSingle(item: ConversationItem): Promise<void> {
    this.set({ isCleaning: true, showScanSuccessAlert: false })
    try {
      const result = await window.api.cleanDelete([item])
      const conversations = this.state.conversations.filter((c) => c.id !== item.id)
      this.set({
        conversations,
        agentInfos: recomputeAgentInfos(conversations, this.state.agentInfos),
        lastCleanedBytes: result.freedBytes > 0 ? result.freedBytes : item.sizeInBytes,
        lastCleanedCount: 1,
        isCleaning: false,
        showCleanSuccessAlert: true
      })
    } catch (error) {
      this.set({ isCleaning: false })
      console.error('[clean] 单条删除失败：', error)
    }
  }

  /** 整类清空（设置页 / 侧栏的「清空本分类」）。 */
  async cleanAllOfCategory(category: AgentCategory): Promise<void> {
    this.set({ isCleaning: true, showScanSuccessAlert: false })
    try {
      const result = await window.api.cleanAll(category)
      const conversations = this.state.conversations.filter(
        (item) => category === 'all' || item.category !== category
      )
      this.set({
        conversations,
        agentInfos: recomputeAgentInfos(conversations, this.state.agentInfos),
        lastCleanedBytes: result.freedBytes,
        lastCleanedCount: 0,
        isCleaning: false,
        showCleanSuccessAlert: true
      })
    } catch (error) {
      this.set({ isCleaning: false })
      console.error('[clean] 整类清空失败：', error)
    }
  }

  dismissAlerts(): void {
    this.set({ showScanSuccessAlert: false, showCleanSuccessAlert: false })
  }

  // MARK: - 设置 / shell

  async setPref<K extends keyof Prefs>(key: K, value: Prefs[K]): Promise<void> {
    const prefs = await window.api.setPrefs({ [key]: value } as Partial<Prefs>)
    this.set({ prefs })
    if (key === 'autoScanOnLaunch' && value) {
      // 刚打开「启动时自动扫描」就立刻补一次扫描，
      // 否则用户得重启应用才看得到效果。
      this.hasAttemptedLaunchScan = false
      await this.scanOnLaunchIfEnabled()
    }
  }

  async revealInFinder(item: ConversationItem): Promise<void> {
    const first = item.associatedPaths.find((path) => existsSyncSafe(path))
    const target = first ?? (item.projectPath && existsSyncSafe(item.projectPath) ? item.projectPath : null)
    if (target === null) return
    await window.api.revealInFinder(target)
  }

  async copyToClipboard(text: string): Promise<void> {
    await window.api.copyText(text)
  }

  async openStoragePath(path: string): Promise<void> {
    await window.api.openPath(path)
  }

  setColumnWidths(widths: ColumnWidths): void {
    writeColumnWidths(widths)
    this.set({ columnWidths: widths })
  }

  // MARK: - 说明文案

  /** 「回收空项目目录」关掉时，侧栏那句说明文字要跟着变。 */
  get emptyFolderPolicyText(): string {
    return this.state.prefs.cleanEmptyProjectFolders
      ? '删除会话后会一并回收空目录与子代理目录。'
      : '空目录将保留在磁盘上，可在设置中开启回收。'
  }

  /** 「同时清理文件历史快照」关掉时，删除只删正文、保留快照。 */
  get snapshotPolicyText(): string {
    return this.state.prefs.cleanFileHistorySnapshots
      ? '清理时同步删除快照与子代理数据。'
      : '清理时保留文件改动快照，只删会话文件。'
  }
}

function sumSizes(items: readonly ConversationItem[]): number {
  let total = 0
  for (const item of items) total += item.sizeInBytes
  return total
}

/**
 * 清理后重算各分类的条数与字节数，但**保留 `isInstalled` 与 `storagePath`** ——
 * 那两个是扫描器的属性，不是会话数据的属性，重算会话列表不该让它们退回默认值。
 */
function recomputeAgentInfos(
  conversations: readonly ConversationItem[],
  previous: readonly AgentInfo[]
): AgentInfo[] {
  return previous.map((info) => {
    let sessionCount = 0
    let totalBytes = 0
    for (const item of conversations) {
      if (item.category !== info.category) continue
      sessionCount += 1
      totalBytes += item.sizeInBytes
    }
    return { ...info, sessionCount, totalBytes }
  })
}

/** 渲染进程没有 fs，路径是否存在只能问主进程；这里退化为「非空即认为存在」。 */
function existsSyncSafe(path: string): boolean {
  return path.length > 0
}

function readColumnWidths(): ColumnWidths {
  try {
    const raw = localStorage.getItem(LS_COLUMN_WIDTHS)
    if (!raw) return { ...DEFAULT_COLUMN_WIDTHS }
    const parsed = JSON.parse(raw) as Partial<ColumnWidths>
    return {
      sidebar: typeof parsed.sidebar === 'number' ? parsed.sidebar : DEFAULT_COLUMN_WIDTHS.sidebar,
      list: typeof parsed.list === 'number' ? parsed.list : DEFAULT_COLUMN_WIDTHS.list
    }
  } catch {
    return { ...DEFAULT_COLUMN_WIDTHS }
  }
}

function writeColumnWidths(widths: ColumnWidths): void {
  try {
    localStorage.setItem(LS_COLUMN_WIDTHS, JSON.stringify(widths))
  } catch {
    /* localStorage 不可用（隐私模式）时静默降级为不记忆 */
  }
}

function readSelectedCategory(): AgentCategory {
  try {
    const raw = localStorage.getItem(LS_SELECTED_CATEGORY)
    if (raw && (ALL_CATEGORIES as string[]).includes(raw)) return raw as AgentCategory
  } catch {
    /* ignore */
  }
  return 'all'
}

function writeSelectedCategory(category: AgentCategory): void {
  try {
    localStorage.setItem(LS_SELECTED_CATEGORY, category)
  } catch {
    /* ignore */
  }
}

/** 全应用单例。挂在 module 上而不是 context 上：状态只有一份，没有多 Provider 的理由。 */
export const cleanStore = new CleanStore()

/** 订阅整份 state。 */
export function useCleanState(): CleanState {
  return useSyncExternalStore(cleanStore.subscribe, cleanStore.getSnapshot, cleanStore.getSnapshot)
}

/**
 * 订阅一个派生值。
 *
 * `selector` 必须在**两次调用之间返回同一个引用**（`===`），
 * 否则 React 会认为状态一直在变，陷入无限重渲染。
 * 所以这里的 selector 只做「返回 store 里已有的对象 / 立即算出的新数组」，
 * 不要在里面 `.map()` 出一个新数组又指望它被跳过。
 * 需要复杂派生时用 `useMemo` 在组件里包一层。
 */
export function useCleanSelector<T>(selector: (state: CleanState) => T): T {
  const getSelection = useCallback(() => selector(cleanStore.getSnapshot()), [selector])
  return useSyncExternalStore(cleanStore.subscribe, getSelection, getSelection)
}

/** 动作表。用法：`const { scanConversations } = useCleanActions()`。 */
export function useCleanActions() {
  return {
    bootstrap: () => cleanStore.bootstrap(),
    scanConversations: () => cleanStore.scanConversations(),
    scanOnLaunchIfEnabled: () => cleanStore.scanOnLaunchIfEnabled(),
    setSelectedCategory: (category: AgentCategory) =>
      cleanStore.setSelectedCategory(category),
    setSearchText: (text: string) => cleanStore.setSearchText(text),
    flushSearchText: () => cleanStore.flushSearchText(),
    requestSearchFocus: () => cleanStore.requestSearchFocus(),
    setSelectedConversationId: (id: string | null) =>
      cleanStore.setSelectedConversationId(id),
    moveSelection: (delta: -1 | 1) => cleanStore.moveSelection(delta),
    selectAll: (select: boolean) => cleanStore.selectAll(select),
    setItemSelected: (id: string, selected: boolean) =>
      cleanStore.setItemSelected(id, selected),
    requestCleanSelected: () => cleanStore.requestCleanSelected(),
    requestCleanAll: () => cleanStore.requestCleanAll(),
    cancelClean: () => cleanStore.cancelClean(),
    refreshEstimate: () => cleanStore.refreshEstimate(),
    executeClean: () => cleanStore.executeClean(),
    deleteSingle: (item: ConversationItem) => cleanStore.deleteSingle(item),
    cleanAllOfCategory: (category: AgentCategory) =>
      cleanStore.cleanAllOfCategory(category),
    dismissAlerts: () => cleanStore.dismissAlerts(),
    setPref: <K extends keyof Prefs>(key: K, value: Prefs[K]) =>
      cleanStore.setPref(key, value),
    revealInFinder: (item: ConversationItem) => cleanStore.revealInFinder(item),
    copyToClipboard: (text: string) => cleanStore.copyToClipboard(text),
    openStoragePath: (path: string) => cleanStore.openStoragePath(path),
    setColumnWidths: (widths: ColumnWidths) => cleanStore.setColumnWidths(widths)
  }
}
