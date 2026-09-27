// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AgentInfo, ConversationItem, Prefs, ScanResult } from '@shared/types'
import { DEFAULT_PREFS } from '@shared/types'
import { cleanStore } from '@renderer/state/cleanStore'
import { ConversationListView } from './ConversationListView'

/**
 * 会话列表测试。
 *
 * 重点是任务书点名的两块：**搜索过滤** 与 **批量选择**，
 * 外加自绘列表必须自己补的键盘导航（↑↓ / Home / End / Space）、
 * 排序切换、四种空态。
 *
 * 数据同样从 `window.api` 的假实现喂进 `cleanStore.scanConversations()`，
 * 走的是和真实应用一样的 store → selector 链路。
 */

let prefs: Prefs = { ...DEFAULT_PREFS }
let scanResult: ScanResult = { items: [], agents: [], issues: [], durationMs: 1 }
let cleaned: ConversationItem[] = []

function installApi(): void {
  const api = {
    scanAll: vi.fn(async () => scanResult),
    cleanDelete: vi.fn(async (items: ConversationItem[]) => {
      cleaned = items
      return {
        freedBytes: items.reduce((sum, i) => sum + i.sizeInBytes, 0),
        deletedCount: items.length
      }
    }),
    cleanAll: vi.fn(async () => ({ freedBytes: 0, deletedCount: 0 })),
    getPrefs: vi.fn(async () => prefs),
    setPrefs: vi.fn(async (patch: Partial<Prefs>) => {
      prefs = { ...prefs, ...patch }
      return prefs
    }),
    getAppInfo: vi.fn(async () => ({
      version: '2.0.0',
      platform: 'darwin',
      home: '/Users/tester',
      electron: '44',
      node: '22'
    })),
    getAgentIcons: vi.fn(async () => ({})),
    revealInFinder: vi.fn(async () => true),
    openPath: vi.fn(async () => true),
    copyText: vi.fn(async () => true)
  }
  ;(window as unknown as { api: unknown }).api = api
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

const AGENTS: AgentInfo[] = [
  {
    category: 'claudeCode',
    isInstalled: true,
    storagePath: '/Users/tester/.claude/projects',
    sessionCount: 3,
    totalBytes: 1024 * 1024 * 95
  }
]

function item(over: Partial<ConversationItem> & { id: string }): ConversationItem {
  return {
    sessionId: `sess-${over.id}`,
    title: `会话 ${over.id}`,
    category: 'claudeCode',
    projectPath: '/Users/tester/projects/conversation-clean',
    gitBranch: 'main',
    messageCount: 4,
    sizeInBytes: 1024 * 1024,
    updatedAt: new Date().toISOString(),
    isSelected: false,
    snippet: '',
    associatedPaths: [],
    ...over
  }
}

beforeEach(async () => {
  localStorage.clear()
  prefs = { ...DEFAULT_PREFS, autoScanOnLaunch: false }
  cleaned = []
  installApi()
  scanResult = {
    items: [
      item({
        id: 'a',
        title: '重构扫描器的并发调度',
        sizeInBytes: 1024 * 1024 * 45,
        messageCount: 2,
        updatedAt: '2026-09-26T10:00:00.000Z'
      }),
      item({
        id: 'b',
        title: '加上分隔条拖拽与列宽记忆',
        sizeInBytes: 1024 * 1024 * 50,
        messageCount: 9,
        updatedAt: '2026-09-25T10:00:00.000Z'
      }),
      item({
        id: 'c',
        title: 'README 截图与文档对齐',
        sizeInBytes: 0,
        messageCount: 40,
        updatedAt: '2026-09-24T10:00:00.000Z'
      })
    ],
    agents: AGENTS,
    issues: [],
    durationMs: 1
  }
  cleanStore.setSelectedCategory('all')
  cleanStore.setSearchText('')
  // 行选中是 store 级状态，不重置的话会从上一条用例泄露过来
  cleanStore.setSelectedConversationId(null)
  await sleep(150)
  await cleanStore.bootstrap()
  await cleanStore.scanConversations()
  cleanStore.dismissAlerts()
  render(<ConversationListView />)
})

afterEach(cleanup)

function rowIds(): string[] {
  return screen.getAllByRole('option').map((el) => el.getAttribute('data-row-id') ?? '')
}

function rowById(id: string): HTMLElement {
  const el = document.querySelector(`[data-row-id="${id}"]`)
  if (!el) throw new Error(`列表里没有行 ${id}`)
  return el as HTMLElement
}

function checkboxIn(id: string): HTMLElement {
  return within(rowById(id)).getByRole('checkbox')
}

describe('ConversationListView · 渲染与排序', () => {
  it('默认按「占用空间」降序，0 KB 那条在最后', () => {
    expect(rowIds()).toEqual(['b', 'a', 'c'])
    expect(screen.getByText('共 3 项')).toBeTruthy()
    // 0 KB 行降透明度：删了不省空间
    expect(rowById('c').className).toContain('rowZero')
    expect(rowById('a').className).not.toContain('rowZero')
  })

  it('切到「最近更新」按时间降序', () => {
    fireEvent.click(screen.getByRole('radio', { name: '最近更新' }))
    expect(rowIds()).toEqual(['a', 'b', 'c'])
    expect(localStorage.getItem('listSortMode')).toBe('date')
  })

  it('切到「对话轮数」按消息数降序', () => {
    fireEvent.click(screen.getByRole('radio', { name: '对话轮数' }))
    expect(rowIds()).toEqual(['c', 'b', 'a'])
  })

  it('体积用 1024 进制的 formatBytes', () => {
    expect(within(rowById('a')).getByText('45 MB')).toBeTruthy()
    expect(within(rowById('c')).getByText('0 KB')).toBeTruthy()
  })
})

describe('ConversationListView · 搜索过滤', () => {
  it('输入搜索词后只留匹配的会话，清除后恢复', () => {
    const input = screen.getByPlaceholderText('搜索标题、摘要、项目路径或会话 ID')
    fireEvent.change(input, { target: { value: 'README' } })

    expect(rowIds()).toEqual(['c'])
    expect(screen.getByText('共 1 项')).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: '清除搜索词' }))
    expect(rowIds()).toEqual(['b', 'a', 'c'])
    expect((input as HTMLInputElement).value).toBe('')
  })

  it('也会搜摘要、项目路径与会话 ID', () => {
    const input = screen.getByPlaceholderText('搜索标题、摘要、项目路径或会话 ID')
    fireEvent.change(input, { target: { value: 'sess-b' } })
    expect(rowIds()).toEqual(['b'])

    fireEvent.change(input, { target: { value: 'conversation-clean' } })
    expect(rowIds()).toEqual(['b', 'a', 'c'])
  })

  it('搜不到时给的是「无搜索结果」空态，不是「还没扫描」', () => {
    fireEvent.change(
      screen.getByPlaceholderText('搜索标题、摘要、项目路径或会话 ID'),
      { target: { value: '不存在的关键词' } }
    )
    expect(screen.getByText('没有匹配「不存在的关键词」的会话')).toBeTruthy()
    expect(screen.getByText('换个关键词，或清空搜索词看全部 3 个会话。')).toBeTruthy()

    fireEvent.click(screen.getByText('清除搜索词'))
    expect(rowIds()).toEqual(['b', 'a', 'c'])
  })

  it('⌘F 请求计数自增时把焦点拉回搜索框', () => {
    const input = screen.getByPlaceholderText('搜索标题、摘要、项目路径或会话 ID')
    expect(document.activeElement).not.toBe(input)
    cleanStore.requestSearchFocus()
    waitFor(() => expect(document.activeElement).toBe(input))
  })
})

describe('ConversationListView · 批量选择', () => {
  it('勾选两条：批量条读数跟着变，清理按钮带上条数', () => {
    fireEvent.click(checkboxIn('b'))
    fireEvent.click(checkboxIn('a'))

    const batch = screen.getByText(/已选/).closest('span') as HTMLElement
    expect(batch.textContent).toContain('2')
    expect(batch.textContent).toContain('95 MB')
    expect(screen.getByText('清理选中项（2）')).toBeTruthy()
  })

  it('点勾选框不会顺带改行选中（stopPropagation）', () => {
    fireEvent.click(checkboxIn('b'))
    expect(cleanStore.getSnapshot().selectedConversationId).toBeNull()

    // 点行只改行选中，不会把勾选状态带回去
    fireEvent.click(rowById('b'))
    expect(cleanStore.getSnapshot().selectedConversationId).toBe('b')
    expect(checkboxIn('b').getAttribute('aria-checked')).toBe('true')
  })

  it('全选当前 / 取消全选只作用于当前可见集合', () => {
    fireEvent.click(screen.getByText('全选当前'))
    expect(screen.getByText('取消全选')).toBeTruthy()
    expect(cleanStore.getSelectedItems().length).toBe(3)

    fireEvent.click(screen.getByText('取消全选'))
    expect(cleanStore.getSelectedItems().length).toBe(0)
  })

  it('已选后未选的行标成半选', () => {
    fireEvent.click(checkboxIn('b'))
    expect(checkboxIn('a').getAttribute('aria-checked')).toBe('mixed')
    expect(checkboxIn('b').getAttribute('aria-checked')).toBe('true')
  })

  it('清理选中项走二次确认（confirmBeforeClean 默认开）', () => {
    fireEvent.click(checkboxIn('a'))
    fireEvent.click(screen.getByText('清理选中项（1）'))

    const state = cleanStore.getSnapshot()
    expect(state.showCleanConfirmAlert).toBe(true)
    expect(state.cleanTarget).toBe('selected')
    expect(state.estimateCount).toBe(1)
    // 面板没确认之前不落盘
    expect((window as unknown as { api: { cleanDelete: unknown } }).api.cleanDelete).not.toHaveBeenCalled()

    cleanStore.cancelClean()
    expect(cleanStore.getSnapshot().showCleanConfirmAlert).toBe(false)
  })

  it('没勾选时清理按钮禁用', () => {
    expect((screen.getByText('清理选中项') as HTMLElement).closest('button')?.disabled).toBe(true)
  })

  it('确认后真的把选中的交给 cleanDelete，并弹完成通知', async () => {
    fireEvent.click(checkboxIn('a'))
    fireEvent.click(screen.getByText('清理选中项（1）'))
    await cleanStore.executeClean()

    const api = (window as unknown as {
      api: { cleanDelete: ReturnType<typeof vi.fn> }
    }).api
    expect(api.cleanDelete).toHaveBeenCalledTimes(1)
    expect(cleaned.map((i) => i.id)).toEqual(['a'])
    expect(cleanStore.getSnapshot().showCleanSuccessAlert).toBe(true)
    expect(screen.getByText(/清理完成 · 删除 1 个会话/)).toBeTruthy()
  })
})

describe('ConversationListView · 键盘导航（自绘后自己补）', () => {
  it('↑↓ 移动行选中；没有任何选中时 ↓ 进第一条、↑ 进最后一条', () => {
    const list = screen.getByRole('listbox')
    fireEvent.keyDown(list, { key: 'ArrowDown' })
    expect(cleanStore.getSnapshot().selectedConversationId).toBe('b') // 排序后第一条

    fireEvent.keyDown(list, { key: 'ArrowDown' })
    expect(cleanStore.getSnapshot().selectedConversationId).toBe('a')
    fireEvent.keyDown(list, { key: 'ArrowUp' })
    expect(cleanStore.getSnapshot().selectedConversationId).toBe('b')
  })

  it('Home / End 跳到首尾', () => {
    const list = screen.getByRole('listbox')
    fireEvent.keyDown(list, { key: 'End' })
    expect(cleanStore.getSnapshot().selectedConversationId).toBe('c')
    fireEvent.keyDown(list, { key: 'Home' })
    expect(cleanStore.getSnapshot().selectedConversationId).toBe('b')
  })

  it('空格勾选当前行', () => {
    const list = screen.getByRole('listbox')
    fireEvent.keyDown(list, { key: 'ArrowDown' })
    fireEvent.keyDown(list, { key: ' ' })
    expect(cleanStore.getSelectedItems().map((i) => i.id)).toEqual(['b'])
  })

  it('Shift+点击连选：从锚点连到本行', () => {
    fireEvent.click(rowById('a')) // 锚点（体积序里的第 2 行）
    fireEvent.click(rowById('c'), { shiftKey: true })
    expect(cleanStore.getSelectedItems().map((i) => i.id).sort()).toEqual(['a', 'c'])
  })

  it('在搜索框里按 ↑↓ / 空格不劫持输入', () => {
    const input = screen.getByPlaceholderText('搜索标题、摘要、项目路径或会话 ID')
    fireEvent.keyDown(input, { key: 'ArrowDown' })
    expect(cleanStore.getSnapshot().selectedConversationId).toBeNull()
  })
})

describe('ConversationListView · 通知条与空态', () => {
  it('扫描完成通知条可关掉', async () => {
    await cleanStore.scanConversations()
    expect(screen.getByText(/扫描完成 · 命中 3 个会话，合计 95 MB。/)).toBeTruthy()
    fireEvent.click(screen.getByText('知道了'))
    expect(cleanStore.getSnapshot().showScanSuccessAlert).toBe(false)
  })

  it('切到没有会话的分类 → 「暂无 X 会话记录」', async () => {
    cleanStore.setSelectedCategory('zed')
    await waitFor(() => expect(screen.getByText('暂无 Zed AI 会话记录')).toBeTruthy())
    expect(screen.getByText('未在本地检测到该 Agent 的历史会话文件，或所有会话均已被清理。')).toBeTruthy()
    expect(screen.queryAllByRole('option')).toHaveLength(0)
  })

  it('行右键菜单：在 Finder 中显示 / 复制会话 ID / 删除此会话', async () => {
    fireEvent.contextMenu(rowById('a'))
    expect(screen.getByRole('menu')).toBeTruthy()

    const api = (window as unknown as {
      api: { copyText: ReturnType<typeof vi.fn>; cleanDelete: ReturnType<typeof vi.fn> }
    }).api
    fireEvent.click(screen.getByText('复制会话 ID'))
    expect(api.copyText).toHaveBeenCalledWith('sess-a')
    expect(cleanStore.getSnapshot().conversations.length).toBe(3)

    fireEvent.contextMenu(rowById('a'))
    fireEvent.click(screen.getByText('删除此会话'))
    await waitFor(() => expect(cleanStore.getSnapshot().conversations.length).toBe(2))
    expect(api.cleanDelete).toHaveBeenCalledTimes(1)
  })
})
