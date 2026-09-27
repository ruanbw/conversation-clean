// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ReactElement } from 'react'
import type {
  AgentInfo,
  AppInfo,
  CleanResult,
  ConversationItem,
  Prefs,
  ScanResult
} from '@shared/types'
import { DEFAULT_PREFS } from '@shared/types'

/**
 * DetailView 的 jsdom 用例。
 *
 * 驱动方式是**真的**走 `window.api` → `cleanStore` → 组件，不 mock 组件内部的动作函数：
 * 这样「点了复制会话 ID 有没有真的落到剪贴板桥上」才验得到。
 * `vi.resetModules()` 拿到一份全新的 store 单例，避免用例之间共享上一次的状态。
 */

const HOME = '/Users/tester'

// 2026-09-27 19:54（本地时区构造，`formatFullDate` 的断言与时区无关）
const UPDATED_AT = new Date(2026, 8, 27, 19, 54).toISOString()

function makeItem(overrides: Partial<ConversationItem> = {}): ConversationItem {
  return {
    id: 'item-1',
    sessionId: 'sess-0001-abcd',
    title: '重构扫描器的并发调度',
    category: 'piAgent',
    projectPath: `${HOME}/projects/conversation-clean`,
    gitBranch: 'main',
    messageCount: 42,
    sizeInBytes: 45 * 1024 * 1024,
    updatedAt: UPDATED_AT,
    isSelected: false,
    snippet: '把 15 个扫描器改成 mapLimit，避开 fd 爆掉。',
    associatedPaths: [`${HOME}/.pi/agent/sessions/sess-0001-abcd.jsonl`],
    ...overrides
  }
}

function makeAgent(overrides: Partial<AgentInfo> = {}): AgentInfo {
  return {
    category: 'piAgent',
    isInstalled: true,
    storagePath: `${HOME}/.pi/agent/sessions`,
    sessionCount: 1,
    totalBytes: 45 * 1024 * 1024,
    ...overrides
  }
}

interface ApiMock {
  scanAll: ReturnType<typeof vi.fn>
  cleanDelete: ReturnType<typeof vi.fn>
  cleanAll: ReturnType<typeof vi.fn>
  getPrefs: ReturnType<typeof vi.fn>
  setPrefs: ReturnType<typeof vi.fn>
  getAppInfo: ReturnType<typeof vi.fn>
  getAgentIcons: ReturnType<typeof vi.fn>
  revealInFinder: ReturnType<typeof vi.fn>
  openPath: ReturnType<typeof vi.fn>
  copyText: ReturnType<typeof vi.fn>
}

/** 装一份 `window.api` 假桥。prefs 是可变对象，`setPrefs` 会真的改它并回传。 */
function installApi(
  items: ConversationItem[],
  agents: AgentInfo[],
  prefs: Prefs = { ...DEFAULT_PREFS }
): ApiMock {
  const api: ApiMock = {
    scanAll: vi.fn(async (): Promise<ScanResult> => ({
      items,
      agents,
      issues: [],
      durationMs: 12
    })),
    cleanDelete: vi.fn(async (): Promise<CleanResult> => ({
      freedBytes: 0,
      deletedCount: 0
    })),
    cleanAll: vi.fn(async (): Promise<CleanResult> => ({ freedBytes: 0, deletedCount: 0 })),
    getPrefs: vi.fn(async (): Promise<Prefs> => ({ ...prefs })),
    setPrefs: vi.fn(async (patch: Partial<Prefs>): Promise<Prefs> => {
      Object.assign(prefs, patch)
      return { ...prefs }
    }),
    getAppInfo: vi.fn(async (): Promise<AppInfo> => ({
      version: '2.0.0',
      platform: 'darwin',
      home: HOME,
      electron: '44.0.0',
      node: '22.5.0'
    })),
    getAgentIcons: vi.fn(async (): Promise<Record<string, string | null>> => ({})),
    revealInFinder: vi.fn(async (): Promise<boolean> => true),
    openPath: vi.fn(async (): Promise<boolean> => true),
    copyText: vi.fn(async (): Promise<boolean> => true)
  }
  ;(window as unknown as { api: unknown }).api = api
  return api
}

/** 重置模块图 → 装桥 → bootstrap（拉取 prefs / homeDir / 图标，并按开关决定要不要启动扫描）。 */
async function boot(
  items: ConversationItem[] = [],
  agents: AgentInfo[] = [],
  prefs: Prefs = { ...DEFAULT_PREFS }
): Promise<{ api: ApiMock; store: typeof import('@renderer/state/cleanStore').cleanStore }> {
  vi.resetModules()
  const api = installApi(items, agents, prefs)
  const { cleanStore } = await import('@renderer/state/cleanStore')
  await cleanStore.bootstrap()
  return { api, store: cleanStore }
}

async function renderDetail(item: ConversationItem | null): Promise<void> {
  const { DetailView } = await import('@renderer/views/DetailView')
  const element: ReactElement = <DetailView item={item} />
  render(element)
}

beforeEach(() => {
  vi.restoreAllMocks()
})

afterEach(() => {
  cleanup()
  vi.useRealTimers()
})

describe('DetailView · 元数据渲染', () => {
  it('渲染标题 / 徽章 / 轮数 / 体积读数与全部元数据行', async () => {
    const item = makeItem()
    await boot([item], [makeAgent()])
    await renderDetail(item)

    expect(screen.getByRole('heading', { name: item.title })).toBeTruthy()
    // 分类徽章走 CATEGORY_LABELS，不是枚举 key
    expect(screen.getByText('Pi Agent')).toBeTruthy()
    expect(screen.getByText('42 轮')).toBeTruthy()

    // 体积读数：数值 21px + 单位 10px 拆开渲染（splitBytes），再拼成一句给读屏
    expect(screen.getByText('45')).toBeTruthy()
    expect(screen.getByText('MB')).toBeTruthy()
    expect(screen.getByLabelText('占用空间 45 MB')).toBeTruthy()

    // 元数据表：8 行，按标签取值。
    // 「占用空间」在头部读数里也出现一次，关联文件有同名分区标题，
    // 所以不能按文本全局找——直接拿「元数据」分区下那张卡的行来对。
    const metaSection = screen.getByRole('heading', { name: '元数据' }).parentElement as HTMLElement
    const metaCard = metaSection.querySelector('div') as HTMLElement
    const valueOf = (label: string): string => {
      for (const row of Array.from(metaCard.children)) {
        const [labelEl, valueEl] = Array.from(row.children)
        if (labelEl?.textContent === label) return valueEl?.textContent ?? ''
      }
      return ''
    }
    expect(valueOf('占用空间')).toBe('45 MB')
    expect(valueOf('对话轮数')).toBe('42')
    expect(valueOf('关联文件')).toBe('1')
    expect(valueOf('最后更新')).toBe('2026-09-27 19:54')
    expect(valueOf('Git 分支')).toBe('main')
    // 项目路径按 Swift 基准显示**全路径**（home 已缩写成 ~），换行不截断；
    // title 上带同一份完整值
    expect(valueOf('项目路径')).toBe('~/projects/conversation-clean')
    const projectCell = metaCard.querySelector('[title]')
    expect(projectCell?.getAttribute('title')).toBe('~/projects/conversation-clean')
    expect(projectCell?.textContent).toBe('~/projects/conversation-clean')
    expect(valueOf('存储路径')).toBe('~/.pi/agent/sessions')
    expect(valueOf('会话 ID')).toBe('sess-0001-abcd')

    // 摘要与原子清理区（piAgent 命中索引表）
    expect(screen.getByText(item.snippet)).toBeTruthy()
    expect(screen.getByText(/context-mode SQLite 索引行同步删除/)).toBeTruthy()
  })

  it('空字段渲染成「—」，摘要为空时整区不出现', async () => {
    // claudeCode 不在索引表里，所以「原子清理」区也不该出现
    const item = makeItem({
      category: 'claudeCode',
      gitBranch: null,
      projectPath: null,
      snippet: ''
    })
    await boot([item], [makeAgent()])
    await renderDetail(item)

    const emDashes = screen.getAllByText('—')
    // Git 分支 / 项目路径 / 存储路径 三行为空
    expect(emDashes.length).toBeGreaterThanOrEqual(3)
    expect(screen.queryByRole('heading', { name: '摘要' })).toBeNull()
    expect(screen.queryByRole('heading', { name: '原子清理' })).toBeNull()
  })

  it('关联文件逐条渲染，点一行复制该行路径', async () => {
    const item = makeItem({ associatedPaths: [] })
    const { api } = await boot([item], [makeAgent()])
    await renderDetail(item)

    // 拿不到 associatedPaths 时按 <project>/.session → <storagePath>/<sessionId>.jsonl → 索引位置 拼
    const rows = screen.getAllByRole('button', { name: /^复制路径 / })
    expect(rows).toHaveLength(3)
    expect(screen.getByText('~/projects/conversation-clean/.session')).toBeTruthy()
    expect(screen.getByText('~/.pi/agent/context-mode')).toBeTruthy()

    await act(async () => {
      fireEvent.click(rows[0] as HTMLElement)
    })
    // 复制的是**展示用**的路径（home 已缩写成 ~），与 Swift 版一致
    expect(api.copyText).toHaveBeenCalledWith('~/projects/conversation-clean/.session')
  })
})

describe('DetailView · 操作回调', () => {
  it('「在 Finder 中显示」把关联文件首条交给 revealInFinder', async () => {
    const item = makeItem()
    const { api } = await boot([item], [makeAgent()])
    await renderDetail(item)

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: '在 Finder 中显示' }))
    })
    expect(api.revealInFinder).toHaveBeenCalledTimes(1)
    expect(api.revealInFinder).toHaveBeenCalledWith(`${HOME}/.pi/agent/sessions/sess-0001-abcd.jsonl`)
  })

  it('「复制项目路径」/「复制会话 ID」分别落到 copyText，并给出 1.5s 已复制反馈', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const item = makeItem()
    const { api } = await boot([item], [makeAgent()])
    await renderDetail(item)

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: '复制项目路径' }))
    })
    expect(api.copyText).toHaveBeenCalledWith('~/projects/conversation-clean')

    const idButton = screen.getByRole('button', { name: '复制会话 ID' })
    await act(async () => {
      fireEvent.click(idButton)
    })
    expect(api.copyText).toHaveBeenCalledWith('sess-0001-abcd')
    // 反馈文案换上去，1.5s 后自己退回
    expect(screen.getByRole('button', { name: '已复制' })).toBeTruthy()

    await act(async () => {
      vi.advanceTimersByTime(1_600)
    })
    expect(screen.getByRole('button', { name: '复制会话 ID' })).toBeTruthy()
  })

  it('项目路径为空时「复制项目路径」禁用', async () => {
    const item = makeItem({ projectPath: null })
    const { api } = await boot([item], [makeAgent()])
    await renderDetail(item)

    const button = screen.getByRole('button', { name: '复制项目路径' }) as HTMLButtonElement
    expect(button.disabled).toBe(true)
    await act(async () => {
      fireEvent.click(button)
    })
    expect(api.copyText).not.toHaveBeenCalled()
  })

  it('「删除此会话」走 deleteSingle → cleanDelete([item])', async () => {
    const item = makeItem()
    const { api } = await boot([item], [makeAgent()])
    await renderDetail(item)

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: '删除此会话' }))
    })
    expect(api.cleanDelete).toHaveBeenCalledTimes(1)
    expect((api.cleanDelete as unknown as { mock: { calls: unknown[][] } }).mock.calls[0]?.[0]).toEqual([
      item
    ])
  })
})

describe('DetailView · 未选中态', () => {
  it('item 为 null 时渲染 OverviewView 的「还没扫过」空态', async () => {
    // autoScanOnLaunch 关掉 → hasScanned 保持 false
    await boot([], [], { ...DEFAULT_PREFS, autoScanOnLaunch: false })
    await renderDetail(null)
    expect(screen.getByText('还没有扫描过会话')).toBeTruthy()
  })
})
