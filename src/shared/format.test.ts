/**
 * `format.ts` 的特征测试。
 *
 * 逐条移植自 Swift 版 `scripts/tests/FormattingTests.swift`（`testFormatting`）。
 * Swift 侧那一整段 `t.assert(...)` 在这里一一对应到 `it(...)`，
 * 断言文案也尽量保留原文，方便两版对照。
 *
 * 锁的是行为而不是实现，尤其锁 1024 进制：同一条 2,411,724 字节的会话，
 * 1000 进制会打成 2.4 MB（`ByteCountFormatter` 的口径），
 * 1024 进制打成 2.3 MB，后者才与 `du` / `df` / `ls -h` 一致。
 */

import { describe, expect, it } from 'vitest'
import { homedir } from 'node:os'
import {
  abbreviateHome,
  formatBytes,
  formatFullDate,
  formatRelativeDate,
  pathTail,
  percentOf,
  splitBytes
} from '@shared/format'

/**
 * 相对时间的特征测试锚点。
 *
 * 锚在 2100 年不是随手取的（**照抄 Swift 版 `FormattingTests.swift` 的处理**）：
 * Swift 的 `isDateInToday` / `isDateInYesterday` 读的是**真实**系统时钟，
 * 早先把「30 天前」锚在 2027-01-15 时，它落在 2026-12-16 ——
 * 到了那一天真实时钟会把它判成「今天」，断言当天变红。
 * 「今天」「昨天」两个分支同理，分支条件只认真实时钟，无法用注入的 now 驱动。
 *
 * 这里的 TS 实现**已经**吃注入的 `now`（`formatRelativeDate(date, now)`），
 * 所以「今天 / 昨天」可以钉住。但仍统一用 2100 锚点：万一哪天实现退回读真实时钟，
 * 只有「N 天前 / M月D日」这两条会红，而不是全部。
 * 月日用本地时间现算，不写死时区。
 */
const ANCHOR = new Date(2100, 0, 2, 12, 0, 0, 0)
const DAY_MS = 86_400_000
const daysBefore = (n: number): Date => new Date(ANCHOR.getTime() - n * DAY_MS)

describe('formatBytes —— 1024 进制', () => {
  it('0 → 0 KB', () => {
    expect(formatBytes(0)).toBe('0 KB')
  })

  it('1023 → 1.0 KB（<10 保留 1 位小数）', () => {
    expect(formatBytes(1023)).toBe('1.0 KB')
  })

  it('1024 → 1.0 KB', () => {
    expect(formatBytes(1024)).toBe('1.0 KB')
  })

  it('34816 → 34 KB（≥10 四舍五入为整数）', () => {
    expect(formatBytes(34 * 1024)).toBe('34 KB')
  })

  it('2411724 → 2.3 MB（1024 而非 1000 进制）', () => {
    expect(formatBytes(2_411_724)).toBe('2.3 MB')
  })

  it('1 GiB → 1.0 GB', () => {
    expect(formatBytes(1024 * 1024 * 1024)).toBe('1.0 GB')
  })

  it('负数夹到 0：-1 → 0.0 KB（与 Swift 的 max(n, 0) 同口径）', () => {
    expect(formatBytes(-1)).toBe('0.0 KB')
  })

  it('超出 TB 仍在 TB 收口，不越界（1 PiB → 1.0 TB）', () => {
    expect(formatBytes(1024 ** 4)).toBe('1.0 TB')
    expect(formatBytes(1024 ** 4 * 5)).toBe('5.0 TB')
  })
})

describe('splitBytes —— 与 formatBytes 同口径', () => {
  it('0 → { 0, KB }', () => {
    expect(splitBytes(0)).toEqual({ value: '0', unit: 'KB' })
  })

  it('逐条与 formatBytes 对齐（拼起来必须完全相等）', () => {
    for (const n of [1, 1023, 1024, 34 * 1024, 2_411_724, 1024 ** 3]) {
      const { value, unit } = splitBytes(n)
      expect(`${value} ${unit}`).toBe(formatBytes(n))
    }
  })

  it('2411724 → 2.3 / MB', () => {
    expect(splitBytes(2_411_724)).toEqual({ value: '2.3', unit: 'MB' })
  })
})

describe('pathTail —— 只保留末两级', () => {
  it('长路径保留末两级', () => {
    expect(pathTail('/Users/tester/projects/conversation-clean')).toBe('…/projects/conversation-clean')
  })

  it('3 段路径保留末两级', () => {
    expect(pathTail('/a/b/c')).toBe('…/b/c')
  })

  it('≤2 段原样返回', () => {
    expect(pathTail('/foo')).toBe('/foo')
    expect(pathTail('/a/b')).toBe('/a/b')
  })
})

describe('abbreviateHome', () => {
  it('非 home 前缀原样返回', () => {
    expect(abbreviateHome('/opt/x', '/Users/tester')).toBe('/opt/x')
  })

  it('home 前缀缩写成 ~', () => {
    // home 由调用方传入（shared/format 不能 import node:os），
    // 测试用真实 homedir() 现场构造输入，不把用户名写死在期望值里。
    const home = homedir()
    expect(abbreviateHome(`${home}/Library/Caches/app`, home)).toBe('~/Library/Caches/app')
  })

  it('恰好等于 home 时 → "~"', () => {
    expect(abbreviateHome('/Users/tester', '/Users/tester')).toBe('~')
  })

  it('home 传空串时不做任何替换', () => {
    expect(abbreviateHome('/Users/tester/x', '')).toBe('/Users/tester/x')
  })
})

describe('formatRelativeDate —— 显式传 now，保证确定性', () => {
  it('3 天前 → 「3 天前」', () => {
    expect(formatRelativeDate(daysBefore(3), ANCHOR)).toBe('3 天前')
  })

  it('30 天前越过 7 天窗口 → 「M月D日」', () => {
    // 月日用本地时间现算，不写死时区；2100-01-02 减 30 天 = 2099-12-03。
    const target = daysBefore(30)
    const expected = `${target.getMonth() + 1}月${target.getDate()}日`
    expect(formatRelativeDate(target, ANCHOR)).toBe(expected)
    expect(expected).toBe('12月3日')
  })

  it('6 天前仍落在 N 天前窗口', () => {
    expect(formatRelativeDate(daysBefore(6), ANCHOR)).toBe('6 天前')
  })

  it('7 天前掉出窗口（边界：days < 7）', () => {
    const target = daysBefore(7)
    expect(formatRelativeDate(target, ANCHOR)).toBe(`${target.getMonth() + 1}月${target.getDate()}日`)
  })

  it('今天 → 「今天 HH:mm」', () => {
    // Swift 版这个分支读真实时钟、无法注入，钉不住；
    // TS 实现吃注入的 now（`startOfDay(now)`），所以这里能钉。
    expect(formatRelativeDate(new Date(2100, 0, 2, 9, 5, 0, 0), ANCHOR)).toBe('今天 09:05')
  })

  it('昨天 → 「昨天 HH:mm」', () => {
    expect(formatRelativeDate(new Date(2100, 0, 1, 23, 7, 0, 0), ANCHOR)).toBe('昨天 23:07')
  })
})

describe('formatFullDate —— 检视器「最后更新」用，精确到分', () => {
  it('形如 yyyy-MM-dd HH:mm（与时区无关，只钉形状）', () => {
    const stamp = formatFullDate(new Date(0))
    const [ymd, hm] = stamp.split(' ')
    const dateParts = (ymd ?? '').split('-')
    const timeParts = (hm ?? '').split(':')
    const allDigits = (parts: string[]): boolean => parts.every((s) => /^\d+$/.test(s))
    expect(dateParts).toHaveLength(3)
    expect(dateParts[0]).toHaveLength(4)
    expect(dateParts[1]).toHaveLength(2)
    expect(dateParts[2]).toHaveLength(2)
    expect(timeParts).toHaveLength(2)
    expect(timeParts[0]).toHaveLength(2)
    expect(timeParts[1]).toHaveLength(2)
    expect(allDigits([...(dateParts ?? []), ...(timeParts ?? [])])).toBe(true)
  })

  it('月/日/时/分都补零', () => {
    // 2026-01-02 03:04 本地时间
    expect(formatFullDate(new Date(2026, 0, 2, 3, 4, 0, 0))).toBe('2026-01-02 03:04')
  })

  it('分钟截断，秒不进串', () => {
    expect(formatFullDate(new Date(2026, 11, 31, 23, 59, 59, 999))).toBe('2026-12-31 23:59')
  })
})

describe('percentOf', () => {
  it('分母为 0 返回 0，不返回 NaN', () => {
    expect(percentOf(10, 0)).toBe(0)
    expect(percentOf(0, 0)).toBe(0)
    expect(percentOf(10, -5)).toBe(0)
  })

  it('常规百分比', () => {
    expect(percentOf(1, 4)).toBe(25)
    expect(percentOf(3, 4)).toBe(75)
  })

  it('夹到 [0, 100]', () => {
    expect(percentOf(9, 4)).toBe(100)
    expect(percentOf(-3, 4)).toBe(0)
  })
})
