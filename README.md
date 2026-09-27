# ConversationClean (macOS)

基于 **Electron 44 + React 19 + TypeScript 5.9** 构建的 macOS 应用，用于扫描并清理本机各类 AI 编码 Agent / IDE 遗留的会话数据。

<img src="docs/app-screenshot.png" alt="ConversationClean 主界面：左侧为 Agent 分类与工具，中间为可搜索、可排序的会话列表，右侧为选中会话的元数据" width="900">

<sub>真实运行截图，会话标题 / 项目路径 / 会话 ID 等内容已做马赛克处理。</sub>

---

## 🌟 项目特性

- **15 款 Agent 全覆盖**：统一 `AgentScanner` 协议接入 CLI Agent（Claude Code、Codex、Pi Agent、Cline、Roo Code、Continue、OpenViking、Aider、Zed AI、OpenHands）与 VS Code 系 IDE（Copilot / VS Code Chat、Cursor、Windsurf、Trae、Antigravity）。未安装的 Agent 也照列，只是置灰 —— 装没装是运行时的事，不该写进模型里。
- **双层索引原子清理**：对同时维护「会话文件 + SQLite 索引」的 Agent（VS Code 系 `state.vscdb`、Copilot `session-store.db`、Pi Agent context-mode、Claude Code `sessions-index.json`），删会话时同步裁剪索引。只删正文、留着索引行，Agent 侧就会留下一批永远查不到的幽灵会话 —— 那比不删还糟。
- **全自绘 UI**：隐藏标题栏 + 手搓三栏（`App.tsx`），红黄绿浮在自有背景上。列表、勾选框、按钮、分段器、搜索框、空态、开关、图标全部自绘，只保留原生 `<button>` / `<input>` 作交互原语并在 CSS 里剥掉系统外观 —— 换成 `div onClick` 会同时失去键盘可达、焦点环与语义角色，那是拿可用性换一张皮。SF Symbols 在 Electron 里不存在，全部换成 1.6px 描边的自绘 SVG。
- **设计系统 token 化**：色彩、间距、圆角、排版集中在 `styles/tokens.css`，那里是全应用**唯一**允许出现颜色与字号字面量的地方。8pt baseline grid、正文 13px（macOS 真实值，不是 iOS 的 17px），深浅色用 `light-dark()` 一处切换。
  - 档位不是随手取的：详情栏大号读数用 **21px 而不是 22px** —— 栏宽更大，同号数字显得小一号；确认弹层 26px，因为弹层更宽、那是整个面板唯一需要抢眼的东西。分布色阶是**同一 hue（250°）的明度阶梯**而不是彩虹：相邻段亮度差 ≥12% 保证可区分，同 hue 保证堆起来是一族颜色而不是一串语义不明的色块。
- **三栏表面梯 + 可拖拽**：侧栏 / 列表 / 详情栏分属四级不同底色（`--sidebar` / `--bg` / `--surface` / `--sunken`），不再是三块同色白板拼贴。两条分隔条可拖动并记忆列宽，上限随窗口宽度**动态收窄** —— 固定 max 会拼出「窗口 1000px 时列表 760 + 侧栏 420，剩下不够详情栏 minWidth」的挤变形破图。
- **键盘可达**：⌘R 扫描、⌘Delete 清理、⌘F 聚焦搜索、↑↓ 移动选中、Esc 逐级清空（先清搜索词，再清勾选）。原生 `keyboardShortcut` 在 Electron 里不存在，全部在 `App.tsx` 手写 `keydown`。⌘F 的语义是「请把搜索框拉到焦点」而不是「当前是否聚焦」，所以它是**自增计数**不是 boolean —— 否则用户已在搜索框里时再按 ⌘F，视图收不到通知，光标也不会重新全选。
- **体积优先的信息层级**：清理工具里「多大」比「叫什么」重要，所以体积数字的视觉重量**高于**会话标题。数字列一律 `tabular-nums`，否则右对齐时会跳。
- **1024 进制**：不用 `ByteCountFormatter`（它按 1000 进制，同一条 2,411,724 字节会打成 2.4 MB，而 `du` / `df` / `ls -h` 显示 2.3 MB）。这个应用通篇在讲磁盘占用，用的必须是 1024。
- **真实数据，不演数字**：卷容量读 `fs.statfsSync` 真值 + 沿路径上溯找挂载点 + `diskutil` 取卷名；读不到就整块返回 `null`、UI 整节不渲染。宁可少一节，也不能拿一个写死的演示分母去承诺用户「清理后 91.750% 已用」。
- **并发扫描，串行删除**：`registry.ts` 用 `Promise.all` 调度 15 个扫描器并逐个 `catch`，一个 Agent 挂掉不能拖垮整次扫描；但删除是串行的 —— 多个扫描器同时删磁盘上同一批目录会互相干扰，收益远小于风险。

---

## 🛠️ 技术栈与架构

**三段进程。** `src/main/` 持有全部 IO（扫描、删除、偏好、卷容量、shell），窗口是 `titleBarStyle: 'hiddenInset'` 的自绘三栏。`src/preload/index.ts` 用 `contextBridge.exposeInMainWorld` 挂 11 个白名单函数 —— 渲染进程拿不到 `ipcRenderer` 本身是刻意的，`ipcRenderer.send('anything:else')` 会是一条提权路径。`src/renderer/` 是 React 19 + `useSyncExternalStore`，零 Node 依赖，`index.html` 里有 `Content-Security-Policy`（禁 `eval` 与远程脚本）。

App Sandbox 的 `.entitlements` 概念在 Electron 下不存在，隔离改由 `contextIsolation: true` + `nodeIntegration: false` + preload 白名单 + CSP 承担。`sandbox: false` 是必需妥协：`electron-vite` 在 `type: module` 下把 preload 编译成 ESM（`index.mjs`），ESM preload 要关掉 sandbox 才能工作，两者必须同时改。

**扫描器协议。** `core/scanner.ts` 的 `AgentScanner` 只有 5 个成员：`category` / `isInstalled` / `storagePath` / `scan()` / `delete()` / `cleanAll()`。三条约定：`scan()` **绝不**修改任何文件，连 mtime 都不许写；`delete()` 返回的「实际释放字节数」必须走 `CleanPrefs.freedBytesBeforeDelete` 扣掉被保留的快照，否则 UI 会报一个比实际大的数；`associatedPaths` 列出这条会话真正占盘的全部路径，删除时逐条删，抛错只发生在「这个 Agent 整个不可用」时 —— 一个坏 JSONL 不该让整个分类清空。`deleteItemsWithPaths()` 收口了「逐条删 + 记账」的公共部分，十几个扫描器只写自己那部分索引清理。

**15 款 Agent 对照。** 侧栏顺序即 `AGENT_CATEGORIES` 的顺序（`all` 打头）。Cline / Roo Code / Continue 是跑在 VS Code 里的扩展，只是按数据形态归到 `cli/` 目录。

| 目录 | 分类（显示名） | 默认数据目录（`~/` 下） | 环境变量 |
|---|---|---|---|
| `cli/` | Claude Code | `.claude` | `CLAUDE_HOME` |
| `cli/` | Codex | `.codex` | `CODEX_HOME` |
| `cli/` | Pi Agent | `.pi` | `PI_HOME` |
| `cli/` | Cline | `…/Code/User/globalStorage/saoudrizwan.claude-dev` | `CLINE_HOME` |
| `cli/` | Roo Code | `…/Code/User/globalStorage/rooveterinaryinc.roo-cline` | `ROO_CODE_HOME` |
| `cli/` | Continue | `.continue` | `CONTINUE_HOME` |
| `vscode/` | Copilot / VS Code | `Library/Application Support/Code/User` | `VSCODE_USER_DATA` |
| `vscode/` | Cursor | `Library/Application Support/Cursor` | `CURSOR_HOME` |
| `vscode/` | Windsurf | `Library/Application Support/Windsurf` | `WINDSURF_HOME` |
| `vscode/` | Trae | `Library/Application Support/Trae` | `TRAE_HOME` |
| `cli/` | Aider | `.aider` | `AIDER_HOME` |
| `cli/` | OpenViking | `.openviking` | `OPENVIKING_HOME` |
| `cli/` | Zed AI | `Library/Application Support/Zed` | `ZED_HOME` |
| `cli/` | OpenHands | `.openhands`（旧版 `.open-devin`） | `OPENHANDS_HOME` |
| `vscode/` | Antigravity | `.gemini/antigravity` | `ANTIGRAVITY_HOME` |

路径一律 `realpath` 规范化一次：`/var` → `/private/var` 这类别名不解析，侧栏显示的路径会跟 Finder 里点开的不一致，删除时也会出现「文件明明存在却删不掉」。

**SQLite 索引层。** `core/vscdb.ts` 用 **Node 内建的 `node:sqlite`（`DatabaseSync`）**，不是 `better-sqlite3`：后者是原生模块，每次升 Electron 都要按新 ABI 重建；`node:sqlite` 在 Node 22.5+ 与 Electron 44（内嵌 Node 24.21）里都有，装依赖时不用管它。它覆盖 `state.vscdb` 的 8 组索引 key（`chat.ChatSessionStore.index` / `memento/interactive-session%` / `interactive.sessions` / `workbench.panel.chat%` / `agentSessions.state.cache` / `agentSessions.model.cache` / `composer.composerData` / `workbench.panel.aichat…chatdata`）与 Copilot `session-store.db` 的 6 张关系表。三条约定：扫描一律 `readOnly: true`（IDE 可能正持有这个库）；改完索引立刻 `VACUUM`（SQLite 删行不缩文件）；文件不存在或表结构不对一律静默返回 —— 索引清理是清理流程的**补充**而非前置条件，索引坏了不该让文件删除也失败。

**状态中枢。** `src/renderer/src/state/cleanStore.ts` 是全应用唯一的状态来源。三条不变量：**不缓存派生数据**（`filteredConversations` / `categoryStats` / `totalSize` 在 selector 里现算，不存在两个状态不同步的中间帧）；**派生值必须返回同一引用**，否则 `useSyncExternalStore` 认为状态一直在变，陷入无限重渲染；**搜索词 120ms 防抖**（一次全盘扫描可能有上万条会话，每敲一个键就重算全量过滤会掉帧，但防抖值优先、无防抖值才用即时值，所以「Esc 立刻清空搜索」不会慢半拍；防抖值必须是 state 而不是 store 私有字段，只通知 listener 不换快照会被 `useSyncExternalStore` 当成“没变化”而跳过重渲染）。列宽与当前分类记在 `localStorage`；4 个设置开关记在主进程 userData 下的 `preferences.json`，每次读都重新走一遍文件而不是缓存成只读值，否则运行中改开关要重启才生效。

---

## 📁 目录结构

```text
conversation-clean/
├── package.json · electron.vite.config.ts · electron-builder.yml · vitest.config.ts
├── tsconfig.json / .node.json / .web.json     # node 查主进程与 shared，web 查渲染进程与 shared
├── build/ · design-demos/ · out/               # 图标资源 / UI 设计稿 / 构建产物（release/ 打包时才生成）
├── docs/                                       # app-screenshot.png · dev-guide.md · known-issues.md · prototype.html
├── scripts/                                    # scanner-health.mjs 扫描器自检 + mosaic_readme_shot.py 截图打码
├── src/
│   ├── shared/      types.ts（16 个分类 / 字形映射 / IPC 契约）· format.ts（1024 进制格式化）
│   ├── main/
│   │   ├── index.ts · ipc.ts                  # 窗口（hiddenInset）· 全部 ipcMain.handle
│   │   ├── core/                              # 跨扫描器共享基建，各带 .test.ts
│   │   │   └── scanner.ts（协议 + 原语 + 删除标准实现）· vscdb.ts（SQLite 索引层）
│   │   │       prefs.ts（设置存储 + 快照判定）· fsutil.ts（体积 / 删除 / 空目录回收）
│   │   │       datetime.ts（ISO 解析）· volume.ts（卷容量）· agentIcons.ts（.app 图标 → dataURL）
│   │   └── scanners/  registry.ts（注册 / 并发扫描 / 串行删除）
│   │       ├── cli/                           # 10 款以 JSONL / JSON 会话文件为主
│   │       │   └── ClaudeCode · Codex · Cline · RooCode（继承 Cline）· Continue
│   │       │       PiAgent + +Parsing / +ContextMode / +ACPSessionMap
│   │       │       OpenViking · Aider · Zed · OpenHands .ts
│   │       └── vscode/                        # 5 款共享 state.vscdb 索引形态
│   │           └── VSCodeChat · Cursor（+JSONL / +StateDatabase / +DirectoryScan）
│   │               Windsurf · Trae · Antigravity .ts
│   ├── preload/     index.ts（window.api 白名单，11 个方法）
│   ├── renderer/
│   │   ├── index.html                          # 含 Content-Security-Policy
│   │   └── src/  main.tsx · App.tsx（三栏外壳 + 全局键盘）· state/cleanStore.ts（状态中枢）
│   │            styles/tokens.css · global.css
│   │            components/（DrawnControls / Splitter / AgentGlyph）
│   │            views/（Sidebar / ConversationList / Detail / Overview / Settings / CleanConfirmSheet）
│   └── test-support/                           # 夹具工厂：文件系统 + mock state.vscdb
```

视图样式一律走 **CSS Modules**（`XxxView.module.css`）：多个文件并行开发时共用全局 class 名必然撞车。颜色 / 间距 / 字号一律 `var(--token)`，值集中在 `styles/tokens.css`；渲染进程里**不许**出现裸 `<svg>` 字形，统一走 `DrawnControls` 的 `DrawnIcon` 或 `AgentGlyph.tsx`（`App.test.ts` 会 grep 并让测试失败——就地画一个 1.5px 的图标而其余都是 1.6px，这种偏差截图上看不出来）。

---

## 🚀 快速上手

```bash
npm install          # Node >= 22.5（node:sqlite 起始版本）
npm run dev          # electron-vite dev：起开发服务器并拉起 Electron
npm run build        # 打包 main / preload / renderer 三段到 out/
npm run start        # electron-vite preview：跑刚打好的产物
npm run typecheck    # node + web 两套 tsconfig 都要过
npm test             # vitest run
npm run test:watch   # vitest 监听模式
npm run port:status  # 移植状态探针：还有哪些扫描器 / 视图是占位
npm run dist         # build + electron-builder --mac --publish never → release/*.dmg
npm run dist:dir     # 同上但不封装，只出解包目录
```

`typecheck` 拆成 `typecheck:node`（主进程 / preload / shared）与 `typecheck:web`（渲染进程 / shared），两边都开了 `strict` + `noUnusedLocals` + `noUnusedParameters` + `verbatimModuleSyntax`（所以类型导入必须写 `import type`）。

---

## 🧪 测试

Vitest 5，**30 个测试文件 / 548 个用例**，全部串行（`fileParallelism: false` + `pool: 'forks'`）—— 扫描器用例会读本机真实 Agent 目录，并行跑会让 I/O 抖动把断言搞红。测试文件与被测文件同名同目录：

| 层 | 文件 | 用例 |
|---|---|---|
| 共享基建 | `core/scanner` · `core/vscdb` · `core/prefs` · `core/datetime` · `shared/format` | 63 / 33 / 26 / 21 / 30 |
| CLI 扫描器 | Aider · ClaudeCode · Cline · Codex · Continue · OpenHands · OpenViking · PiAgent(×4) · RooCode · Zed | 16 / 17 / 17 / 15 / 15 / 17 / 14 / 5+16+20 / 15 / 23 |
| VS Code 系 | Antigravity · Cursor · Trae · VSCodeChat · Windsurf | 18 / 20 / 16 / 15 / 15 |
| 渲染进程 | DrawnControls · Splitter · SidebarView · ConversationListView · DetailView · OverviewView · SettingsView · CleanConfirmSheet | 16 / 8 / 10 / 23 / 8 / 8 / 10 / 18 |

环境默认 `node`，UI 用例在文件顶部用 `// @vitest-environment jsdom` 逐个切换；夹具工厂在 `src/test-support/`。跑真实目录的用例有两个坑，改测试前先看：

1. **临时目录必须 `realpath`。** macOS 的 `tmpdir()` 给的是 `/var/folders/...`，真身是 `/private/var/folders/...`；不规范化的话扫描器返回的路径和断言里的对不上，整条 `delete()` 链路会随机红。偏好同理要用 `CONVERSATION_CLEAN_DATA_DIR` 指到临时目录，否则跑一次测试就在用户真实 HOME 里留一个文件。
2. **真实目录用例是只读的。** 每个扫描器都有一组「扫本机真实目录不抛错且不修改任何文件」的用例，目录不存在时用 `it.skipIf` / `it.skip` 跳过；它们会先给目录树打一份 `(路径, 体积, mtime)` 签名，扫完再比一次，签名变了就是回归。**必须**显式造出被测目录（比如 Windsurf 在注入目录下找不到 `.codeium/windsurf` 时路径会回落到真实的 `~/.codeium/windsurf`），否则会去读用户真实数据。

想看收集到多少用例而不执行：`npx vitest list`。

---

## ⚠️ 已知问题与刻意取舍

代码里有不少地方**看着像 bug，但改掉就错**。完整清单见 **[`docs/known-issues.md`](docs/known-issues.md)**，
开发约定与扫描器写法见 [`docs/dev-guide.md`](docs/dev-guide.md)。最值得注意的几条：

- **Zed 的 `delete` 刻意绕开 `deleteItemsWithPaths`。** Zed 的会话正文在 `threads/threads.db`（SQLite）里而不是独立文件，
  走通用流程会把整个线程库当关联路径删掉。同理 Zed 与 OpenHands 都不回收空目录，
  设置里的「回收空项目目录」对这两款 Agent 无效（测试已把这个无效性钉住）。
- **15 个扫描器没有共用一条删除流水线。** 各家 Agent 的「一条会话占哪些文件」根本不同，
  强行统一必然要么误删要么漏删。公共部分收在 `core/scanner.ts`，差异部分各写各的。
- **Cursor 的 JSONL 与索引来源之间不去重**，同一条会话会出现两条。两条的 id 不是同一个 id 空间，
  强行匹配会误合并 —— 宁可重复也不误合并。
- **确认弹层的目标集合钉在打开那一刻**（`estimateCategory`）。面板是「整类清理」语义，
  期间切分类不该改它的目标集合，否则用户在弹层上看着一个「预计释放」、点确认删的却是另一批。
- **索引数组删到不剩元素时删掉整个 `ItemTable` key**（`cleanAgentSessionsCache` / `cleanComposerData` /
  `cleanAiChatData`）。对 IDE 行为等价，而删 key 更干净 —— `VACUUM` 之后文件真的变小。
  `vscdb.test.ts` 有专门一组断言钉住它。
- **列宽上下限在 TS 与 CSS 里各有一份**，用 `App.test.ts` 逐条比对钉住。漏掉这个测试的代价是
  「改了 CSS 忘了改 TS」，而且只在手动拖窗口时偶发，测试和 typecheck 都不报。
