import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { RefObject } from 'react'
import { formatBytes } from '@shared/format'
import { DrawnButton, DrawnIcon, DrawnIconButton } from '@renderer/components/DrawnControls'
import { Splitter } from '@renderer/components/Splitter'
import { cleanStore, useCleanActions, useCleanState } from '@renderer/state/cleanStore'
import { ConversationListView } from '@renderer/views/ConversationListView'
import { SidebarView } from '@renderer/views/SidebarView'
import { DetailView } from '@renderer/views/DetailView'
import { OverviewView } from '@renderer/views/OverviewView'
import { SettingsView } from '@renderer/views/SettingsView'
import CleanConfirmSheet from '@renderer/views/CleanConfirmSheet'
import styles from './App.module.css'

/**
 * 应用外壳：三栏工作台 + 顶栏 + 全局键盘。
 *
 * 移植自 `ConversationClean/ContentView.swift`。
 *
 * 为什么不是 `NavigationSplitView`：后者会自己往窗口上挂一条 NSToolbar
 * （多出约 52px 带子）、给侧栏套 sidebar 材质，形态都不是我们要的。
 * 三栏手搓 HStack，隐藏标题栏把标题栏那块变成我们自己的背景，
 * 代价是得自己给红绿灯让出左侧 78px（`--size-traffic-light-inset`）。
 *
 * 外壳样式（`.app` / `.topBar` / `.cols` / `.col*` / `.overlay` / `.settingsPanel`）
 * 在 `App.module.css`，与分隔条自己的 `Splitter.module.css` 分开 ——
 * 早先这两份是同一文件，因为分配给本任务的文件清单里没有 `App.module.css`；
 * 现在拆开了，CSS Modules 的类名才会在「谁定义」这件事上说得清。
 *
 * 右侧两个插槽（`views/` 下，UI-views 子代理产出）的 props 契约：
 *   · `DetailView({ item })` —— `item: ConversationItem | null`，传 null 时它自己渲染 OverviewView。
 *     App 只负责把 `cleanStore.getSelectedConversation()` 的结果喂进去。
 *   · `SettingsView({ onClose, initialTab })` —— 自己不带遮罩，遮罩与显隐由 App 编排。
 */

/**
 * 三栏的列宽上下限（px）。
 *
 * 与 `tokens.css` 的 `--col-*` **一一对应**。CSS 变量在 JS 里读不到（不引入
 * `getComputedStyle` 运行时测量：那会让首帧多一次强制重排，而这几个数字是静态的），
 * 所以这里必然是同一组数字的第二份表示。
 *
 * 既然无法合并成一份，就用**测试钉住**：`App.test.ts` 会读 `tokens.css` 逐条比对，
 * 两边漂了就红。改一边忘了另一边，构建会直接失败而不是等到运行时才发现。
 *
 * @see src/renderer/src/styles/tokens.css 的 `--col-sidebar-min/max`、`--col-list-min/max`
 */
export const COLUMN_LIMITS = {
  sidebarMin: 168,
  sidebarMax: 320,
  listMin: 320,
  listMax: 720
} as const

const SIDEBAR_MIN = COLUMN_LIMITS.sidebarMin
const SIDEBAR_MAX = COLUMN_LIMITS.sidebarMax
const LIST_MIN = COLUMN_LIMITS.listMin
const LIST_MAX = COLUMN_LIMITS.listMax
/** 详情栏是唯一吃剩余宽度的栏，它的 minWidth 是另两条分隔条拖拽上限的来源。 */
const DETAIL_MIN = 300

export default function App() {
  const state = useCleanState()
  const actions = useCleanActions()

  useEffect(() => {
    void actions.bootstrap()
    // 只在挂载时跑一次：bootstrap 自身幂等，再跑会把全盘扫描重复一遍。
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const [settingsOpen, setSettingsOpen] = useState(false)

  const colsRef = useRef<HTMLDivElement | null>(null)
  const available = useViewportWidth(colsRef)

  const filteredCount = useMemo(
    () => cleanStore.getFilteredConversations(state).length,
    [state]
  )
  const totalSize = useMemo(() => cleanStore.getTotalSize(state), [state])
  const isBusy = state.isScanning || state.isCleaning

  /**
   * 分隔条的可达区间必须随窗口宽度收窄。
   *
   * 固定 max 会拼出这种破图：窗口只有 1000px 时把列表拖到 760，
   * 侧栏又停在 420，1000 - 420 - 760 = -180，剩下不够详情栏的 minWidth，
   * 三栏互相挤到变形。所以上限用 `available - 另一栏的 min - 详情栏 min` 算。
   *
   * 实际生效的宽度要再夹一次，不能只靠拖拽时的 range：存值可能来自一个更宽的
   * 窗口（上次把侧栏拖到 320，现在把窗口缩回 1000），那种情况下 range
   * 从头到尾没参与计算，不夹就会直接挤变形。
   */
  const geometry = useMemo(() => {
    const sidebarCeiling = Math.max(
      SIDEBAR_MIN,
      Math.min(SIDEBAR_MAX, available - LIST_MIN - DETAIL_MIN)
    )
    const sidebar = Math.min(state.columnWidths.sidebar, sidebarCeiling)
    const listCeiling = Math.max(LIST_MIN, Math.min(LIST_MAX, available - sidebar - DETAIL_MIN))
    const list = Math.min(state.columnWidths.list, listCeiling)
    return { sidebar, list, sidebarCeiling, listCeiling }
  }, [available, state.columnWidths])

  const setSidebarWidth = useCallback(
    (sidebar: number) => actions.setColumnWidths({ ...state.columnWidths, sidebar }),
    [actions, state.columnWidths]
  )
  const setListWidth = useCallback(
    (list: number) => actions.setColumnWidths({ ...state.columnWidths, list }),
    [actions, state.columnWidths]
  )

  // 全局键盘。原生 `.keyboardShortcut` 那一套在 Electron 里不存在，全部走这里。
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      const mod = event.metaKey || event.ctrlKey
      const key = event.key.toLowerCase()

      if (mod && key === 'r') {
        event.preventDefault()
        void actions.scanConversations()
        return
      }
      if (mod && (event.key === 'Delete' || event.key === 'Backspace')) {
        event.preventDefault()
        actions.requestCleanSelected()
        return
      }
      if (mod && key === 'f') {
        event.preventDefault()
        actions.requestSearchFocus()
        return
      }
      if (event.key === 'Escape') {
        if (settingsOpen) {
          setSettingsOpen(false)
          return
        }
        if (state.showCleanConfirmAlert) {
          actions.cancelClean()
          return
        }
        // 逐级退：先清搜索词，再清勾选。
        // 行选中（看详情）不参与 —— 它不是「批量操作状态」，
        // Esc 掉它会让人突然丢失右侧详情，且没有对应的恢复手势。
        if (state.searchText.trim().length > 0) {
          actions.setSearchText('')
        } else if (cleanStore.getSelectedItems().length > 0) {
          actions.selectAll(false)
        }
        return
      }
      if (event.key !== 'ArrowUp' && event.key !== 'ArrowDown') return
      // 列表自己有 ↑↓，且它处理过的事件会 preventDefault —— 别抢。
      if (event.defaultPrevented) return
      // 在输入框里打字时 ↑↓ 属于输入框，不能顺手把列表选中行也挪走。
      if (isEditableTarget(event.target)) return
      event.preventDefault()
      actions.moveSelection(event.key === 'ArrowDown' ? 1 : -1)
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [actions, settingsOpen, state.searchText, state.showCleanConfirmAlert])

  return (
    <div className={styles['app']}>
      <header className={styles['topBar']}>
        <span className={styles['brand']}>ConversationClean</span>
        <span className={styles['brandSub']}>会话清理</span>
        <span className={styles['topDivider']} />
        <span className={styles['topTotal']}>{formatBytes(totalSize)}</span>
        <span className={styles['topTotalNote']}>· {state.conversations.length} 个会话</span>
        <span className={styles['grow']} />

        {/* 危险动作图标用 dangerQuiet（红前景、无底色）：顶栏只有 26px 高，
            实心红底会扎眼，但灰色又会让「删全部」看起来和「设置」一样重。 */}
        <DrawnIconButton
          icon={<DrawnIcon name="trash" size={12} />}
          variant="dangerQuiet"
          help="清除当前列表中的全部会话"
          disabled={filteredCount === 0 || isBusy}
          onClick={actions.requestCleanAll}
        />
        <DrawnButton
          variant="primary"
          disabled={isBusy}
          help="扫描本机全部 Agent 的会话缓存"
          icon={<DrawnIcon name={state.isScanning ? 'scan' : 'refresh'} size={11} />}
          onClick={() => void actions.scanConversations()}
        >
          {state.isScanning ? '正在扫描…' : '一键扫描'}
        </DrawnButton>
        <DrawnIconButton
          icon={<DrawnIcon name="gear" size={12} />}
          help="设置"
          onClick={() => setSettingsOpen(true)}
        />
      </header>

      <div className={styles['cols']} ref={colsRef}>
        <div
          className={`${styles['col']} ${styles['colSidebar']}`}
          style={{ width: geometry.sidebar }}
        >
          <SidebarView onOpenSettings={() => setSettingsOpen(true)} />
        </div>

        <Splitter
          width={geometry.sidebar}
          min={SIDEBAR_MIN}
          max={geometry.sidebarCeiling}
          growsWithRightwardDrag
          onChange={setSidebarWidth}
        />

        <div
          className={`${styles['col']} ${styles['colList']}`}
          style={{ width: geometry.list }}
        >
          <ConversationListView />
        </div>

        {/* 列表是中间栏，往右拖它变宽、详情栏变窄，所以方向取反。 */}
        <Splitter
          width={geometry.list}
          min={LIST_MIN}
          max={geometry.listCeiling}
          growsWithRightwardDrag={false}
          onChange={setListWidth}
        />

        <div className={`${styles['col']} ${styles['colDetail']}`}>
          <DetailView item={cleanStore.getSelectedConversation(state)} />
        </div>
      </div>

      {/* 清理二次确认：无 props，自己连 store 读 `showCleanConfirmAlert`，
          常年挂在根上，开不开由它自己判断（Swift 的 `.sheet` 语义）。 */}
      <CleanConfirmSheet />

      {settingsOpen ? (
        <div
          className={styles['overlay']}
          role="presentation"
          onMouseDown={() => setSettingsOpen(false)}
        >
          <div
            className={styles['settingsPanel']}
            role="dialog"
            aria-modal="true"
            aria-label="设置"
            onMouseDown={(event) => event.stopPropagation()}
          >
            <SettingsView onClose={() => setSettingsOpen(false)} />
          </div>
        </div>
      ) : null}
    </div>
  )
}

/**
 * `OverviewView` 由 `DetailView` 在 `item === null` 时自行渲染，
 * 这里显式再挂一份会重复。保留导出是为了让 `DetailView` 的契约在
 * App 这一层可读（见文件头注释），不实际渲染。
 */
export { OverviewView }

// MARK: - 工具

function isEditableTarget(target: EventTarget | null): boolean {
  if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) return true
  return target instanceof HTMLElement && target.isContentEditable
}

/** 量三栏容器的宽度。测不到（首帧 / jsdom）时退回 `window.innerWidth`。 */
function useViewportWidth(ref: RefObject<HTMLElement | null>): number {
  const [width, setWidth] = useState(0)
  useEffect(() => {
    const measure = () => setWidth(ref.current?.getBoundingClientRect().width || window.innerWidth)
    measure()
    window.addEventListener('resize', measure)
    return () => window.removeEventListener('resize', measure)
  }, [ref])
  return width
}
