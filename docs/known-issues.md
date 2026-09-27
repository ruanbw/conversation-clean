# 已知问题与刻意取舍

> 这份文档记录**看起来像 bug、但其实是刻意为之**的地方，以及已知的粗糙近似。
> 目的：让下一个人不要「顺手优化」掉它们，也不要把它们当成待修的缺陷报上来。
>
> 记号：
> - **[取舍]** = 有意这样写，附理由。改动前先读理由。
> - **[粗糙]** = 已知不精确，当前可接受。要改请连带把测试里的对应断言一起改。
> - **[缺口]** = 确实没做，列在这里备查。

---

## 一、扫描器的「不统一」是刻意的

15 个扫描器没有共用一条删除流水线，因为**各家 Agent 的「一条会话占哪些文件」根本不同**。
强行统一必然要么误删、要么漏删。公共部分已经收在 `core/scanner.ts` 的
`deleteItemsWithPaths`，各扫描器只写自己那部分索引清理。

### Zed [取舍] `delete` 刻意不走 `deleteItemsWithPaths`

Zed 的会话正文在 `threads/threads.db`（SQLite）里，**不是独立文件**。
通用流程会把 `associatedPaths` 里的路径逐条删掉 —— 那会把整个线程库删掉。
所以 Zed 改用 `hasPhysicalFile` 判断：只有真实存在的文件才删，库本体只发一条
`DELETE FROM threads WHERE id=?` + `VACUUM`。

看到这里觉得「为什么不统一」，先读完这段再动。

### OpenHands [取舍] `delete` 也绕开通用流程

只为加一道路径白名单（`isSafeToDelete`），但白名单是**前置过滤**，
不能塞进「先记账再逐条删」的通用流程里。

### Cursor [粗糙] JSONL 来源与 `state.vscdb` 索引来源之间不去重

同一条会话会以两条独立记录出现。两条的元数据来源不同（一个来自会话文件的
`composerId`，一个来自索引的 `allComposers`），去重需要跨来源匹配 id，
而 Cursor 的 composerId 与 sessionId **不是同一个 id 空间**，
强行匹配会误合并。宁可重复也不误合并。

### Trae [粗糙] `cleanAll` 会把 `emptyWindowChatSessions` 删两次

globalStorage 缓存清理排在 `emptyWindowChatSessions` 重建**之后**，
而该目录名含 `chat`，会被前一步的规则再命中一次。第二次体积已是 0，
只多一轮 IO，不影响正确性。

### Aider [粗糙] 存储目录内任意文件名都算可删

用前缀比较而非路径分量比较。语义偏宽，但 `~/.aider*` 本来就是 Aider 自己的目录。

### Aider / Zed / OpenHands [取舍] 名称包含匹配

`session-1` 会被 `session-10` 命中。真实数据里这种前缀关系少见，
而精确匹配漏掉一条的代价比多命中一条高（用户会问「为什么这条没被列出来」）。

### Aider [取舍] `sessionId` 短哈希用确定性 FNV-1a

不用进程随机种子的哈希：否则同一个会话在两次启动之间 id 会漂移，
表现为「上次勾选过的会话这次对不上」。

### Codex [粗糙] 索引行认不出 id 时保留该行

宁可留残，不可误删。删错一行等于删掉一个用户没选中的会话。

### Cline / Roo Code [粗糙] 索引数组里有非字典元素就整份跳过

类型收窄失败即放弃处理该文件。`as? [[String: Any]]` 的语义，
比「逐个 try 解析」更安全：Agent 正在写文件时可能读到半截结构。

### OpenViking [粗糙] `createdAt` 阈值与其他扫描器不同

1e12 / 1e9 这组阈值是 OpenViking 自己的格式决定的。统一成别的扫描器的阈值会解析错。

### OpenViking [粗糙] `cleanAll` 不走 scan + delete

直接清空并重建 `pending/`。它的目录结构简单，扫描一遍反而多一次读盘。

### Zed / OpenHands [缺口] 不回收空目录

所以设置里的「删除会话后自动移除空项目目录」对这两款 Agent 无效。
真要支持得给它们补 `cleanEmptyDirectories` 调用。

### Pi Agent

- [粗糙] 超过 512KB 的会话文件把「换行数」当「消息数」累加。
- [粗糙] context-mode 删行后不 `VACUUM`（SQLite 不会自动缩文件）。
- [粗糙] `detectedTimestamp` 无条件赋值：后续行解析失败会抹掉先前解析出的时间戳。
- [缺口] `associatedPaths` 天然不含 `checkpoints` 等快照目录名，
  所以「同时清理文件历史快照」开关在真实布局下对 Pi 基本无效果。
- [取舍] `scan()` **不打开任何 SQLite**。扫描是纯读文件操作，
  context-mode 索引只在删除时才写。`openReadOnly` 回查是测试在用。

### Continue [取舍] 递归枚举有 12 层深度上限

用户目录里可能有符号链接环，无上限会把整次扫描挂死。

### Windsurf [缺口] 注入目录下无 `.codeium/windsurf` 时会回落到真实 `~/.codeium/windsurf`

测试必须显式造出该目录，否则会去读用户真实数据。

### Antigravity [粗糙] 判定「活跃会话」的兜底 id 是硬编码 UUID

真实在用时拦不住。删掉活跃会话的风险由 UI 层提示承担。

### Codex / Zed / OpenHands [缺口] 部分实现不回收空目录或不做二次索引扫描

详见上方各节。

---

## 二、基建层

### `vscdb.ts` [取舍] 索引数组删到不剩元素时删整个 key

`cleanAgentSessionsCache` / `cleanComposerData` / `cleanAiChatData` 三处。
删空数组与删掉 key 对 IDE 行为等价（缺 key 与空数组都读作「无会话」），
而删 key 更干净 —— `VACUUM` 之后文件真的变小。
`vscdb.test.ts` 有一组断言专门钉住它，改之前先看那里。

### `vscdb.ts` [取舍] 索引清理对异常一律静默

文件不存在、表结构不对、JSON 形状不认识 —— 全部静默返回。
索引清理是清理流程的**补充**而不是前置条件，索引坏了不该让文件删除也失败。

唯一例外是「形状不认识就删掉整个 key」：宁可少一条，也不可留一个
永远查不到的幽灵条目。

### `fsutil.ts` [取舍] `sizeOfPath` 跳过隐藏项

目录枚举跳过 `.` 前缀项。全应用统一，避免把 `.DS_Store`、`.git` 算进会话体积。

### `prefs.ts` [取舍] 每次读都重走文件，不缓存成只读值

设置窗口改动不会通知主进程，缓存下来会让「运行中改开关要重启才生效」。

### `prefs.ts` [取舍] 写文件先写临时文件再 `rename`

断电 / 崩溃时不会留下半截 JSON。

### `datetime.ts` [取舍] 正则先做形状判断再交给 `Date`

很多 Agent 的时间戳是毫秒或秒级 epoch，形状判断能把它们挡在外面，
交给扫描器走 `fromEpoch` 分支。放宽正则会让脏数据混进来。

---

## 三、渲染进程

### `cleanStore.ts` [取舍] 搜索防抖值必须是 state，不能是私有字段

`useSyncExternalStore` 用 `Object.is` 比较快照，
**只通知 listener 而不换快照会被 React 当成「没变化」而跳过重渲染**。
防抖落地时必须 `set()` 出一个新快照。

曾经踩过：防抖值放在私有字段里，只 emit 一次，症状是「慢速输入时列表停在旧查询上」，
只能在视图层再补一个定时器踢一下重渲染 —— 那是把 store 的缺陷甩给视图。
现在 `debouncedSearchText` 在 state 里，`App.tsx` 不需要任何补偿。

### `cleanStore.ts` [取舍] `searchFocusRequest` 用自增计数而不是 boolean

⌘F 的语义是「请把搜索框拉到焦点」，不是「当前是否聚焦」。
用户已经在搜索框里时按 ⌘F，boolean 不会变化，视图收不到通知，光标也不会重新全选。

### `cleanConfirmSheet.tsx` [取舍] 目标集合钉在打开那一刻

面板的分类读 `state.estimateCategory` 而不是活的 `selectedCategory`。
面板是「整类清理」语义，期间切分类不该改它的目标集合 ——
否则用户在弹层上看着一个「预计释放」的数字，点确认删的却是另一批。

### `DetailView.tsx` [取舍] 项目路径显示完整值，不做 `pathTail` 缩写

会话**列表行**用 `pathTail`（只留末两级）是对的：那里空间窄，
且末段才是区分同名项目的东西。详情栏空间充足，显示全路径更好。
两处不要互相"统一"。

### `App.tsx` [取舍] 列宽上下限在 TS 与 CSS 里各有一份

CSS 变量在 JS 里读不到（除非运行时 `getComputedStyle`，那会多一次强制重排，
而这几个数字是静态的），所以 `COLUMN_LIMITS` 与 `tokens.css` 的 `--col-*`
必然是同一组数字的两次表示。

既然无法合并，就用**测试钉住**：`App.test.ts` 逐条比对两边，
漂了就红。漏掉这个测试的代价是「改了 CSS 忘了改 TS，分隔条实际能拖到的位置
和 CSS 声明对不上」，而且只在手动拖窗口时偶发，测试和 typecheck 都不报。

### 渲染进程不允许的事

- 禁止 `import` 任何 `node:*` 或 `electron`（`contextIsolation: true`）
- 禁止 `dangerouslySetInnerHTML`（有 CSP）
- 禁止裸 hex 与 px 字号 —— 全部 `var(--token)`（`tokens.css`）
- 视图样式一律 CSS Modules，不用全局 class
- 禁止裸 `<svg>` 字形：统一走 `DrawnControls` 的 `DrawnIcon` 或 `AgentGlyph.tsx`。
  `App.test.ts` 会 grep 渲染进程里的裸 `<svg` 并让测试失败 ——
  就地画一个 1.5px 的图标而其余都是 1.6px，这种偏差截图上看不出来。

---

## 四、待定夺（没结论，列出备查）

这几处代码本身没错，但**当初为什么这么写已经无法从代码里读出来了**。
处理原则：**不擅自改行为，也不给它盖上「勿改」的章** —— 盖了就把后人挡在门外。
要动请先补一个钉住当前行为的测试，再改。

### Aider 首条 prompt 取未 trim 的原始行

`AiderScanner` 里 `lines` 用 `isBlank`（内部走 `trimSpaces`）过滤空行，
但取首条 prompt 时用 `lines[0]` 而不是 `trimSpaces(lines[0])`，
所以 Markdown 缩进（列表项、引用块）会留在摘要开头。

**倾向是疏漏**：同一函数里两行之上刚用 `trimSpaces` 判空，
如果真要保留缩进，没有理由定义这个 trim 却不在取值处用。
但当前测试的夹具都是无缩进内容，**没有一个用例钉住这个行为**。

### Zed / OpenHands 的「名称包含匹配」粒度

`session-1` 会被 `session-10` 命中。收紧成路径分量精确匹配会更正确，
但也可能因此漏掉 Agent 实际写法的变体。没有真实样本支撑任一方向。
现在倾向保留宽松：漏列一条用户会来问，多命中一条顶多多占一行。

---

## 五、一条方法论备注

多代理并行移植时，任务书写错过一条（要求 Pi Agent 在 `scan()` 里预索引 context-mode
的 SQLite 索引）。实现代理 grep 完全仓后发现**真实实现从不打开 SQLite**，
拒绝执行该指令、照抄了真实行为并把冲突报了回来。

**任务书是需求，源码是事实，两者冲突时以源码为准，并把冲突报回来。**
任何对现有行为的描述，都应该先 grep 源码，不要照抄别处的文档。
