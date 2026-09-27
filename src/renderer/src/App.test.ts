// @vitest-environment node
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { COLUMN_LIMITS } from './App'

/**
 * 列宽上下限的**两份表示**必须永远一致。
 *
 * `tokens.css` 的 `--col-*` 给 CSS 用，`App.tsx` 的 `COLUMN_LIMITS` 给 JS 钳制用。
 * CSS 变量在 JS 里读不到（除非运行时 `getComputedStyle`，那会多一次强制重排），
 * 所以这两份无法合并成一份 —— 那就用测试钉住，漂了就红。
 *
 * 漏掉这个测试的代价很具体：改了 CSS 里的 `--col-sidebar-min` 忘了改 TS，
 * 分隔条实际能拖到的位置就会和 CSS 声明的最小宽度对不上，
 * 而且这个偏差只在手动拖窗口时才偶发，测试和 typecheck 都不会报。
 */
const HERE = dirname(fileURLToPath(import.meta.url))
const TOKENS_CSS = readFileSync(join(HERE, 'styles/tokens.css'), 'utf8')

/** 从 `:root` 块里取出某个自定义属性的像素值。 */
function cssToken(name: string): number {
  const match = new RegExp(`--${name}:\\s*(\\d+)px`).exec(TOKENS_CSS)
  if (!match) throw new Error(`tokens.css 里找不到 --${name}`)
  return Number(match[1])
}

describe('列宽上下限：CSS token 与 TS 常量一致', () => {
  const cases: Array<[keyof typeof COLUMN_LIMITS, string]> = [
    ['sidebarMin', 'col-sidebar-min'],
    ['sidebarMax', 'col-sidebar-max'],
    ['listMin', 'col-list-min'],
    ['listMax', 'col-list-max']
  ]

  for (const [tsKey, cssName] of cases) {
    it(`COLUMN_LIMITS.${tsKey} === --${cssName}`, () => {
      expect(COLUMN_LIMITS[tsKey]).toBe(cssToken(cssName))
    })
  }

  it('上下限的次序合理（min < max）', () => {
    expect(COLUMN_LIMITS.sidebarMin).toBeLessThan(COLUMN_LIMITS.sidebarMax)
    expect(COLUMN_LIMITS.listMin).toBeLessThan(COLUMN_LIMITS.listMax)
  })
})

describe('渲染进程不残留自绘 svg 字形', () => {
  /**
   * 集成阶段把各视图就地自绘的 SVG 全部收进了 `DrawnControls`。
   * 漏一处不会让 typecheck 变红、也不会让测试变红 —— 只会让描边语言悄悄分叉
   * （某个图标 1.5px、其余 1.6px），这种偏差在截图上几乎看不出来。
   * 所以直接把裸 `<svg` 文本搜出来。
   */
  const files = [
    'App.tsx',
    join('views', 'DetailView.tsx'),
    join('views', 'OverviewView.tsx'),
    join('views', 'SettingsView.tsx'),
    join('views', 'CleanConfirmSheet.tsx'),
    join('views', 'SidebarView.tsx'),
    join('views', 'ConversationListView.tsx')
  ]

  for (const rel of files) {
    it(`${rel} 里没有裸 <svg>（字形应统一走 DrawnIcon / AgentGlyph）`, () => {
      const source = readFileSync(join(HERE, rel), 'utf8')
      // 去掉注释与字符串里的误报，再找真正的 JSX 元素
      const stripped = source
        .replace(/\/\*[\s\S]*?\*\//g, '')
        .replace(/\{\/\*[\s\S]*?\*\/\}/g, '')
        .replace(/^\s*\/\/.*$/gm, '')
      expect(stripped).not.toMatch(/<svg[\s>]/)
    })
  }
})
