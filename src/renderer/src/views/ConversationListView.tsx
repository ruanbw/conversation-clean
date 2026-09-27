import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { KeyboardEvent as ReactKeyboardEvent, MouseEvent as ReactMouseEvent, RefObject } from 'react'
import type { AgentCategory, ConversationItem } from '@shared/types'
import { CATEGORY_LABELS } from '@shared/types'
import { formatBytes, formatRelativeDate, pathTail } from '@shared/format'
import { AgentMark } from '@renderer/components/AgentGlyph'
import {
  DrawnButton,
  DrawnCheckbox,
  DrawnEmptyState,
  DrawnIcon,
  DrawnIconButton,
  DrawnNotice,
  DrawnSearchField,
  DrawnSegmented,
  Hairline,
  ShareBar
} from '@renderer/components/DrawnControls'
import { cleanStore, useCleanActions, useCleanState } from '@renderer/state/cleanStore'
import styles from './ConversationListView.module.css'

/**
 * 会话列表。
 *
 * 移植自 `ConversationClean/Views/ConversationListView.swift`。视觉按 `ui-a-precision.html`，
 * 修掉的四处：
 *   ① 系统 `List` → 自绘虚拟化。行完全自绘，选中态用「2px 靛蓝竖条 + 极淡靛蓝底」
 *      内嵌在行里（不占布局，不会把文字推歪）。
 *   ② 62px 的会话 ID 列删掉 —— 它用三级字，肉眼几乎看不见，却占着右对齐数字区里
 *      最宽的一格，把体积挤到了一边。纯浪费的视觉预算。
 *   ③ 体积提到 12.5px semibold（比标题的 medium 更重）。标题比体积更重，
 *      在一个「清理 99MB 垃圾」的工具里层级是反的。
 *   ④ 禁用的「清理选中项」不换色，只降 opacity。
 *
 * **虚拟化**：不引第三方库。按可视窗口切片渲染 + 6 行 overscan；
 * 行高固定 32px（`--size-row`），所以偏移量就是 `index * 32`。
 * 测不到高度时（jsdom、尚未布局）退化为全量渲染 —— 宁可多画，也不要白屏。
 */

/** 排序模式。Swift 是文件私有的 `ListSortMode`（默认 `.size`）。 */
export const SORT_MODES = ['date', 'size', 'msgs'] as const
export type SortMode = (typeof SORT_MODES)[number]

const SORT_LABELS: Record<SortMode, string> = {
  date: '最近更新',
  size: '占用空间',
  msgs: '对话轮数'
}

const SORT_OPTIONS: { value: SortMode; label: string }[] = SORT_MODES.map((mode) => ({
  value: mode,
  label: SORT_LABELS[mode]
}))

/** 行高，与 `--size-row` 一致。CSS 里那一条也写死了 32px，改一处要改两处。 */
const ROW_HEIGHT = 32
const OVERSCAN = 6

/** Swift 用 `@AppStorage("listSortMode")` / `@AppStorage("searchText")`，键名照搬。 */
const LS_SORT = 'listSortMode'
const LS_SEARCH = 'searchText'

export function ConversationListView() {
  const state = useCleanState()
  const actions = useCleanActions()

  const [sort, setSort] = useState<SortMode>(readSort)
  const searchText = state.searchText
  const isBusy = state.isScanning || state.isCleaning

  // 搜索词持久化（Swift 的 `@AppStorage("searchText")`）。挂载时回填一次。
  useEffect(() => {
    const saved = readString(LS_SEARCH)
    if (saved.length > 0 && state.searchText.length === 0) actions.setSearchText(saved)
    // 只在挂载时跑一次。
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
  useEffect(() => {
    writeString(LS_SEARCH, searchText)
  }, [searchText])

  const rows = useMemo(() => {
    const sorted = [...cleanStore.getFilteredConversations(state)]
    if (sort === 'date') sorted.sort(byUpdatedDesc)
    else if (sort === 'size') sorted.sort(bySizeDesc)
    else sorted.sort(byMessagesDesc)
    return sorted
  }, [state, sort])

  const totalSize = useMemo(() => cleanStore.getTotalSize(state), [state])
  const selectedItems = useMemo(() => cleanStore.getSelectedItems(state), [state])
  const selectedSize = useMemo(() => cleanStore.getSelectedSize(state), [state])
  const allSelected = rows.length > 0 && rows.every((item) => item.isSelected)
  const someSelected = !allSelected && rows.some((item) => item.isSelected)
  const hasQuery = searchText.trim().length > 0

  const scrollRef = useRef<HTMLDivElement | null>(null)
  const [scrollTop, setScrollTop] = useState(0)
  const viewportH = useViewportHeight(scrollRef)

  // 列表默认吃掉键盘焦点（对应 Swift 的 `.focusable()`）——
  // 否则 ↑↓ 只有一个需要点一下列表才生效的隐藏前提。
  useEffect(() => {
    scrollRef.current?.focus()
  }, [])

  // 选中行变化时把它滚进视野（Swift 的 `proxy.scrollTo(id, anchor: .center)`）。
  useEffect(() => {
    const id = state.selectedConversationId
    const el = scrollRef.current
    if (!id || !el) return
    const index = rows.findIndex((item) => item.id === id)
    if (index < 0) return
    const top = index * ROW_HEIGHT
    if (top < el.scrollTop || top + ROW_HEIGHT > el.scrollTop + el.clientHeight) {
      el.scrollTop = Math.max(0, top - el.clientHeight / 2 + ROW_HEIGHT / 2)
    }
  }, [state.selectedConversationId, rows])

  const onSortChange = useCallback((next: SortMode) => {
    writeString(LS_SORT, next)
    setSort(next)
  }, [])

  const [menu, setMenu] = useState<{ item: ConversationItem; x: number; y: number } | null>(null)
  useEffect(() => {
    if (!menu) return
    const close = () => setMenu(null)
    const onKey = (event: globalThis.KeyboardEvent) => {
      if (event.key === 'Escape') close()
    }
    document.addEventListener('mousedown', close)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', close)
      document.removeEventListener('keydown', onKey)
    }
  }, [menu])

  // ↑↓ / Home / End / Space。系统 List 自带这些行为，自绘后必须自己补，
  // 否则列表只能用鼠标点 —— 那是可用性回退，不是等价替换。
  //
  // 步进走的是**当前排序后的 `rows`**，不是 store 的 `getFilteredConversations()`：
  // 默认排序是「占用空间」，store 那个数组还是扫描顺序（多数扫描器按时间倒序）。
  // 直接用 store 的 `moveSelection` 会让 ↓ 在「时间序」和「体积序」之间跳。
  const onListKeyDown = useCallback(
    (event: ReactKeyboardEvent<HTMLDivElement>) => {
      const target = event.target
      if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) return
      const current = rows.findIndex((row) => row.id === state.selectedConversationId)
      switch (event.key) {
        case 'ArrowDown':
        case 'ArrowUp': {
          if (rows.length === 0) return
          event.preventDefault()
          // 没有任何选中时：↓ 进第一条、↑ 进最后一条
          const delta = event.key === 'ArrowDown' ? 1 : -1
          const next =
            current === -1
              ? delta > 0
                ? 0
                : rows.length - 1
              : Math.min(rows.length - 1, Math.max(0, current + delta))
          const target2 = rows[next]
          if (target2) actions.setSelectedConversationId(target2.id)
          return
        }
        case 'Home': {
          event.preventDefault()
          const first = rows[0]
          if (first) actions.setSelectedConversationId(first.id)
          return
        }
        case 'End': {
          event.preventDefault()
          const last = rows[rows.length - 1]
          if (last) actions.setSelectedConversationId(last.id)
          return
        }
        case ' ': {
          const item = current >= 0 ? rows[current] : undefined
          if (!item) return
          event.preventDefault()
          if (!isBusy) actions.setItemSelected(item.id, !item.isSelected)
          return
        }
        default:
          break
      }
    },
    [actions, isBusy, rows, state.selectedConversationId]
  )

  const anchorId = useRef<string | null>(null)

  const onRowClick = useCallback(
    (item: ConversationItem, event: ReactMouseEvent<HTMLDivElement>) => {
      // Shift+点击连选：从锚点连到本行，全部置成本行勾选框**将要变成**的状态。
      if (event.shiftKey) {
        const from = anchorId.current ? rows.findIndex((row) => row.id === anchorId.current) : -1
        const to = rows.findIndex((row) => row.id === item.id)
        if (from >= 0 && to >= 0 && !isBusy) {
          const [start, end] = from <= to ? [from, to] : [to, from]
          const next = !item.isSelected
          for (let i = start; i <= end; i += 1) {
            const target = rows[i]
            if (target && target.isSelected !== next) actions.setItemSelected(target.id, next)
          }
        }
        anchorId.current = item.id
        actions.setSelectedConversationId(item.id)
        return
      }
      anchorId.current = item.id
      actions.setSelectedConversationId(item.id)
    },
    [actions, isBusy, rows]
  )

  const onToggle = useCallback(
    (id: string) => {
      if (isBusy) return
      const item = state.conversations.find((row) => row.id === id)
      actions.setItemSelected(id, !(item?.isSelected ?? false))
    },
    [actions, isBusy, state.conversations]
  )

  // 可视窗口切片。测不到高度就全量渲染。
  const start = viewportH > 0 ? Math.max(0, Math.floor(scrollTop / ROW_HEIGHT) - OVERSCAN) : 0
  const end =
    viewportH > 0
      ? Math.min(rows.length, start + Math.ceil(viewportH / ROW_HEIGHT) + OVERSCAN * 2)
      : rows.length
  const visible = rows.slice(start, end)

  return (
    <div className={styles['list']}>
      <div className={styles['filter']}>
        <DrawnSearchField
          value={searchText}
          onChange={actions.setSearchText}
          placeholder="搜索标题、摘要、项目路径或会话 ID"
          focusRequest={state.searchFocusRequest}
        />
        <div className={styles['filterRow']}>
          <DrawnSegmented value={sort} options={SORT_OPTIONS} onChange={onSortChange} />
          <span className={styles['count']}>共 {rows.length} 项</span>
          <DrawnIconButton
            icon={<DrawnIcon name="refresh" size={11} />}
            help="重新扫描"
            variant="flat"
            disabled={isBusy}
            onClick={() => void actions.scanConversations()}
          />
        </div>
      </div>

      <Hairline edge="bottom" />

      {state.showCleanSuccessAlert ? (
        <DrawnNotice
          className={styles['notice']}
          text={`清理完成 · 删除 ${state.lastCleanedCount} 个会话，释放 ${formatBytes(
            state.lastCleanedBytes
          )} 磁盘空间，剩余 ${state.conversations.length} 个会话。`}
          dismissTitle="知道了"
          onDismiss={actions.dismissAlerts}
        />
      ) : state.showScanSuccessAlert ? (
        <DrawnNotice
          className={styles['notice']}
          text={`扫描完成 · 命中 ${state.scanSuccessCount} 个会话，合计 ${formatBytes(
            state.scanSuccessBytes
          )}。`}
          dismissTitle="知道了"
          onDismiss={actions.dismissAlerts}
        />
      ) : null}

      {rows.length === 0 ? (
        <EmptyState
          isScanning={state.isScanning}
          hasScanned={state.hasScanned}
          hasQuery={hasQuery}
          query={searchText.trim()}
          category={state.selectedCategory}
          totalConversations={state.conversations.length}
          onScan={() => void actions.scanConversations()}
          onClearSearch={() => actions.setSearchText('')}
        />
      ) : (
        <div
          ref={scrollRef}
          className={styles['scroll']}
          tabIndex={0}
          role="listbox"
          aria-label="会话列表"
          onKeyDown={onListKeyDown}
          onScroll={(event) => setScrollTop(event.currentTarget.scrollTop)}
        >
          <div className={styles['canvas']} style={{ height: rows.length * ROW_HEIGHT }}>
            <div
              className={styles['window']}
              style={{ transform: `translateY(${start * ROW_HEIGHT}px)` }}
            >
              {visible.map((item) => (
                <ConversationRow
                  key={item.id}
                  item={item}
                  totalSize={totalSize}
                  isFocused={state.selectedConversationId === item.id}
                  isMixed={!item.isSelected && someSelected}
                  isBusy={isBusy}
                  icons={state.agentIcons}
                  onClick={onRowClick}
                  onToggle={onToggle}
                  onContextMenu={(target, position) => setMenu({ item: target, ...position })}
                />
              ))}
            </div>
          </div>
        </div>
      )}

      {menu ? (
        <>
          <div className={styles['ctxBackdrop']} onMouseDown={() => setMenu(null)} />
          <div
            className={styles['ctxMenu']}
            role="menu"
            style={{
              left: Math.max(0, Math.min(menu.x, window.innerWidth - 200)),
              top: Math.max(0, Math.min(menu.y, window.innerHeight - 160))
            }}
          >
            <button
              type="button"
              role="menuitem"
              className={styles['ctxItem']}
              onClick={() => {
                setMenu(null)
                void actions.revealInFinder(menu.item)
              }}
            >
              <DrawnIcon name="folder" size={12} />
              在 Finder 中显示
            </button>
            <button
              type="button"
              role="menuitem"
              className={styles['ctxItem']}
              onClick={() => {
                setMenu(null)
                void actions.copyToClipboard(menu.item.projectPath ?? '')
              }}
            >
              <DrawnIcon name="reveal" size={12} />
              复制项目路径
            </button>
            <button
              type="button"
              role="menuitem"
              className={styles['ctxItem']}
              onClick={() => {
                setMenu(null)
                void actions.copyToClipboard(menu.item.sessionId)
              }}
            >
              <DrawnIcon name="info" size={12} />
              复制会话 ID
            </button>
            <div className={styles['ctxDivider']} />
            <button
              type="button"
              role="menuitem"
              className={`${styles['ctxItem']} ${styles['ctxItemDanger']}`}
              onClick={() => {
                setMenu(null)
                void actions.deleteSingle(menu.item)
              }}
            >
              <DrawnIcon name="trash" size={12} />
              删除此会话
            </button>
          </div>
        </>
      ) : null}

      <div className={styles['batch']}>
        <span className={styles['batchStat']}>
          已选 <b>{selectedItems.length}</b> 项 · <b>{formatBytes(selectedSize)}</b>
        </span>
        <div className={styles['batchActions']}>
          <DrawnButton
            variant="flat"
            compact
            paddingX={6}
            disabled={rows.length === 0}
            onClick={() => actions.selectAll(!allSelected)}
          >
            {allSelected ? '取消全选' : '全选当前'}
          </DrawnButton>
          <DrawnIconButton
            icon={<DrawnIcon name="folder" size={11} />}
            help="在 Finder 中显示选中的会话"
            compact
            variant="flat"
            disabled={selectedItems.length === 0 || isBusy}
            onClick={() => {
              for (const item of selectedItems) void actions.revealInFinder(item)
            }}
          />
          <DrawnButton
            variant="danger"
            compact
            icon={<DrawnIcon name="trash" size={11} />}
            disabled={selectedItems.length === 0 || isBusy}
            help="删除选中的会话及其索引行"
            onClick={actions.requestCleanSelected}
          >
            {selectedItems.length > 0 ? `清理选中项（${selectedItems.length}）` : '清理选中项'}
          </DrawnButton>
        </div>
      </div>
    </div>
  )
}

// MARK: - 空态

interface EmptyStateProps {
  isScanning: boolean
  hasScanned: boolean
  hasQuery: boolean
  query: string
  category: AgentCategory
  totalConversations: number
  onScan: () => void
  onClearSearch: () => void
}

function EmptyState({
  isScanning,
  hasScanned,
  hasQuery,
  query,
  category,
  totalConversations,
  onScan,
  onClearSearch
}: EmptyStateProps) {
  if (isScanning) {
    return (
      <DrawnEmptyState
        icon="scan"
        title="正在扫描本机会话…"
        message="正在查找本机各 Agent 的会话缓存，请稍候。"
      />
    )
  }
  if (!hasScanned) {
    return (
      <DrawnEmptyState
        icon="magnifier"
        title="还没有扫描过会话"
        message="已关闭「启动时自动扫描」。点下方按钮手动扫描本机各 Agent 的会话缓存。"
        actionTitle="重新扫描"
        onAction={onScan}
      />
    )
  }
  if (hasQuery) {
    return (
      <DrawnEmptyState
        icon="magnifier"
        title={`没有匹配「${query}」的会话`}
        message={`换个关键词，或清空搜索词看全部 ${totalConversations} 个会话。`}
        actionTitle="清除搜索词"
        onAction={onClearSearch}
      />
    )
  }
  return (
    <DrawnEmptyState
      category={category}
      title={`暂无 ${CATEGORY_LABELS[category]} 会话记录`}
      message="未在本地检测到该 Agent 的历史会话文件，或所有会话均已被清理。"
    />
  )
}

// MARK: - 会话行

interface ConversationRowProps {
  item: ConversationItem
  totalSize: number
  isFocused: boolean
  isMixed: boolean
  isBusy: boolean
  icons: Record<string, string | null>
  onClick: (item: ConversationItem, event: ReactMouseEvent<HTMLDivElement>) => void
  onToggle: (id: string) => void
  onContextMenu: (item: ConversationItem, position: { x: number; y: number }) => void
}

/**
 * 全自绘的行。行高 32px（一屏 24 行）。
 *
 * 副标题给「这条属于哪、什么时候的」，而不是重复标题 —— 标题常常就是首条
 * user prompt 的原文，再显示一遍只会让每行看起来都是重复噪音。
 * 而删除决策需要的是位置与时间。
 */
const ConversationRow = memo(function ConversationRow({
  item,
  totalSize,
  isFocused,
  isMixed,
  isBusy,
  icons,
  onClick,
  onToggle,
  onContextMenu
}: ConversationRowProps) {
  const sharePercent = totalSize > 0 ? (item.sizeInBytes / totalSize) * 100 : 0
  const path = pathTail(item.projectPath ?? '')

  return (
    <div
      className={[
        styles['row'],
        isFocused && styles['rowOn'],
        item.sizeInBytes === 0 && styles['rowZero']
      ]
        .filter(Boolean)
        .join(' ')}
      role="option"
      aria-selected={isFocused}
      data-row-id={item.id}
      onClick={(event) => onClick(item, event)}
      onContextMenu={(event) => {
        event.preventDefault()
        onContextMenu(item, { x: event.clientX, y: event.clientY })
      }}
    >
      <DrawnCheckbox
        checked={item.isSelected}
        mixed={isMixed}
        disabled={isBusy}
        stopPropagation
        label={`选择会话：${item.title}`}
        help={item.isSelected ? '取消选择此会话' : '选择此会话'}
        onChange={() => onToggle(item.id)}
      />
      <span className={styles['rowMark']}>
        <AgentMark category={item.category} icons={icons} size={16} />
      </span>
      <span className={styles['tcol']}>
        <span
          className={[styles['title'], isFocused && styles['titleOn']].filter(Boolean).join(' ')}
        >
          {item.title}
        </span>
        <span className={styles['subtitle']}>
          {path.length > 0 ? (
            <>
              <span className={styles['subtitleText']}>{path}</span>
              <span className={styles['subtitleDot']}>·</span>
            </>
          ) : null}
          <span className={styles['subtitleText']}>
            {formatRelativeDate(new Date(item.updatedAt))}
          </span>
          {item.gitBranch ? (
            <>
              <span className={styles['subtitleDot']}>·</span>
              <span className={styles['subtitleText']}>{item.gitBranch}</span>
            </>
          ) : null}
        </span>
      </span>
      <ShareBar className={styles['share']} percent={sharePercent} height={5} />
      <span
        className={[styles['size'], item.sizeInBytes === 0 && styles['sizeZero']]
          .filter(Boolean)
          .join(' ')}
      >
        {formatBytes(item.sizeInBytes)}
      </span>
    </div>
  )
})

// MARK: - 排序与持久化

function byUpdatedDesc(a: ConversationItem, b: ConversationItem): number {
  return a.updatedAt < b.updatedAt ? 1 : a.updatedAt > b.updatedAt ? -1 : 0
}

function bySizeDesc(a: ConversationItem, b: ConversationItem): number {
  return b.sizeInBytes - a.sizeInBytes
}

function byMessagesDesc(a: ConversationItem, b: ConversationItem): number {
  return b.messageCount - a.messageCount
}

function readSort(): SortMode {
  const raw = readString(LS_SORT)
  return (SORT_MODES as readonly string[]).includes(raw) ? (raw as SortMode) : 'size'
}

function readString(key: string): string {
  try {
    return localStorage.getItem(key) ?? ''
  } catch {
    return ''
  }
}

function writeString(key: string, value: string): void {
  try {
    localStorage.setItem(key, value)
  } catch {
    /* localStorage 不可用（隐私模式）时静默降级为不记忆 */
  }
}

/** 测可视区高度。测不到（jsdom / 尚未布局）返回 0，调用方据此全量渲染。 */
function useViewportHeight(ref: RefObject<HTMLDivElement | null>): number {
  const [height, setHeight] = useState(0)
  useEffect(() => {
    const measure = () => setHeight(ref.current?.clientHeight ?? 0)
    measure()
    window.addEventListener('resize', measure)
    return () => window.removeEventListener('resize', measure)
  }, [ref])
  return height
}
