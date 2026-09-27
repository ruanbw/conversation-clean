import { useMemo } from 'react'
import type { AgentCategory, ConversationItem } from '@shared/types'
import { CATEGORY_LABELS, SCANNER_CATEGORIES } from '@shared/types'
import { formatBytes, formatRelativeDate, percentOf } from '@shared/format'
import { DrawnIcon } from '@renderer/components/DrawnControls'
import { useCleanActions, useCleanState, cleanStore } from '../state/cleanStore'
import styles from './OverviewView.module.css'

/**
 * 详情栏未选中态。
 *
 * 这一栏的语义是「现在该从谁开始删」：全库按体积降序的 Top 5 大户 + Agent 占用分布。
 * 点一行直接选中它（`setSelectedConversationId`），详情栏随之切到该会话的元数据。
 *
 * 全部数据取自 `state.conversations`（**全库**，不是当前筛选结果）——
 * 这里回答的是「先删谁」，不是「当前分类里谁最大」。
 *
 * 硬约束：全部自绘 —— 分隔线、插画、按钮的外观都由本项目自己定，
 * 不借用任何平台控件的默认外观。
 *
 * 图标：统一走 `components/DrawnControls.tsx` 的 `DrawnIcon`（与主窗口其余视图
 * 同一套 1.6px 描边字形），本文件不再内联第二份 SVG。
 */

const TOP_N = 5

/**
 * 分布色阶：同 hue 250° 的 8 级明度阶梯（tokens.css 的 `--d1`~`--d8`），
 * 而不是彩虹色。一条堆叠条里同色相的明暗差能把「相邻两段」读出来，
 * 换成不同色相反而变成一块拼图。
 */
function distColorVar(index: number): string {
  const level = Math.min(Math.max(index, 0), 7)
  return `var(--d${level + 1})`
}

interface Segment {
  id: string
  name: string
  category: AgentCategory | null
  bytes: number
  share: number
}

export function OverviewView() {
  const state = useCleanState()
  const { scanConversations, setSelectedConversationId } = useCleanActions()

  const conversations = state.conversations

  /** 全库总量。堆叠条、横条、大户行共用这一个分母，三者天然对得上。 */
  const totalSize = useMemo(
    () => conversations.reduce((sum, item) => sum + item.sizeInBytes, 0),
    [conversations]
  )

  /** 全库按体积降序取前 N。它是「先删谁」的答案，比任何图都直接。 */
  const biggest = useMemo(
    () => [...conversations].sort((a, b) => b.sizeInBytes - a.sizeInBytes).slice(0, TOP_N),
    [conversations]
  )

  /**
   * 占用 > 0 的分类降序取前 5，其余合并成「其他 N 款」。
   *
   * 颜色索引直接吃色阶：段数超过色阶长度时 `distColorVar` 自己夹到末级。
   */
  const segments = useMemo<Segment[]>(() => {
    const stats = cleanStore.getCategoryStats(state)
    const ranked = SCANNER_CATEGORIES.map((category) => ({
      category,
      bytes: stats.get(category)?.sizeInBytes ?? 0
    }))
      .filter((entry) => entry.bytes > 0)
      .sort((a, b) => b.bytes - a.bytes)

    const out: Segment[] = ranked.slice(0, TOP_N).map((entry) => ({
      id: entry.category,
      name: CATEGORY_LABELS[entry.category],
      category: entry.category,
      bytes: entry.bytes,
      share: totalSize > 0 ? entry.bytes / totalSize : 0
    }))

    if (ranked.length > TOP_N) {
      let rest = 0
      for (const entry of ranked.slice(TOP_N)) rest += entry.bytes
      out.push({
        id: 'other',
        name: `其他 ${ranked.length - TOP_N} 款`,
        category: null,
        bytes: rest,
        share: totalSize > 0 ? rest / totalSize : 0
      })
    }
    return out
  }, [state, totalSize])

  if (!state.hasScanned) {
    return (
      <div className={styles.root}>
        <div className={styles.emptyState}>
          <span className={styles.emptyBadge}>
            <DrawnIcon name="magnifier" size={21} />
          </span>
          <h2 className={styles.emptyStateTitle}>还没有扫描过会话</h2>
          <p className={styles.emptyStateText}>
            已关闭「启动时自动扫描」，或本机尚未完成首次扫描。点下方按钮手动扫描本机各 Agent
            的会话缓存。
          </p>
          <button
            type="button"
            className={styles.primaryBtn}
            disabled={state.isScanning}
            onClick={() => void scanConversations()}
          >
            一键扫描
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className={styles.root}>
      <div className={styles.scroll}>
        <div className={styles.stack}>
          <div className={styles.head}>
            <h2 className={styles.headTitle}>占用大户</h2>
            <span className={styles.headCount}>共 {conversations.length} 个会话</span>
          </div>

          <div className={styles.card}>
            {biggest.length === 0 ? (
              <div className={styles.cardEmpty}>
                <p className={styles.emptyTitle}>没有扫描到任何会话</p>
                <p className={styles.emptyText}>
                  本机这 15 款 Agent 都没有可读的会话记录，或记录已被清理干净。
                </p>
              </div>
            ) : (
              biggest.map((item) => (
                <BiggestRow
                  key={item.id}
                  item={item}
                  total={totalSize}
                  onSelect={() => setSelectedConversationId(item.id)}
                />
              ))
            )}
          </div>

          <h3 className={styles.distHead}>按 Agent 分布</h3>

          {segments.length === 0 || totalSize <= 0 ? (
            /* 全库 0 字节时：没有一根条值得画，硬画一条空轨反而像坏了。 */
            <div className={styles.card}>
              <div className={styles.cardEmpty}>
                <p className={styles.emptyTitle}>没有可统计的占用</p>
                <p className={styles.emptyText}>扫到的会话都是 0 KB，或本机一个会话都没有。</p>
              </div>
            </div>
          ) : (
            <>
              <div className={styles.stackBar} aria-hidden="true">
                {segments.map((segment, index) => (
                  <span
                    key={segment.id}
                    className={styles.stackSeg}
                    style={{ flexGrow: segment.share, background: distColorVar(index) }}
                  />
                ))}
              </div>

              {segments.map((segment, index) => (
                <div className={styles.distRow} key={segment.id}>
                  <span
                    className={styles.distSwatch}
                    style={{ background: distColorVar(index) }}
                  />
                  <span className={styles.distName}>{segment.name}</span>
                  <span className={styles.distBar}>
                    <span
                      className={styles.distBarFill}
                      style={{
                        width: `${percentOf(segment.bytes, totalSize)}%`,
                        background: distColorVar(index)
                      }}
                    />
                  </span>
                  <span className={styles.distPct}>{percentText(segment.bytes, totalSize)}</span>
                  <span className={styles.distSize}>{formatBytes(segment.bytes)}</span>
                </div>
              ))}
            </>
          )}

          {/* 空目录策略跟着设置开关走，所以文案只能现取 */}
          <div className={styles.note}>
            <DrawnIcon name="info" size={12} className={styles.noteIcon} />
            <p className={styles.noteText}>
              <span className={styles.noteStrong}>清理说明</span>：
              {cleanStore.emptyFolderPolicyText}
            </p>
          </div>
        </div>
      </div>
    </div>
  )
}

// MARK: - 大户行

/** 44pt 行高，标题 12.5 medium / 副标题 10.5 t3 / 76pt 占比条 / 34pt 百分比 / 58pt 体积。 */
function BiggestRow({
  item,
  total,
  onSelect
}: {
  item: ConversationItem
  total: number
  onSelect: () => void
}) {
  const share = percentOf(item.sizeInBytes, total)
  // 0 字节也进榜：它仍是一条真会话，压暗（`bigRowZero` / `bigSizeZero`）即可，
  // 直接滤掉会让「Top 5」在一堆 0 KB 时忽然变空。
  const zero = item.sizeInBytes <= 0

  return (
    <button
      type="button"
      className={`${styles.bigRow} ${zero ? styles.bigRowZero : ''}`}
      title={`查看「${item.title}」`}
      aria-label={`${item.title}，${formatBytes(item.sizeInBytes)}，占全库 ${shareText(share)}`}
      onClick={onSelect}
    >
      <span className={styles.bigName}>
        <span className={styles.bigTitle}>{item.title}</span>
        <span className={styles.bigSub}>
          {CATEGORY_LABELS[item.category]} · {formatRelativeDate(new Date(item.updatedAt))}
        </span>
      </span>
      <span className={styles.shareTrack} aria-hidden="true">
        <span className={styles.shareFill} style={{ width: `${share}%` }} />
      </span>
      <span className={styles.sharePct}>{shareText(share)}</span>
      <span className={`${styles.bigSize} ${zero ? styles.bigSizeZero : ''}`}>
        {formatBytes(item.sizeInBytes)}
      </span>
    </button>
  )
}

/**
 * 0.4% 以下四舍五入成 0% 会读成「占 0 字节」，与右侧数字自相矛盾。
 * 占比为 0（非 0 字节）时也走 `<1%` 之外的普通路径，0% 就是 0%。
 */
function shareText(share: number): string {
  if (share > 0 && share < 0.5) return '<1%'
  return `${Math.round(share)}%`
}

function percentText(bytes: number, total: number): string {
  if (total <= 0) return '0%'
  return shareText((bytes / total) * 100)
}
