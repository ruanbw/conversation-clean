// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import type { ReactNode } from 'react'
import { formatBytes } from '@shared/format'
import type { AgentCategory, CleanResult, ConversationItem, Prefs } from '@shared/types'
import { DEFAULT_PREFS } from '@shared/types'
import styles from './CleanConfirmSheet.module.css'

/**
 * 清理前的二次确认弹层（对应 Swift `Views/CleanConfirmSheet.swift`）。
 *
 * store 是模块级单例，所以每个用例都 `vi.resetModules()` 后**动态**重新 import
 * 组件与 store —— 拿到一对全新的、配对的实例，测试之间不会串状态。
 * （静态 import 组件 + 动态 import store 会拿到两个不同的 store。）
 */

type PreloadApi = NonNullable<typeof window.api>

const MB = 1024 * 1024

let prefs: Prefs
let items: ConversationItem[]
let cleanDeleteImpl: () => Promise<CleanResult>
let volumeInfo: { name: string; mountPath: string | null; capacity: number; used: number } | null

function makeItem(
  id: string,
  category: AgentCategory,
  sizeInBytes: number,
  isSelected = false
): ConversationItem {
  return {
    id,
    sessionId: `sess-${id}`,
    title: `会话 ${id}`,
    category,
    projectPath: `/tmp/${id}`,
    gitBranch: 'main',
    messageCount: 12,
    sizeInBytes,
    updatedAt: '2026-09-27T10:00:00.000Z',
    isSelected,
    snippet: `摘要 ${id}`,
    associatedPaths: [`/tmp/${id}.jsonl`]
  }
}

function installApi(): void {
  const api = {
    scanAll: async () => ({ items: [...items], agents: [], issues: [], durationMs: 1 }),
    cleanDelete: async () => cleanDeleteImpl(),
    cleanAll: async () => ({ freedBytes: 0, deletedCount: 0 }),
    getPrefs: async () => ({ ...prefs }),
    setPrefs: async (patch: Partial<Prefs>) => {
      prefs = { ...prefs, ...patch }
      return { ...prefs }
    },
    getAppInfo: async () => ({
      version: '2.0.0',
      platform: 'darwin',
      home: '/Users/test',
      electron: '44',
      node: '22'
    }),
    getAgentIcons: async () => ({}),
    revealInFinder: async () => true,
    openPath: async () => true,
    copyText: async () => true,
    getVolumeInfo: async () => volumeInfo
  }
  window.api = api as unknown as PreloadApi
}

/** 拿到一对全新的 store / 组件实例。 */
async function loadSheet(): Promise<{
  cleanStore: typeof import('../state/cleanStore').cleanStore
  CleanConfirmSheet: () => ReactNode
}> {
  vi.resetModules()
  const store = await import('../state/cleanStore')
  const view = await import('./CleanConfirmSheet')
  return { cleanStore: store.cleanStore, CleanConfirmSheet: view.default }
}

function panelText(): string {
  return (screen.getByRole('dialog') as HTMLElement).textContent ?? ''
}

function confirmButton(): HTMLButtonElement {
  return screen.getByRole('button', { name: /确认清除|正在清除/ }) as HTMLButtonElement
}

beforeEach(() => {
  localStorage.clear()
  prefs = { ...DEFAULT_PREFS }
  items = [
    makeItem('c1', 'cursor', 10 * MB),
    makeItem('c2', 'cursor', 20 * MB),
    makeItem('c3', 'cursor', 30 * MB),
    makeItem('p1', 'piAgent', 5 * MB),
    makeItem('p2', 'piAgent', 1 * MB)
  ]
  cleanDeleteImpl = async () => ({ freedBytes: 0, deletedCount: 0 })
  volumeInfo = null
  installApi()
})

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('CleanConfirmSheet · 显隐与目标集合', () => {
  it('显隐受 showCleanConfirmAlert 控制：关闭时什么都不渲染', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    await cleanStore.scanConversations()

    const { container } = render(<CleanConfirmSheet />)
    expect(container.firstChild).toBeNull()
    expect(screen.queryByRole('dialog')).toBeNull()
  })

  it('打开后渲染面板，取消后收起', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    await cleanStore.scanConversations()
    cleanStore.setItemSelected('p1', true)
    cleanStore.requestCleanSelected()

    const { container } = render(<CleanConfirmSheet />)
    expect(screen.getByRole('dialog')).toBeTruthy()
    expect(container.textContent).toContain('确认清除会话？')

    await act(async () => {
      cleanStore.cancelClean()
    })
    expect(screen.queryByRole('dialog')).toBeNull()
  })

  it('cleanTarget=selected：只统计勾选项，并带上索引层估算', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    await cleanStore.scanConversations()
    cleanStore.setItemSelected('p1', true)
    cleanStore.setItemSelected('p2', true)
    cleanStore.requestCleanSelected()

    render(<CleanConfirmSheet />)

    const text = panelText()
    // 2 个会话文件，勾选范围不带「「X」的」前缀
    expect(text).toContain('将删除2 个会话文件')
    expect(text).not.toContain('「')
    // 6 MB 主文件 + 2 × 34 KB 索引层
    expect(text).toContain(formatBytes(6 * MB + 2 * 34 * 1024))
    // 命中的索引会话数写在提示块里
    expect(text).toContain('命中的 2 个会话、每会话 34 KB 估算')
  })

  it('cleanTarget=allInCurrentCategory：统计当前分类的可见集合', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    await cleanStore.scanConversations()
    cleanStore.setSelectedCategory('cursor')
    cleanStore.requestCleanAll()

    render(<CleanConfirmSheet />)

    const text = panelText()
    expect(text).toContain('「Cursor」的 3 个会话文件')
    expect(text).toContain(formatBytes(60 * MB))
    // Cursor 命中 state.vscdb 这一层索引
    expect(text).toContain('索引行 · state.vscdb')
  })

  it('切分类不改变面板的目标集合（钉在 estimateCategory）', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    await cleanStore.scanConversations()
    cleanStore.setSelectedCategory('cursor')
    cleanStore.requestCleanAll()
    render(<CleanConfirmSheet />)

    expect(panelText()).toContain('「Cursor」的 3 个会话文件')

    // 面板开着时切分类：目标集合必须不动
    await act(async () => {
      cleanStore.setSelectedCategory('piAgent')
    })
    expect(panelText()).toContain('「Cursor」的 3 个会话文件')
    expect(panelText()).toContain(formatBytes(60 * MB))
  })

  it('estimateToken 变化时把滚动区拉回顶部', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    await cleanStore.scanConversations()
    cleanStore.setItemSelected('c1', true)
    cleanStore.requestCleanSelected()
    render(<CleanConfirmSheet />)

    const scroller = screen
      .getByRole('dialog')
      .querySelector(`.${styles.scroll}`) as HTMLDivElement
    expect(scroller).toBeTruthy()
    scroller.scrollTop = 120
    expect(scroller.scrollTop).toBe(120)

    await act(async () => {
      cleanStore.refreshEstimate()
    })
    expect(scroller.scrollTop).toBe(0)
  })
})

describe('CleanConfirmSheet · 三条取消路径', () => {
  it('点遮罩 → cancelClean', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    const spy = vi.spyOn(cleanStore, 'cancelClean')
    await cleanStore.scanConversations()
    cleanStore.setItemSelected('c1', true)
    cleanStore.requestCleanSelected()
    render(<CleanConfirmSheet />)

    const scrim = screen.getByRole('dialog').parentElement as HTMLElement
    await act(async () => {
      fireEvent.mouseDown(scrim)
    })

    expect(spy).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('dialog')).toBeNull()
  })

  it('点遮罩但落在面板上 → 不取消', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    const spy = vi.spyOn(cleanStore, 'cancelClean')
    await cleanStore.scanConversations()
    cleanStore.setItemSelected('c1', true)
    cleanStore.requestCleanSelected()
    render(<CleanConfirmSheet />)

    await act(async () => {
      fireEvent.mouseDown(screen.getByRole('dialog'))
    })

    expect(spy).not.toHaveBeenCalled()
    expect(screen.getByRole('dialog')).toBeTruthy()
  })

  it('Esc → cancelClean', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    const spy = vi.spyOn(cleanStore, 'cancelClean')
    await cleanStore.scanConversations()
    cleanStore.setItemSelected('c1', true)
    cleanStore.requestCleanSelected()
    render(<CleanConfirmSheet />)

    await act(async () => {
      fireEvent.keyDown(document, { key: 'Escape' })
    })

    expect(spy).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('dialog')).toBeNull()
  })

  it('点「取消」→ cancelClean', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    const spy = vi.spyOn(cleanStore, 'cancelClean')
    await cleanStore.scanConversations()
    cleanStore.setItemSelected('c1', true)
    cleanStore.requestCleanSelected()
    render(<CleanConfirmSheet />)

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: '取消' }))
    })

    expect(spy).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('dialog')).toBeNull()
  })
})

describe('CleanConfirmSheet · 确认与执行中态', () => {
  it('确认按钮调 executeClean，Enter / ⌘Enter 同样走这条路径', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    const spy = vi.spyOn(cleanStore, 'executeClean').mockResolvedValue(undefined)
    await cleanStore.scanConversations()
    cleanStore.setItemSelected('c1', true)
    cleanStore.requestCleanSelected()
    render(<CleanConfirmSheet />)

    expect(confirmButton().textContent).toBe(`确认清除 · ${formatBytes(10 * MB)}`)

    await act(async () => {
      fireEvent.click(confirmButton())
    })
    expect(spy).toHaveBeenCalledTimes(1)

    await act(async () => {
      fireEvent.keyDown(document, { key: 'Enter' })
    })
    expect(spy).toHaveBeenCalledTimes(2)

    await act(async () => {
      fireEvent.keyDown(document, { key: 'Enter', metaKey: true })
    })
    expect(spy).toHaveBeenCalledTimes(3)
  })

  it('执行中：按钮禁用 + 进度文案', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    let release: (value: CleanResult) => void = () => {}
    cleanDeleteImpl = () =>
      new Promise<CleanResult>((resolve) => {
        release = resolve
      })
    await cleanStore.scanConversations()
    cleanStore.setItemSelected('c1', true)

    // 单条删除不经过确认面板，正好可以把 store 停在 isCleaning 上
    const pending = cleanStore.deleteSingle(items[0] as ConversationItem)
    cleanStore.requestCleanSelected()
    render(<CleanConfirmSheet />)

    expect(confirmButton().disabled).toBe(true)
    expect(confirmButton().textContent).toBe('正在清除…')
    expect(screen.getByRole('dialog').getAttribute('aria-busy')).toBe('true')

    await act(async () => {
      release({ freedBytes: 0, deletedCount: 1 })
      await pending
    })
  })
})

describe('CleanConfirmSheet · 设置开关与文案', () => {
  it('cleanFileHistorySnapshots=false：预计释放扣掉索引层，提示块改口径', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    await cleanStore.scanConversations()
    await cleanStore.setPref('cleanFileHistorySnapshots', false)
    cleanStore.setItemSelected('p1', true)
    cleanStore.setItemSelected('p2', true)
    cleanStore.requestCleanSelected()
    render(<CleanConfirmSheet />)

    const text = panelText()
    // 索引层不删了：6 MB 整，不带 2 × 34 KB
    expect(text).toContain(formatBytes(6 * MB))
    expect(text).not.toContain('34 KB')
    // 空间构成只剩主文件一段，没有「索引行 · context-mode」那一段
    expect(text).toContain('共 1 段')
    expect(text).toContain('Pi Agent 占 100.0% · 共 1 段')
    expect(text).toContain('当前已关闭快照同步清理，仅删除主会话文件，索引行与快照会残留在原处。')
  })

  it('cleanEmptyProjectFolders 关掉时提示块不提空目录', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    await cleanStore.scanConversations()
    await cleanStore.setPref('cleanEmptyProjectFolders', false)
    cleanStore.setItemSelected('c1', true)
    cleanStore.requestCleanSelected()
    render(<CleanConfirmSheet />)

    const text = panelText()
    expect(text).not.toContain('空项目目录')
    expect(text).toContain('将同步删除快照、子代理数据与 SQLite 索引行')
  })

  it('目标集合变空时确认按钮禁用、读数显示破折号', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    await cleanStore.scanConversations()
    cleanStore.setItemSelected('c1', true)
    cleanStore.requestCleanSelected()
    render(<CleanConfirmSheet />)
    expect(confirmButton().disabled).toBe(false)

    await act(async () => {
      cleanStore.setItemSelected('c1', false)
    })

    const text = panelText()
    expect(text).toContain('当前没有可清理的会话。')
    expect(confirmButton().disabled).toBe(true)
    expect(confirmButton().title).toBe('没有可清理的会话')
  })
})

describe('CleanConfirmSheet · 卷占用（依赖卷信息通道）', () => {
  it('拿不到卷信息时整块不渲染', async () => {
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    await cleanStore.scanConversations()
    cleanStore.setItemSelected('c1', true)
    cleanStore.requestCleanSelected()
    render(<CleanConfirmSheet />)

    const text = panelText()
    expect(text).toContain('收益位置')
    expect(text).not.toContain('卷占用')
    expect(text).not.toContain('已用')
  })

  it('拿到卷信息时渲染清理前后对比与量级徽标', async () => {
    volumeInfo = {
      name: 'Macintosh HD',
      mountPath: '/System/Volumes/Data',
      capacity: 500 * 1024 * MB,
      used: 250 * 1024 * MB
    }
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    await cleanStore.scanConversations()
    cleanStore.setItemSelected('c1', true)
    cleanStore.requestCleanSelected()
    render(<CleanConfirmSheet />)
    // 卷信息是异步读的，等它落到 state
    await act(async () => {
      await Promise.resolve()
    })

    const text = panelText()
    expect(text).toContain('占卷总容量')
    expect(text).toContain('卷占用')
    expect(text).toContain('/System/Volumes/Data')
    expect(text).toContain('Macintosh HD')
    expect(text).toContain('清理前')
    expect(text).toContain('清理后')
    // 10 MB 摊到 500 GB 卷上 → 0.002%，量级微小
    expect(text).toContain('量级微小')
    expect(text).toContain('50.000% 已用')
    expect(text).toContain('49.998% 已用')
    expect(text).toContain('可用空间 250.00 GB → 250.01 GB')
  })

  it('释放量在 0.5% ~ 5% 之间时量级徽标走 warn 档（不是 ok 档）', async () => {
    volumeInfo = {
      name: '测试卷',
      mountPath: '/',
      capacity: 1024 * MB,
      used: 600 * MB
    }
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    await cleanStore.scanConversations()
    // 10 MB / 1 GB = 0.98% —— 落在「有限」这一档
    cleanStore.setItemSelected('c1', true)
    cleanStore.requestCleanSelected()
    render(<CleanConfirmSheet />)
    await act(async () => {
      await Promise.resolve()
    })

    // 三档的文案与 class 是钉死的：warn 档才是挂 --warning / --warning-soft 的那条，
    // 之前它回落成 --danger（红），语义不对。
    const badge = screen.getByText('量级有限')
    expect(badge.className).toContain(styles.lvl)
    expect(badge.className).toContain(styles.lvlWarn)
  })

  it('释放量超过卷容量 5% 时量级徽标转 ok 档', async () => {
    volumeInfo = {
      name: '测试卷',
      mountPath: '/',
      capacity: 1024 * MB,
      used: 600 * MB
    }
    const { cleanStore, CleanConfirmSheet } = await loadSheet()
    await cleanStore.scanConversations()
    cleanStore.setSelectedCategory('cursor')
    cleanStore.requestCleanAll()
    render(<CleanConfirmSheet />)
    await act(async () => {
      await Promise.resolve()
    })

    const text = panelText()
    // 60 MB 主文件 + 索引层 ≈ 58.6% → 量级显著
    expect(text).toContain('量级显著')
    expect(text).toContain('58.594% 已用')
  })
})
