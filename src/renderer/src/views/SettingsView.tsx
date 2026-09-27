import { useEffect, useMemo, useState } from 'react'
import type { AgentCategory, AgentInfo, Prefs } from '@shared/types'
import { CATEGORY_LABELS, SCANNER_CATEGORIES } from '@shared/types'
import { abbreviateHome, formatBytes, percentOf, splitBytes } from '@shared/format'
import { AgentMark } from '../components/AgentGlyph'
import { DrawnIcon } from '@renderer/components/DrawnControls'
import { useCleanActions, useCleanState } from '../state/cleanStore'
import styles from './SettingsView.module.css'

/**
 * 设置面板。
 *
 * 与主窗口同一套视觉（四级表面梯 / 1px 发丝线 / 靛蓝强调 / 8px 圆角），
 * 整页自绘：左侧导航栏 + 右侧分组卡片。
 *
 * 分组与开关都自己画的原因：平台开关的轨道是系统蓝渐变 + 高光，和侧栏选中态的
 * 靛蓝不是同一种蓝，两处同屏时颜色对不上；平台分组列表自带 inset 底与材质，
 * 深色下会变成另一块灰。
 *
 * 15 款**全部**列出，未安装的置灰而不隐藏：这一页是功能清单，装没装是运行时的事。
 * 业务侧一个字没动：4 个设置开关的落盘键名（服务层在读，改名等于丢用户设置）、
 * 15 款 Agent 的固定顺序、以及安装状态只认 `AgentInfo.isInstalled`
 * （早期那份把 4 款钉死成「未发现」的硬编码名单已删除，不能再回来）。
 *
 * 图标：统一走 `components/DrawnControls.tsx` 的 `DrawnIcon`（与主窗口其余视图
 * 同一套 1.6px 描边字形），本文件不再内联第二份 SVG。
 */

/** 15 款 Agent 的视觉顺序。`main/scanners/registry.ts` 的注册顺序不同，这里排一次。 */
const SETTINGS_AGENT_ORDER: readonly AgentCategory[] = [
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

/** 有第二层索引载体的 Agent 数量 —— 「关于」页那个数字的唯一来源。 */
const SETTINGS_INDEX_NOTES: ReadonlySet<AgentCategory> = new Set<AgentCategory>([
  'piAgent',
  'copilotChat',
  'cursor',
  'windsurf',
  'trae',
  'antigravity'
])

/** `SCANNER_CATEGORIES` 里全是真 Agent（`all` 已被过滤掉），这个数字的来源只有一处。 */
const AGENT_COUNT = SCANNER_CATEGORIES.length

export const SETTINGS_TABS = ['general', 'paths', 'about'] as const
export type SettingsTab = (typeof SETTINGS_TABS)[number]

const TAB_META: Record<SettingsTab, { title: string; hint: string }> = {
  general: { title: '通用', hint: '扫描策略与安全开关' },
  paths: { title: 'Agent 路径', hint: '已安装 {installed} 款 · 存储路径与占用' },
  about: { title: '关于', hint: '会话扫描与安全清理' }
}

/** 页签字形：通用（齿轮） / 路径（文件夹） / 关于（信息）。 */
const TAB_ICON: Record<SettingsTab, string> = {
  general: 'gear',
  paths: 'folder',
  about: 'info'
}

export interface SettingsViewProps {
  /** 点关闭按钮时回调。App.tsx 用它把设置面板关掉 / 收回 focus。 */
  onClose?: () => void
  /** 初始页签，默认「通用」。 */
  initialTab?: SettingsTab
}

export function SettingsView({ onClose, initialTab = 'general' }: SettingsViewProps = {}) {
  const state = useCleanState()
  const { setPref, openStoragePath, cleanAllOfCategory } = useCleanActions()
  const [tab, setTab] = useState<SettingsTab>(initialTab)
  const [version, setVersion] = useState('dev')

  useEffect(() => {
    let alive = true
    window.api
      .getAppInfo()
      .then((info) => {
        if (alive && info.version) setVersion(info.version)
      })
      .catch(() => {
        /* 拿不到版本号就显示 dev，不弹错误 */
      })
    return () => {
      alive = false
    }
  }, [])

  /** 按固定视觉顺序排；未列进表里的排最后再按 key 字典序，保证顺序稳定。 */
  const agents = useMemo(() => {
    const rank = new Map<AgentCategory, number>(
      SETTINGS_AGENT_ORDER.map((category, index) => [category, index])
    )
    return [...state.agentInfos].sort((a, b) => {
      const ra = rank.get(a.category) ?? Number.MAX_SAFE_INTEGER
      const rb = rank.get(b.category) ?? Number.MAX_SAFE_INTEGER
      return ra === rb ? a.category.localeCompare(b.category) : ra - rb
    })
  }, [state.agentInfos])

  const installedCount = useMemo(
    () => agents.filter((agent) => agent.isInstalled).length,
    [agents]
  )
  const totalSessionCount = useMemo(
    () => agents.reduce((sum, agent) => sum + agent.sessionCount, 0),
    [agents]
  )
  const totalBytes = useMemo(
    () => agents.reduce((sum, agent) => sum + agent.totalBytes, 0),
    [agents]
  )

  const hint =
    tab === 'paths' ? TAB_META.paths.hint.replace('{installed}', String(installedCount)) : TAB_META[tab].hint

  return (
    <div className={styles.root}>
      <nav className={styles.rail} aria-label="设置">
        <p className={styles.railLabel}>设置</p>
        {SETTINGS_TABS.map((item) => {
          const on = item === tab
          return (
            <button
              type="button"
              key={item}
              className={`${styles.railRow} ${on ? styles.railRowOn : ''}`}
              aria-current={on ? 'page' : undefined}
              onClick={() => setTab(item)}
            >
              <DrawnIcon name={TAB_ICON[item]} size={14} className={styles.railRowIcon} />
              <span>{TAB_META[item].title}</span>
            </button>
          )
        })}
      </nav>

      <div className={styles.pane}>
        <header className={styles.paneHeader}>
          <h2 className={styles.paneTitle}>{TAB_META[tab].title}</h2>
          <span className={styles.paneHint}>{hint}</span>
          {onClose !== undefined && (
            <button
              type="button"
              className={styles.closeBtn}
              aria-label="关闭设置"
              title="关闭设置"
              onClick={onClose}
            >
              <DrawnIcon name="xmark" size={13} />
            </button>
          )}
        </header>

        <div className={styles.paneBody}>
          {tab === 'general' && (
            <GeneralPane prefs={state.prefs} onToggle={setPref} />
          )}

          {tab === 'paths' &&
            (agents.length === 0 ? (
              <div className={styles.emptyState}>
                <span className={styles.emptyBadge}>
                  <DrawnIcon name="folderQuestion" size={21} />
                </span>
                <h3 className={styles.emptyStateTitle}>尚未扫描到 Agent 信息</h3>
                <p className={styles.emptyStateText}>请先回到主窗口执行一次扫描。</p>
              </div>
            ) : (
              <PathsPane
                agents={agents}
                installedCount={installedCount}
                totalSessionCount={totalSessionCount}
                totalBytes={totalBytes}
                home={state.homeDir}
                icons={state.agentIcons}
                busy={state.isCleaning}
                onOpenPath={openStoragePath}
                onCleanCategory={cleanAllOfCategory}
              />
            ))}

          {tab === 'about' && (
            <div className={styles.card}>
              <div className={styles.cardBody}>
                <div className={styles.aboutHead}>
                  <span className={styles.aboutBadge}>
                    <DrawnIcon name="tray" size={20} />
                  </span>
                  <div>
                    <h3 className={styles.aboutName}>ConversationClean</h3>
                    <p className={styles.aboutVersion}>
                      版本 {version} · macOS 14.0 Sonoma 及以上
                    </p>
                  </div>
                </div>
                <p className={styles.aboutText}>
                  全面支持 15 款本地 CLI、IDE 插件、AI 原生编辑器及自主 Agent
                  框架的会话扫描与安全清理。对同时维护「会话文件 + SQLite
                  索引」的 Agent，删除会话时同步清理索引行，避免幽灵会话残留。
                </p>
                <div className={styles.facts}>
                  <Fact value={String(AGENT_COUNT)} label="受支持 Agent" />
                  <Fact value={String(SETTINGS_INDEX_NOTES.size)} label="双层索引同步" />
                  <Fact value="1" label="并发扫描任务组" />
                </div>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

// MARK: - 通用页

type PrefKey = keyof Prefs

function GeneralPane({
  prefs,
  onToggle
}: {
  prefs: Prefs
  onToggle: <K extends PrefKey>(key: K, value: Prefs[K]) => Promise<void>
}) {
  return (
    <>
      <div className={styles.card}>
        <div className={styles.cardHead}>
          <DrawnIcon name="refresh" size={11} className={styles.cardHeadIcon} />
          <h3 className={styles.cardTitle}>扫描与清理</h3>
        </div>
        <ToggleRow
          title="启动应用时自动扫描会话"
          subtitle="启动时扫描一次本机全部 Agent 的会话缓存"
          on={prefs.autoScanOnLaunch}
          onToggle={() => void onToggle('autoScanOnLaunch', !prefs.autoScanOnLaunch)}
        />
        <ToggleRow
          title="删除会话时同步清除快照与子代理数据"
          subtitle="关闭后仅删除主会话文件，快照与子代理目录将保留"
          on={prefs.cleanFileHistorySnapshots}
          onToggle={() => void onToggle('cleanFileHistorySnapshots', !prefs.cleanFileHistorySnapshots)}
        />
        <ToggleRow
          title="删除会话后自动移除空项目目录"
          subtitle="清理后递归移除不再包含任何会话的空目录"
          on={prefs.cleanEmptyProjectFolders}
          onToggle={() =>
            void onToggle('cleanEmptyProjectFolders', !prefs.cleanEmptyProjectFolders)
          }
        />
      </div>

      <div className={styles.card}>
        <div className={styles.cardHead}>
          <DrawnIcon name="shieldHalf" size={11} className={styles.cardHeadIcon} />
          <h3 className={styles.cardTitle}>安全策略</h3>
        </div>
        {/* 这一条是本页唯一的危险开关：关掉之后清理立即执行且不可撤销。 */}
        <ToggleRow
          title="执行清理操作前弹出二次确认"
          subtitle="关闭后清理将立即执行，不可撤销"
          on={prefs.confirmBeforeClean}
          risk
          onToggle={() => void onToggle('confirmBeforeClean', !prefs.confirmBeforeClean)}
        />
      </div>
    </>
  )
}

/**
 * 开关行。整行都是可点单元（点行即切换），开关自己**只画不接管事件**，
 * 否则会双触发。语义挂在行上（`role="switch"` + `aria-checked`）。
 */
function ToggleRow({
  title,
  subtitle,
  on,
  risk = false,
  onToggle
}: {
  title: string
  subtitle: string
  on: boolean
  risk?: boolean
  onToggle: () => void
}) {
  const risky = risk && !on
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      className={styles.toggleRow}
      onClick={onToggle}
    >
      <span className={styles.toggleMain}>
        <span className={styles.toggleTitle}>{title}</span>
        <span className={`${styles.toggleSub} ${risky ? styles.toggleSubRisk : ''}`}>
          {risky && <DrawnIcon name="exclamationTriangle" size={10} className={styles.riskIcon} />}
          {subtitle}
        </span>
      </span>
      <span
        className={[styles.switch, on ? styles.switchOn : '', risky ? styles.switchOnRisk : '']
          .filter(Boolean)
          .join(' ')}
        aria-hidden="true"
      >
        <span className={`${styles.switchKnob} ${on ? styles.switchKnobOn : ''}`} />
      </span>
    </button>
  )
}

// MARK: - 路径页

function PathsPane({
  agents,
  installedCount,
  totalSessionCount,
  totalBytes,
  home,
  icons,
  busy,
  onOpenPath,
  onCleanCategory
}: {
  agents: AgentInfo[]
  installedCount: number
  totalSessionCount: number
  totalBytes: number
  home: string
  icons: Record<string, string | null>
  busy: boolean
  onOpenPath: (path: string) => Promise<void>
  onCleanCategory: (category: AgentCategory) => Promise<void>
}) {
  const total = splitBytes(totalBytes)
  return (
    <>
      {/* 列表上方那三格读数：15 款里有几款装了、装出多少会话、总共占多大。 */}
      <div className={styles.summaryStrip}>
        <Stat value={String(installedCount)} unit={`/ ${agents.length} 款`} label="已安装" />
        <Stat value={String(totalSessionCount)} unit="个" label="会话" />
        <Stat value={total.value} unit={total.unit} label="合计占用" />
      </div>

      <div className={styles.card}>
        <div className={styles.cardHead}>
          <DrawnIcon name="grid2x2" size={11} className={styles.cardHeadIcon} />
          <h3 className={styles.cardTitle}>受支持的本地 Agent（{AGENT_COUNT} 款）</h3>
        </div>
        {agents.map((agent) => (
          <AgentPathRow
            key={agent.category}
            agent={agent}
            totalBytes={totalBytes}
            home={home}
            icons={icons}
            busy={busy}
            onOpenPath={onOpenPath}
            onCleanCategory={onCleanCategory}
          />
        ))}
      </div>
    </>
  )
}

function Stat({ value, unit, label }: { value: string; unit: string; label: string }) {
  return (
    <div className={styles.stat}>
      <span className={styles.statLine}>
        <span className={`${styles.statValue} num`}>{value}</span>
        <span className={styles.statUnit}>{unit}</span>
      </span>
      <span className={styles.statLabel}>{label}</span>
    </div>
  )
}

/**
 * 安装状态一律读 `AgentInfo.isInstalled`。
 * 早期版本这里有一份硬编码的 4 款名单把 Aider / OpenViking / Zed / OpenHands
 * 钉死成「未发现」并隐藏 Finder 按钮，而侧栏早已改成读扫描结果 —— 该名单已删除。
 */
function AgentPathRow({
  agent,
  totalBytes,
  home,
  icons,
  busy,
  onOpenPath,
  onCleanCategory
}: {
  agent: AgentInfo
  totalBytes: number
  home: string
  icons: Record<string, string | null>
  busy: boolean
  onOpenPath: (path: string) => Promise<void>
  onCleanCategory: (category: AgentCategory) => Promise<void>
}) {
  const label = CATEGORY_LABELS[agent.category]
  const displayPath = abbreviateHome(agent.storagePath, home)
  const share = percentOf(agent.totalBytes, totalBytes)
  const hasData = agent.totalBytes > 0

  return (
    <div className={styles.agentRow}>
      <AgentMark category={agent.category} icons={icons} size={18} />
      <div className={styles.agentMain}>
        <div className={styles.agentNameLine}>
          <span className={`${styles.agentName} ${agent.isInstalled ? '' : styles.agentNameOff}`}>
            {label}
          </span>
          <span
            className={`${styles.statusChip} ${agent.isInstalled ? '' : styles.statusChipOff}`}
          >
            {statusText(agent)}
          </span>
        </div>
        <span className={styles.agentPath} title={agent.storagePath}>
          {displayPath}
        </span>
      </div>

      {/* 0 字节干脆不画条：右边写的是「— 0 KB」，留个非零的条是在说谎。 */}
      {hasData ? (
        <span className={styles.agentShare} aria-hidden="true">
          <span className={styles.agentShareFill} style={{ width: `${share}%` }} />
        </span>
      ) : (
        <span className={styles.agentShareEmpty} aria-hidden="true" />
      )}

      <span className={styles.agentPct}>{shareText(share)}</span>
      <span className={`${styles.agentSize} ${hasData ? '' : styles.agentSizeZero}`}>
        {formatBytes(agent.totalBytes)}
      </span>

      {agent.isInstalled ? (
        <button
          type="button"
          className={styles.iconBtn}
          title={`在 Finder 中打开 ${label} 的存储目录`}
          aria-label={`在 Finder 中打开 ${label} 的存储目录`}
          onClick={() => void onOpenPath(agent.storagePath)}
        >
          <DrawnIcon name="arrowUpRight" size={12} />
        </button>
      ) : (
        /* 占位保列宽：未安装的 Agent 也要和上面几行对齐 */
        <span className={styles.iconPlaceholder} />
      )}

      <button
        type="button"
        className={`${styles.iconBtn} ${styles.iconBtnDanger}`}
        disabled={busy || agent.sessionCount === 0}
        title={`清空 ${label} 的全部会话`}
        aria-label={`清空 ${label} 的全部会话`}
        onClick={() => void onCleanCategory(agent.category)}
      >
        <DrawnIcon name="trash" size={12} />
      </button>
    </div>
  )
}

function statusText(agent: AgentInfo): string {
  if (!agent.isInstalled) return '未发现'
  return agent.sessionCount > 0 ? `${agent.sessionCount} 会话` : '已检测到'
}

/** 0.4% 四舍五入成 0% 会读成「没占」，与左边的体积自相矛盾。 */
function shareText(share: number): string {
  if (share <= 0) return '—'
  if (share < 0.5) return '<1%'
  return `${Math.round(share)}%`
}

function Fact({ value, label }: { value: string; label: string }) {
  return (
    <div className={styles.fact}>
      <div className={`${styles.factValue} num`}>{value}</div>
      <div className={styles.factLabel}>{label}</div>
    </div>
  )
}
