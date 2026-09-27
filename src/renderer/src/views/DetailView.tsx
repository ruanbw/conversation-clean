import { useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import type { AgentCategory, ConversationItem } from '@shared/types'
import { CATEGORY_LABELS } from '@shared/types'
import {
  abbreviateHome,
  formatBytes,
  formatFullDate,
  formatRelativeDate,
  splitBytes
} from '@shared/format'
import { AgentMark } from '../components/AgentGlyph'
import { DrawnIcon } from '@renderer/components/DrawnControls'
import { useCleanActions, useCleanState } from '../state/cleanStore'
import { OverviewView } from './OverviewView'
import styles from './DetailView.module.css'

/**
 * 详情栏。
 *
 * 上下文切换：
 *   无选中 → OverviewView（占用大户 Top5 + Agent 分布）
 *   有选中 → 会话元数据 + 关联文件 + 操作
 *
 * 焦点只有一份：`item` 由 App.tsx 用 `cleanStore.getSelectedConversation()` 现取，
 * 会话被删后自动变 null，不需要跨模块的焦点通知，视图侧也不必写任何同步代码。
 *
 * 视觉层级（已定稿）：
 *   ① 底色 `var(--bg)`：三栏此前同色，详情栏是三栏里最「沉」的一层。
 *   ② 标题行只留图标与标题，省下的竖向预算全给「体积读数」—— 这是个清理
 *      占空间数据的工具，体积数字的视觉重量高于标题。
 *   ③ 元数据不用 CSS Grid：标签列钉死 58px 右对齐，行间加发丝线，扫读时眼睛能竖着走。
 *   ④ 操作按钮全部自绘：次要动作 ghost，删除 danger 实心红。
 *
 * 图标：Agent 字形走 `components/AgentGlyph.tsx`，功能图标（文件夹 / 文档 /
 * 垃圾桶 / 信息）统一走 `components/DrawnControls.tsx` 的 `DrawnIcon`
 * （与主窗口其余视图同一套 1.6px 描边字形），本文件不再内联第二份。
 */

/** 有第二层索引载体、删除时会连索引行一起删的 Agent。缺失时整个「原子清理」分区不渲染。 */
const IDX_NOTE: Partial<Record<AgentCategory, string>> = {
  piAgent: 'context-mode SQLite 索引行同步删除',
  copilotChat: 'state.vscdb 索引行同步删除',
  cursor: 'state.vscdb 索引行同步删除',
  windsurf: 'state.vscdb 索引行同步删除',
  trae: 'state.vscdb 索引行同步删除',
  antigravity: 'state.vscdb 索引行同步删除'
}

/** 这几款在「关联文件」里多列一条索引位置。 */
const IDX_PATH: Partial<Record<AgentCategory, string>> = {
  piAgent: '~/.pi/agent/context-mode',
  copilotChat: 'state.vscdb',
  cursor: 'state.vscdb',
  windsurf: 'state.vscdb',
  trae: 'state.vscdb',
  antigravity: 'state.vscdb'
}

/** 复制反馈的存活时长。1.5s 够读完「已复制」，又不至于让人等着确认。 */
const COPY_FEEDBACK_MS = 1_500

export interface DetailViewProps {
  /**
   * 当前选中的会话。
   * 传 `null`（或干脆不传，由 App.tsx 传 `cleanStore.getSelectedConversation()` 的结果）
   * 时本组件渲染 OverviewView。
   */
  item: ConversationItem | null
}

export function DetailView({ item }: DetailViewProps) {
  const state = useCleanState()
  const { revealInFinder, copyToClipboard, deleteSingle } = useCleanActions()
  const [copiedId, setCopiedId] = useState(false)
  const copyTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  const home = state.homeDir
  const storagePath = useMemo(() => {
    if (item === null) return ''
    return abbreviateHome(
      state.agentInfos.find((info) => info.category === item.category)?.storagePath ?? '',
      home
    )
  }, [item, state.agentInfos, home])

  // 关联文件算一次，元数据表和文件表共用 —— 不做两处各算一遍的「两边必然相同」
  const paths = useMemo(
    () => (item === null ? [] : relatedPaths(item, storagePath, home)),
    [item, storagePath, home]
  )

  // 切到另一条会话时重置「已复制」文案
  useEffect(() => {
    setCopiedId(false)
  }, [item?.id])

  useEffect(
    () => () => {
      if (copyTimer.current !== null) clearTimeout(copyTimer.current)
    },
    []
  )

  if (item === null) return <OverviewView />

  const label = CATEGORY_LABELS[item.category]
  const projectPath = displayProjectPath(item, home)
  const size = splitBytes(item.sizeInBytes)

  const metaRows: MetaRow[] = [
    { id: 'size', label: '占用空间', value: formatBytes(item.sizeInBytes), kind: 'num' },
    { id: 'msgs', label: '对话轮数', value: String(item.messageCount), kind: 'num' },
    { id: 'files', label: '关联文件', value: String(paths.length), kind: 'num' },
    { id: 'updated', label: '最后更新', value: formatFullDate(new Date(item.updatedAt)), kind: 'plain' },
    { id: 'branch', label: 'Git 分支', value: item.gitBranch ?? '', kind: 'mono' },
    // 「项目路径」给**全路径**：长路径在任意字符处折行、不截断，悬停 `title` 兜底。
    // `pathTail` 缩写只用于会话列表行 —— 两处不要互相「统一」。
    { id: 'project', label: '项目路径', value: projectPath, kind: 'mono', title: projectPath },
    { id: 'store', label: '存储路径', value: storagePath, kind: 'mono' },
    { id: 'session', label: '会话 ID', value: item.sessionId, kind: 'mono' }
  ]

  const note = IDX_NOTE[item.category]

  const onCopySessionId = (): void => {
    void copyToClipboard(item.sessionId)
    setCopiedId(true)
    if (copyTimer.current !== null) clearTimeout(copyTimer.current)
    copyTimer.current = setTimeout(() => {
      copyTimer.current = null
      setCopiedId(false)
    }, COPY_FEEDBACK_MS)
  }

  return (
    <div className={styles.root}>
      <div className={styles.scroll}>
        <div className={styles.stack}>
          {/* ---------- 头部：图标 + 标题 + 徽章 + 体积读数 ---------- */}
          <header className={styles.header}>
            <AgentMark category={item.category} icons={state.agentIcons} size={28} />
            <div className={styles.headerMain}>
              <h2 className={styles.title}>{item.title}</h2>
              <div className={styles.metaLine}>
                <span className={styles.chip}>{label}</span>
                <span className="num">{item.messageCount} 轮</span>
                <span className={styles.metaDot}>·</span>
                <span className={styles.metaTime}>
                  {formatRelativeDate(new Date(item.updatedAt))}
                </span>
              </div>
            </div>
            <div
              className={styles.readout}
              role="group"
              aria-label={`占用空间 ${formatBytes(item.sizeInBytes)}`}
            >
              <div className={styles.readoutLine}>
                <span className={`${styles.readoutValue} num`}>{size.value}</span>
                <span className={styles.readoutUnit}>{size.unit}</span>
              </div>
              <span className={styles.readoutLabel}>占用空间</span>
            </div>
          </header>

          {/* ---------- 元数据 ---------- */}
          <section className={styles.section}>
            <h3 className={styles.sectionTitle}>元数据</h3>
            <div className={styles.card}>
              {metaRows.map((row) => (
                <div className={styles.metaRow} key={row.id}>
                  <span className={styles.metaLabel}>{row.label}</span>
                  <span
                    className={[
                      styles.metaValue,
                      row.kind === 'mono' ? styles.metaMono : '',
                      row.kind === 'num' ? styles.metaNum : '',
                      row.value.length === 0 ? styles.metaValueEmpty : ''
                    ]
                      .filter(Boolean)
                      .join(' ')}
                    title={row.title}
                  >
                    {row.value.length === 0 ? '—' : row.value}
                  </span>
                </div>
              ))}
            </div>
          </section>

          {/* 摘要为空时整区不显示 */}
          {item.snippet.length > 0 && (
            <section className={styles.section}>
              <h3 className={styles.sectionTitle}>摘要</h3>
              <div className={styles.card}>
                <p className={`${styles.cardBody} ${styles.snippet} selectable`}>{item.snippet}</p>
              </div>
            </section>
          )}

          {/* ---------- 原子清理（仅 IDX_NOTE 命中的 Agent） ---------- */}
          {note !== undefined && (
            <section className={styles.section}>
              <h3 className={styles.sectionTitle}>原子清理</h3>
              <div className={styles.tinted}>
                <DrawnIcon name="shieldHalf" size={14} className={styles.noteIcon} />
                <p className={styles.noteText}>
                  {note}，不会留下幽灵会话。
                </p>
              </div>
            </section>
          )}

          {/* ---------- 关联文件（点击复制路径） ---------- */}
          <section className={styles.section}>
            <h3 className={styles.sectionTitle}>关联文件</h3>
            <div className={styles.card}>
              {paths.map((path) => (
                <button
                  type="button"
                  className={styles.fileRow}
                  key={path}
                  title={`复制路径：${path}`}
                  aria-label={`复制路径 ${path}`}
                  onClick={() => void copyToClipboard(path)}
                >
                  {/* 索引载体（state.vscdb）没有目录层级，用文件夹图标是错的 */}
                  <DrawnIcon
                    name={path.includes('/') ? 'folder' : 'docOnDoc'}
                    size={12}
                    className={styles.fileIcon}
                  />
                  <span className={styles.filePath}>{path}</span>
                  <DrawnIcon name="docOnDoc" size={10} className={styles.fileHint} />
                </button>
              ))}
            </div>
          </section>

          {/* ---------- 操作 ---------- */}
          <section className={styles.section}>
            <h3 className={styles.sectionTitle}>操作</h3>
            <div className={styles.actionGrid}>
              <ActionButton
                icon={<DrawnIcon name="folder" />}
                label="在 Finder 中显示"
                variant="ghost"
                onClick={() => void revealInFinder(item)}
              />
              <ActionButton
                icon={<DrawnIcon name="docOnDoc" />}
                label="复制项目路径"
                variant="ghost"
                disabled={projectPath.length === 0}
                onClick={() => void copyToClipboard(projectPath)}
              />
              <ActionButton
                /* 反馈态用 check；常态是井号（会话 ID 是个 # 号，不是文本）。 */
                icon={<DrawnIcon name={copiedId ? 'check' : 'numberSign'} />}
                label={copiedId ? '已复制' : '复制会话 ID'}
                variant="ghost"
                onClick={onCopySessionId}
              />
              <ActionButton
                icon={<DrawnIcon name="trash" />}
                label="删除此会话"
                variant="danger"
                disabled={state.isCleaning}
                onClick={() => void deleteSingle(item)}
              />
            </div>
          </section>
        </div>
      </div>
    </div>
  )
}

// MARK: - 元数据行模型

/**
 * 一行元数据。`kind` 决定值的排版：路径 / ID 走等宽，数字走 tabular-nums，其余走正文。
 */
interface MetaRow {
  id: string
  label: string
  value: string
  kind: 'mono' | 'num' | 'plain'
  /** 行尾省略之外的补充信息，落在 `title` 上。 */
  title?: string
}

/** 项目路径：home 缩写成 `~`，空值给空串（渲染时显示「—」）。 */
function displayProjectPath(item: ConversationItem, home: string): string {
  const raw = item.projectPath
  if (!raw || raw.length === 0) return ''
  return abbreviateHome(raw, home)
}

/**
 * 优先用扫描器给出的真实 `associatedPaths`；
 * 拿不到时按 `<project>/.session` → `<agent.storagePath>/<sessionId>.jsonl` → 索引位置 拼。
 */
function relatedPaths(item: ConversationItem, storagePath: string, home: string): string[] {
  if (item.associatedPaths.length > 0) {
    return item.associatedPaths.map((path) => abbreviateHome(path, home))
  }
  const out: string[] = []
  const project = displayProjectPath(item, home)
  if (project.length > 0) out.push(`${project}/.session`)
  if (storagePath.length > 0) out.push(`${storagePath}/${item.sessionId}.jsonl`)
  const idx = IDX_PATH[item.category]
  if (idx !== undefined) out.push(idx)
  return out
}

// MARK: - 操作按钮

type ButtonVariant = 'ghost' | 'danger'

const VARIANT_CLASS: Record<ButtonVariant, string> = {
  ghost: 'btnGhost',
  danger: 'btnDanger'
}

function ActionButton({
  icon,
  label,
  variant,
  disabled = false,
  onClick
}: {
  icon: ReactNode
  label: string
  variant: ButtonVariant
  disabled?: boolean
  onClick: () => void
}) {
  return (
    <button
      type="button"
      className={`${styles.btn} ${styles[VARIANT_CLASS[variant]]}`}
      disabled={disabled}
      onClick={onClick}
    >
      {icon}
      <span className={styles.btnLabel}>{label}</span>
    </button>
  )
}
