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
 * OverviewView（详情栏未选中态）的 jsdom 用例。
 *
 * 覆盖三件容易错的事：
 *   ① Top 5 必须**按体积降序**取，而不是按扫描顺序（`sortByUpdatedDesc` 的结果序）。
 *   ② 体积的视觉重量高于标题 —— 断言用的 `aria-label` 里体积紧跟标题，
 *      且体积走 `formatBytes` 的 1024 进制。
 *   ③ 空态两态：「还没扫过」（hasScanned=false）与「扫完确实没有会话」（hasScanned=true）。
 */

const HOME = '/Users/tester'

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

function installApi(items: ConversationItem[], agents: AgentInfo[], prefs: Prefs): ApiMock {
  const api: ApiMock = {
    scanAll: vi.fn(async (): Promise<ScanResult> => ({
      items,
      agents,
      issues: [],
      durationMs: 12
    })),
    cleanDelete: vi.fn(async (): Promise<CleanResult> => ({ freedBytes: 0, deletedCount: 0 })),
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

async function renderOverview(): Promise<void> {
  const { OverviewView } = await import('@renderer/views/OverviewView')
  const element: ReactElement = <OverviewView />
  render(element)
}

function makeItem(
  id: string,
  sizeInBytes: number,
  overrides: Partial<ConversationItem> = {}
): ConversationItem {
  return {
    id,
    sessionId: `sess-${id}`,
    title: `会话 ${id}`,
    category: 'piAgent',
    projectPath: null,
    gitBranch: null,
    messageCount: 4,
    sizeInBytes,
    updatedAt: new Date(2026, 8, 27, 9, 26).toISOString(),
    isSelected: false,
    snippet: '',
    associatedPaths: [],
    ...overrides
  }
}

function makeAgent(category: AgentInfo['category'], totalBytes: number): AgentInfo {
  return {
    category,
    isInstalled: true,
    storagePath: `${HOME}/.x/${category}`,
    sessionCount: 1,
    totalBytes
  }
}

const MB = 1024 * 1024

/** 大户行的可及名 = 「标题，占用，占全库百分比」，标题在最前。 */
function biggestTitles(): string[] {
  return screen
    .getAllByRole('button')
    .map((el) => (el.getAttribute('aria-label') ?? '').split('，')[0] ?? '')
}

beforeEach(() => {
  vi.restoreAllMocks()
})

afterEach(() => {
  cleanup()
})

describe('OverviewView · 占用大户 Top 5', () => {
  it('按体积降序取前 5，扫描顺序不参与排序', async () => {
    const items = [
      makeItem('a', 3 * MB),
      makeItem('b', 45 * MB),
      makeItem('c', 6 * MB),
      makeItem('d', 19 * MB),
      makeItem('e', 1 * MB),
      makeItem('f', 15 * MB),
      makeItem('g', 0)
    ]
    await boot(items, [makeAgent('piAgent', 89 * MB)])
    await renderOverview()

    expect(screen.getByText('共 7 个会话')).toBeTruthy()
    expect(biggestTitles()).toEqual(['会话 b', '会话 d', '会话 f', '会话 c', '会话 a'])
  })

  it('体积与占比跟全库总量对齐（1024 进制 + tabular 百分比）', async () => {
    const items = [makeItem('a', 45 * MB), makeItem('b', 55 * MB)]
    await boot(items, [makeAgent('piAgent', 100 * MB)])
    await renderOverview()

    const row = screen.getByRole('button', { name: /会话 a/ })
    expect(row.getAttribute('aria-label')).toBe('会话 a，45 MB，占全库 45%')
    expect(screen.getByRole('button', { name: /会话 b/ }).getAttribute('aria-label')).toBe(
      '会话 b，55 MB，占全库 55%'
    )
  })

  it('点一行把该会话设为选中', async () => {
    const items = [makeItem('a', 45 * MB)]
    const { store } = await boot(items, [makeAgent('piAgent', 45 * MB)])
    await renderOverview()

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /会话 a/ }))
    })
    expect(store.getSnapshot().selectedConversationId).toBe('a')
  })

  it('0 KB 的会话照样进 Top 5，但体积退到 t3（读数仍在）', async () => {
    const items = [makeItem('a', 1 * MB), makeItem('zero', 0)]
    await boot(items, [makeAgent('piAgent', 1 * MB)])
    await renderOverview()

    expect(biggestTitles()).toEqual(['会话 a', '会话 zero'])
    expect(screen.getByText('0 KB')).toBeTruthy()
  })
})

describe('OverviewView · Agent 分布', () => {
  it('按占用降序列出，超过 5 款时其余合并成「其他 N 款」', async () => {
    const items = [
      makeItem('p1', 52 * MB, { category: 'piAgent' }),
      makeItem('a1', 47 * MB, { category: 'antigravity' }),
      makeItem('c1', 3 * MB, { category: 'copilotChat' }),
      makeItem('w1', 2 * MB, { category: 'windsurf' }),
      makeItem('t1', 1024, { category: 'trae' }),
      makeItem('z1', 512, { category: 'zed' }),
      makeItem('h1', 256, { category: 'openHands' })
    ]
    const agents = [
      makeAgent('piAgent', 52 * MB),
      makeAgent('antigravity', 47 * MB),
      makeAgent('copilotChat', 3 * MB),
      makeAgent('windsurf', 2 * MB),
      makeAgent('trae', 1024),
      makeAgent('zed', 512),
      makeAgent('openHands', 256)
    ]
    await boot(items, agents)
    await renderOverview()

    for (const label of [
      'Pi Agent',
      'Antigravity',
      'Copilot / VS Code',
      'Windsurf',
      'Trae',
      '其他 2 款'
    ]) {
      expect(screen.getByText(label)).toBeTruthy()
    }
    // 0.4% 以下不四舍五入成 0%（那会与右侧数字自相矛盾）
    expect(screen.getAllByText('<1%').length).toBe(3)
    // 色阶：前 5 段 + 「其他」共 6 段，各取同 hue 阶梯上不同的一级
    const colors = Array.from(document.querySelectorAll<HTMLElement>('span[style]'))
      .map((el) => el.style.background)
      .filter((value) => value.startsWith('var(--d'))
    expect(new Set(colors)).toEqual(
      new Set(['var(--d1)', 'var(--d2)', 'var(--d3)', 'var(--d4)', 'var(--d5)', 'var(--d6)'])
    )
  })
})

describe('OverviewView · 空态两态', () => {
  it('还没扫过：hasScanned=false → 引导按钮「一键扫描」', async () => {
    // 关掉「启动时自动扫描」→ bootstrap 不触发扫描 → hasScanned 保持 false
    const { api } = await boot([], [], { ...DEFAULT_PREFS, autoScanOnLaunch: false })
    await renderOverview()

    expect(screen.getByText('还没有扫描过会话')).toBeTruthy()
    expect(screen.queryByText('没有扫描到任何会话')).toBeNull()
    expect(screen.queryByRole('heading', { name: '占用大户' })).toBeNull()

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: '一键扫描' }))
    })
    expect(api.scanAll).toHaveBeenCalledTimes(1)
  })

  it('扫完确实没有会话：hasScanned=true → 两个区块各给一句解释', async () => {
    const { store } = await boot([], [], { ...DEFAULT_PREFS, autoScanOnLaunch: false })
    await act(async () => {
      await store.scanConversations()
    })
    await renderOverview()

    expect(store.getSnapshot().hasScanned).toBe(true)
    expect(screen.getByText('没有扫描到任何会话')).toBeTruthy()
    expect(screen.getByText('没有可统计的占用')).toBeTruthy()
    expect(screen.queryByText('还没有扫描过会话')).toBeNull()
    // 清理说明块两态都在
    expect(screen.getByText('清理说明')).toBeTruthy()
  })

  it('扫到的会话全是 0 字节时，同样不画分布条', async () => {
    const items = [makeItem('a', 0), makeItem('b', 0)]
    await boot(items, [makeAgent('piAgent', 0)])
    await renderOverview()

    expect(screen.getByText('没有可统计的占用')).toBeTruthy()
  })
})
