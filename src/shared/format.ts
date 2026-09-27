/**
 * 1024 进制体积 / 时间 / 路径格式化。
 *
 * 移植自 Swift 版 `ConversationClean/Core/Formatting.swift` 的 `enum Fmt`。
 * 放在 `shared/` 是因为主进程（确认面板的「预计释放」）与渲染进程（列表、检视器）
 * 要用**完全同一套**换算，两边各写一遍必然漂。
 */

/** 与原型 `fmtBytes` 同口径：1024 进制、<10 保留 1 位小数、≥10 四舍五入为整数、0 输出「0 KB」。 */
export function formatBytes(n: number): string {
  if (n === 0) return '0 KB'
  const units = ['KB', 'MB', 'GB', 'TB']
  let value = Math.max(n, 0)
  let index = -1
  do {
    value /= 1024
    index += 1
  } while (value >= 1024 && index < units.length - 1)
  const text = value < 10 ? value.toFixed(1) : String(Math.round(value))
  return `${text} ${units[index]}`
}

/**
 * `formatBytes` 的拆版：返回 (数值, 单位)，供需要混排两种字号的地方用。
 * 侧栏「可回收空间」体检卡要 22px 的 `52.3` 配 12px 的 `MB`，
 * 拼成单个字符串就只能用一种字号，大号读数的视觉重量就没了。
 */
export function splitBytes(n: number): { value: string; unit: string } {
  if (n === 0) return { value: '0', unit: 'KB' }
  const units = ['KB', 'MB', 'GB', 'TB']
  let value = Math.max(n, 0)
  let index = -1
  do {
    value /= 1024
    index += 1
  } while (value >= 1024 && index < units.length - 1)
  const text = value < 10 ? value.toFixed(1) : String(Math.round(value))
  return { value: text, unit: units[index] }
}

function pad2(n: number): string {
  return String(n).padStart(2, '0')
}

/** `2026-09-26 19:54`。检视器的「最后更新」用它（要精确到分）。 */
export function formatFullDate(date: Date): string {
  return (
    `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())} ` +
    `${pad2(date.getHours())}:${pad2(date.getMinutes())}`
  )
}

function hhmm(date: Date): string {
  return `${pad2(date.getHours())}:${pad2(date.getMinutes())}`
}

function startOfDay(date: Date): number {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime()
}

/** 今天 HH:mm / 昨天 HH:mm / N 天前 / M月D日。 */
export function formatRelativeDate(date: Date, now: Date = new Date()): string {
  const todayStart = startOfDay(now)
  const dayStart = startOfDay(date)
  if (dayStart === todayStart) return `今天 ${hhmm(date)}`
  if (dayStart === todayStart - 86_400_000) return `昨天 ${hhmm(date)}`
  const days = Math.round((todayStart - dayStart) / 86_400_000)
  if (days > 0 && days < 7) return `${days} 天前`
  return `${date.getMonth() + 1}月${date.getDate()}日`
}

/**
 * 把 home 目录缩写成 `~`，供存储路径、关联文件这类长路径显示。
 *
 * `home` 必须由调用方传入：这个模块同时跑在渲染进程里，**不能** import `node:os`
 * （vite 会试图把 node 内建模块打进浏览器 bundle）。主进程传 `os.homedir()`，
 * 渲染进程从 `app:info` 拿 `AppInfo.home`。
 */
export function abbreviateHome(path: string, home: string): string {
  if (home && path.startsWith(home)) return `~${path.slice(home.length)}`
  return path
}

/**
 * 只保留路径末两级，前面加省略号。
 *
 *   `~/projects/conversation-clean` → `…/projects/conversation-clean`
 *   `~/Developer/atlas-api`          → `…/atlas-api`
 *
 * 列表行的项目路径用它，而不是整条路径 + CSS 截断 ——
 * 后者砍掉的恰恰是末段，而末段才是区分两个同名项目的东西。
 */
export function pathTail(path: string): string {
  const parts = path.split('/').filter(Boolean)
  if (parts.length <= 2) return path
  return `…/${parts.slice(-2).join('/')}`
}

/** 百分比，供分布条 / 体检卡用。分母为 0 时返回 0，不返回 NaN。 */
export function percentOf(part: number, total: number): number {
  if (total <= 0) return 0
  return Math.min(100, Math.max(0, (part / total) * 100))
}
