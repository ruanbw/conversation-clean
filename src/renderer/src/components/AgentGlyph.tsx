import type { CSSProperties } from 'react'
import type { AgentCategory } from '@shared/types'
import { CATEGORY_GLYPHS } from '@shared/types'

/**
 * Agent 字形库 —— 侧栏、列表、检视器、设置路径页共用同一套线稿符号。
 *
 * 定位：**真实 app 图标优先，字形只是兜底**。优先取 `state.agentIcons[category]`
 * （主进程解析好的 app 图标 dataURL），解析不到才画这里的线稿。
 *
 * 铁律：一律线性。每个 glyph 都是 `fill="none" stroke="currentColor" stroke-width="1.6"`，
 * 整套 UI 只靠 1.6px 描边建立识别度；一旦混入填充变体，描边语言就断了，
 * 侧栏 / 标题行 / 检视器 / 设置路径页会各自用不同粗细的符号。
 *
 * category → 字形 key 的映射（`CATEGORY_GLYPHS`）放在 `shared/types.ts` 而不是这里：
 * 主进程与渲染进程都要用同一份映射，两边各写一份必然漂。
 *
 * 两处**刻意**不与其他 Agent 同形，理由都是「同形等于没有区分」：
 *   · Aider 用 terminalClock 而不与 Claude Code 同用 terminal —— 真实侧栏里
 *     这两款会同时出现，撞脸等于没有区分。
 *   · Zed AI 是 textbox（文本光标意象），不是方块。
 */
const GLYPHS: Record<string, string> = {
  // 托盘：全部会话
  tray: 'M3 13h5l1.5 3h5L16 13h5M3 13l2.6-7.2A2 2 0 0 1 7.5 4.5h9a2 2 0 0 1 1.9 1.3L21 13v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-5Z',
  // 终端提示符：Claude Code
  terminal: 'M3.5 5.5h17a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1h-17a1 1 0 0 1-1-1v-11a1 1 0 0 1 1-1ZM6.5 9.5 9.5 12l-3 2.5M12.5 15h5',
  // 双尖括号 + 斜杠：Codex
  chevronCode: 'M8.5 7.5 4.5 12l4 4.5M15.5 7.5l4 4.5-4 4.5M13.8 4.6 10.2 19.4',
  // 芯片：Pi Agent
  cpu: 'M7 7h10v10H7zM9.5 3.5v3.5M14.5 3.5v3.5M9.5 17v3.5M14.5 17v3.5M3.5 9.5H7M3.5 14.5H7M17 9.5h3.5M17 14.5h3.5',
  // 闪电：Cline
  bolt: 'M13.2 2.8 4.9 13.2h5.6l-.7 8 8.3-10.4h-5.6l.7-8Z',
  // 火花：Roo Code
  sparkles: 'M12 3.2 13.5 8 18.3 9.5 13.5 11 12 15.8 10.5 11 5.7 9.5 10.5 8 12 3.2ZM18.4 15.2l.8 2.4 2.4.8-2.4.8-.8 2.4-.8-2.4-2.4-.8 2.4-.8.8-2.4Z',
  // 播放：Continue
  play: 'M4.5 6.8A1.8 1.8 0 0 1 6.3 5h11.4a1.8 1.8 0 0 1 1.8 1.8v10.4A1.8 1.8 0 0 1 17.7 19H6.3a1.8 1.8 0 0 1-1.8-1.8V6.8ZM10.4 9.3 15 12l-4.6 2.7V9.3Z',
  // 对话气泡：Copilot / VS Code
  chat: 'M4 6.4A1.9 1.9 0 0 1 5.9 4.5h12.2A1.9 1.9 0 0 1 20 6.4v6.7a1.9 1.9 0 0 1-1.9 1.9H9.8L5.6 19.2a.6.6 0 0 1-1-.46V6.4Z',
  // 光标 + 光芒：Cursor
  cursor: 'M6.2 3.6 18.4 11.3l-5.2 1.3-2.6 4.9-4.4-13.9ZM13.2 12.6l3.4 5',
  // 风：Windsurf
  wind: 'M3.5 8.5h9.2a2.6 2.6 0 1 0-2.6-2.8M3.5 12.6h13a2.6 2.6 0 1 1-2.6 2.8M3.5 16.7h5.9',
  // 六边环：Trae
  ring: 'M12 3.4 19 7.5v8.9L12 20.5 5 16.4V7.5l7-4.1ZM12 3.4v8.5l7 4.5M12 11.9l-7 4.5M12 11.9v8.6',
  // 终端 + 时钟：Aider（刻意不同于 terminal）
  terminalClock: 'M3.5 5.5h10.2a1 1 0 0 1 1 1v5.4M3.5 5.5v11a1 1 0 0 0 1 1h6.3M6.5 9.5 9.2 12l-2.7 2.5M12 9.2h6.6M12 12.6h6.6M12 16h3.8',
  // 盾：OpenViking
  shield: 'M12 3.2 19 6v6.2c0 3.9-2.9 7.2-7 8.6-4.1-1.4-7-4.7-7-8.6V6l7-2.8ZM9.2 12.1l2 2 3.6-3.9',
  // 文本光标：Zed AI
  textbox: 'M4.5 6.2A1.7 1.7 0 0 1 6.2 4.5h11.6a1.7 1.7 0 0 1 1.7 1.7v11.6a1.7 1.7 0 0 1-1.7 1.7H6.2a1.7 1.7 0 0 1-1.7-1.7V6.2ZM8.6 8.6v6.8M8.6 12h3.4M14.8 9.6v4.8a1.4 1.4 0 0 0 2.8 0V9.6',
  // 举手：OpenHands
  hand: 'M8.4 11V5.6a1.4 1.4 0 0 1 2.8 0V10m0-4.8a1.4 1.4 0 0 1 2.8 0V10m0-3.6a1.4 1.4 0 0 1 2.8 0v5.2m-11.2-.6V9.4a1.4 1.4 0 0 1 2.8 0V13M5.6 13.2v-1.6M5.6 13.2 4.2 11a1.4 1.4 0 0 0-2.3 1.6l3.1 5.3a4.6 4.6 0 0 0 3.9 2.1h2.3a4.4 4.4 0 0 0 4.4-4.4v-2.6',
  // 层叠：Antigravity
  layers: 'M12 3.4 3.6 7.6 12 11.8l8.4-4.2L12 3.4ZM3.6 12.2 12 16.4l8.4-4.2M3.6 16.4 12 20.6l8.4-4.2'
}

export interface AgentGlyphProps {
  category: AgentCategory
  /** 边长（px）。默认 14 —— 侧栏行内的标准尺寸。 */
  size?: number
  /** 直接指定字形 key，绕过 category 映射。 */
  glyph?: string
  className?: string
  style?: CSSProperties
}

/**
 * 画一个 Agent 的线稿字形。
 *
 * 用法：`<AgentGlyph category="claudeCode" size={14} />`
 * 颜色继承 `currentColor`（`var(--t1)` / `var(--t2)` / `var(--accent)` 由调用方决定）。
 */
export function AgentGlyph({ category, size = 14, glyph, className, style }: AgentGlyphProps) {
  const d = GLYPHS[glyph ?? CATEGORY_GLYPHS[category]] ?? GLYPHS['tray']
  return (
    <svg
      className={className}
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

/**
 * Agent 标记：**真实 app 图标优先，线稿字形兜底**。
 *
 * `icons[category]` 是主进程解析好的 app 图标 dataURL（CLI Agent 与
 * VS Code 扩展没有独立 app，值为 null），此时画 <img>；否则画 `AgentGlyph`。
 *
 * 真实图标本身就是色彩与识别度的锚点 —— 拿「彩色字母块」替代它，
 * 既丢了识别度，又得靠一堆语义色去补，色板自然就花。
 */
export function AgentMark({
  category,
  icons,
  size = 16,
  className,
  style
}: AgentGlyphProps & { icons?: Record<string, string | null> }) {
  const dataUrl = icons?.[category]
  if (dataUrl) {
    return (
      <img
        className={className}
        style={{ width: size, height: size, borderRadius: size * 0.22, ...style }}
        src={dataUrl}
        alt=""
        draggable={false}
      />
    )
  }
  return <AgentGlyph category={category} size={size} className={className} style={style} />
}
