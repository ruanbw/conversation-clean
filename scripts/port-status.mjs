#!/usr/bin/env node
/**
 * 端口状态探针：一眼看清 Swift → TypeScript 移植还剩哪些洞。
 *
 * 判定「还是占位实现」的唯一依据是占位文件里那句 `尚未从 Xxx.swift 移植` 的 throw。
 * 不靠文件行数、不靠 git 历史 —— 那些都会被合法的重构骗到。
 *
 * 用法：
 *   node scripts/port-status.mjs           # 人类可读
 *   node scripts/port-status.mjs --json    # 机器可读（给 CI / 后续脚本）
 */
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SCANNER_DIRS = [join(ROOT, 'src/main/scanners/cli'), join(ROOT, 'src/main/scanners/vscode')]

/** 占位实现里必然出现的标记串。与生成占位文件的脚本保持一致。 */
const STUB_MARKER = '尚未从'

const results = []

for (const dir of SCANNER_DIRS) {
  if (!existsSync(dir)) continue
  const family = dir.endsWith('cli') ? 'CLIAgents' : 'VSCodeFamily'
  for (const name of readdirSync(dir).sort()) {
    if (!name.endsWith('.ts') || name.endsWith('.test.ts')) continue
    const file = join(dir, name)
    const source = readFileSync(file, 'utf8')
    const isStub = source.includes(STUB_MARKER)

    let testFile = null
    let testCount = 0
    const candidate = file.replace(/\.ts$/, '.test.ts')
    if (existsSync(candidate)) {
      testFile = relative(ROOT, candidate)
      testCount = (readFileSync(candidate, 'utf8').match(/\b(it|test)\(/g) ?? []).length
    }

    results.push({
      scanner: name.replace(/\.ts$/, ''),
      family,
      file: relative(ROOT, file),
      status: isStub ? 'stub' : 'ported',
      lines: source.split('\n').length,
      hasTest: testFile !== null,
      testCount,
      testFile
    })
  }
}

/** 渲染进程：视图 / 组件是否还是占位。 */
const UI_STUBS = [
  'src/renderer/src/App.tsx',
  'src/renderer/src/components/DrawnControls.tsx',
  'src/renderer/src/components/Splitter.tsx',
  'src/renderer/src/views/SidebarView.tsx',
  'src/renderer/src/views/ConversationListView.tsx',
  'src/renderer/src/views/DetailView.tsx',
  'src/renderer/src/views/OverviewView.tsx',
  'src/renderer/src/views/SettingsView.tsx',
  'src/renderer/src/views/CleanConfirmSheet.tsx'
]

const uiResults = UI_STUBS.map((rel) => {
  const file = join(ROOT, rel)
  if (!existsSync(file)) return { file: rel, status: 'missing', hasTest: false, testCount: 0 }
  const source = readFileSync(file, 'utf8')
  const isStub = source.includes('移植占位')
  const candidate = file.replace(/\.tsx$/, '.test.tsx')
  const hasTest = existsSync(candidate)
  return {
    file: rel,
    status: isStub ? 'stub' : 'ported',
    hasTest,
    testCount: hasTest
      ? (readFileSync(candidate, 'utf8').match(/\b(it|test)\(/g) ?? []).length
      : 0
  }
})

const scanners = results
const ui = uiResults
const totalScanners = scanners.length
const portedScanners = scanners.filter((s) => s.status === 'ported').length
const testedScanners = scanners.filter((s) => s.hasTest).length
const totalUi = ui.length
const portedUi = ui.filter((u) => u.status === 'ported').length

const summary = {
  scanners: { total: totalScanners, ported: portedScanners, tested: testedScanners },
  ui: { total: totalUi, ported: portedUi },
  tests: {
    totalCases: [...scanners, ...ui].reduce((sum, item) => sum + item.testCount, 0)
  },
  done: portedScanners === totalScanners && portedUi === totalUi
}

if (process.argv.includes('--json')) {
  console.log(JSON.stringify({ summary, scanners, ui }, null, 2))
  process.exit(summary.done ? 0 : 1)
}

const mark = (status) => (status === 'ported' ? '✓' : status === 'stub' ? '·' : '✗')

console.log('扫描器')
for (const item of scanners) {
  const test = item.hasTest ? `${item.testCount} 用例` : '无测试'
  console.log(`  ${mark(item.status)} ${item.scanner.padEnd(24)} ${String(item.lines).padStart(4)} 行  ${test}`)
}
console.log('\n渲染进程')
for (const item of ui) {
  const test = item.hasTest ? `${item.testCount} 用例` : '无测试'
  console.log(`  ${mark(item.status)} ${item.file.replace('src/renderer/src/', '').padEnd(24)} ${test}`)
}
console.log(
  `\n扫描器 ${portedScanners}/${totalScanners}（其中 ${testedScanners} 个带测试）· ` +
    `UI ${portedUi}/${totalUi} · 累计 ${summary.tests.totalCases} 个测试用例`
)
console.log(summary.done ? '\n全部移植完成。' : '\n尚未移植完成（· = 占位，✗ = 缺文件）。')

process.exit(summary.done ? 0 : 1)
