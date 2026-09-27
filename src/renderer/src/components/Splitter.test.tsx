// @vitest-environment jsdom
import type { ComponentProps } from 'react'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import { SPLITTER_HIT_WIDTH, Splitter, clampWidth } from './Splitter'

/**
 * 分隔条的拖拽与钳制。
 *
 * jsdom 没有 `PointerEvent`（只有 `MouseEvent`），而 `@testing-library` 的
 * `fireEvent.pointerXxx` 在构造器缺失时会退化成 `window.Event`，
 * 那样 `clientX` 根本传不进去。这里把 `window.PointerEvent` 指向 `MouseEvent`，
 * 于是事件类型名对、坐标也带得上。
 */
beforeAll(() => {
  ;(window as unknown as { PointerEvent: unknown }).PointerEvent = MouseEvent
})

afterEach(cleanup)

function drag(
  onChange: (next: number) => void,
  props: Partial<ComponentProps<typeof Splitter>> = {}
) {
  render(
    <Splitter
      width={300}
      min={200}
      max={400}
      growsWithRightwardDrag
      onChange={onChange}
      {...props}
    />
  )
  const el = screen.getByRole('separator')
  return el
}

describe('clampWidth', () => {
  it('夹到区间内；min > max 时也不会反转', () => {
    expect(clampWidth(150, 200, 400)).toBe(200)
    expect(clampWidth(500, 200, 400)).toBe(400)
    expect(clampWidth(320, 200, 400)).toBe(320)
    expect(clampWidth(320, 400, 200)).toBe(320)
  })
})

describe('Splitter', () => {
  it('命中区 11px、视觉线 1px、方向语义写进 aria', () => {
    const el = drag(() => {})
    expect(el.style.width).toBe(`${SPLITTER_HIT_WIDTH}px`)
    expect(el.getAttribute('aria-orientation')).toBe('vertical')
    expect(el.getAttribute('aria-valuenow')).toBe('300')
    expect(el.getAttribute('aria-valuemin')).toBe('200')
    expect(el.getAttribute('aria-valuemax')).toBe('400')
  })

  it('往右拖：侧栏变宽；拖动量从按下那一刻起算', () => {
    const onChange = vi.fn()
    const el = drag(onChange)

    fireEvent.pointerDown(el, { clientX: 100, button: 0 })
    fireEvent.pointerMove(document, { clientX: 150 })
    expect(onChange).toHaveBeenLastCalledWith(350)

    fireEvent.pointerMove(document, { clientX: 130 })
    // 锚点 300 + (130 - 100) = 330，不是 350 - 20 的逐帧累加（数值相同但语义不同，
    // 一旦中间被钳过就会分叉）
    expect(onChange).toHaveBeenLastCalledWith(330)
  })

  it('中间列表方向取反：往右拖变窄', () => {
    const onChange = vi.fn()
    const el = drag(onChange, { growsWithRightwardDrag: false })
    fireEvent.pointerDown(el, { clientX: 100, button: 0 })
    fireEvent.pointerMove(document, { clientX: 160 })
    expect(onChange).toHaveBeenLastCalledWith(240)
  })

  it('钳制到 max：中途超界后再往回拖，仍以按下时的锚点算', () => {
    const onChange = vi.fn()
    const el = drag(onChange)

    fireEvent.pointerDown(el, { clientX: 100, button: 0 })
    fireEvent.pointerMove(document, { clientX: 250 }) // 300 + 150 → 钳到 400
    expect(onChange).toHaveBeenLastCalledWith(400)

    // 逐帧累加会给出 390（400 - 10），锚点算给出 300 + 140 → 440 → 仍钳到 400
    fireEvent.pointerMove(document, { clientX: 240 })
    expect(onChange).toHaveBeenLastCalledWith(400)
  })

  it('钳制到 min', () => {
    const onChange = vi.fn()
    const el = drag(onChange)
    fireEvent.pointerDown(el, { clientX: 300, button: 0 })
    fireEvent.pointerMove(document, { clientX: 40 })
    expect(onChange).toHaveBeenLastCalledWith(200)
  })

  it('松手后停止跟踪；非主键不启动拖拽', () => {
    const onChange = vi.fn()
    const el = drag(onChange)

    fireEvent.pointerDown(el, { clientX: 100, button: 0 })
    fireEvent.pointerUp(document)
    fireEvent.pointerMove(document, { clientX: 180 })
    expect(onChange).not.toHaveBeenCalled()

    fireEvent.pointerDown(el, { clientX: 100, button: 2 })
    expect(el.getAttribute('data-dragging')).toBe('false')
    fireEvent.pointerMove(document, { clientX: 180 })
    expect(onChange).not.toHaveBeenCalled()
  })

  it('hover 加上高亮类', () => {
    const el = drag(() => {})
    expect(el.getAttribute('data-dragging')).toBe('false')
    fireEvent.pointerEnter(el)
    expect(el.className).toContain('splitterActive')
    fireEvent.pointerLeave(el)
    expect(el.className).not.toContain('splitterActive')
  })
})
