import { useEffect, useRef, useState } from 'react'
import styles from './Splitter.module.css'

/**
 * 栏间分隔条。
 *
 * 两处细节决定它好不好用：
 *   ① 命中区 11px，视觉线只有 1px。线画多宽就只能拖多宽的话，那条线根本点不中。
 *   ② 拖动量从**按下那一刻**的宽度起算（anchor），不是逐帧累加 delta。
 *      累加的话掉一帧就把误差一并放大，鼠标一松手列宽会跳一下。
 *
 * `min` / `max` 由 App 按窗口宽度现算传进来 —— 固定 max 会拼出破图：
 * 窗口只有 1000px 时把列表拖到 760、侧栏又停在 420，剩下的不够详情栏的
 * minWidth，三栏互相挤到变形。
 */

/** 命中区宽度。视觉线仍是 1px，差出来的 10px 是给鼠标准备的。 */
export const SPLITTER_HIT_WIDTH = 11

export function clampWidth(value: number, min: number, max: number): number {
  const lo = Math.min(min, max)
  const hi = Math.max(min, max)
  return Math.min(hi, Math.max(lo, value))
}

export interface SplitterProps {
  width: number
  min: number
  max: number
  onChange: (next: number) => void
  /**
   * true = 往右拖变宽（左侧栏）；false = 往左拖变宽（中间列表）。
   * 两条分隔条方向相反，所以这个开关不是冗余参数，是它们唯一的区别。
   */
  growsWithRightwardDrag: boolean
  help?: string
  className?: string
}

export function Splitter({
  width,
  min,
  max,
  onChange,
  growsWithRightwardDrag,
  help = '拖动调整列宽',
  className
}: SplitterProps) {
  const [dragging, setDragging] = useState(false)
  const [hovering, setHovering] = useState(false)
  // 拖动期间不再回读 props 宽度，全用按下那一刻的锚点算。
  const anchor = useRef<{ x: number; width: number } | null>(null)
  const active = dragging || hovering

  useEffect(() => {
    if (!dragging) return

    const move = (event: PointerEvent) => {
      const start = anchor.current
      if (!start) return
      const delta = event.clientX - start.x
      const next = start.width + (growsWithRightwardDrag ? delta : -delta)
      onChange(clampWidth(next, min, max))
    }
    const stop = () => {
      anchor.current = null
      setDragging(false)
    }

    document.addEventListener('pointermove', move)
    document.addEventListener('pointerup', stop)
    document.addEventListener('pointercancel', stop)
    return () => {
      document.removeEventListener('pointermove', move)
      document.removeEventListener('pointerup', stop)
      document.removeEventListener('pointercancel', stop)
    }
  }, [dragging, growsWithRightwardDrag, min, max, onChange])

  return (
    <div
      className={[styles['splitter'], active && styles['splitterActive'], className]
        .filter(Boolean)
        .join(' ')}
      style={{ width: SPLITTER_HIT_WIDTH }}
      role="separator"
      aria-orientation="vertical"
      aria-label={help}
      aria-valuenow={Math.round(width)}
      aria-valuemin={Math.round(min)}
      aria-valuemax={Math.round(max)}
      title={help}
      data-dragging={dragging ? 'true' : 'false'}
      onPointerEnter={() => setHovering(true)}
      onPointerLeave={() => setHovering(false)}
      onPointerDown={(event) => {
        // 只响应主键；右键/中键拖拽不该改列宽。
        if (event.button !== 0) return
        event.preventDefault()
        anchor.current = { x: event.clientX, width }
        setDragging(true)
      }}
    >
      <span className={styles['splitterLine']} />
    </div>
  )
}
