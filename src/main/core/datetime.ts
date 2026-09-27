/**
 * 进程级共享的 ISO 8601 时间解析。
 *
 * 移植自 Swift 版 `Core/DateParsing.swift`。
 *
 * 背景：Swift 里 `ISO8601DateFormatter` 的构造成本远高于单次解析本身，
 * 而 `scanAll()` 会并发调用全部 scanner；此前 6 个 scanner 各自持有配置完全相同的
 * formatter 副本。这里同理：统一一个 `parse()`，消除重复实例，也消除并发共享可变对象。
 *
 * 覆盖两组配置：带小数秒、不带小数秒。
 */

/**
 * 带小数秒：`2026-09-26T19:54:02.123Z` / `2026-09-26T19:54:02.123+08:00`
 *
 * 时区偏移必须在这里接受：Swift 侧用的是
 * `ISO8601DateFormatter([.withInternetDateTime, .withFractionalSeconds])`，
 * 它接受带偏移的时间戳。第一版只写了 `Z?`，遇到 `+08:00` 的 Agent 会整条会话时间丢失。
 */
const FRACTIONAL = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}\.\d+(Z|[+-]\d{2}:?\d{2})?$/
/** 不带小数秒：`2026-09-26T19:54:02Z` / `2026-09-26T19:54:02+08:00` */
const PLAIN = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:?\d{2})?$/

/**
 * 依次尝试「带小数秒」与「不带小数秒」解析，空串 / 无法识别返回 `null`。
 *
 * 先做形状判断再交给 `Date`：很多 Agent 的时间戳是**毫秒**或**秒**级 epoch
 * （例如 `1769398442123`、`1769398442`），正则不会命中，扫描器需要走 `fromEpoch()`。
 */
export function parseIsoDate(value: unknown): Date | null {
  if (typeof value !== 'string' || value.length === 0) return null
  if (!FRACTIONAL.test(value) && !PLAIN.test(value)) return null
  const parsed = new Date(value.replace(' ', 'T'))
  return Number.isNaN(parsed.getTime()) ? null : parsed
}

/** epoch 毫秒 → `Date`；非法值返回 `null`。 */
export function fromEpoch(value: unknown): Date | null {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return null
  // 10 位是秒，13 位是毫秒；混在一起的 Agent 见过不少。
  const ms = value < 1e11 ? value * 1000 : value
  const date = new Date(ms)
  return Number.isNaN(date.getTime()) ? null : date
}

/**
 * 各 scanner 的统一时间入口：ISO 字符串、epoch 秒、epoch 毫秒都吃，
 * 解析不出来回落到文件 mtime，再不济回落到 `epoch`（1970）—— 调用方据此判断时间是否可信。
 */
export function parseTimestamp(value: unknown, fallbackMtime?: number): Date | null {
  return parseIsoDate(value) ?? fromEpoch(value) ?? (fallbackMtime ? fromEpoch(fallbackMtime) : null)
}
