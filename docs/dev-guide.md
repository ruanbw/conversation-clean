# 开发指南

> 写这份文档的目的是：**让下一个人不用先读完 3 万行代码就知道该在哪写、不能怎么写。**
> 架构层面的「为什么这样」在 `docs/known-issues.md`，视觉基线在 `design-demos/ui-a-precision.html`。

---

## 1. 三段结构与各自的权限

```
src/main/        Electron 主进程。有完整 Node 权限。所有文件 IO、SQLite、删除都在这里。
src/preload/     预加载桥。白名单 11 个方法，contextIsolation 下暴露为 window.api。
src/renderer/    React 渲染进程。**没有任何 Node 权限**。
src/shared/      三段共用的类型契约与纯函数。
```

**渲染进程的硬约束**（违反会在 review 被打回）：

- 不许 `import` 任何 `node:*` 或 `electron`
- 不许 `dangerouslySetInnerHTML`（`index.html` 里有 CSP）
- 不许裸 hex 与 px 字号 —— 全部 `var(--token)`
- 需要主进程能力时：先在 `src/shared/types.ts` 的 `RendererApi` 加签名 →
  在 `src/main/ipc.ts` 加 handler → 在 `src/preload/index.ts` 挂上。
  **不要**在渲染进程里找变通。

## 2. 命令

```bash
npm install
npm run dev            # electron-vite dev（渲染进程热更新）
npm run build          # 三段产物到 out/
npm run typecheck      # node + web 两套 tsconfig 都要过
npm test               # vitest 全量
npm run test:watch
npm run dist           # 打包 dmg（需签名配置，见 electron-builder.yml）
npm run check:scanners # 扫描器完整性自检
```

**验收线：`npm run typecheck` 与 `npm test` 都必须绿。** 只写代码不验证 = 没做完。

## 3. 铁律

1. **不删功能。** 减少一个已有行为必须在 PR 里说清理由。
2. **不"顺手优化"。** 遇到看着别扭的地方，先查 `docs/known-issues.md` ——
   那里大半的"丑"都是刻意的。
3. **不写裸样式。** 颜色 / 间距 / 字号一律 `var(--token)`，值在 `styles/tokens.css`。
   需要新档位就往 `tokens.css` 加，并在同处写清为什么现有档位不够。
4. **不新增依赖**（除非要先在 PR 里论证）。
5. **`scan()` 绝不落盘。** 扫描是只读操作，连 mtime 都不许写。
   写测试时用「scan 前后目录树 size+mtime 快照一致」来证明这一点。
6. **类型导入用 `import type`。** 开了 `verbatimModuleSyntax`，值导入和类型导入必须分开。
7. **共享契约只改 `src/shared/`。** 想在别处另立一份结构相同的 interface 是重犯。

## 4. 样式：必须用 CSS Modules

每个组件配一个同目录的 `XxxView.module.css`，在 tsx 里 `import styles from './XxxView.module.css'`。

- **禁止**全局样式（`:global`、裸 class 写在非 module 文件里）。
  真的需要全局的（`body`、滚动条、token）已在 `styles/global.css`。
- CSS Modules 的类名按文件生成，把 A 文件的类写进 B 文件虽然能跑，
  但读代码的人会去错误的文件里找定义。
- 控件几何尺寸（图标 14/16px、开关 30×17 之类）可以用 px；
  颜色与字号不行。

## 5. 写一个扫描器

`core/scanner.ts` 里的 `AgentScanner` 协议：

```ts
interface AgentScanner {
  readonly category: Exclude<AgentCategory, 'all'>
  readonly isInstalled: boolean
  readonly storagePath: string
  scan(): Promise<ConversationItem[]>
  delete(items: ConversationItem[]): Promise<number>
  cleanAll(): Promise<number>
}
```

模板：

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
    // 环境变量 > 默认目录；resolveStoragePath 内部做 realpath 规范化
    this.root = options.storagePath ?? resolveStoragePath(['.xxx'], { key: 'XXX_HOME' })
  }

  get storagePath(): string { return this.root }
  get isInstalled(): boolean { return isDirectory(this.root) }

  async scan(): Promise<ConversationItem[]> { /* ... */ }
  async delete(items: ConversationItem[]): Promise<number> {
    // 第二参数是「文件删完之后」做索引同步 / 空目录回收
    return deleteItemsWithPaths(items, (ids) => { /* ... */ })
  }
  async cleanAll(): Promise<number> { /* 通常 scan() + delete() + 额外目录 */ }
}
```

**注册**：在 `scanners/registry.ts` 的 `createScanners()` 里加一行，**并保持与侧栏顺序一致**。
漏注册会有 `check:scanners` 报出来。

**测试**：`XxxScanner.test.ts` 放在同级。夹具自包含 ——
用 `src/test-support/fixtures.ts` 的 `useTempDir()` 在 `os.tmpdir()` 下现造，
不要读用户真实目录（除非是显式的「real」只读冒烟用例，且只断言不修改）。

```ts
import { useTempDir, writeJsonLinesFile } from '../../test-support/fixtures'
const root = useTempDir('cc-xxx-')   // 自动 afterEach 清理
```

## 6. 已知的坑

- **`Int64` 溢出**：JS `number` 只精确到 2^53。会话体积远小于此，
  但**不要**用 `| 0` 或位移做算术。
- **目录枚举顺序**：`readdirSync` 不保证顺序。`scan()` 末尾一律 `sortByUpdatedDesc()`。
- **跳过隐藏项**：`listFiles` / `listDirectories` 已处理；
  手写 `readdirSync` 时要自己加 `!name.startsWith('.')`。
- **符号链接**：`sizeOfPath` 用 `lstat`（不跟随），与其它地方用 `stat` 不同。
- **`node:sqlite` 是同步 API**：扫描大库会阻塞事件循环。
  `state.vscdb` 通常几 MB 可接受，但**不要**在一次 `scan()` 里反复开关同一个库。
  扫描一律 `readOnly: true` 打开（IDE 可能正持有该库）。
- **`CleanPrefs` 在测试里会写文件**：不设 `CONVERSATION_CLEAN_DATA_DIR` 的话会写到
  `$HOME/.conversation-clean/`。在 `beforeAll` 设一次，或用 `CleanPrefs.__resetForTests(dir)`。
- **测试里不能 `import` 顶层 electron 依赖**：`core/prefs.ts` 有 try/catch 兜底，
  但更干净的做法是用上面的环境变量 / `__resetForTests`。
- **文件名里的 `+` 号**：截图打码脚本的坐标曾因差 2pt 泄漏真实数据。
  任何「不可逆」的操作都要 1:1 放大复核，不能只看缩略图。

## 7. 并行开发时的文件所有权

多代理并行时按**文件**划分所有权，不要按功能。
共享契约（`src/shared/`、`core/`、`registry.ts`、`tokens.css`、`cleanStore.ts`）
由一个人统一改，其它人只读 —— 否则会出现"两份都改了一半"的中间态。
