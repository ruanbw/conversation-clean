# 迁移说明：Swift → Electron 移植中的刻意偏差与已知问题

> 这份文档记录**所有**「不是照抄，而是有意为之」的地方，以及照抄下来的 Swift 缺陷。
> 目的有两个：
> 1. 机械移植里最容易丢的就是「这里为什么不一样」，写下来才不会被下一个人「顺手修掉」。
> 2. 评审时能一眼看出哪些是移植引入的、哪些是 Swift 原本就有的。
>
> 记号：
> - **[照抄]** = Swift 原本的缺陷/怪癖，刻意保留。**不要在移植里修**。
> - **[刻意]** = 有意与基准不同，附理由。
> - **[已修]** = 移植过程中发现并修掉的真 bug。

---

## 一、基建的真 bug（已修）

### 1. `prefs.ts` —— 合法 JSON 字面量导致 IPC 整条挂死 [已修]

`preferences.json` 的内容如果**完全合法但是个字面量**（`null` / `42` / `"x"` / `[]`），
`JSON.parse` 不抛错，于是后面的 `parsed[key]` 抛 `TypeError`。
现象是只要这个文件被写成 `null`（半写入、被别的工具覆写），每次 `CleanPrefs.all()` 都抛，
整条 `prefs:get` IPC 全挂。

修法：`read()` 在解码后加一道「必须是非 null 的对象」的类型闸门，不合格就回落 `DEFAULT_PREFS`。

### 2. `datetime.ts` —— 带时区偏移的 ISO 时间戳被形状判断挡掉 [已修]

第一版的 `FRACTIONAL` 正则结尾只允许 `Z?`，不接受 `+08:00`。
而 Swift 侧用的是 `ISO8601DateFormatter([.withInternetDateTime, .withFractionalSeconds])`，
`.withInternetDateTime` 自带 ±HH:MM，是**接受**数字偏移的。
代价是：任何记录本地时区偏移的 Agent，整条会话的 `updatedAt` 会丢失。

修法：两条正则的时区部分统一成 `Z|[+-]\d{2}:?\d{2}`，同时保持「非 ISO 形状一律 null」
（不能因为放宽就把 epoch 毫秒、`not a date` 放进来）。

### 3. `prefs.ts` 写进用户 HOME [已修]

兜底路径（`app` 不可用时）原本把偏好文件写到 `~/.conversation-clean/preferences.json`。
单元测试跑一次就在用户真实 HOME 里留一个文件，且不同用例会互相干扰。
修法：新增 `CONVERSATION_CLEAN_DATA_DIR` 环境变量 + `CleanPrefs.__resetForTests()`，
测试不必再 `vi.mock('electron')`。顺带给「便携安装」留了口子。

---

## 二、基建层与基准的刻意偏差

### 4. `vscdb.ts` 数组删空时删 key，Swift 写回空数组 [刻意]

`cleanAgentSessionsCache` / `cleanComposerData` / `cleanAiChatData` 在数组被删空时
**删除整个 ItemTable key**，Swift 版是写回一个空数组。

理由：两条路径对 IDE 行为等价（缺 key 与空数组都读作「无会话」），而删 key 更干净
（`VACUUM` 之后文件真的变小）。保留 TS 行为，测试里已显式标注此差异。
`vscdb.test.ts` 有专门一组断言盯住它，改动前先看那里。

### 5. `CleanConfirmSheet` 的目标集合钉在 `estimateCategory` [刻意]

Swift 版读的是**活的** `filteredConversations`，所以确认面板开着的时候切分类，
面板算出来的「预计释放」会跟着变 —— 用户在弹层上看着一个数，点确认删的却是另一批。

TS 版用 `cleanStore.getCleanTargets({ ...state, selectedCategory: state.estimateCategory })`
把分类钉在打开弹层那一刻。这是**修掉**了一个真实缺陷，而不是抄 bug，
所以它不在这份文档的「照抄」清单里，但要知道这里有意不同。

---

## 三、照抄下来的 Swift 缺陷（不要在移植里修）

### Claude Code

- **[照抄]** `removeAllSessionsIndices` 在 `projects/` 不存在时早退，
  导致根目录的 `sessions-index.json` 漏删。
- **[照抄]** `sessions-index.json` 的数组元素若缺 `sessionId` / `id` 字段，
  会被**一并丢弃**（`sid.isEmpty` 就当没匹配上）。
- **[照抄]** `cleanSingleSessionsIndex` 即使一条都没裁掉，也会重写整个文件。
- **[照抄]** `plans` / `session-env` 不在 `CleanPrefs` 的快照目录名单里，
  所以「同时清理文件历史快照」关掉时它们照删。
- **[刻意]** `readJsonLinesHead` 会跳过解析失败的行，因此「读前 51 行」的上限
  按**有效行**计，而不是物理行。Swift 的 `enumerateLines` 同样跳过失败行，但计数方式不同。
- **[刻意]** 写文件用「隐藏临时文件 + rename」对应 Swift 的 `.atomic` 写选项。

### Zed AI

- **[照抄]** `delete` 刻意**绕开** `deleteItemsWithPaths`。走通用流程会把
  `threads/threads.db` 当成关联路径删掉 —— 那是整个线程库的本体。
  改用 `hasPhysicalFile` 决定是否只发一条 `DELETE FROM threads WHERE id=?`。
- **[照抄]** 会话名用「包含」匹配关联，误挂 `session-1` ↔ `session-10`。
- **[照抄]** SQLite 行的 summary 会 `trim`，文件会话的标题不 `trim`。
- **[照抄]** Zed 与 OpenHands 都**不**回收空目录，所以设置里的「回收空项目目录」
  对这两款 Agent 完全无效。测试已把这个无效性钉住。
- **[刻意]** `listFiles` / `listDirectories` 会跳过隐藏项（移植规范要求），
  Swift 的 `contentsOfDirectory` 不过滤。这是全应用统一的目录枚举行为。

### OpenHands

- **[照抄]** `OPENHANDS_HOME` 这一条分支**不做** realpath 规范化（另外两条分支做）。
- **[照抄]** `isSafeToDelete` 的路径白名单用 `isInside`（要求严格的父子关系），
  比 Swift 的 `hasPrefix` 严一档：根目录本身不会被判为可删。

### VS Code 系（VS Code Chat / Cursor / Windsurf / Trae）

- **[照抄]** Trae 的 `cleanAll` 里，globalStorage 缓存清理跑在
  `emptyWindowChatSessions` 重建**之后**，而该目录名含 "chat"，会被再删再重建一次
  （第二次 size 已经是 0，所以只是多一轮 IO，不影响正确性）。
- **[照抄]** Antigravity 判定「活跃会话」的兜底 id 是硬编码 UUID，真实在用时拦不住。
- **[照抄]** Windsurf 在注入目录下若找不到 `.codeium/windsurf`，路径会回落到**真实的**
  `~/.codeium/windsurf`。测试夹具必须显式造出该目录，否则会去读用户真实数据。
- **[照抄]** Cursor 的 JSONL 来源与 `state.vscdb` 索引来源之间**不去重**，
  同一条会话会以两条独立记录出现。列表里看着像重复，其实两条元数据来源不同。
- **[照抄]** `clearStateDatabaseChatData` 在 Swift 里本来就是死代码，TS 版原样保留。
  **不要**以为是移植搞出来的。
- **[照抄]** Cursor 的 JSONL 解析比 Copilot 少一条「顶层 `requests` 兜底」——
  Swift 侧这两个扫描器本来就不一致。
- **[刻意]** Antigravity 的 `conversation_summaries.db` 是关系表而非
  VS Code 的 `ItemTable` key-value 结构，`core/vscdb.ts` 的封装复用不了，
  因此该扫描器内部直接用 `openReadOnly` / `openReadWrite` + `node:sqlite`。
- **[刻意]** `parseStateDatabase` 的纯 JSON 兜底在文件确为 SQLite 时跳过，
  避免把几十 MB 二进制当 JSON 读。行为与 Swift 等价。
- **[刻意]** Swift 的 `withTaskGroup` 并发解析在 TS 里退化为同步循环（纯 CPU，结果一致）。

### Codex / Cline / Roo Code / Continue / OpenViking / Aider

- **[照抄]** Codex `cleanAll` 里第二次（幂等的）`cleanGlobalState` 调用照留。
- **[照抄]** Codex 索引行认不出 id 时**保留**该行（宁可留残，不可误删）。
- **[照抄]** Cline / Roo Code 的 `as? [[String: Any]]` 语义：数组里只要有**一个**非字典元素，
  整份索引就跳过不处理。
- **[照抄]** Codex 没有快照目录，所以「同时清理文件历史快照」开关对它无影响。
- **[照抄]** Continue 数字串 `dateCreated` 没有 `> 0` 判断（`"0"` → 1970 年）。
- **[照抄]** Aider 存储目录内**任意文件名**都算可删（前缀比较而非路径分量比较）。
- **[照抄]** Aider 的 `~/.aider` 有内容时它本身就在 `associatedPaths` 里，`delete` 已经删掉，
  `cleanAll` 不再重建。
- **[照抄]** OpenViking 的 `createdAt` 阈值（1e12 / 1e9）与其他扫描器不同；
  `cleanAll` **不走** scan+delete，而是直接清空并重建 `pending/`。
- **[照抄]** Roo Code 在 Swift 里就是 `ClineScanner` 的子类（只覆写三个成员），
  TS 版同样用继承，扫描/删除/索引同步全部复用，不重复实现。
- **[刻意]** Continue 的递归枚举加了 **12 层深度上限**，Swift 无上限。
  理由：用户目录里可能有符号链接环，无上限会把整次扫描挂死。
- **[刻意]** Aider 的 `sessionId` 短哈希用**确定性 FNV-1a**。
  Swift 的 `hashValue` 每进程换种子，会让同一会话在不同启动间 id 漂移，
  导致「上次的勾选这次对不上」。这是**修 bug**，不是抄。

### Pi Agent

- **[照抄]** 超过 512KB 的会话文件把「换行数」当「消息数」累加（粗糙近似）。
- **[照抄]** context-mode 删行后**不** `VACUUM`（Swift 也没有）。
- **[照抄]** Pi 的 `associatedPaths` 天然不含 `checkpoints` 等快照目录名，
  所以「同时清理文件历史快照」开关在真实布局下对 Pi 基本无效果。
- **[照抄]** `detectedTimestamp` 无条件赋值：后续行解析失败会**抹掉**先前解析出的时间戳。
- **[刻意]** `scan()` **不打开任何 SQLite**。任务书里曾要求「预索引 context-mode 索引读取」，
  但核对 Swift 后确认 `scan()` 只做 `preIndexTasks()`、全程零 SQLite 访问，
  因此**没有**在扫描阶段新造索引读取。**任务书写错了，以源码为准。**

### 统一枚举跳过隐藏项 [全局刻意偏差]

`listFiles` / `listDirectories` 会跳过 `.` 前缀项，Swift 的 `contentsOfDirectory` 不过滤。
这是全应用统一的目录枚举行为（避免把 `.DS_Store`、`.git` 当成会话目录）。
Zed / OpenHands 因此与 Swift 存在可观察差异，已在各自小节标出。

---

## 四、一条方法论备注

移植过程中任务书写错了一条（要求 Pi Agent 在 `scan()` 里预索引 context-mode 的 SQLite 索引）。
实现代理 grep 完全仓后发现 Swift 版 `scan()` 从不打开 SQLite，**拒绝执行该指令**并照抄了真实行为。

这正是机械移植该有的样子：**任务书是需求，源码是事实，两者冲突时以源码为准，并把冲突报回来。**
任何后续修改 Agent 能力的描述，都应该先 grep 源码，不要照抄别处的文档。

---

## 五、渲染进程的刻意偏差

### DetailView 的「项目路径」行 [刻意 · 已知待改回]

当前实现用 `pathTail` 显示缩写（`…/a/b`），完整值放在 `title` 上。
**Swift 版是全路径换行显示。** 这是移植过程中自行做的主观优化，
按「不顺手优化设计」的铁律应当改回。复制按钮仍应复制完整路径。
→ 集成阶段统一改回 `DetailView.tsx`。

### 图标在三处重复内联 [刻意 · 集成时收敛]

`DetailView` / `OverviewView` / `SettingsView` 各自内联画了一份 1.5px 描边的小图标
（Folder / Trash / X 等），原因是移植时 `components/DrawnControls.tsx` 尚未落地，
import 它会让 typecheck 变红。

正确做法是等 `DrawnControls` 导出完整图标集后统一复用。
→ 集成阶段收敛。判断依据：三个文件里出现重复的 `path` / `strokeWidth` 字面量。

### 确认弹层的读数字号 [已修 token]

26px 的主读数、9px / 10px 的徽标字号在 `tokens.css` 里原本没有对应档位，
组件里只能现算。已补三个 token：
`--text-hero-readout: 26px`、`--text-badge-small: 9px`、`--text-badge-tiny: 10px`。
组件里应改用 token 而不是 `calc()`。

### 确认弹层的警示色 [已修 token]

「量级」徽标（微小 / 有限 / 显著三档）的中间档原本回落到了 `--danger`（红），
语义不对。已补 `--warning` / `--warning-soft`。

### 卷容量 IPC 通道 [已补]

Swift 版的确认弹层读 `URLResourceValues` 的 `volumeTotalCapacityKey` /
`volumeAvailableCapacityForImportantUsageKey` 拿真实卷信息，
渲染初版没有对应通道，导致「占卷总容量」行与整个「卷占用」节不渲染。
已补 `IPC.volumeInfo` + `core/volume.ts`（`fs.statfsSync` + 沿路径上溯找挂载点 + `diskutil` 取卷名）。

**口径说明**：Swift 优先用 `...ForImportantUsage`（与 Finder「可用空间」同口径，已扣 purgeable），
Node 无对应字段，退回 `bavail`。`bavail` 比 `bfree` 保守（不含 root 保留块），方向上安全。

---

## 六、Swift 版遗留、本次未移植的东西

- `ConversationClean.xcodeproj` / Swift 源码 / `scripts/run_tests.sh` /
  `scripts/tests/*.swift` **原样保留在仓库里**，作为行为基准与对照，不是死代码。
  删不删是产品决定，不是移植决定。
- App Sandbox 的 `.entitlements` 概念在 Electron 下不存在，改为
  `contextIsolation: true` + `nodeIntegration: false` + `sandbox: false`
  （ESM preload 需要）+ preload 白名单 + 渲染进程 `Content-Security-Policy`。
- Swift 版的 `@AppStorage` → `localStorage`（渲染进程）/ `preferences.json`（主进程）。
- App 图标从 asset catalog 用 `iconutil` 合成 `build/icon.icns`（仍复用原 512@2x 资源）。
