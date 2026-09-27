import { nativeImage } from 'electron'
import { existsSync, readdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { CATEGORY_APP_BUNDLES, SCANNER_CATEGORIES, type AgentCategory } from '@shared/types'

/**
 * Agent 图标解析：优先用**产品自己的 app 图标**，找不到才回退自绘字形。
 *
 * 移植自 Swift 版 `Views/AgentIconView.swift` 的 `enum AgentIcon`（那里用
 * `NSWorkspace.shared.icon(forFile:)`）。Electron 侧的等价物是
 * `nativeImage.createFromPath()` + `toDataURL()` —— 直接把图标编码成 dataURL 交给渲染进程，
 * 渲染进程那边就完全不需要碰文件系统。
 *
 * 纯 CLI（Codex / Aider / Pi Agent）与 VS Code 扩展（Cline / Roo / Continue）
 * 本身没有独立 app 图标，这类返回 `null`，由 UI 回退到 1.6px 线稿字形。
 *
 * 缓存是进程级的：扫描 `/Applications` 要读目录，15 款逐个查会让首屏卡一下。
 */
const cache = new Map<AgentCategory, string | null>()

/** 应用可能装在系统区、用户区或 Utilities 里，四个位置都找。 */
function appSearchRoots(): string[] {
  const home = homedir()
  return [
    '/Applications',
    join(home, 'Applications'),
    '/Applications/Utilities',
    join(home, 'Applications/Utilities')
  ]
}

function locate(bundle: string): string | null {
  for (const root of appSearchRoots()) {
    const candidate = join(root, bundle)
    if (existsSync(candidate)) return candidate
  }
  return null
}

/** 在 `.app` 包里找图标文件。优先 `AppIcon.icns`，其次任意 `*.icns`。 */
function iconFileIn(appPath: string): string | null {
  const resources = join(appPath, 'Contents', 'Resources')
  if (!existsSync(resources)) return null

  const preferred = join(resources, 'AppIcon.icns')
  if (existsSync(preferred)) return preferred

  let entries: string[]
  try {
    entries = readdirSync(resources)
  } catch {
    return null
  }
  const icns = entries.find((name) => name.toLowerCase().endsWith('.icns'))
  return icns ? join(resources, icns) : null
}

/**
 * 解析一个分类的 app 图标（dataURL，32×32）。
 *
 * @returns dataURL 字符串；该 Agent 没有独立 app、或图标读不出来时返回 `null`。
 */
export function agentIconDataUrl(category: AgentCategory): string | null {
  if (category === 'all') return null
  const cached = cache.get(category)
  if (cached !== undefined) return cached

  let result: string | null = null
  for (const bundle of CATEGORY_APP_BUNDLES[category]) {
    const appPath = locate(bundle)
    if (!appPath) continue
    const iconFile = iconFileIn(appPath)
    if (!iconFile) continue
    try {
      const image = nativeImage.createFromPath(iconFile)
      if (image.isEmpty()) continue
      const resized = image.resize({ width: 32, height: 32, quality: 'best' })
      result = resized.toDataURL()
      break
    } catch {
      // 图标损坏 / 格式不支持：试下一个 bundle。
    }
  }
  cache.set(category, result)
  return result
}

/** 一次性解析全部 15 款的图标，UI 挂载时调一次即可。 */
export function allAgentIcons(): Record<string, string | null> {
  const out: Record<string, string | null> = {}
  for (const category of SCANNER_CATEGORIES) {
    out[category] = agentIconDataUrl(category)
  }
  return out
}
