import { useEffect, useRef, useState } from 'react'
import type { CSSProperties, ReactNode } from 'react'
import type { AgentCategory } from '@shared/types'
import { AgentGlyph } from './AgentGlyph'
import styles from './DrawnControls.module.css'

/**
 * DrawnControls —— 全应用的自绘控件库。
 *
 * 移植自 `ConversationClean/Views/DrawnControls.swift`，外加
 * `SettingsView.swift` 里的 `DrawnSwitch`（系统 `Toggle` 的替代品）。
 *
 * 边界说明（Swift 版的原话，这里同样成立）：
 *   · 交互原语仍是原生 `<button>` / `<input>`。它们不是「系统控件外观」，
 *     只是布局与事件容器 —— 外观（高光、描边、圆角、hover、press）全在本文件
 *     自己的 CSS 里，系统外观一点不露。换成 `div onClick` 会同时失去键盘可达、
 *     焦点环与语义角色 —— 那是拿可用性换一张皮，方向错了。
 *   · `<input>` 的输入法、光标、选区无法自绘重写，所以只自绘外壳
 *     （圆角、描边、focus ring、放大镜、清除钮）。
 *
 * 视觉基线 `design-demos/ui-a-precision.html`，所有颜色/间距/字号取 `var(--token)`。
 */

/** 拼 className。CSS Modules 的类名是哈希值，没法用逻辑运算合并。 */
function cx(...parts: (string | false | null | undefined)[]): string {
  return parts.filter(Boolean).join(' ')
}

// MARK: - 自绘字形

/**
 * 线性图标集。替代 SF Symbols —— 混进系统符号会让自绘控件的描边语言断掉
 * （系统符号有填充变体、有更粗的字重），这里与 `AgentGlyph` 一样
 * 一律 1.6px 描边 + `fill: none`。
 */
const ICON_PATHS: Record<string, string> = {
  trash: 'M4.5 6.5h15M9.5 6.5V4.9c0-.8.6-1.4 1.4-1.4h2.2c.8 0 1.4.6 1.4 1.4v1.6M6.6 6.5l.8 12.1c0 .8.7 1.4 1.5 1.4h6.2c.8 0 1.5-.6 1.5-1.4l.8-12.1M10.2 10.2v6M13.8 10.2v6',
  gear: 'M12 15.4a3.4 3.4 0 1 0 0-6.8 3.4 3.4 0 0 0 0 6.8ZM12 2.8v2M12 19.2v2M2.8 12h2M19.2 12h2M5.5 5.5l1.4 1.4M17.1 17.1l1.4 1.4M18.5 5.5l-1.4 1.4M6.9 17.1l-1.4 1.4',
  refresh: 'M20 12a8 8 0 1 1-2.6-5.9M20.2 4.6v4.6h-4.6',
  scan: 'M12 20.2a8.2 8.2 0 0 0 7.5-4.7M19.8 12A7.8 7.8 0 1 0 12 4.2M15.9 2.1v3.1h-3.1',
  folder: 'M3.6 7.4c0-.8.6-1.4 1.4-1.4h3.9l2 2.4h8.1c.8 0 1.4.6 1.4 1.4v8.8c0 .8-.6 1.4-1.4 1.4H5c-.8 0-1.4-.6-1.4-1.4V7.4Z',
  reveal: 'M14.2 4.6h5.2v5.2M19.4 4.6 11.6 12.4M17.8 13.8v4.7c0 .9-.7 1.5-1.5 1.5H5.6c-.9 0-1.5-.6-1.5-1.5V7.7c0-.8.6-1.5 1.5-1.5h4.7',
  xmark: 'M6.6 6.6 17.4 17.4M17.4 6.6 6.6 17.4',
  check: 'M5.2 12.4 10 17.2 18.8 7',
  checkCircle: 'M12 20.4a8.4 8.4 0 1 0 0-16.8 8.4 8.4 0 0 0 0 16.8ZM8.2 12.2 11 15l5-5.4',
  magnifier: 'M10.8 17.6a6.8 6.8 0 1 0 0-13.6 6.8 6.8 0 0 0 0 13.6ZM15.6 15.6 20.4 20.4',
  info: 'M12 20.4a8.4 8.4 0 1 0 0-16.8 8.4 8.4 0 0 0 0 16.8ZM12 11v5.2M12 7.8h.01',
  // ---- 以下为补齐集：避免其它视图各画一份内联图标 ----
  exclamation: 'M12 20.4a8.4 8.4 0 1 0 0-16.8 8.4 8.4 0 0 0 0 16.8ZM12 7.4v5.6M12 16.4h.01',
  docOnDoc: 'M9.4 3.6h6.9l4.1 4.1v9.1a1.8 1.8 0 0 1-1.8 1.8H9.4a1.8 1.8 0 0 1-1.8-1.8V5.4a1.8 1.8 0 0 1 1.8-1.8ZM16.1 3.6v4.3h4.2M10.6 11.4h6M10.6 14.6h6M10.6 8.2h3',
  clock: 'M12 20.4a8.4 8.4 0 1 0 0-16.8 8.4 8.4 0 0 0 0 16.8ZM12 7.2V12l3.2 1.9',
  bubble: 'M4 6.6A1.9 1.9 0 0 1 5.9 4.7h12.2A1.9 1.9 0 0 1 20 6.6v6.6a1.9 1.9 0 0 1-1.9 1.9H9.6l-4.1 3.4a.6.6 0 0 1-1-.45V6.6Z',
  sort: 'M6.6 8.4 9.4 5.2l2.8 3.2M9.4 5.2v13.6M17.4 15.6 14.6 18.8l-2.8-3.2M14.6 18.8V5.2',
  chevronRight: 'M9.4 5.6 15.8 12l-6.4 6.4',
  arrowUpRight: 'M7.4 16.6 16.6 7.4M8.6 7.4h8v8',
  checkSquare: 'M5.4 4.6h13.2a.8.8 0 0 1 .8.8v13.2a.8.8 0 0 1-.8.8H5.4a.8.8 0 0 1-.8-.8V5.4a.8.8 0 0 1 .8-.8ZM8.8 12.2 11 14.4l4.4-4.6',
  square: 'M5.4 4.6h13.2a.8.8 0 0 1 .8.8v13.2a.8.8 0 0 1-.8.8H5.4a.8.8 0 0 1-.8-.8V5.4a.8.8 0 0 1 .8-.8Z',
  window: 'M3.6 5.4a1.8 1.8 0 0 1 1.8-1.8h13.2a1.8 1.8 0 0 1 1.8 1.8v13.2a1.8 1.8 0 0 1-1.8 1.8H5.4a1.8 1.8 0 0 1-1.8-1.8V5.4ZM3.6 9h16.8M6.6 7.2h.01M9 7.2h.01M11.4 7.2h.01',
  bolt: 'M13.2 2.8 4.9 13.2h5.6l-.7 8 8.3-10.4h-5.6l.7-8Z',
  sparkle: 'M12 3.2 13.5 8 18.3 9.5 13.5 11 12 15.8 10.5 11 5.7 9.5 10.5 8 12 3.2ZM18.4 15.2l.8 2.4 2.4.8-2.4.8-.8 2.4-.8-2.4-2.4-.8 2.4-.8.8-2.4Z',

  // ↓ 以下 7 枚是集成阶段补的。
  //
  // 背景：三个视图在 `DrawnControls` 尚未落地时各自内联画了一份图标，
  // 收敛过来时发现语义对不上的有 7 处。当时的权宜之计是「拿最接近的现成字形顶上」，
  // 于是出现了「关于卡用 sparkle 代表 tray.2」「会话数用 docOnDoc 代表 #」这种错配 ——
  // 肉眼看得出是凑数。所以补齐真字形，而不是让错配留在代码里。
  // 命名沿用 Swift 版的 SF Symbol 名，便于回查基准。
  //
  // tray.2：托盘 —— 「关于」卡自身的 symbol，也是「全部会话」分类的字形。
  tray: 'M3 13h5l1.5 3h5L16 13h5M3 13l2.6-7.2A2 2 0 0 1 7.5 4.5h9a2 2 0 0 1 1.9 1.3L21 13v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-5Z',
  // numberSign：井号 —— 侧栏分类行的会话数。
  numberSign: 'M8.4 3.6 6.8 20.4M17.2 3.6l-1.6 16.8M3.8 8.6h16.4M3.4 15.4h16.4',
  // shieldHalf：半填充盾牌 —— 「双层索引原子清理」分区的语义标记。
  shieldHalf: 'M12 3.2 19 6v6.2c0 3.9-2.9 7.2-7 8.6-4.1-1.4-7-4.7-7-8.6V6l7-2.8ZM12 3.2v17.6M12 11.9l7 4.5',
  // grid2x2：2×2 方格 —— 设置页的「通用 / Agent 路径 / 关于」页签图标。
  grid2x2: 'M4.6 4.6h6v6h-6zM13.4 4.6h6v6h-6zM4.6 13.4h6v6h-6zM13.4 13.4h6v6h-6z',
  // exclamationTriangle：警告三角（描边版，描边语言要统一所以不用填充）—— 量级徽标、风险提示。
  exclamationTriangle: 'M10.7 3.9 2.6 17.4c-.6 1 .1 2.2 1.3 2.2h16.2c1.2 0 1.9-1.2 1.3-2.2L13.3 3.9c-.6-1-2-1-2.6 0ZM12 9.2v4.4M12 16.6h.01',
  // doc：单张文档 —— 关联文件列表里的普通文件（与 docOnDoc 的「双张=复制」区分开）。
  doc: 'M6.2 3.8h7l4.6 4.6v11.8H6.2V3.8ZM13.2 3.8v4.6h4.6',
  // folderQuestion：带问号的文件夹 —— 存储目录不存在时的入口。
  folderQuestion: 'M3.6 7.4c0-.8.6-1.4 1.4-1.4h3.9l2 2.4h8.1c.8 0 1.4.6 1.4 1.4v8.8c0 .8-.6 1.4-1.4 1.4H5c-.8 0-1.4-.6-1.4-1.4V7.4ZM9.9 11.6a2.1 2.1 0 1 1 2.8 2v1M12.7 16.8h.01'
}

export type DrawnIconName = keyof typeof ICON_PATHS | string

export interface DrawnIconProps {
  name: DrawnIconName
  size?: number
  className?: string
  style?: CSSProperties
}

/** 线性图标。与 `AgentGlyph` 同一套描边语言。 */
export function DrawnIcon({ name, size = 12, className, style }: DrawnIconProps) {
  const d = ICON_PATHS[name] ?? ICON_PATHS['info']
  return (
    <svg
      className={cx(styles['glyph'], className)}
      style={style}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.6}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d={d} />
    </svg>
  )
}

// MARK: - 按钮

/**
 * 按钮视觉变体（对应 Swift 的 `DrawnButtonVariant`）。
 *
 * `flat` / `dangerQuiet` 无底色：工具栏图标与次要动作。
 * `dangerQuiet` 单独拆出来 —— 破坏性动作的图标不该和「设置」长得一样重，
 * 但顶栏只有 26px 高，实心红底会太扎眼，所以只借红色前景。
 */
export type DrawnButtonVariant = 'flat' | 'dangerQuiet' | 'ghost' | 'primary' | 'danger'

export interface DrawnButtonProps {
  variant?: DrawnButtonVariant
  /** 左侧图标，建议 `<DrawnIcon />` 或 `<AgentGlyph />` */
  icon?: ReactNode
  children?: ReactNode
  onClick?: () => void
  disabled?: boolean
  /** 紧凑模式：行高 22px，批量条里用 */
  compact?: boolean
  /** 纯图标按钮：正方形 26px（compact 时 22px） */
  iconOnly?: boolean
  /** 覆盖左右内边距（px）。Swift 版是 `horizontalPadding` 参数。 */
  paddingX?: number
  /** tooltip，也是纯图标按钮的可访问名 */
  help?: string
  className?: string
  style?: CSSProperties
}

/**
 * 自绘按钮。hover 提亮、press 压暗、禁用降透明 —— 全部自己实现。
 *
 * 注意禁用态**只降 opacity 不换色**：Swift 版踩过的坑是
 * `.tint(.red) + .disabled` 在 macOS 上会渲染成粉红，禁用看着像可点。
 */
export function DrawnButton({
  variant = 'flat',
  icon,
  children,
  onClick,
  disabled = false,
  compact = false,
  iconOnly = false,
  paddingX,
  help,
  className,
  style
}: DrawnButtonProps) {
  return (
    <button
      type="button"
      className={cx(
        styles['btn'],
        styles[variant],
        compact && styles['compact'],
        iconOnly && styles['iconOnly'],
        className
      )}
      style={{ paddingInline: paddingX, ...style }}
      title={help}
      aria-label={children ? undefined : help}
      disabled={disabled}
      onClick={onClick}
    >
      {icon}
      {children}
    </button>
  )
}

/** 纯图标按钮。`help` 必填 —— 没有文字就没有可访问名，也没有 tooltip 兜底。 */
export function DrawnIconButton({
  icon,
  help,
  variant = 'flat',
  disabled = false,
  compact = false,
  className,
  onClick
}: Omit<DrawnButtonProps, 'iconOnly' | 'children'> & { icon: ReactNode; help: string }) {
  return (
    <DrawnButton
      variant={variant}
      icon={icon}
      iconOnly
      help={help}
      disabled={disabled}
      compact={compact}
      className={className}
      onClick={onClick}
    />
  )
}

// MARK: - 勾选框

export interface DrawnCheckboxProps {
  checked: boolean
  onChange?: (next: boolean) => void
  /** 半选：整列操作时「部分已选」 */
  mixed?: boolean
  disabled?: boolean
  size?: number
  help?: string
  /** 无障碍名。列表行里由行文本提供语义，这里给一个可读的兜底。 */
  label?: string
  /** 点击时是否阻止冒泡（列表行里点勾选框不该同时改行选中） */
  stopPropagation?: boolean
  className?: string
}

/** 勾选框里的那笔勾 / 那道横杠。抽出来是为了让纯展示版本与可点版本共用。 */
function CheckboxMark({ checked, mixed }: { checked: boolean; mixed: boolean }) {
  if (mixed) return <span className={styles['cbDash']} />
  if (checked) return <span className={styles['cbCheck']} />
  return null
}

/**
 * 纯展示的勾选框（不接管事件）。
 *
 * 侧栏的「仅显示有数据」那一行整行可点，行内再嵌一个 `<button>` 是非法嵌套，
 * 浏览器会把 DOM 结构拆坏。所以行里画这个 —— 与 Swift 版在 Button 的 label 里
 * 放一个 `Image(systemName: "checkmark.square.fill")` 是同一件事。
 */
export function DrawnCheckboxBox({
  checked,
  mixed = false,
  size,
  className
}: {
  checked: boolean
  mixed?: boolean
  size?: number
  className?: string
}) {
  return (
    <span
      aria-hidden="true"
      className={cx(styles['cb'], (checked || mixed) && styles['cbOn'], className)}
      style={size ? { width: size, height: size } : undefined}
    >
      <CheckboxMark checked={checked} mixed={mixed} />
    </span>
  )
}

/**
 * 手绘勾选框，支持半选态。
 *
 * 原实现用系统 `Toggle(.checkbox)`，它带一个系统绘制的框；这里整块重画，
 * 尺寸按 A 版的 14px，比系统默认小 1px，密度更高。
 */
export function DrawnCheckbox({
  checked,
  onChange,
  mixed = false,
  disabled = false,
  size,
  help,
  label,
  stopPropagation = false,
  className
}: DrawnCheckboxProps) {
  const on = checked || mixed
  return (
    <button
      type="button"
      role="checkbox"
      aria-checked={mixed ? 'mixed' : checked}
      aria-label={label}
      title={help}
      className={cx(styles['cb'], on && styles['cbOn'], className)}
      style={size ? { width: size, height: size } : undefined}
      disabled={disabled}
      onClick={(event) => {
        if (stopPropagation) event.stopPropagation()
        onChange?.(!checked)
      }}
    >
      <CheckboxMark checked={checked} mixed={mixed} />
    </button>
  )
}

// MARK: - 分段控件

export interface SegmentedOption<T extends string> {
  value: T
  label: string
}

export interface DrawnSegmentedProps<T extends string> {
  value: T
  options: readonly SegmentedOption<T>[]
  onChange: (next: T) => void
  className?: string
}

/** 自绘分段控件。替代系统 `Picker(.segmented)`。 */
export function DrawnSegmented<T extends string>({
  value,
  options,
  onChange,
  className
}: DrawnSegmentedProps<T>) {
  return (
    <div className={cx(styles['seg'], className)} role="radiogroup">
      {options.map((option) => {
        const on = option.value === value
        return (
          <button
            key={option.value}
            type="button"
            role="radio"
            aria-checked={on}
            className={cx(styles['segItem'], on && styles['segItemOn'])}
            onClick={() => onChange(option.value)}
          >
            {option.label}
          </button>
        )
      })}
    </div>
  )
}

// MARK: - 搜索框

export interface DrawnSearchFieldProps {
  value: string
  onChange: (next: string) => void
  placeholder: string
  onSubmit?: () => void
  /**
   * ⌘F 的「请把搜索框拉到焦点」请求计数。
   * 用自增 int 而不是 boolean：用户已经在搜索框里时按 ⌘F，boolean 不变化，
   * 视图收不到通知，光标也不会重新全选。与 `cleanStore.searchFocusRequest` 同源。
   */
  focusRequest?: number
  className?: string
}

/** 自绘搜索框。圆角、描边、focus ring、放大镜、清除钮全部自绘。 */
export function DrawnSearchField({
  value,
  onChange,
  placeholder,
  onSubmit,
  focusRequest = 0,
  className
}: DrawnSearchFieldProps) {
  const inputRef = useRef<HTMLInputElement | null>(null)
  const [focused, setFocused] = useState(false)

  useEffect(() => {
    if (focusRequest <= 0) return
    const input = inputRef.current
    if (!input) return
    input.focus()
    input.select()
    // 只在请求计数变化时重新聚焦；依赖里不含 value，避免每敲一个字就抢焦点。
  }, [focusRequest])

  return (
    <div
      className={cx(styles['search'], focused && styles['searchFocused'], className)}
      onClick={() => inputRef.current?.focus()}
    >
      <span className={styles['searchIcon']}>
        <DrawnIcon name="magnifier" size={13} />
      </span>
      <input
        ref={inputRef}
        className={styles['searchInput']}
        type="text"
        value={value}
        placeholder={placeholder}
        aria-label={placeholder}
        onChange={(event) => onChange(event.target.value)}
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        onKeyDown={(event) => {
          if (event.key === 'Enter') onSubmit?.()
        }}
      />
      {value.length > 0 ? (
        <button
          type="button"
          className={styles['searchClear']}
          title="清除搜索词"
          aria-label="清除搜索词"
          onClick={(event) => {
            event.stopPropagation()
            onChange('')
            inputRef.current?.focus()
          }}
        >
          <DrawnIcon name="xmark" size={8} />
        </button>
      ) : null}
    </div>
  )
}

// MARK: - 通知条

export interface DrawnNoticeProps {
  icon?: DrawnIconName
  text: string
  tone?: 'success' | 'danger'
  dismissTitle?: string
  onDismiss?: () => void
  className?: string
}

/** 自绘通知条。替代原来那条 `tint.opacity(0.12)` 的绿色横条。 */
export function DrawnNotice({
  icon = 'checkCircle',
  text,
  tone = 'success',
  dismissTitle,
  onDismiss,
  className
}: DrawnNoticeProps) {
  return (
    <div
      className={cx(
        styles['notice'],
        tone === 'success' ? styles['noticeSuccess'] : styles['noticeDanger'],
        className
      )}
      role="status"
    >
      <DrawnIcon name={icon} size={12} />
      <span className={styles['noticeText']}>{text}</span>
      {dismissTitle && onDismiss ? (
        <DrawnButton variant="flat" paddingX={6} onClick={onDismiss}>
          {dismissTitle}
        </DrawnButton>
      ) : null}
    </div>
  )
}

// MARK: - 占比条

export interface ShareBarProps {
  /** 0...100 */
  percent: number
  width?: number
  height?: number
  className?: string
}

/**
 * 占比条。靛蓝渐变填充 —— 修掉原来 `Color.primary.opacity(0.55)` 的黑灰条
 * （深色模式下 `Color.primary` 变白，整条变成白条）。
 */
export function ShareBar({ percent, width, height, className }: ShareBarProps) {
  const clamped = Math.min(100, Math.max(0, percent))
  return (
    <div
      className={cx(styles['share'], className)}
      style={{ width, height }}
      aria-hidden="true"
    >
      <div className={styles['shareFill']} style={{ width: `${clamped}%` }} />
    </div>
  )
}

// MARK: - 空态

export interface DrawnEmptyStateProps {
  /** 图标名（`DrawnIcon` 字形表）；给了 `category` 时优先用 Agent 字形 */
  icon?: DrawnIconName
  category?: AgentCategory
  title: string
  message: string
  actionTitle?: string
  onAction?: () => void
  className?: string
}

/** 自绘空态。替代 `ContentUnavailableView`（它带系统插画与系统排版）。 */
export function DrawnEmptyState({
  icon = 'magnifier',
  category,
  title,
  message,
  actionTitle,
  onAction,
  className
}: DrawnEmptyStateProps) {
  return (
    <div className={cx(styles['empty'], className)}>
      <span className={styles['emptyBadge']}>
        {category ? (
          <AgentGlyph category={category} size={22} />
        ) : (
          <DrawnIcon name={icon} size={21} />
        )}
      </span>
      <div className={styles['emptyText']}>
        <span className={styles['emptyTitle']}>{title}</span>
        <span className={styles['emptyMessage']}>{message}</span>
      </div>
      {actionTitle && onAction ? (
        <DrawnButton variant="primary" paddingX={16} onClick={onAction}>
          {actionTitle}
        </DrawnButton>
      ) : null}
    </div>
  )
}

// MARK: - 开关

export interface DrawnSwitchProps {
  checked: boolean
  onChange?: (next: boolean) => void
  disabled?: boolean
  /** 开启时用危险色（设置页的破坏性开关） */
  tone?: 'accent' | 'danger'
  label?: string
  className?: string
}

/**
 * iOS 式开关。系统 `Toggle` 的轨道渐变 + 高光在深色模式下是另一种蓝，
 * 和侧栏选中态摆在一起颜色对不上，这里整块重画。
 *
 * Swift 版是「纯绘制视图」——开关画在整行 Button 里，行才是可点单元。
 * 这里做成独立可点单元（设置页按行点击时用 `stopPropagation` 保持一致）。
 */
export function DrawnSwitch({
  checked,
  onChange,
  disabled = false,
  tone = 'accent',
  label,
  className
}: DrawnSwitchProps) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      className={cx(
        styles['switch'],
        checked && styles['switchOn'],
        checked && tone === 'danger' && styles['switchDangerOn'],
        !checked && styles['switchOff'],
        className
      )}
      onClick={() => onChange?.(!checked)}
    >
      <span className={cx(styles['switchThumb'], checked && styles['switchThumbOn'])} />
    </button>
  )
}

// MARK: - 徽章

export interface BadgeProps {
  text: string
  tone?: 'neutral' | 'accent' | 'success' | 'danger' | 'inverse'
  className?: string
}

/** 小胶囊。侧栏计数、设置页安装状态共用。 */
export function Badge({ text, tone = 'neutral', className }: BadgeProps) {
  return (
    <span className={cx(styles['badge'], styles[`badge${tone[0]?.toUpperCase()}${tone.slice(1)}`], className)}>
      {text}
    </span>
  )
}

// MARK: - 发丝线

export interface HairlineProps {
  edge?: 'top' | 'bottom' | 'start' | 'end'
  className?: string
}

/**
 * 1px 发丝线（Linear 风格：不用系统 Divider 的默认色）。
 * 注意是真实的 1px 盒子，不是 overlay —— 裸 `position:absolute` 的假线
 * 曾经把顶栏 48px 和批量条 44px 整条盖平，看上去「那里什么都没有」。
 */
export function Hairline({ edge = 'bottom', className }: HairlineProps) {
  return <div aria-hidden="true" className={cx(styles['hairline'], styles[`hairline${edge[0]?.toUpperCase()}${edge.slice(1)}`], className)} />
}

// MARK: - 两种面

export interface SurfaceProps {
  children?: ReactNode
  radius?: number
  className?: string
  style?: CSSProperties
}

/** 卡片面：白底 + 发丝边，A 版的克制做法（不用阴影）。 */
export function CardSurface({ children, radius, className, style }: SurfaceProps) {
  return (
    <div className={cx(styles['card'], className)} style={{ borderRadius: radius, ...style }}>
      {children}
    </div>
  )
}

/** 靛蓝淡底 + 靛蓝淡边（体检卡 / 路径卡 / 说明块）。 */
export function TintedSurface({ children, radius, className, style }: SurfaceProps) {
  return (
    <div className={cx(styles['tinted'], className)} style={{ borderRadius: radius, ...style }}>
      {children}
    </div>
  )
}

// MARK: - 区块标题

export interface SectionLabelProps {
  text: string
  /** `upper` = 侧栏那套 11px 大写三级字；`strong` = 内容栏的 12px semibold */
  tone?: 'upper' | 'strong'
  /** 去掉上边距（紧跟上一块时用） */
  flush?: boolean
  className?: string
}

export function SectionLabel({
  text,
  tone = 'upper',
  flush = false,
  className
}: SectionLabelProps) {
  return (
    <div
      className={cx(
        styles['section'],
        tone === 'upper' ? styles['sectionUpper'] : styles['sectionStrong'],
        flush && styles['sectionFlush'],
        className
      )}
    >
      {text}
    </div>
  )
}
