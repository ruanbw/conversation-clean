# ConversationClean：Swift → Electron + React + TypeScript 移植规范

> 所有移植任务共读这一份。**开工前先读完，不要边写边猜。**
> Swift 源码留在仓库里作为唯一的行为基准（`ConversationClean/`，只读，不要改）。

## 0. 目录地图

| 层 | 路径 | 谁拥有 | 说明 |
|---|---|---|---|
| 共享契约 | `src/shared/` | **已完成，勿改** | 类型 + 格式化函数，主/preload/renderer 三方共用 |
| 主进程基建 | `src/main/core/` | **已完成，勿改** | 扫描器协议、prefs、fsutil、SQLite 索引层 |
| 扫描器 | `src/main/scanners/{cli,vscode}/` | 按文件分工 | 15 个扫描器，一个子代理一个文件，互不重叠 |
| 注册表 | `src/main/scanners/registry.ts` | **已完成，勿改** | 15 个扫描器的显式导入与排序 |
| 主进程入口 | `src/main/{index,ipc}.ts` | **已完成，勿改** | 窗口 + IPC |
| preload | `src/preload/index.ts` | **已完成，勿改** | `window.api` 白名单 |
| 渲染状态 | `src/renderer/src/state/cleanStore.ts` | **已完成，勿改** | 全部 UI 状态与动作 |
| 设计 token | `src/renderer/src/styles/tokens.css` | **已完成，勿改** | 唯一允许出现颜色/字号字面量的地方 |
| 渲染组件 | `src/renderer/src/{components,views}/` | 按文件分工 | |

## 1. 铁律

1. **不删功能。** Swift 版有的行为，TS 版必须有。没有就说明没移植完。
2. **不"顺手优化"。** 端口是机械翻译。发现 Swift 版有 bug 就**照抄 bug**，在 PR 描述里记一笔 —— 修 bug 是另一次改动。
3. **不引入新依赖。** 需要什么先看 `src/main/core/scanner.ts` 里的原语；真需要就在报告里说明，不要自己 `npm i`。
4. **不写颜色 / 字号字面量**（渲染进程）。一律 `var(--token)`。
5. **`scan()` 绝不落盘。** 扫描是只读操作，连 mtime 都不许写。
6. **类型用 `import type`。** 开了 `verbatimModuleSyntax`，值导入和类型导入必须分开写。

## 2. Swift → TS 映射表

| Swift | TypeScript |
|---|---|
| `struct` / `class` | `interface`（数据）/ `class`（有行为的） |
| `enum X: String` | `const X = [...] as const` + `type X = typeof X[number]` |
| `URL` | `string`（绝对路径） |
| `Date` | `Date`（主进程内）/ ISO 字符串（`ConversationItem.updatedAt`） |
| `Int64` | `number` |
| `try?` / `guard let ... else` | `try { } catch { }` / `?? default` |
| `FileManager.contentsOfDirectory(at:)` | `listDirectories()` / `listFiles()`（`core/scanner.ts`） |
| `String(format: "%.1f", v)` | `v.toFixed(1)` |
| `prefix(n)` | `slice(0, n)` |
| `async throws` | `Promise<T>`，需要失败语义时 throw |
| `withTaskGroup` | `Promise.all` 或 `mapLimit()` |
| `NSLock` + 静态 formatter | 模块级单例；`node:sqlite` / `JSON` 本身线程安全无需加锁 |
| `@AppStorage` | `localStorage`（渲染进程）/ `core/prefs.ts`（主进程） |
| `@Published` / `ObservableObject` | `useSyncExternalStore`（见 `cleanStore.ts`） |
| `@State` / `@Binding` | `useState` / props |
| `NSWorkspace.open` | `window.api.openPath()` |
| `NSWorkspace.selectFile` | `window.api.revealInFinder()` |
| `NSPasteboard` | `window.api.copyText()` |
| `Data(x.utf8).base64EncodedString()` | `Buffer.from(x, 'utf8').toString('base64')` |
| `DateFormatter` | `Intl.DateTimeFormat` 或 `shared/format.ts` |
| `ISO8601DateFormatter` | `core/datetime.ts` 的 `parseIsoDate` |
| `sqlite3` C API | `node:sqlite` 的 `DatabaseSync`（见 `core/vscdb.ts`） |
| `SF Symbols` | 自绘 SVG 字形（`components/AgentGlyph.tsx`） |
| `Color(nsColor:)` 动态色 | CSS `light-dark()`（见 `tokens.css`） |
| `SwiftUI View` + `modifier` | React 组件 + CSS Module class |
| `@State private var x = 1` | `useState(1)` |
| `Binding` / `@Binding` | props + 回调 props（不要引第三方状态库） |

## 3. 命令

```bash
npm run typecheck          # node + web 两套 tsconfig 都要过
npm run typecheck:node     # 只查主进程 / preload / shared
npm run typecheck:web      # 只查渲染进程 / shared
npm test                   # vitest
npm run dev                # 起 Electron 开发服务器
npm run build              # 打包三段（main/preload/renderer）
```

**验收线：`npm run typecheck` 与 `npm test` 都必须绿。** 只写代码不验证 = 没做完。

> 并行端口期间多个子代理同时写仓库：只验**自己负责的测试文件**
> （`npx vitest run <你的文件>`）。`npm test` 全量跑时别的文件可能是红的，
> 那不是你的问题，但你**不许去修别人的文件**。

## 3.1 渲染进程样式：必须用 CSS Modules

多个子代理同时写视图，共用全局 class 名必然撞车。所以：

- 每个组件配一个同目录的 `XxxView.module.css`，在 tsx 里 `import styles from './XxxView.module.css'`。
- **禁止**写全局样式（`:global`、裸 class 选择器写在非 module 文件里）。
  真的需要全局的（`body`、滚动条、`tokens.css`）已经在 `styles/global.css` 里了。
- 颜色 / 间距 / 字号一律用 `var(--token)`，`tokens.css` 里全都有。
- 阴影 / 模糊这类 `tokens.css` 里没有的值，允许在 module 里用 `color-mix()` 配 `var(--token)` 现算，
  但**不许**写裸 hex / px 字号。

## 4. 扫描器写作模板

```ts
import type { ConversationItem } from '@shared/types'
import type { AgentScanner, ScannerOptions } from '@main/core/scanner'
import {
  isDirectory, listFiles, listDirectories, mtimeMs, fileSize,
  makeItem, mapLimit, readJson, readJsonLines, readJsonLinesHead,
  deleteItemsWithPaths, sortByUpdatedDesc, truncate, singleLine,
  resolveStoragePath, expandTilde, CleanPrefs, sizeOfPath, removeIfExists
} from '@main/core/scanner'

export class XxxScanner implements AgentScanner {
  readonly category = 'xxx' as const
  private readonly root: string

  constructor(options: ScannerOptions = {}) {
    this.root = options.storagePath ?? resolveStoragePath(['.xxx'], { key: 'XXX_HOME' })
  }

  get storagePath(): string { return this.root }
  get isInstalled(): boolean { return isDirectory(this.root) }

  async scan(): Promise<ConversationItem[]> { /* ... */ }
  async delete(items: ConversationItem[]): Promise<number> {
    return deleteItemsWithPaths(items, (ids) => { /* 索引同步、空目录回收 */ })
  }
  async cleanAll(): Promise<number> { /* 通常是 scan() + delete() + 额外目录 */ }
}
```

`cleanAll()` 的标准写法：`const items = await this.scan(); const freed = await this.delete(items); /* 再补删快照目录 */ return freed`。

## 5. 已知的移植陷阱

- **`Int64` 溢出**：JS 的 `number` 只精确到 2^53。会话体积远小于此，但**不要**用 `| 0` 或 `<<` 做位移。
- **目录枚举顺序**：`readdirSync` 的顺序不保证。`scan()` 末尾一律 `sortByUpdatedDesc()`。
- **`FileManager` 的 `skipsHiddenFiles`**：Swift 版靠枚举选项跳过点文件，Node 版没有这个选项 —— 必须自己 `!name.startsWith('.')` 过滤（`listFiles` / `listDirectories` 已处理，手写 `readdirSync` 时要自己加）。
- **符号链接**：`statSync` 跟随软链，`lstatSync` 不跟。`sizeOfPath` 用 `lstat`（Swift 的 `enumerator` 默认不跟），枚举子项时要小心。
- **`node:sqlite` 的 `DatabaseSync`**：同步 API，扫描大库时会阻塞事件循环。`state.vscdb` 通常只有几 MB，可接受；但**不要**在一次 `scan()` 里反复开关同一个库。
- **CSP**：`src/renderer/index.html` 里有 `Content-Security-Policy`，禁止 `eval` 与远程脚本。组件里不要用 `dangerouslySetInnerHTML`。
