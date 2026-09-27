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
 * SettingsView 的 jsdom 用例。
 *
 * 覆盖两条主线：
 *   ① 4 个开关都走 `setPref` → `window.api.setPrefs`，并且 aria-checked 跟着翻；
 *   ② 每款 Agent 一行的存储路径缩写 + 「打开目录」/「清空」两个动作落到 IPC 桥上。
 *
 * 同 DetailView / OverviewView：驱动的是真 store，不 mock 组件内部回调。
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

async function renderSettings(): Promise<() => void> {
  const { SettingsView } = await import('@renderer/views/SettingsView')
  const element: ReactElement = <SettingsView />
  render(element)
  return () => undefined
}

function makeAgent(overrides: Partial<AgentInfo> = {}): AgentInfo {
  return {
    category: 'piAgent',
    isInstalled: true,
    storagePath: `${HOME}/.pi/agent/sessions`,
    sessionCount: 19,
    totalBytes: 52 * 1024 * 1024,
    ...overrides
  }
}

async function gotoPathsTab(): Promise<void> {
  await act(async () => {
    fireEvent.click(screen.getByRole('button', { name: 'Agent 路径' }))
  })
}

beforeEach(() => {
  vi.restoreAllMocks()
})

afterEach(() => {
  cleanup()
})

describe('SettingsView · 通用页开关', () => {
  it('4 个开关默认全开，标题与副标题都渲染出来', async () => {
    await boot()
    await renderSettings()

    const switches = screen.getAllByRole('switch')
    expect(switches).toHaveLength(4)
    for (const el of switches) {
      expect(el.getAttribute('aria-checked')).toBe('true')
    }
    expect(screen.getByText(/关闭后清理将立即执行，不可撤销/)).toBeTruthy()
    expect(screen.getByText(/启动时扫描一次本机全部 Agent 的会话缓存/)).toBeTruthy()
    expect(screen.getByText(/关闭后仅删除主会话文件，快照与子代理目录将保留/)).toBeTruthy()
    expect(screen.getByText(/清理后递归移除不再包含任何会话的空目录/)).toBeTruthy()
  })

  it('点开关 → setPref(key, 反值) → setPrefs IPC → aria-checked 翻转', async () => {
    const { api, store } = await boot()
    await renderSettings()

    const cases: Array<[RegExp, keyof Prefs]> = [
      [/启动应用时自动扫描会话/, 'autoScanOnLaunch'],
      [/删除会话时同步清除快照与子代理数据/, 'cleanFileHistorySnapshots'],
      [/删除会话后自动移除空项目目录/, 'cleanEmptyProjectFolders'],
      [/执行清理操作前弹出二次确认/, 'confirmBeforeClean']
    ]

    for (const [name, key] of cases) {
      const sw = screen.getByRole('switch', { name })
      expect(sw.getAttribute('aria-checked')).toBe('true')
      await act(async () => {
        fireEvent.click(sw)
      })
      expect(api.setPrefs).toHaveBeenCalledWith({ [key]: false })
      expect(store.getSnapshot().prefs[key]).toBe(false)
      expect(screen.getByRole('switch', { name }).getAttribute('aria-checked')).toBe('false')
    }
  })

  it('「二次确认」关掉后整行转危险色（副标题 + 警示三角）', async () => {
    await boot()
    await renderSettings()

    const sw = screen.getByRole('switch', { name: /执行清理操作前弹出二次确认/ })
    await act(async () => {
      fireEvent.click(sw)
    })
    // 警示三角是 aria-hidden 的 SVG，只能从 class 认：关掉后多了 riskIcon
    const row = screen.getByRole('switch', { name: /执行清理操作前弹出二次确认/ })
    expect(row.innerHTML).toContain('riskIcon')
  })
})

describe('SettingsView · Agent 路径页', () => {
  it('每款 Agent 一行：名称 / 安装状态 / 会话数 / 体积 / 缩写后的存储路径', async () => {
    const agents = [
      makeAgent(),
      makeAgent({
        category: 'cursor',
        isInstalled: false,
        storagePath: `${HOME}/Library/Application Support/Cursor/User/workspaceStorage`,
        sessionCount: 0,
        totalBytes: 0
      })
    ]
    await boot([], agents)
    await renderSettings()
    await gotoPathsTab()

    expect(screen.getByText('已安装 1 款 · 存储路径与占用')).toBeTruthy()
    // 读数条
    expect(screen.getByText('52')).toBeTruthy()
    expect(screen.getByText('/ 2 款')).toBeTruthy()
    expect(screen.getByText('19')).toBeTruthy()

    // 安装状态只认 AgentInfo.isInstalled：Cursor 没装就是「未发现」
    expect(screen.getByText('19 会话')).toBeTruthy()
    expect(screen.getByText('未发现')).toBeTruthy()
    expect(screen.getByText('52 MB')).toBeTruthy()
    expect(screen.getByText('0 KB')).toBeTruthy()

    // 存储路径走 abbreviateHome，0 字节的 Agent 占比列写「—」
    expect(screen.getByText('~/.pi/agent/sessions')).toBeTruthy()
    expect(
      screen.getByText('~/Library/Application Support/Cursor/User/workspaceStorage')
    ).toBeTruthy()
    expect(screen.getByText('—')).toBeTruthy()
  })

  it('「打开目录」把**原始**（未缩写）存储路径交给 openStoragePath', async () => {
    const agents = [makeAgent()]
    const { api } = await boot([], agents)
    await renderSettings()
    await gotoPathsTab()

    await act(async () => {
      fireEvent.click(
        screen.getByRole('button', { name: '在 Finder 中打开 Pi Agent 的存储目录' })
      )
    })
    expect(api.openPath).toHaveBeenCalledTimes(1)
    expect(api.openPath).toHaveBeenCalledWith(`${HOME}/.pi/agent/sessions`)
  })

  it('未安装的 Agent 不给「打开目录」按钮（用占位保列宽）', async () => {
    const agents = [makeAgent({ category: 'zed', isInstalled: false, sessionCount: 0 })]
    await boot([], agents)
    await renderSettings()
    await gotoPathsTab()

    expect(
      screen.queryByRole('button', { name: '在 Finder 中打开 Zed AI 的存储目录' })
    ).toBeNull()
  })

  it('「清空」走 cleanAllOfCategory → cleanAll(category)；无会话时禁用', async () => {
    const agents = [makeAgent(), makeAgent({ category: 'zed', isInstalled: false, sessionCount: 0 })]
    const { api } = await boot([], agents)
    await renderSettings()
    await gotoPathsTab()

    const clearButton = screen.getByRole('button', { name: '清空 Pi Agent 的全部会话' })
    const disabledButton = screen.getByRole('button', {
      name: '清空 Zed AI 的全部会话'
    }) as HTMLButtonElement
    expect(disabledButton.disabled).toBe(true)

    await act(async () => {
      fireEvent.click(clearButton)
    })
    expect(api.cleanAll).toHaveBeenCalledTimes(1)
    expect(api.cleanAll).toHaveBeenCalledWith('piAgent')
  })

  it('没扫过（agentInfos 为空）→ 引导回主窗口扫描', async () => {
    await boot([], [])
    await renderSettings()
    await gotoPathsTab()

    expect(screen.getByText('尚未扫描到 Agent 信息')).toBeTruthy()
    expect(screen.getByText('请先回到主窗口执行一次扫描。')).toBeTruthy()
  })
})

describe('SettingsView · 关于页与导航', () => {
  it('三个页签可切，关于页显示版本与三格事实', async () => {
    await boot()
    await renderSettings()

    expect(screen.getByRole('heading', { name: '通用' })).toBeTruthy()
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: '关于' }))
    })
    expect(screen.getByRole('heading', { name: '关于' })).toBeTruthy()
    expect(screen.getByText(/版本 2\.0\.0/)).toBeTruthy()
    expect(screen.getByText('受支持 Agent')).toBeTruthy()
    expect(screen.getByText('双层索引同步')).toBeTruthy()
    // 6 款双层索引 Agent
    expect(screen.getByText('并发扫描任务组')).toBeTruthy()
  })

  it('传 onClose 时才渲染关闭按钮', async () => {
    await boot()
    const { SettingsView } = await import('@renderer/views/SettingsView')
    const onClose = vi.fn()
    const element: ReactElement = <SettingsView onClose={onClose} />
    render(element)
    expect(screen.getByRole('button', { name: '关闭设置' })).toBeTruthy()

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: '关闭设置' }))
    })
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})
