import { Fragment, useEffect, useMemo, useRef, useState } from 'react'
import type { MouseEvent, ReactNode } from 'react'
import { cleanStore, useCleanState } from '../state/cleanStore'
import type { CleanState } from '../state/cleanStore'
import { CATEGORY_LABELS } from '@shared/types'
import type { AgentCategory } from '@shared/types'
import { formatBytes, splitBytes } from '@shared/format'
import { DrawnIcon } from '@renderer/components/DrawnControls'
import styles from './CleanConfirmSheet.module.css'

/**
 * 清理前的二次确认弹层。
 *
 * 移植自 Swift 版 `ConversationClean/Views/CleanConfirmSheet.swift`（1001 行）。
 * 逐块对应关系（原型 `docs/prototype.html` 的 `#scrim > .sheet`）：
 *
 *   ① 头部           .sheet-h
 *   ② 预计释放        .sheet-hero / .est-hero   —— 留在滚动区之外，headline 不该被滚没
 *   ③ 收益位置        .est-sec + .eb × 2
 *   ④ 卷占用          .est-sec + .cap × 2 + .cap-d + .est-note
 *   ⑤ 空间构成        .est-sec + .stack + .cr
 *   ⑥ 提示块          .sheet-b .tip
 *   ⑦ 页脚            .sheet-f
 *
 * 显隐由 `state.showCleanConfirmAlert` 驱动（本组件整体挂载 / 卸载）。
 * 三条取消路径 —— 遮罩 / Esc / 「取消」—— 都只调 `cleanStore.cancelClean()`：
 * 只收起面板，不碰任何数据。
 *
 * **目标集合的钉法**（与 Swift 版的关键差异，见最终报告）：
 * Swift 的 `targets = estimateTargets(for: cleanTarget)` 读的是**活的**
 * `filteredConversations`，面板开着时切分类会连目标集合一起改 ——
 * 面板上写着的条数与「确认清除」实际删掉的会不是同一批。
 * 这里把 `selectedCategory` 换成 `state.estimateCategory`（打开那一刻的分类）再喂给
 * `cleanStore.getCleanTargets()`：口径仍然是 store 的 selector，不重算，
 * 但语义钉住了。搜索词与 Swift 版保持一致（仍然实时）。
 *
 * **数据来源的已知缺口**：`.cap` / `.cap-d` 依赖真实卷容量。
 * 渲染进程读不到 fs，需要主进程加一个卷信息 IPC 通道；
 * 通道没到位时 `readVolumeInfo()` 返回 null，`.cap` 整块不渲染 ——
 * 与 Swift 版「拿不到真实卷信息就整块不渲染」是同一条分支。
 */

// MARK: - 常量（对应 Swift 版的 static let）

/**
 * 第二层索引行（Pi 的 context-mode SQLite、VS Code 家族的 state.vscdb）
 * 不是独立文件，没有实测大小可读，按每会话 34 KB 估。
 * 与原型 `IDX_PER = 34*1024` 一致。
 */
const IDX_PER = 34 * 1024

/** 空间构成最多列 5 个 Agent，多出来的并成「其余 N 个会话」。 */
const MAIN_MAX = 5

/** GB 换算用。Swift 版 `fmtVol` 是固定两位的 `%.2f GB`，与 `formatBytes` 的口径不同。 */
const BYTES_PER_GB = 1024 * 1024 * 1024

const TITLE_ID = 'clean-confirm-sheet-title'

/** `Theme.distColor` 的 8 级靛蓝色阶，对应 `--d1` ~ `--d8`。 */
const DIST_COLORS = [
  'var(--d1)',
  'var(--d2)',
  'var(--d3)',
  'var(--d4)',
  'var(--d5)',
  'var(--d6)',
  'var(--d7)',
  'var(--d8)'
]

/** 顺位分配；色阶只有 8 级，段数上限 7，超了自然夹到末阶。 */
function distColor(colorIndex: number): string {
  return DIST_COLORS[Math.min(Math.max(colorIndex, 0), DIST_COLORS.length - 1)] as string
}

/**
 * 这些 Agent 除了主会话文件还维护第二层索引载体，清理时会连索引行一起删。
 * 名字取载体的末段（原型 `mid()`）。与 Swift 版 `indexLayer(for:)` 逐条对应。
 */
const INDEX_LAYERS: Partial<Record<AgentCategory, string>> = {
  piAgent: 'context-mode',
  copilotChat: 'state.vscdb',
  cursor: 'state.vscdb',
  windsurf: 'state.vscdb',
  trae: 'state.vscdb',
  antigravity: 'state.vscdb'
}

function indexLayer(category: AgentCategory): string | null {
  return INDEX_LAYERS[category] ?? null
}

// MARK: - 宿主卷信息

interface VolumeInfo {
  name: string
  mountPath: string | null
  capacity: number
  used: number
}

/**
 * 读主目录所在卷。拿不到就返回 null，调用方整块不渲染。
 *
 * 🔴 已知缺口：渲染进程没有 fs，也没有对应的 IPC 通道
 * （`src/shared/types.ts` 的 `RendererApi` / `src/main/ipc.ts` 里都还没有卷信息）。
 * 这里按**可选方法**探测：通道补上之前返回 null，走 Swift 版同一条「不渲染」分支；
 * 通道补上之后这一行不用改，`.cap` 两节自动回来。
 */
async function readVolumeInfo(): Promise<VolumeInfo | null> {
  const bridge = window.api as unknown as { getVolumeInfo?: () => Promise<VolumeInfo | null> }
  if (typeof bridge?.getVolumeInfo !== 'function') return null
  try {
    const info = await bridge.getVolumeInfo()
    // 与 Swift 版同一道闸：数值不合理就不画这一节，
    // 宁可少一节，也不能拿假分母编出一个占比。
    if (!info || !(info.capacity > 0) || !(info.used > 0)) return null
    return { ...info, mountPath: info.mountPath ?? null }
  } catch {
    return null
  }
}

// MARK: - 派生数据

/** 一个 Agent 在本次清理中的合计。 */
interface AgentShare {
  category: AgentCategory
  bytes: number
  count: number
}

/** 空间构成的一段（Agent / 其余合并 / 索引行）。堆叠条与横条列表共用同一份。 */
interface CompSegment {
  key: string
  name: string
  bytes: number
  colorIndex: number
  tag?: string
  isEstimated?: boolean
}

interface Estimate {
  count: number
  /** 主会话文件合计（不含索引层估算）。 */
  mainBytes: number
  /** 命中的第二层索引会话数。快照同步关掉时恒为 0。 */
  idxCount: number
  /** 索引层估算字节数 = idxCount × 34 KB。 */
  idxBytes: number
  totalBytes: number
  allBytes: number
  scopeLabel: string | null
  shares: AgentShare[]
  segments: CompSegment[]
  stackCaption: string
  /** 本次之外未被纳入预估的会话条数。 */
  others: number
}

/**
 * 面板的全部数字一次算完（对应 Swift 版「先算好，避免 body 里反复 reduce」）。
 *
 * 纯函数：输入是 store 快照，输出是面板上要显示的一切。
 * 分类已经由调用方钉成 `estimateCategory`。
 */
function computeEstimate(state: CleanState): Estimate {
  const targets = cleanStore.getCleanTargets({
    ...state,
    selectedCategory: state.estimateCategory
  })

  let mainBytes = 0
  const bytesByCategory = new Map<AgentCategory, number>()
  const countByCategory = new Map<AgentCategory, number>()
  for (const item of targets) {
    mainBytes += item.sizeInBytes
    bytesByCategory.set(item.category, (bytesByCategory.get(item.category) ?? 0) + item.sizeInBytes)
    countByCategory.set(item.category, (countByCategory.get(item.category) ?? 0) + 1)
  }

  // 「同时清理文件历史快照」关掉时索引层不删，统计要跟着扣掉。
  const syncSnapshots = state.prefs.cleanFileHistorySnapshots
  const idxLayers: string[] = []
  let idxCount = 0
  if (syncSnapshots) {
    for (const item of targets) {
      const layer = indexLayer(item.category)
      if (layer === null) continue
      idxCount += 1
      if (!idxLayers.includes(layer)) idxLayers.push(layer)
    }
  }
  const idxBytes = idxCount * IDX_PER
  const totalBytes = mainBytes + idxBytes

  // 全库主文件 + 同一口径下的索引层估算（「占全部可清理空间」的分母）。
  let allIdxHits = 0
  if (syncSnapshots) {
    for (const item of state.conversations) {
      if (indexLayer(item.category) !== null) allIdxHits += 1
    }
  }
  const allBytes = cleanStore.getTotalSize(state) + allIdxHits * IDX_PER

  // 整类清理时带上范围名；只清选中项、或范围就是「全部会话」时省略。
  const scopeLabel =
    state.cleanTarget === 'selected' || state.estimateCategory === 'all'
      ? null
      : CATEGORY_LABELS[state.estimateCategory]

  const shares: AgentShare[] = [...bytesByCategory.keys()].map((category) => ({
    category,
    bytes: bytesByCategory.get(category) ?? 0,
    count: countByCategory.get(category) ?? 0
  }))
  // 降序；同字节按名称排，保证每次渲染顺序稳定。
  shares.sort((a, b) => {
    if (a.bytes !== b.bytes) return b.bytes - a.bytes
    return CATEGORY_LABELS[a.category] < CATEGORY_LABELS[b.category] ? -1 : 1
  })

  const mainRows = shares.slice(0, MAIN_MAX)
  const restRows = shares.slice(MAIN_MAX)
  // 「其余 N 个会话」的 N 是被折叠掉的**会话条数**，不是被折叠掉的 Agent 数。
  const restCount = restRows.reduce((sum, row) => sum + row.count, 0)
  const restBytes = restRows.reduce((sum, row) => sum + row.bytes, 0)
  const indexRowTitle =
    idxLayers.length === 1
      ? `索引行 · ${idxLayers[0] as string}`
      : `索引行与快照 · ${idxLayers.length} 层`

  const segments: CompSegment[] = mainRows.map((row, index) => ({
    key: row.category,
    name: CATEGORY_LABELS[row.category],
    bytes: row.bytes,
    colorIndex: index
  }))
  if (restCount > 0) {
    segments.push({
      key: 'rest',
      name: `其余 ${restCount} 个会话`,
      bytes: restBytes,
      colorIndex: segments.length
    })
  }
  if (idxBytes > 0) {
    segments.push({
      key: 'index',
      name: indexRowTitle,
      bytes: idxBytes,
      colorIndex: segments.length,
      tag: '估算',
      isEstimated: true
    })
  }

  return {
    count: targets.length,
    mainBytes,
    idxCount,
    idxBytes,
    totalBytes,
    allBytes,
    scopeLabel,
    shares,
    segments,
    stackCaption: stackCaptionOf(segments, totalBytes),
    others: state.conversations.length - targets.length
  }
}

/** 堆叠条下面那行注脚：把「谁最大」直接写成文字，省掉读者在段与段之间换算。 */
function stackCaptionOf(segments: readonly CompSegment[], totalBytes: number): string {
  let top: CompSegment | null = null
  for (const segment of segments) {
    if (segment.bytes <= 0) continue
    if (top === null || segment.bytes > top.bytes) top = segment
  }
  if (top === null) return '本次没有可清理的空间。'
  const percent = totalBytes > 0 ? (top.bytes / totalBytes) * 100 : 0
  return `${top.name} 占 ${percent.toFixed(1)}% · 共 ${segments.length} 段`
}

// MARK: - 数字与单位工具

/** 原型 `fmtVol`：GB 保留两位小数，与 `formatBytes` 的口径刻意分开。 */
function fmtVol(bytes: number): string {
  return `${(bytes / BYTES_PER_GB).toFixed(2)} GB`
}

/** 0.4% 四舍五入成 0% 会读成「占 0 字节」，与右边的体积自相矛盾。 */
function percentText(percent: number): string {
  if (percent > 0 && percent < 0.5) return '<1%'
  return `${percent.toFixed(1)}%`
}

function ratioOf(bytes: number, basis: number): number {
  return basis > 0 ? (bytes / basis) * 100 : 0
}

/** 说明句里要加粗的数字。Swift 版是 `Text.figureEmphasis`。 */
type Part = string | { fig: string }

function parts(list: readonly Part[]): ReactNode[] {
  return list.map((part, index) =>
    typeof part === 'string' ? (
      <Fragment key={index}>{part}</Fragment>
    ) : (
      <b key={index} className={styles.fig}>
        {part.fig}
      </b>
    )
  )
}

// MARK: - 小组件

interface EstBarRowProps {
  label: string
  value: number
  basis: number
  caption: Part[]
}

/**
 * 收益条：左上标签 + 右上数值，中间隔一条 9pt 描边条，底下跟一行说明。
 * 条宽 `value/basis*100`，数值 > 0 时至少 0.5%（原型 `Math.max(w, 0.5)`）。
 */
function EstBarRow({ label, value, basis, caption }: EstBarRowProps) {
  const percent = ratioOf(value, basis)
  const fill = value > 0 ? Math.max(percent, 0.5) : 0
  return (
    <div className={styles.ebRow}>
      <div className={styles.ebTop}>
        <span className={styles.ebLabel}>{label}</span>
        <span className={`${styles.ebValue} num`}>{formatBytes(value)}</span>
      </div>
      <div className={styles.ebTrack} aria-hidden="true">
        <div className={styles.ebFill} style={{ width: `${fill}%` }} />
      </div>
      <div className={styles.ebCaption}>{parts(caption)}</div>
    </div>
  )
}

interface CapRowProps {
  label: string
  usedRatio: number
  /** 只有「清理后」那条有值，画成一小段语义绿。 */
  gainPercent: number | null
  readout: number
  isAfter?: boolean
}

/** 卷容量双条：36pt 标签 + 真比例条 + 右对齐读数。 */
function CapRow({ label, usedRatio, gainPercent, readout, isAfter = false }: CapRowProps) {
  const usedWidth = Math.min(1, Math.max(0, usedRatio)) * 100
  const gainWidth = gainPercent === null ? 0 : Math.max(0.16, gainPercent)
  return (
    <div className={isAfter ? `${styles.capRow} ${styles.capAfter}` : styles.capRow}>
      <span className={styles.capLabel}>{label}</span>
      <div className={styles.capTrack} aria-hidden="true">
        <div className={styles.capUsed} style={{ width: `${usedWidth}%` }} />
        {gainPercent !== null ? (
          <div className={styles.capGain} style={{ width: `${gainWidth}%` }} />
        ) : null}
      </div>
      <span className={styles.capReadout}>
        <b className={styles.fig}>{`${(readout * 100).toFixed(3)}%`}</b>
        <span className={styles.capReadoutMuted}> 已用</span>
      </span>
    </div>
  )
}

interface CompositionStackProps {
  segments: readonly CompSegment[]
  basis: number
}

/**
 * 空间构成堆叠总览条：8pt 高、段间 2pt 缝、胶囊端。
 * 段色取靛蓝明度阶梯 —— 同一 hue，堆起来是一族颜色而不是彩虹。
 */
function CompositionStack({ segments, basis }: CompositionStackProps) {
  return (
    <div className={styles.stack} aria-hidden="true">
      {segments.map((segment) =>
        segment.bytes > 0 && basis > 0 ? (
          <div
            key={segment.key}
            className={segment.isEstimated ? `${styles.stackSeg} ${styles.stackEst}` : styles.stackSeg}
            style={{
              flexBasis: `${(segment.bytes / basis) * 100}%`,
              backgroundColor: distColor(segment.colorIndex)
            }}
          />
        ) : null
      )}
    </div>
  )
}

interface CompositionRowProps {
  segment: CompSegment
  basis: number
}

/** 构成行：8pt 色块 + 名字(+ tag) + 5pt 细条 + 百分比 + 大小。 */
function CompositionRow({ segment, basis }: CompositionRowProps) {
  const percent = ratioOf(segment.bytes, basis)
  const fraction = Math.min(1, Math.max(0, percent / 100))
  const color = distColor(segment.colorIndex)
  return (
    <div className={segment.isEstimated ? `${styles.crRow} ${styles.crEstimated}` : styles.crRow}>
      <span className={styles.crSwatch} style={{ background: color }} aria-hidden="true" />
      <span className={styles.crNameCell}>
        <span className={styles.crName}>{segment.name}</span>
        {segment.tag ? <span className={styles.crTag}>{segment.tag}</span> : null}
      </span>
      <span className={styles.crBar} aria-hidden="true" style={{ color }}>
        {segment.isEstimated ? (
          <span className={styles.crBarEst} style={{ width: `${Math.max(1.5, fraction * 100)}%` }} />
        ) : (
          <span className={styles.crBarFill} style={{ width: `${Math.max(1.5, fraction * 100)}%` }} />
        )}
      </span>
      <span className={`${styles.crPct} num`}>{percentText(percent)}</span>
      <span className={`${styles.crSize} num`}>{formatBytes(segment.bytes)}</span>
    </div>
  )
}

interface LevelBadgeProps {
  text: string
  isOK: boolean
}

/** 量级徽标：ok / warn 两态。 */
function LevelBadge({ text, isOK }: LevelBadgeProps) {
  return (
    <span className={isOK ? styles.lvl : `${styles.lvl} ${styles.lvlWarn}`} aria-hidden="true">
      {text}
    </span>
  )
}

/**
 * 弹层里用到的两个系统符号（`exclamationmark.triangle` / `info.circle`）**已收敛到
 * `DrawnControls` 的 `DrawnIcon`**（`exclamationTriangle` / `info`）。
 *
 * 最初这里是就地自绘的两份 SVG —— 那是移植时 `DrawnControls` 还没落地、
 * import 它会让 typecheck 变红的权宜之计。集成阶段统一收回了图标库，
 * 本文件不再持有任何自绘 `<svg>`。统一 1.6px 线性描边、继承 `currentColor`。
 */

// MARK: - 主体

/**
 * 清理前的二次确认弹层。**无 props**，内部自己连 store。
 *
 * 导出签名（`App.tsx` 直接用）：
 *   `export default function CleanConfirmSheet(): ReactNode`
 * 用法：`<CleanConfirmSheet />`，挂在根布局下方即可 ——
 * `showCleanConfirmAlert` 为 false 时返回 null，不占任何布局。
 */
export default function CleanConfirmSheet(): ReactNode {
  const state = useCleanState()
  const open = state.showCleanConfirmAlert

  const panelRef = useRef<HTMLDivElement | null>(null)
  const scrollRef = useRef<HTMLDivElement | null>(null)
  const [volume, setVolume] = useState<VolumeInfo | null>(null)

  // 目标集合与派生数字一次算完；分类已钉在 estimateCategory。
  const estimate = useMemo(() => computeEstimate(state), [state])
  const {
    count,
    idxCount,
    totalBytes,
    allBytes,
    scopeLabel,
    shares,
    segments,
    stackCaption,
    others
  } = estimate

  const syncSnapshots = state.prefs.cleanFileHistorySnapshots
  const dropEmptyFolders = state.prefs.cleanEmptyProjectFolders
  const isCleaning = state.isCleaning
  const canConfirm = count > 0 && !isCleaning

  /**
   * 卷信息整弹只读一次 —— 与 Swift 版 `@State` 初值只在弹层创建时生效一致。
   */
  useEffect(() => {
    if (!open) {
      setVolume(null)
      return
    }
    let cancelled = false
    void readVolumeInfo().then((info) => {
      // 同一个引用直接返回：让 React 跳过这次 bail-out 之外的调度，
      // 否则「本来就没有卷信息」也会在弹层打开后多渲染一帧。
      if (!cancelled) setVolume((previous) => (previous === info ? previous : info))
    })
    return () => {
      cancelled = true
    }
  }, [open])

  /**
   * 滚动区在 `estimateToken` 变化时回到顶部。
   *
   * Swift 版是 `estimateToken` 的存在理由：目标一变就重建滚动状态，
   * 否则每次重绘都新建 ScrollView、把滚动位置弹回顶部。
   * 这里不把滚动位置写进 state（那会在每次重绘时新建 DOM 状态），
   * 只在 token 真的变了的那一刻归零。
   */
  useEffect(() => {
    const element = scrollRef.current
    if (element) element.scrollTop = 0
  }, [state.estimateToken])

  /** 打开时把焦点落在面板上，键盘用户不用先 Tab 一圈。 */
  useEffect(() => {
    if (open) panelRef.current?.focus()
  }, [open])

  /**
   * 键盘：Esc 取消（对应 Swift 的 `.keyboardShortcut(.cancelAction)`），
   * Enter / ⌘Enter 确认（对应 `.keyboardShortcut(.defaultAction)`）。
   *
   * 焦点在按钮上时按 Enter 由浏览器自己派发 click，这里让开，
   * 免得一次按键触发两次 `executeClean`。
   */
  useEffect(() => {
    if (!open) return
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') {
        event.preventDefault()
        cleanStore.cancelClean()
        return
      }
      if (event.key !== 'Enter') return
      const onButton = (event.target as HTMLElement | null)?.tagName === 'BUTTON'
      if (onButton && !event.metaKey && !event.ctrlKey) return
      if (!canConfirm) return
      event.preventDefault()
      void cleanStore.executeClean()
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [open, canConfirm])

  if (!open) return null

  /** 遮罩：只认落在遮罩自己身上的按下（原型 `.scrim` 的 mousedown 处理）。 */
  const onScrimMouseDown = (event: MouseEvent<HTMLDivElement>): void => {
    if (event.target === event.currentTarget) cleanStore.cancelClean()
  }

  const split = splitBytes(totalBytes)
  const usedBefore = volume === null ? 0 : volume.used / volume.capacity
  const usedAfter = volume === null ? 0 : Math.max(0, volume.used - totalBytes) / volume.capacity
  const gainPct = volume === null ? 0 : (totalBytes / volume.capacity) * 100
  const freeBefore = volume === null ? 0 : Math.max(0, volume.capacity - volume.used)
  const freeAfter = freeBefore + totalBytes
  const freeJump = freeBefore > 0 ? (totalBytes / freeBefore) * 100 : 0

  return (
    <div className={styles.scrim} onMouseDown={onScrimMouseDown}>
      <div
        ref={panelRef}
        className={styles.panel}
        role="dialog"
        aria-modal="true"
        aria-labelledby={TITLE_ID}
        aria-busy={isCleaning}
        tabIndex={-1}
      >
        {/* ---- ① 头部 ---- */}
        <div className={styles.header}>
          <span className={styles.warn} aria-hidden="true">
            <DrawnIcon name="exclamationTriangle" size={17} />
          </span>
          <h2 id={TITLE_ID} className={styles.headerTitle}>
            确认清除会话？
          </h2>
        </div>

        {/* ---- ② 预计释放：刻意在滚动区之外 ---- */}
        <div className={styles.heroCard}>
          <div className={styles.heroLabel}>预计释放</div>
          <div className={styles.heroFigure}>
            {count === 0 ? (
              <span className={`${styles.heroValue} ${styles.heroEmpty} num`}>—</span>
            ) : (
              <>
                <span className={`${styles.heroValue} num`}>{split.value}</span>
                {split.unit ? <span className={styles.heroUnit}>{split.unit}</span> : null}
              </>
            )}
          </div>
          <div className={styles.heroCaption}>
            {count === 0
              ? '当前没有可清理的会话。'
              : parts([
                  '将删除',
                  ...(scopeLabel === null ? [] : [`「${scopeLabel}」的 `]),
                  { fig: String(count) },
                  ' 个会话文件，覆盖 ',
                  { fig: String(shares.length) },
                  ' 个 Agent。此操作不可撤销。'
                ])}
          </div>
        </div>

        {/* ---- ③ 滚动区 ---- */}
        <div ref={scrollRef} className={styles.scroll}>
          {/* 收益位置 */}
          <section className={styles.section}>
            <div className={styles.sectionHead}>
              <span className={styles.sectionLabel}>收益位置</span>
            </div>
            <EstBarRow
              label="占全部可清理空间"
              value={totalBytes}
              basis={allBytes}
              caption={[
                '全部可清理 ',
                { fig: formatBytes(allBytes) },
                ' · 本次占 ',
                { fig: allBytes > 0 ? `${((totalBytes / allBytes) * 100).toFixed(1)}%` : '0%' }
              ]}
            />
            {/* 卷容量读不到时整行不画：宁可少一条收益，也不用假分母编出一个占比。 */}
            {volume !== null ? (
              <EstBarRow
                label="占卷总容量"
                value={totalBytes}
                basis={volume.capacity}
                caption={[
                  '卷容量 ',
                  { fig: formatBytes(volume.capacity) },
                  ' · 本次占 ',
                  // 卷容量口径三位小数：几百 MB 摊到 TB 级卷上，两位小数会全变成 0.00%
                  { fig: `${((totalBytes / volume.capacity) * 100).toFixed(3)}%` }
                ]}
              />
            ) : null}
          </section>

          {/* 卷占用 + 释放说明：拿不到真实卷信息就整块不渲染 */}
          {volume !== null ? (
            <section className={styles.section}>
              <div className={styles.sectionHead}>
                <span className={styles.sectionLabel}>卷占用</span>
                {volume.mountPath ? (
                  <span className={styles.sectionPath}>{volume.mountPath}</span>
                ) : null}
                <span className={styles.sectionBadge}>{volume.name}</span>
              </div>
              <CapRow label="清理前" usedRatio={usedBefore} gainPercent={null} readout={usedBefore} />
              <CapRow
                label="清理后"
                usedRatio={usedAfter}
                gainPercent={gainPct}
                readout={usedAfter}
                isAfter
              />
              <div className={styles.capDetail}>
                <LevelBadge
                  text={gainPct < 0.5 ? '量级微小' : gainPct < 5 ? '量级有限' : '量级显著'}
                  isOK={gainPct >= 5}
                />
                {parts([
                  '可用空间 ',
                  { fig: `${fmtVol(freeBefore)} → ${fmtVol(freeAfter)}` },
                  `（+${freeJump.toFixed(2)}%），相当于卷容量的 `,
                  { fig: `${gainPct.toFixed(3)}%` },
                  '。'
                ])}
              </div>
              <div className={styles.note}>
                <span className={styles.noteIcon} aria-hidden="true">
                  <DrawnIcon name="info" size={12} />
                </span>
                <span>
                  {parts([
                    '实际释放可能低于预估：APFS 稀疏文件按分配块回收，Time Machine 本地快照仍保留旧数据块，被其他进程占用的文件句柄也会延后释放。',
                    ...(others > 0
                      ? [
                          '本次之外另有 ',
                          { fig: String(others) },
                          ' 个会话占用 ',
                          { fig: formatBytes(Math.max(allBytes - totalBytes, 0)) },
                          '，未纳入本次预估。'
                        ]
                      : [])
                  ])}
                </span>
              </div>
            </section>
          ) : null}

          {/* 空间构成 */}
          <section className={styles.section}>
            <div className={styles.sectionHead}>
              <span className={styles.sectionLabel}>空间构成</span>
            </div>
            {totalBytes > 0 ? (
              <>
                {/* 先看整体谁大，再看下面逐段的量 —— 只有横条没有它，
                    读者得在心里自己做加法。 */}
                <CompositionStack segments={segments} basis={totalBytes} />
                <div className={styles.stackCaption}>{stackCaption}</div>
              </>
            ) : null}
            {segments.map((segment) => (
              <CompositionRow key={segment.key} segment={segment} basis={totalBytes} />
            ))}
          </section>
        </div>

        {/* ---- ④ 提示块：随设置开关变化的说明文字 ---- */}
        <div className={styles.tipWrap}>
          <div className={styles.tip}>
            <span className={styles.tipIcon} aria-hidden="true">
              <DrawnIcon name="info" size={13} />
            </span>
            <span>
              {syncSnapshots
                ? parts([
                    '将同步删除快照、子代理数据与 SQLite 索引行',
                    ...(dropEmptyFolders ? ['，并移除空项目目录'] : []),
                    // 「34 KB」必须按 1024 进制写：formatBytes 会打成 34.8 KB
                    `；索引层按命中的 ${idxCount} 个会话、每会话 ${IDX_PER / 1024} KB 估算。`
                  ])
                : '当前已关闭快照同步清理，仅删除主会话文件，索引行与快照会残留在原处。'}
            </span>
          </div>
        </div>

        {/* ---- ⑤ 页脚 ---- */}
        <div className={styles.footer}>
          <button type="button" className={`${styles.btn} ${styles.btnGhost}`} onClick={() => cleanStore.cancelClean()}>
            取消
          </button>
          <button
            type="button"
            className={`${styles.btn} ${styles.btnDanger}`}
            disabled={!canConfirm}
            title={count > 0 ? `删除这 ${count} 个会话文件及其索引行` : '没有可清理的会话'}
            onClick={() => void cleanStore.executeClean()}
          >
            {isCleaning ? '正在清除…' : `确认清除 · ${formatBytes(totalBytes)}`}
          </button>
        </div>
      </div>
    </div>
  )
}
