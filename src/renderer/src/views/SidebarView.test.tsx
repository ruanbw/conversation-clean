// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AgentInfo, ConversationItem, Prefs, ScanResult } from '@shared/types'
import { DEFAULT_PREFS } from '@shared/types'
import { cleanStore } from '@renderer/state/cleanStore'
import { SidebarView } from './SidebarView'

/**
 * 侧栏测试。
 *
 * 数据通过 `window.api` 的假实现喂进 `cleanStore.scanConversations()` ——
 * 走的是和真实应用完全相同的那条路（store → selector → 视图），
 * 不用去 mock store 本身，派生数据的口径也就跟着被验到了。
 */

let prefs: Prefs = { ...DEFAULT_PREFS }
let scanResult: ScanResult = { items: [], agents: [], issues: [], durationMs: 1 }

function installApi(): void {
  const api = {
    scanAll: vi.fn(async () => scanResult),
    cleanDelete: vi.fn(async () => ({ freedBytes: 0, deletedCount: 0 })),
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

function item(over: Partial<ConversationItem> & { id: string }): ConversationItem {
  return {
    sessionId: over.id,
    title: `会话 ${over.id}`,
    category: 'claudeCode',
    projectPath: '/Users/tester/projects/conversation-clean',
    gitBranch: 'main',
    messageCount: 4,
    sizeInBytes: 1024 * 1024 * 45,
    updatedAt: new Date().toISOString(),
    isSelected: false,
    snippet: '',
    associatedPaths: [],
    ...over
  }
}

const AGENTS: AgentInfo[] = [
  {
    category: 'claudeCode',
    isInstalled: true,
    storagePath: '/Users/tester/.claude/projects',
    sessionCount: 3,
    totalBytes: 1024 * 1024 * 95
  },
  {
    category: 'cursor',
    isInstalled: false,
    storagePath: '/Users/tester/.cursor',
    sessionCount: 0,
    totalBytes: 0
  },
  {
    // 装了但一条会话没有：用来验「仅显示有数据」把它滤掉
    category: 'zed',
    isInstalled: true,
    storagePath: '/Users/tester/Library/Application Support/Zed',
    sessionCount: 0,
    totalBytes: 0
  }
]

beforeEach(async () => {
  localStorage.clear()
  // 关掉启动自动扫描：bootstrap 里的启动扫描是进程级幂等的
  // （`hasAttemptedLaunchScan` 只跑一次），第二个用例就扫不到了。
  // 改成显式调 scanConversations，每条用例的数据都是确定的。
  prefs = { ...DEFAULT_PREFS, autoScanOnLaunch: false }
  installApi()
  scanResult = {
    items: [
      item({ id: 'a', sizeInBytes: 1024 * 1024 * 45, category: 'claudeCode' }),
      item({ id: 'b', sizeInBytes: 1024 * 1024 * 50, category: 'claudeCode' }),
      item({ id: 'c', sizeInBytes: 0, category: 'claudeCode' })
    ],
    agents: AGENTS,
    issues: [],
    durationMs: 1
  }
  cleanStore.setSelectedCategory('all')
  cleanStore.setSearchText('')
  cleanStore.setColumnWidths({ sidebar: 208, list: 460 })
  // 等 120ms 防抖落地，把 store 内部的 debouncedQuery 清成空串，
  // 否则下一个用例的过滤会读到上一条用例留下的查询词。
  await sleep(150)
  await cleanStore.bootstrap()
  await cleanStore.scanConversations()
  cleanStore.dismissAlerts()
  render(<SidebarView />)
})

afterEach(cleanup)

function navRow(category: string): HTMLElement {
  const el = document.querySelector(`[data-category="${category}"]`)
  if (!el) throw new Error(`侧栏里没有分类行 ${category}`)
  return el as HTMLElement
}

describe('SidebarView · 分类导航', () => {
  it('未安装的 Agent 置灰但仍列出来', () => {
    const cursor = navRow('cursor')
    expect(cursor.getAttribute('data-installed')).toBe('false')
    expect(cursor.className).toContain('navRowDim')
    expect(cursor.getAttribute('title')).toBe('Cursor · 0 个会话 · 0 KB')

    expect(navRow('claudeCode').getAttribute('data-installed')).toBe('true')
    expect(navRow('claudeCode').className).not.toContain('navRowDim')
  })

  it('「全部会话」恒在首位且不带置灰', () => {
    const first = document.querySelector('[data-category]')
    expect(first?.getAttribute('data-category')).toBe('all')
    expect(first?.getAttribute('data-installed')).toBe('true')
  })

  it('15 款全部列出（含未安装的），未安装的仍可点', () => {
    const rows = [...document.querySelectorAll('[data-category]')]
    expect(rows.length).toBe(16) // 15 款 + all
    fireEvent.click(navRow('cursor'))
    expect(cleanStore.getSnapshot().selectedCategory).toBe('cursor')
  })

  it('点击分类行切换当前分类，并带上会话数与体积', () => {
    fireEvent.click(navRow('claudeCode'))
    expect(cleanStore.getSnapshot().selectedCategory).toBe('claudeCode')
    // 重新渲染读的是新分类下的统计
    fireEvent.click(navRow('all'))
    const row = navRow('claudeCode')
    expect(row.textContent).toContain('3')
    expect(row.textContent).toContain('95 MB')
  })

  it('「仅显示有数据」滤掉 0 会话的分类与未安装的分类', () => {
    // 关：装了但没会话的 Zed 仍在列表里
    expect(navRow('zed')).toBeTruthy()
    expect(navRow('cursor').getAttribute('data-installed')).toBe('false')

    fireEvent.click(screen.getByText('仅显示有数据').closest('button') as HTMLElement)
    // 开：0 会话与未安装的都被滤掉，只剩有数据的 claudeCode 与恒在的 all
    expect(() => navRow('zed')).toThrow()
    expect(() => navRow('cursor')).toThrow()
    expect(navRow('claudeCode')).toBeTruthy()
    expect(navRow('all')).toBeTruthy()

    // 开关状态记忆到 localStorage（键名就是 hideEmptyCategories）
    expect(localStorage.getItem('hideEmptyCategories')).toBe('1')
  })
})

describe('SidebarView · 体检卡与路径卡', () => {
  it('22px 大号读数用 splitBytes 拆成数值 + 单位', () => {
    // 全部会话：45 + 50 + 0 = 95 MB → 大于 10，取整 95
    expect(screen.getByText('95')).toBeTruthy()
    expect(screen.getByText('MB')).toBeTruthy()
    expect(screen.getByText('占 全部 Agent 合计 100%')).toBeTruthy()
    expect(screen.getByText('3 会话')).toBeTruthy()
  })

  it('切到具体 Agent 时读数跟着走，占比按全量算', () => {
    fireEvent.click(navRow('claudeCode'))
    expect(screen.getByText('占 Claude Code 100%')).toBeTruthy()
    expect(screen.getByText('3 会话')).toBeTruthy()
  })

  it('存储路径把 home 缩写成 ~', () => {
    expect(screen.getByText('~/.claude/projects')).toBeTruthy()
  })

  it('选中未安装的 Agent 时路径说明换成「未检测到」', async () => {
    fireEvent.click(navRow('cursor'))
    expect(screen.getByText('未在本机检测到该 Agent 的存储目录。')).toBeTruthy()
    expect(screen.getByText('~/.cursor')).toBeTruthy()

    // 存储路径存在就允许「在 Finder 中打开」（目录可能已被删，
    // 交给 Finder 自己报错比在 UI 里猜一层更准）。
    const api = (window as unknown as { api: { openPath: ReturnType<typeof vi.fn> } }).api
    fireEvent.click(screen.getByText('在 Finder 中打开').closest('button') as HTMLElement)
    expect(api.openPath).toHaveBeenCalledWith('/Users/tester/.cursor')
  })

  it('两条说明文字都跟着设置开关变', async () => {
    // 默认：两个开关都开
    expect(screen.getByText('清理时同步删除快照与子代理数据。')).toBeTruthy()
    expect(screen.getByText('删除会话后会一并回收空目录与子代理目录。')).toBeTruthy()

    await cleanStore.setPref('cleanFileHistorySnapshots', false)
    await cleanStore.setPref('cleanEmptyProjectFolders', false)

    await waitFor(() => {
      expect(screen.getByText('清理时保留文件改动快照，只删会话文件。')).toBeTruthy()
      expect(screen.getByText('空目录将保留在磁盘上，可在设置中开启回收。')).toBeTruthy()
    })
  })
})
