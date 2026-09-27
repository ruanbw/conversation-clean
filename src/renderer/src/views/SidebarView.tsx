import { useCallback, useEffect, useMemo, useState } from 'react'
import type { AgentCategory, AgentInfo } from '@shared/types'
import { CATEGORY_LABELS } from '@shared/types'
import { abbreviateHome, formatBytes, splitBytes } from '@shared/format'
import { AgentMark } from '@renderer/components/AgentGlyph'
import {
  CardSurface,
  DrawnButton,
  DrawnCheckboxBox,
  DrawnIcon,
  SectionLabel,
  ShareBar,
  TintedSurface
} from '@renderer/components/DrawnControls'
import { cleanStore, useCleanActions, useCleanState } from '@renderer/state/cleanStore'
import styles from './SidebarView.module.css'

/**
 * 侧栏：功能清单 + 存储体检。
 *
 * 视觉基线 `design-demos/ui-a-precision.html`，三处刻意的取舍：
 *   ① 顶部不再留 38px 空档 —— 红绿灯浮在顶栏上，侧栏从顶栏**下方**才开始，
 *      旧布局在顶栏下面又空 38px，侧栏开头 86px 全白。
 *   ② 下方大片空白（只装了 4 款 Agent 却有 15 个分类位）现在填成
 *      「可回收空间」体检卡 + 存储路径卡，把空白换成决策信息。
 *   ③ 行高 28px，计数用等宽数字。
 *
 * 分类列表的口径：**15 款全部列出**，未安装的置灰。理由是分类导航是本 App 的
 * 功能清单，「装没装」是运行时的事；未安装的行点进去会看到
 * 「未在本机检测到该 Agent 的存储目录」，这比先在侧栏里藏起来更有用。
 * 「仅显示有数据」开关打开时才滤掉未安装与 0 会话的分类（`.all` 恒在首位）。
 */

/** 侧栏固定顺序。注意 antigravity 排在 windsurf 之后，不是字母序。 */
const SIDEBAR_AGENT_ORDER: readonly Exclude<AgentCategory, 'all'>[] = [
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
  'antigravity',
  'aider',
  'openViking',
  'zed',
  'openHands'
]

/** 「仅显示有数据」开关的持久化键。 */
const LS_HIDE_EMPTY = 'hideEmptyCategories'

function readHideEmpty(): boolean {
  try {
    return localStorage.getItem(LS_HIDE_EMPTY) === '1'
  } catch {
    return false
  }
}

function writeHideEmpty(value: boolean): void {
  try {
    localStorage.setItem(LS_HIDE_EMPTY, value ? '1' : '0')
  } catch {
    /* localStorage 不可用时静默降级为不记忆 */
  }
}

export interface SidebarViewProps {
  /** 打开设置面板。这里只抛事件，遮罩与显隐由 App 编排。 */
  onOpenSettings?: () => void
}

export function SidebarView({ onOpenSettings }: SidebarViewProps) {
  const state = useCleanState()
  const { setSelectedCategory, openStoragePath } = useCleanActions()
  const [hideEmpty, setHideEmpty] = useState(readHideEmpty)

  const stats = useMemo(() => cleanStore.getCategoryStats(state), [state])
  const totalSize = useMemo(() => cleanStore.getTotalSize(state), [state])

  useEffect(() => {
    writeHideEmpty(hideEmpty)
  }, [hideEmpty])

  const installedSet = useMemo(() => {
    const set = new Set<AgentCategory>()
    for (const info of state.agentInfos) if (info.isInstalled) set.add(info.category)
    return set
  }, [state.agentInfos])

  const isInstalled = useCallback(
    (category: AgentCategory) => category === 'all' || installedSet.has(category),
    [installedSet]
  )

  // 15 款全部列出；未安装的置灰。`hideEmpty` 打开时才滤掉未安装的
  // 与 0 会话的分类（`.all` 恒在首位且不受影响）。
  const visibleCategories = useMemo<AgentCategory[]>(() => {
    const agents = SIDEBAR_AGENT_ORDER.filter((category) => {
      if (!hideEmpty) return true
      if (!installedSet.has(category)) return false
      return (stats.get(category)?.count ?? 0) > 0
    })
    return ['all', ...agents]
  }, [hideEmpty, installedSet, stats])

  const currentStats = stats.get(state.selectedCategory)
  const split = splitBytes(currentStats?.sizeInBytes ?? 0)
  const gaugeShare = share(currentStats?.sizeInBytes ?? 0, totalSize)
  const gaugeCaption = `占 ${
    state.selectedCategory === 'all' ? '全部 Agent 合计' : CATEGORY_LABELS[state.selectedCategory]
  } ${Math.round(gaugeShare)}%`
  const gaugeCount = `${currentStats?.count ?? 0} 会话`

  const pathAgent = useMemo(
    () => pathAgentFor(state.selectedCategory, state.agentInfos),
    [state.selectedCategory, state.agentInfos]
  )
  const currentStoragePath = pathAgent?.storagePath ?? ''
  const displayedPath = abbreviateHome(currentStoragePath, state.homeDir)
  const pathNote =
    pathAgent && isInstalled(pathAgent.category)
      ? cleanStore.snapshotPolicyText
      : '未在本机检测到该 Agent 的存储目录。'

  return (
    <nav className={styles['sidebar']} aria-label="Agent 分类">
      <div className={styles['scroll']}>
        <SectionLabel text="Agent 分类" />

        {visibleCategories.map((category) => (
          <CategoryRow
            key={category}
            category={category}
            count={stats.get(category)?.count ?? 0}
            sizeInBytes={stats.get(category)?.sizeInBytes ?? 0}
            isSelected={state.selectedCategory === category}
            isInstalled={isInstalled(category)}
            icons={state.agentIcons}
            onSelect={() => setSelectedCategory(category)}
          />
        ))}

        <SectionLabel text="工具" />

        <button
          type="button"
          className={styles['toolRow']}
          onClick={() => setHideEmpty(!hideEmpty)}
          aria-pressed={hideEmpty}
          title="仅显示有数据的分类"
        >
          <span className={styles['toolIcon']}>
            <DrawnCheckboxBox checked={hideEmpty} />
          </span>
          <span className={styles['toolLabel']}>仅显示有数据</span>
        </button>

        <button
          type="button"
          className={styles['toolRow']}
          onClick={() => onOpenSettings?.()}
          title="设置"
        >
          <span className={styles['toolIcon']}>
            <DrawnIcon name="gear" size={13} />
          </span>
          <span className={styles['toolLabel']}>设置…</span>
        </button>

        <SectionLabel text="当前分类" />

        {/* 体检卡在存储路径卡之前（设计稿 A 的顺序）：先给「能省多少」这个答案，
            再给「去哪儿删」的入口。侧栏内容很长，体检卡沉底就等于白做。 */}
        <CardSurface className={styles['gauge']}>
          <div className={styles['gaugeLabel']}>可回收空间</div>
          <div className={styles['gaugeValueRow']}>
            <span className={styles['gaugeValue']}>{split.value}</span>
            <span className={styles['gaugeUnit']}>{split.unit}</span>
          </div>
          <div className={styles['gaugeBar']}>
            <ShareBar percent={gaugeShare} />
          </div>
          <div className={styles['gaugeMeta']}>
            <span className={styles['gaugeMetaCaption']}>{gaugeCaption}</span>
            <span className={styles['gaugeMetaCount']}>{gaugeCount}</span>
          </div>
          <div className={styles['gaugeNote']}>{cleanStore.emptyFolderPolicyText}</div>
        </CardSurface>

        <TintedSurface className={styles['pathCard']}>
          <div className={styles['pathTitle']}>存储路径</div>
          <div
            className={`${styles['pathValue']} ${styles['pathValueClamp']}`}
            title={currentStoragePath}
          >
            {displayedPath.length === 0 ? '—' : displayedPath}
          </div>
          <div className={styles['pathNote']}>{pathNote}</div>
          <DrawnButton
            variant={currentStoragePath.length === 0 ? 'flat' : 'ghost'}
            compact
            paddingX={0}
            className={styles['pathButton']}
            icon={<DrawnIcon name="reveal" size={11} />}
            disabled={currentStoragePath.length === 0}
            help="在 Finder 中打开"
            onClick={() => {
              if (currentStoragePath.length > 0) void openStoragePath(currentStoragePath)
            }}
          >
            在 Finder 中打开
          </DrawnButton>
        </TintedSurface>
      </div>
    </nav>
  )
}

/**
 * 当前分类对应的存储路径来源。
 * `.all` 时取占用最大的那款 Agent —— 「全部会话」的存储路径指向最大的那块盘，
 * 点 Finder 打开它最有用。
 */
function pathAgentFor(
  category: AgentCategory,
  agentInfos: readonly AgentInfo[]
): AgentInfo | undefined {
  if (category === 'all') {
    return agentInfos.reduce<AgentInfo | undefined>(
      (best, info) => (!best || info.totalBytes > best.totalBytes ? info : best),
      undefined
    )
  }
  return agentInfos.find((info) => info.category === category)
}

function share(part: number, total: number): number {
  if (total <= 0 || part <= 0) return 0
  return (part / total) * 100
}

// MARK: - 分类行

interface CategoryRowProps {
  category: AgentCategory
  count: number
  sizeInBytes: number
  isSelected: boolean
  isInstalled: boolean
  icons: Record<string, string | null>
  onSelect: () => void
}

function CategoryRow({
  category,
  count,
  sizeInBytes,
  isSelected,
  isInstalled,
  icons,
  onSelect
}: CategoryRowProps) {
  return (
    <button
      type="button"
      className={[
        styles['navRow'],
        isSelected && styles['navRowOn'],
        !isInstalled && styles['navRowDim']
      ]
        .filter(Boolean)
        .join(' ')}
      onClick={onSelect}
      title={`${CATEGORY_LABELS[category]} · ${count} 个会话 · ${formatBytes(sizeInBytes)}`}
      aria-current={isSelected}
      data-installed={isInstalled ? 'true' : 'false'}
      data-category={category}
    >
      <span className={styles['navIcon']}>
        <AgentMark category={category} icons={icons} size={16} />
      </span>
      <span
        className={[
          styles['navLabel'],
          isSelected && styles['navLabelOn']
        ]
          .filter(Boolean)
          .join(' ')}
      >
        {CATEGORY_LABELS[category]}
      </span>
      {count > 0 ? (
        <span
          className={[
            styles['navCount'],
            isSelected && styles['navCountOn']
          ]
            .filter(Boolean)
            .join(' ')}
        >
          {count}
        </span>
      ) : null}
      {sizeInBytes > 0 ? (
        <span
          className={[
            styles['navSize'],
            isSelected && styles['navSizeOn']
          ]
            .filter(Boolean)
            .join(' ')}
        >
          {formatBytes(sizeInBytes)}
        </span>
      ) : null}
    </button>
  )
}
