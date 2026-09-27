#!/usr/bin/env node
/**
 * 扫描器完整性检查。
 *
 * 15 个扫描器分散在 `src/main/scanners/{cli,vscode}/`，但真正决定「哪些分类能被扫到」
 * 的只有两个地方：`@shared/types` 里的 `SCANNER_CATEGORIES`，和 `scanners/registry.ts`。
 * 这两处都是**手写**的，没有类型系统能兜住「我写了一个新扫描器但忘了注册」——
 * 编译照样通过，运行时那个 Agent 就是静默不出现在列表里。
 * 这个脚本就是替 typescript 补上这道检查。
 *
 * 五项检查：
 *   1. 注册表完整性：`SCANNER_CATEGORIES` 的每个分类都有扫描器声明它，
 *      而那个扫描器确实在 `createScanners()` 里被 `new` 出来了 —— 分类 → 文件 → 实例，三段都得连上。
 *   2. 孤儿文件：`cli/` 与 `vscode/` 下每个 `XxxScanner.ts` 都被 registry 导入；
 *      反向也查：在 `createScanners()` 之外 `new` 出来的扫描器，等于没注册。
 *   3. 每个扫描器都有同名 `XxxScanner.test.ts`。
 *   4. `readonly category` 与所在目录、文件名一致。
 *   5. 真的实现了 `scan` / `delete` / `cleanAll`（沿 `extends` 链解析），
 *      并扫描占位实现的痕迹。
 *
 * 用法：
 *   node scripts/scanner-health.mjs          人类可读，有问题 exit 1
 *   node scripts/scanner-health.mjs --json   给 CI 的结构化输出
 */

import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { basename, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = fileURLToPath(new URL('..', import.meta.url))
const TYPES_PATH = join(ROOT, 'src/shared/types.ts')
const SCANNERS_DIR = join(ROOT, 'src/main/scanners')
const REGISTRY_PATH = join(SCANNERS_DIR, 'registry.ts')
const SCANNER_DIRS = ['cli', 'vscode']
const REQUIRED_METHODS = ['scan', 'delete', 'cleanAll']

/**
 * 分类 → 扫描器该待在哪个目录。规则只有一条：
 * 数据落在 VS Code 系扩展存储里（globalStorage / workspaceStorage / state.vscdb）的进
 * `vscode/`，其余（独立 CLI 工具、自有目录格式）进 `cli/`。
 * 新增分类必须在这里补一行，否则第 4 项检查会报「目录约定未登记」——这是故意的：
 * 「新 Agent 属于哪一族」是个需要人拍板的问题，不该由默认分支替人决定。
 */
const CATEGORY_DIR = {
  claudeCode: 'cli',
  codex: 'cli',
  piAgent: 'cli',
  cline: 'cli',
  rooCode: 'cli',
  continueDev: 'cli',
  openViking: 'cli',
  aider: 'cli',
  zed: 'cli',
  openHands: 'cli',
  copilotChat: 'vscode',
  cursor: 'vscode',
  windsurf: 'vscode',
  trae: 'vscode',
  antigravity: 'vscode'
}

/**
 * 产品名与内部分类名不同名的少数派。第 4 项的文件名校验默认要求
 * `XxxScanner.ts` 的 `Xxx` 与 category 互为前缀（大小写无关），
 * 这类例外写在这里，别去放宽正则。
 */
const FILE_STEM_ALIASES = { copilotChat: 'VSCodeChat' }

/** 占位实现会留下的痕迹。真的在扫描器里 `throw new Error()` 是没有意义的。 */
const PLACEHOLDER_MARKERS = [
  { pattern: /尚未从/, label: '「尚未从 …」移植占位标记' },
  { pattern: /throw new Error\(/, label: '`throw new Error(`' }
]

// ───────────────────────────────────────────────────────────── 解析

function readOrFail(path) {
  if (!existsSync(path)) {
    fail(`找不到 ${relative(ROOT, path)}`)
  }
  return readFileSync(path, 'utf8')
}

function fail(message) {
  process.stderr.write(`scanner-health: ${message}\n`)
  process.exit(2)
}

/**
 * 抹掉注释再匹配。
 *
 * 关键：被注释掉的那行 `// new AntigravityScanner()` 正是「写了但没注册」最常见的现场，
 * 不先抹注释就会被当成已注册，那道检查等于不存在。
 * 行号用 `\n` 保留，方便报错时指位置；字符串 / 模板串里的内容原样留下。
 */
function stripComments(source) {
  let out = ''
  let i = 0
  let mode = 'code' // code | line | block | single | double | template
  while (i < source.length) {
    const c = source[i]
    const n = source[i + 1]
    if (mode === 'code') {
      if (c === '/' && n === '/') mode = 'line'
      else if (c === '/' && n === '*') mode = 'block'
      else if (c === "'") mode = 'single'
      else if (c === '"') mode = 'double'
      else if (c === '`') mode = 'template'
      out += c
      i += 1
      continue
    }
    if (mode === 'line') {
      if (c === '\n') {
        mode = 'code'
        out += c
      }
      i += 1
      continue
    }
    if (mode === 'block') {
      if (c === '*' && n === '/') {
        mode = 'code'
        i += 2
        continue
      }
      if (c === '\n') out += c
      i += 1
      continue
    }
    if (c === '\\') {
      out += c + (n ?? '')
      i += 2
      continue
    }
    const closing = { single: "'", double: '"', template: '`' }[mode]
    if (c === closing) mode = 'code'
    out += c
    i += 1
  }
  return out
}

/** 从 `types.ts` 取全部分类名（含 `all`），并确认 `SCANNER_CATEGORIES` 仍是它的 filter。 */
function parseCategories(source) {
  const array = source.match(/export const AGENT_CATEGORIES\s*=\s*\[([\s\S]*?)\]/)
  if (!array) fail('src/shared/types.ts 里读不到 AGENT_CATEGORIES 字面量数组，本脚本的解析假设失效')
  const all = [...array[1].matchAll(/'([^']+)'/g)].map((m) => m[1])
  const derived = /export const SCANNER_CATEGORIES\s*=\s*AGENT_CATEGORIES\.filter/.test(source)
  const scanners = all.filter((c) => c !== 'all')
  return { scanners, derived }
}

/** 从 `registry.ts` 取导入表与 `createScanners()` 里的实例化顺序。 */
function parseRegistry(source) {
  const code = stripComments(source)
  const imports = new Map()
  for (const m of code.matchAll(
    /import\s*\{\s*(\w+)\s*\}\s*from\s*'\.\/(cli|vscode)\/([\w+]+)'/g
  )) {
    imports.set(m[1], { dir: m[2], module: m[3] })
  }

  const body = code.match(/export function createScanners\(\)[^{]*\{([\s\S]*?)\n\}/)
  if (!body) fail('src/main/scanners/registry.ts 里读不到 createScanners() 函数体')

  const registered = [...body[1].matchAll(/new\s+(\w+)\s*\(/g)].map((m) => m[1])
  // 全文件的 `new XxxScanner()` —— 出现在 createScanners() 之外的那些就是「写了但没注册」。
  const instantiatedAnywhere = new Set([...code.matchAll(/new\s+(\w+Scanner)\s*\(/g)].map((m) => m[1]))
  return { imports, registered, instantiatedAnywhere }
}

/** 读一个 `XxxScanner.ts`：类名、父类、category 字段、三个方法是否自己实现了。 */
function parseScannerFile(absPath) {
  const source = stripComments(readFileSync(absPath, 'utf8'))
  const decl = source.match(/export class\s+(\w+)(?:\s+extends\s+(\w+))?/)
  const category = source.match(/readonly\s+category\s*(?::\s*[^=]*?)?=\s*'([^']+)'/)
  const own = {}
  for (const method of REQUIRED_METHODS) {
    own[method] = new RegExp(`^\\s+(?:async\\s+)?(?:override\\s+)?${method}\\s*\\(`, 'm').test(source)
  }
  const placeholders = PLACEHOLDER_MARKERS.filter((m) => m.pattern.test(source)).map((m) => m.label)
  return {
    className: decl ? decl[1] : null,
    parent: decl && decl[2] ? decl[2] : null,
    category: category ? category[1] : null,
    own,
    placeholders
  }
}

function listScannerFiles() {
  const files = []
  for (const dir of SCANNER_DIRS) {
    const abs = join(SCANNERS_DIR, dir)
    if (!existsSync(abs)) continue
    for (const entry of readdirSync(abs)) {
      // `PiAgentScanner+Parsing.ts` 这类拆分文件不是扫描器，`*.test.ts` 也不是。
      if (!entry.endsWith('Scanner.ts')) continue
      files.push({ dir, name: entry, abs: join(abs, entry) })
    }
  }
  return files.sort((a, b) => a.name.localeCompare(b.name))
}

// ───────────────────────────────────────────────────────────── 检查

function run() {
  const problems = []
  const add = (check, message, extra = {}) => problems.push({ check, message, ...extra })

  const typesSource = readOrFail(TYPES_PATH)
  const { scanners: expectedCategories, derived } = parseCategories(typesSource)
  if (!derived) {
    add(
      'contract',
      'SCANNER_CATEGORIES 不再由 AGENT_CATEGORIES.filter 派生，本脚本对分类的解析假设已失效'
    )
  }

  const registrySource = readOrFail(REGISTRY_PATH)
  const { imports, registered, instantiatedAnywhere } = parseRegistry(registrySource)

  const files = listScannerFiles()
  const parsed = files.map((file) => ({ ...file, ...parseScannerFile(file.abs) }))

  /** 沿 `extends` 链把三个方法解析出来（`RooCodeScanner` 继承 `ClineScanner` 就是这么过的）。 */
  const byClass = new Map(parsed.map((p) => [p.className, p]))
  const methodsOf = (entry, seen = new Set()) => {
    const chain = []
    let cur = entry
    while (cur && !seen.has(cur.className)) {
      seen.add(cur.className)
      chain.push(cur)
      cur = cur.parent ? byClass.get(cur.parent) : null
    }
    const methods = {}
    for (const method of REQUIRED_METHODS) {
      methods[method] = chain.some((link) => link.own[method])
    }
    return methods
  }

  const byCategory = new Map()
  for (const entry of parsed) {
    if (!entry.category) continue
    if (!byCategory.has(entry.category)) byCategory.set(entry.category, [])
    byCategory.get(entry.category).push(entry)
  }

  // 1. 注册表完整性：分类 → 扫描器文件 → createScanners() 实例，三段都得连上
  for (const category of expectedCategories) {
    const hits = byCategory.get(category) ?? []
    if (hits.length === 0) {
      add('registry', `注册表缺少分类 ${category}：types.ts 声明了它，但没有任何扫描器声明这个 category`, {
        category
      })
      continue
    }
    if (hits.length > 1) {
      add(
        'registry',
        `分类 ${category} 被 ${hits.map((h) => h.className).join(' / ')} 同时认领，应只留一个`,
        { category }
      )
      continue
    }
    const entry = hits[0]
    if (!registered.includes(entry.className)) {
      add(
        'registry',
        `注册表缺少分类 ${category}：${entry.className} 声明了它，但 createScanners() 里没有实例化（这个 Agent 永远扫不到）`,
        { category }
      )
    }
  }
  for (const className of registered) {
    const entry = byClass.get(className)
    const category = entry ? entry.category : null
    if (category && !expectedCategories.includes(category)) {
      add('registry', `${className} 声明了不在 SCANNER_CATEGORIES 里的分类 ${category}`, { category })
    }
  }

  // 2. 文件 ↔ 注册表双向
  for (const entry of parsed) {
    const stem = basename(entry.name, '.ts')
    if (!entry.className) {
      add('file', `${entry.dir}/${entry.name} 里读不到导出的扫描器类`, { file: entry.name })
      continue
    }
    if (entry.className !== stem) {
      add('file', `${entry.dir}/${entry.name} 导出的类叫 ${entry.className}，类名应与文件名一致`, {
        file: entry.name
      })
    }
    const imported = imports.get(entry.className)
    if (!imported || imported.module !== stem || imported.dir !== entry.dir) {
      add('file', `${entry.dir}/${entry.name} 没有被 registry.ts 导入（孤儿扫描器文件，永远不会被扫描）`, {
        file: entry.name,
        category: entry.category
      })
    }
  }
  for (const className of registered) {
    if (!byClass.has(className)) {
      add('file', `createScanners() 实例化了 ${className}，但 scanners/{cli,vscode} 下找不到同名文件`, {
        category: null
      })
    }
  }
  for (const className of instantiatedAnywhere) {
    if (imports.has(className) && !registered.includes(className)) {
      add('file', `${className} 在 registry.ts 的 createScanners() 之外被 new 出来，它等于没注册`, {
        category: (byClass.get(className) || {}).category || null
      })
    }
  }

  // 3~5. 逐扫描器
  const report = new Map()
  for (const entry of parsed) {
    const stem = basename(entry.name, '.ts')
    const testName = `${stem}.test.ts`
    const hasTest = existsSync(join(entry.abs, '..', testName))
    if (!hasTest) {
      add('test', `${entry.dir}/${stem} 没有同名测试 ${testName}`, {
        file: entry.name,
        category: entry.category
      })
    }

    let categoryOk = Boolean(entry.category)
    if (entry.category) {
      const expectedDir = CATEGORY_DIR[entry.category]
      if (expectedDir === undefined) {
        categoryOk = false
        add('category', `分类 ${entry.category} 没登记目录约定，请先在本脚本的 CATEGORY_DIR 里定它属于哪一族`, {
          category: entry.category,
          file: entry.name
        })
      } else if (expectedDir !== entry.dir) {
        categoryOk = false
        add(
          'category',
          `${entry.category} 放在 ${entry.dir}/，但它属于 ${expectedDir}/（数据布局不同，实现手法也不同）`,
          { category: entry.category, file: entry.name }
        )
      }
      const short = stem.replace(/Scanner$/, '')
      const norm = (s) => s.toLowerCase()
      const named =
        FILE_STEM_ALIASES[entry.category] === short ||
        norm(entry.category).startsWith(norm(short)) ||
        norm(short).startsWith(norm(entry.category))
      if (!named) {
        categoryOk = false
        add('category', `${entry.dir}/${entry.name} 的文件名与分类 ${entry.category} 对不上`, {
          category: entry.category,
          file: entry.name
        })
      }
    } else {
      add('category', `${entry.dir}/${entry.name} 没有 readonly category 字段，注册表无从认领它`, {
        file: entry.name
      })
    }

    const methods = methodsOf(entry)
    const missing = REQUIRED_METHODS.filter((m) => !methods[m])
    if (missing.length > 0) {
      add('impl', `${entry.className ?? stem} 没实现 ${missing.join(' / ')}`, {
        file: entry.name,
        category: entry.category
      })
    }
    for (const marker of entry.placeholders) {
      add('impl', `${entry.dir}/${entry.name} 里还有占位实现痕迹：${marker}`, {
        file: entry.name,
        category: entry.category
      })
    }

    report.set(entry.category ?? `#${entry.name}`, {
      category: entry.category,
      className: entry.className,
      file: relative(ROOT, entry.abs),
      dir: entry.dir,
      testFile: `${entry.dir}/${testName}`,
      inheritedFrom: entry.parent,
      methods,
      checks: {
        registered: registered.includes(entry.className),
        test: hasTest,
        category: categoryOk,
        impl: missing.length === 0 && entry.placeholders.length === 0
      }
    })
  }

  // 分类在 types.ts 里声明了，磁盘上却没有对应扫描器文件
  for (const category of expectedCategories) {
    if (!report.has(category)) {
      report.set(category, {
        category,
        className: null,
        file: null,
        dir: null,
        testFile: null,
        inheritedFrom: null,
        methods: { scan: false, delete: false, cleanAll: false },
        checks: { registered: false, test: false, category: false, impl: false }
      })
    }
  }

  // 行序 = 侧栏分类序；不属于任何已声明分类的孤儿扫描器接在后面（它们已经报过错了）
  const rows = [
    ...expectedCategories.map((category) => report.get(category)).filter(Boolean),
    ...[...report.values()].filter((row) => !expectedCategories.includes(row.category))
  ]
  return { ok: problems.length === 0, problems, scanners: rows, meta: { expected: expectedCategories.length } }
}

// ───────────────────────────────────────────────────────────── 输出

function line(ok, text) {
  return `  ${ok ? '✓' : '✗'} ${text}`
}

function plural(n, one) {
  return `${n} 个${one}`
}

function printHuman({ ok, problems, scanners, meta }) {
  const total = scanners.length
  const byDir = (dir) => scanners.filter((s) => s.dir === dir).length
  const detail = (key) => `${scanners.filter((s) => s.checks[key]).length}/${total}`
  const countOf = (check) => problems.filter((p) => p.check === check).length

  console.log(`扫描器完整性检查 — ${meta.expected} 个分类 / ${total} 个扫描器文件`)
  console.log('')

  console.log('[1] 注册表完整性')
  console.log(
    line(
      countOf('registry') === 0,
      `SCANNER_CATEGORIES ${meta.expected} 个分类 ↔ createScanners() ${detail('registered')} 实例，一一对应（不缺失 / 不重复 / 不多余）`
    )
  )
  console.log(
    line(countOf('contract') === 0, 'SCANNER_CATEGORIES 仍由 AGENT_CATEGORIES 派生（本脚本的解析前提成立）')
  )

  console.log('[2] 扫描器文件 ↔ 注册表')
  console.log(
    line(
      countOf('file') === 0,
      `cli/ ${byDir('cli')} 个 + vscode/ ${byDir('vscode')} 个，均被 registry 导入，无孤儿文件、无在外处 new 出来的`
    )
  )

  console.log('[3] 测试覆盖')
  console.log(line(countOf('test') === 0, `同名 XxxScanner.test.ts 齐备：${detail('test')}`))

  console.log('[4] 分类字段 ↔ 目录 / 文件名')
  console.log(line(countOf('category') === 0, `category 与所在目录、文件名一致：${detail('category')}`))

  console.log('[5] 实现完整性')
  console.log(
    line(countOf('impl') === 0, `scan / delete / cleanAll 齐备且无占位实现：${detail('impl')}`)
  )
  const withParent = scanners.filter((s) => s.inheritedFrom)
  if (withParent.length > 0) {
    console.log(`    （${withParent.map((s) => `${s.className} ← ${s.inheritedFrom}`).join('，')} 走继承，已沿 extends 链核对）`)
  }

  console.log('')
  console.log('分类明细（每行 4 个标记：注册 / 测试 / 分类一致 / 实现完整）')
  for (const s of scanners) {
    const mark = (key) => (s.file ? (s.checks[key] ? '✓' : '✗') : '✗')
    const parts = [`  ${mark('registered')}${mark('test')}${mark('category')}${mark('impl')} ${s.category ?? '?'}`]
    if (s.file) {
      parts.push(`${s.dir}/${basename(s.file)}`)
      if (s.testFile) parts.push(`测试 ${basename(s.testFile)}`)
      if (s.inheritedFrom) parts.push(`实现继承自 ${s.inheritedFrom}`)
    } else {
      parts.push('（scanners/ 下找不到对应的 XxxScanner.ts）')
    }
    console.log(parts.join('  ·  '))
  }

  if (problems.length > 0) {
    console.log('')
    console.log('问题')
    for (const p of problems) {
      console.log(`  ✗ [${p.check}] ${p.message}`)
    }
  }

  console.log('')
  if (ok) {
    console.log(`✓ 通过：${total} 个扫描器，0 个问题`)
  } else {
    console.log(`✗ 未通过：${plural(problems.length, '问题')}`)
  }
}

const result = run()
if (process.argv.includes('--json')) {
  console.log(JSON.stringify({ ok: result.ok, problems: result.problems, scanners: result.scanners }, null, 2))
} else {
  printHuman(result)
}
process.exit(result.ok ? 0 : 1)
