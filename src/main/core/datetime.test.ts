/**
 * `core/datetime.ts` 的测试。
 *
 * 这里钉的是**形状判断的边界**，不是“某个时间戳算对不对”（那由 `Date` 自己负责）。
 * `parseIsoDate` 先用两条正则（`FRACTIONAL` / `PLAIN`）判形状，判不过就一律 `null`，
 * 交由调用方改走 `fromEpoch` / 文件 mtime。所以本文件锁三件事：
 *
 * 1. **认得的形状全要吃**：带 / 不带小数秒、`T` / 空格分隔、`Z` / 无时区后缀（按本地时间）、
 *    `±HH:MM` / 紧凑 `±HHMM`、小数秒位数不限。
 * 2. **形状不认的一定返回 `null`**：epoch 毫秒、epoch 秒、它们的字符串形式、
 *    纯日期、缺秒、形状对但值非法（`2026-13-45T99:99:99Z`）、以及非字符串。
 *    这里的正则一旦放得太宽，任意脏数据就会被当成年份 1 / 1970 之类的假时间，
 *    侧栏的排序会整体错乱且很难排查。
 * 3. **`parseTimestamp` 的优先级**固定为 ISO → epoch → 文件 mtime → `null`，
 *    且 ISO 有效时**必须**忽略 mtime。
 *
 * 第 1 条里“带小数秒 + 数字时区偏移”那条是踩坑回归：形状正则原先只写了 `Z?`，
 * 把带 `±HH:MM` 的时间直接挡在外面，代价是整条会话的 `updatedAt` 丢失。
 * 放宽正则时必须同时盯紧第 2 条，否则就是把 bug 换了个方向。
 */

import { describe, expect, it } from 'vitest'
import { fromEpoch, parseIsoDate, parseTimestamp } from '@main/core/datetime'

describe('parseIsoDate —— 带小数秒', () => {
  it('2026-09-26T19:54:02.123Z', () => {
    const d = parseIsoDate('2026-09-26T19:54:02.123Z')
    expect(d).not.toBeNull()
    expect(d?.toISOString()).toBe('2026-09-26T19:54:02.123Z')
  })

  it('小数秒位数不限', () => {
    expect(parseIsoDate('2026-09-26T19:54:02.1Z')?.toISOString()).toBe('2026-09-26T19:54:02.100Z')
    expect(parseIsoDate('2026-09-26T19:54:02.123456Z')?.getTime()).toBe(
      Date.parse('2026-09-26T19:54:02.123Z')
    )
  })
})

describe('parseIsoDate —— 不带小数秒 / 空格分隔 / 时区偏移', () => {
  it('2026-09-26T19:54:02Z', () => {
    expect(parseIsoDate('2026-09-26T19:54:02Z')?.toISOString()).toBe('2026-09-26T19:54:02.000Z')
  })

  it('无时区后缀按本地时间解释', () => {
    const d = parseIsoDate('2026-09-26T19:54:02')
    expect(d).not.toBeNull()
    expect(d?.getFullYear()).toBe(2026)
    expect(d?.getHours()).toBe(19)
  })

  it('空格分隔（部分 Agent 写出的就是这种形状）', () => {
    expect(parseIsoDate('2026-09-26 19:54:02Z')?.toISOString()).toBe('2026-09-26T19:54:02.000Z')
  })

  it('+08:00 与 +0800 两种偏移写法', () => {
    expect(parseIsoDate('2026-09-26T19:54:02+08:00')?.toISOString()).toBe(
      '2026-09-26T11:54:02.000Z'
    )
    expect(parseIsoDate('2026-09-26T19:54:02+0800')?.toISOString()).toBe('2026-09-26T11:54:02.000Z')
  })

  it('-05:00 负偏移', () => {
    expect(parseIsoDate('2026-09-26T19:54:02-05:00')?.toISOString()).toBe('2026-09-27T00:54:02.000Z')
  })

  it('带小数秒 + 数字时区偏移：必须接受', () => {
    // 带小数秒的正则也得认 `±HH:MM` / 紧凑 `±HHMM`。
    // 第一版 TS 的 `FRACTIONAL` 正则只写了 `Z?`，会把这类直接挡掉，
    // 代价是整个会话的 updatedAt 丢失 —— 已修（见 `datetime.ts` 的正则注释）。
    const parsed = parseIsoDate('2026-09-26T19:54:02.500+08:00')
    expect(parsed).toBeInstanceOf(Date)
    // +08:00 的 19:54 换算成 UTC 是 11:54。
    expect(parsed?.toISOString()).toBe('2026-09-26T11:54:02.500Z')
    // 空格隔写法同理
    expect(parseIsoDate('2026-09-26 19:54:02.500+08:00')?.toISOString()).toBe(
      '2026-09-26T11:54:02.500Z'
    )
    // 紧凑偏移 `+0800` 也要认（Date 能解析，但不能被形状判断挡掉）
    expect(parseIsoDate('2026-09-26T19:54:02.500+0800')).toBeInstanceOf(Date)
  })

  it('仍然是 ISO 形状：非时间戳字符串一律返回 null（不能被放宽的正则放进来）', () => {
    expect(parseIsoDate('2026-09-26T19:54:02.500')).toBeInstanceOf(Date)
    expect(parseIsoDate('not a date')).toBeNull()
    expect(parseIsoDate('1769398442123')).toBeNull()
  })
})

describe('parseIsoDate —— 非法值返回 null', () => {
  const illegal: unknown[] = [
    '',
    'not a date',
    '2026-09-26', // 只有日期，没有时间
    '2026/09/26 19:54:02',
    '1769398442123', // epoch 毫秒（字符串）—— 形状不认识
    '1769398442', // epoch 秒（字符串）
    '2026-09-26T19:54', // 缺秒
    '2026-13-45T99:99:99Z', // 形状对但值非法
    1769398442123,
    null,
    undefined,
    {},
    []
  ]

  for (const value of illegal) {
    it(`返回 null：${JSON.stringify(value) ?? String(value)}`, () => {
      expect(parseIsoDate(value)).toBeNull()
    })
  }
})

describe('fromEpoch —— epoch 秒 / 毫秒', () => {
  it('10 位当秒', () => {
    expect(fromEpoch(1769398442)?.toISOString()).toBe('2026-01-26T03:34:02.000Z')
  })

  it('13 位当毫秒', () => {
    expect(fromEpoch(1769398442123)?.toISOString()).toBe('2026-01-26T03:34:02.123Z')
  })

  it('同一时刻两种写法解析结果一致', () => {
    expect(fromEpoch(1769398442)?.getTime()).toBe(fromEpoch(1769398442000)?.getTime())
  })

  it('分界：1e11 判为毫秒（10 位及以下判为秒）', () => {
    expect(fromEpoch(99_999_999_999)?.toISOString()).toBe('5138-11-16T09:46:39.000Z')
    expect(fromEpoch(100_000_000_000)?.toISOString()).toBe('1973-03-03T09:46:40.000Z')
  })

  it('非法值返回 null', () => {
    for (const value of [0, -1, -1769398442, Number.NaN, Infinity, -Infinity, '1769398442', null, undefined, {}]) {
      expect(fromEpoch(value), String(value)).toBeNull()
    }
  })
})

describe('parseTimestamp —— 统一入口', () => {
  it('ISO 字符串优先', () => {
    expect(parseTimestamp('2026-09-26T19:54:02Z')?.toISOString()).toBe('2026-09-26T19:54:02.000Z')
  })

  it('epoch 秒', () => {
    expect(parseTimestamp(1769398442)?.toISOString()).toBe('2026-01-26T03:34:02.000Z')
  })

  it('epoch 毫秒', () => {
    expect(parseTimestamp(1769398442123)?.getTime()).toBe(1769398442123)
  })

  it('都解析不出来时回落到文件 mtime', () => {
    const mtime = 1_700_000_000_000
    expect(parseTimestamp('garbage', mtime)?.getTime()).toBe(mtime)
    expect(parseTimestamp(undefined, mtime)?.getTime()).toBe(mtime)
  })

  it('ISO 有效时忽略 mtime', () => {
    expect(parseTimestamp('2026-09-26T19:54:02Z', 1)?.toISOString()).toBe('2026-09-26T19:54:02.000Z')
  })

  it('mtime 缺失且三者都非法 → null', () => {
    expect(parseTimestamp('garbage')).toBeNull()
    expect(parseTimestamp(null)).toBeNull()
  })
})
