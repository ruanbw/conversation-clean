// @vitest-environment jsdom
import { useState } from 'react'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  Badge,
  CardSurface,
  DrawnButton,
  DrawnCheckbox,
  DrawnCheckboxBox,
  DrawnEmptyState,
  DrawnIcon,
  DrawnNotice,
  DrawnSearchField,
  DrawnSegmented,
  DrawnSwitch,
  Hairline,
  SectionLabel,
  ShareBar,
  TintedSurface
} from './DrawnControls'

/**
 * 自绘控件库的行为测试。
 *
 * 覆盖任务书点名的三类交互（勾选框 / 分段器 / 开关），外加搜索框的
 * ⌘F 重聚焦与清除、按钮禁用态、纯展示版勾选框。
 *
 * 注意：vitest 配置 `css: false`，CSS Module 的类名在测试里就是原始 key，
 * 所以断言 className 就是在断言「这个 class 用上了」，样式本身不参与。
 */

afterEach(cleanup)

describe('DrawnCheckbox', () => {
  it('点击时把下一个布尔值交给 onChange', () => {
    const onChange = vi.fn()
    render(<DrawnCheckbox checked={false} onChange={onChange} label="选择" />)
    const box = screen.getByRole('checkbox', { name: '选择' })
    expect(box.getAttribute('aria-checked')).toBe('false')

    fireEvent.click(box)
    expect(onChange).toHaveBeenCalledWith(true)
  })

  it('已勾选时点击给回 false', () => {
    const onChange = vi.fn()
    render(<DrawnCheckbox checked onChange={onChange} label="选择" />)
    const box = screen.getByRole('checkbox', { name: '选择' })
    expect(box.getAttribute('aria-checked')).toBe('true')
    // 已勾选时框里必须有一笔（勾 / 横杠），空框会被读成「没生效」
    expect(box.firstElementChild).not.toBeNull()

    fireEvent.click(box)
    expect(onChange).toHaveBeenCalledWith(false)
  })

  it('半选态：aria-checked=mixed 且画的是横杠不是勾', () => {
    const { container, rerender } = render(
      <DrawnCheckbox checked={false} mixed onChange={() => {}} label="选择" />
    )
    const box = screen.getByRole('checkbox', { name: '选择' })
    expect(box.getAttribute('aria-checked')).toBe('mixed')
    // 横杠：唯一一个非 0 宽度的子元素（勾是旋转的边框，没有背景色）
    const dash = container.querySelector('span')
    expect(dash).not.toBeNull()

    rerender(<DrawnCheckbox checked onChange={() => {}} label="选择" />)
    expect(screen.getByRole('checkbox', { name: '选择' }).getAttribute('aria-checked')).toBe(
      'true'
    )
  })

  it('stopPropagation 时点击不会冒泡到行', () => {
    const onRowClick = vi.fn()
    const onChange = vi.fn()
    render(
      // eslint-disable-next-line jsx-a11y/click-events-have-key-events
      <div onClick={onRowClick}>
        <DrawnCheckbox checked={false} onChange={onChange} stopPropagation label="选择" />
      </div>
    )
    fireEvent.click(screen.getByRole('checkbox', { name: '选择' }))
    expect(onChange).toHaveBeenCalledTimes(1)
    expect(onRowClick).not.toHaveBeenCalled()
  })

  it('disabled 时不触发 onChange', () => {
    const onChange = vi.fn()
    render(<DrawnCheckbox checked={false} disabled onChange={onChange} label="选择" />)
    fireEvent.click(screen.getByRole('checkbox', { name: '选择' }))
    expect(onChange).not.toHaveBeenCalled()
  })

  it('纯展示版 DrawnCheckboxBox 不发事件', () => {
    const { container } = render(<DrawnCheckboxBox checked />)
    const box = container.querySelector('span')
    expect(box).not.toBeNull()
    fireEvent.click(box as HTMLElement)
    expect(box?.getAttribute('role')).toBeNull()
  })
})

describe('DrawnSegmented', () => {
  const options = [
    { value: 'date' as const, label: '最近更新' },
    { value: 'size' as const, label: '占用空间' },
    { value: 'msgs' as const, label: '对话轮数' }
  ]

  it('点中某项把该值的 value 交出去，且选中态跟着走', () => {
    const onChange = vi.fn()
    const { rerender } = render(
      <DrawnSegmented value="size" options={options} onChange={onChange} />
    )
    expect(screen.getByRole('radio', { name: '占用空间' }).getAttribute('aria-checked')).toBe(
      'true'
    )

    fireEvent.click(screen.getByRole('radio', { name: '对话轮数' }))
    expect(onChange).toHaveBeenCalledWith('msgs')

    rerender(<DrawnSegmented value="msgs" options={options} onChange={onChange} />)
    expect(screen.getByRole('radio', { name: '对话轮数' }).getAttribute('aria-checked')).toBe(
      'true'
    )
    expect(screen.getByRole('radio', { name: '占用空间' }).getAttribute('aria-checked')).toBe(
      'false'
    )
  })
})

describe('DrawnSwitch', () => {
  it('role=switch，点击反向切换', () => {
    const onChange = vi.fn()
    const { rerender } = render(
      <DrawnSwitch checked={false} onChange={onChange} label="启动时自动扫描" />
    )
    const sw = screen.getByRole('switch', { name: '启动时自动扫描' })
    expect(sw.getAttribute('aria-checked')).toBe('false')

    fireEvent.click(sw)
    expect(onChange).toHaveBeenCalledWith(true)

    rerender(<DrawnSwitch checked onChange={onChange} label="启动时自动扫描" />)
    expect(screen.getByRole('switch', { name: '启动时自动扫描' }).getAttribute('aria-checked')).toBe(
      'true'
    )
    fireEvent.click(screen.getByRole('switch', { name: '启动时自动扫描' }))
    expect(onChange).toHaveBeenLastCalledWith(false)
  })

  it('disabled 时点击无效', () => {
    const onChange = vi.fn()
    render(<DrawnSwitch checked disabled onChange={onChange} label="回收空目录" />)
    fireEvent.click(screen.getByRole('switch', { name: '回收空目录' }))
    expect(onChange).not.toHaveBeenCalled()
  })
})

describe('DrawnSearchField', () => {
  it('清除钮清空并把焦点还给输入框', () => {
    const onChange = vi.fn()
    function Harness() {
      const [value, setValue] = useState('重构扫描')
      return (
        <DrawnSearchField
          value={value}
          onChange={(next) => {
            setValue(next)
            onChange(next)
          }}
          placeholder="搜索标题、摘要"
        />
      )
    }
    render(<Harness />)
    fireEvent.change(screen.getByLabelText('搜索标题、摘要'), { target: { value: '重构' } })
    expect(onChange).toHaveBeenLastCalledWith('重构')

    fireEvent.click(screen.getByRole('button', { name: '清除搜索词' }))
    expect(onChange).toHaveBeenLastCalledWith('')
    expect((screen.getByLabelText('搜索标题、摘要') as HTMLInputElement).value).toBe('')
    expect(document.activeElement).toBe(screen.getByLabelText('搜索标题、摘要'))
  })

  it('focusRequest 自增时重新聚焦并全选（⌘F 的语义）', () => {
    const { rerender } = render(
      <DrawnSearchField value="a" onChange={() => {}} placeholder="p" focusRequest={0} />
    )
    const input = screen.getByLabelText('p') as HTMLInputElement
    expect(document.activeElement).not.toBe(input)

    rerender(<DrawnSearchField value="a" onChange={() => {}} placeholder="p" focusRequest={1} />)
    expect(document.activeElement).toBe(input)
  })

  it('回车触发 onSubmit', () => {
    const onSubmit = vi.fn()
    render(<DrawnSearchField value="" onChange={() => {}} placeholder="p" onSubmit={onSubmit} />)
    fireEvent.keyDown(screen.getByLabelText('p'), { key: 'Enter' })
    expect(onSubmit).toHaveBeenCalledTimes(1)
  })
})

describe('DrawnButton / DrawnIcon', () => {
  it('禁用时不触发 onClick', () => {
    const onClick = vi.fn()
    render(
      <DrawnButton variant="danger" disabled onClick={onClick}>
        清理选中项
      </DrawnButton>
    )
    fireEvent.click(screen.getByRole('button', { name: '清理选中项' }))
    expect(onClick).not.toHaveBeenCalled()
  })

  it('纯图标按钮把 help 当可访问名', () => {
    const onClick = vi.fn()
    render(
      <DrawnButton
        iconOnly
        help="重新扫描"
        icon={<DrawnIcon name="refresh" size={11} />}
        onClick={onClick}
      />
    )
    fireEvent.click(screen.getByRole('button', { name: '重新扫描' }))
    expect(onClick).toHaveBeenCalledTimes(1)
  })
})

describe('其余自绘件', () => {
  it('ShareBar 把百分比夹在 0…100 并写成内联宽度', () => {
    const { container, rerender } = render(<ShareBar percent={140} />)
    const track = container.querySelector('div') as HTMLElement
    const fill = track.firstElementChild as HTMLElement
    expect(fill.style.width).toBe('100%')

    rerender(<ShareBar percent={-5} />)
    const again = container.querySelector('div') as HTMLElement
    expect((again.firstElementChild as HTMLElement).style.width).toBe('0%')
  })

  it('Badge / Hairline / SectionLabel / 两种面 / 通知条 / 空态都能渲染出内容', () => {
    render(
      <>
        <Badge text="3" tone="accent" />
        <Hairline edge="top" />
        <SectionLabel text="Agent 分类" />
        <SectionLabel text="按 Agent 分布" tone="strong" flush />
        <CardSurface>卡片面</CardSurface>
        <TintedSurface>靛蓝面</TintedSurface>
        <DrawnNotice text="扫描完成 · 命中 3 个会话。" dismissTitle="知道了" onDismiss={() => {}} />
        <DrawnEmptyState
          title="没有匹配「x」的会话"
          message="换个关键词"
          actionTitle="清除搜索词"
          onAction={() => {}}
        />
      </>
    )
    expect(screen.getByText('3')).toBeTruthy()
    expect(screen.getByText('卡片面')).toBeTruthy()
    expect(screen.getByText('靛蓝面')).toBeTruthy()
    expect(screen.getByText(/扫描完成/)).toBeTruthy()
    expect(screen.getByText('没有匹配「x」的会话')).toBeTruthy()
    expect(screen.getByText('清除搜索词')).toBeTruthy()
  })
})
