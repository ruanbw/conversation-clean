# ConversationClean UI 重构设计：转向原生

- 日期：2026-09-27
- 状态：已批准，待实现
- 参考项目：`/Users/ruanbw/projects/DefaultAppManager`
- 基线：`xcodebuild` BUILD SUCCEEDED，`./scripts/run_tests.sh` 全绿

---

## 1. 背景

ConversationClean 当前的界面是 Open Design HTML 原型（`docs/prototype.html`）的**逐像素移植**。
这套实现有两个特征：

1. **自绘一切**。`CC` 设计系统（839 行）用硬编码 sRGB 色值定义全部表面、文字、按钮、徽章、
   分段控件、搜索框、复选框、进度条与弹层遮罩。源码注释里成段记录了为什么不用系统控件 ——
   不用 `NavigationSplitView`（*"挂一条 NSToolbar"*）、不用 `List`（*"行高与背景冲突"*）、
   不用 `.sheet`（*"另开一个附着窗口"*）。
2. **单色锁定**。所有颜色是 `Color(hex:)` 写死的字面量，**完全没有深色模式**。

DefaultAppManager 是相反的形态：系统控件 + 语义色（`.accentColor` / `.secondary` /
`Color(NSColor.windowBackgroundColor)`），深浅色自动适配，`.listStyle` / `Picker` / `.sheet`
全部交给系统。

本设计把 ConversationClean 转向后者。**这是一次推翻既有决策的重构** —— 原生路线的选择
记录在 commit `eb033a7`（*"三栏改固定几何、弹层改窗口内遮罩，全面对齐 Open Design 原型"*），
那些注释解释的取舍在「全面转向原生」的前提下不再成立。

---

## 2. 目标

### 2.1 目标

- 界面改用系统控件与语义色，**获得深色模式**（当前完全没有）。
- 三栏结构由 `NavigationSplitView` 承载，详情栏常驻、由列表选中驱动。
- 恢复原生 `Settings` 窗口，接 ⌘,。
- 主色跟随系统强调色，消除「强调色 / 成功绿 / 危险红」三者的撞车。
- 删掉 839 行自绘设计系统。
- **零功能回归**：现有每一项可见行为都保留（见 §7 验收清单）。

### 2.2 非目标

- 不改任何扫描器、`Core` 层的扫描/删除逻辑、数据模型。
- 不改 `scripts/tests/` 下的 18 个扫描器测试用例。
- 不改 Xcode 工程格式（保持 `objectVersion = 56`，继续支持 Xcode 15）。
- 不删 `docs/prototype.html`（留作历史参考），只是代码不再参照它。
- 不做视觉之外的改动：不加新功能、不加新设置项、不重命名任何用户可见文案。

---

## 3. 已定的决策

六个方向性问题已确认。每条都记录了被否掉的备选，避免日后重开讨论。

### D1 · 全面转向原生

放弃原型逐像素移植，改用系统控件与语义色。

*否掉的备选*：只借视觉语言保留自绘结构；只借布局保留原型配色。
两者都会留下「自绘控件 + 语义色」的混合体，深色模式只修一半。

### D2 · 三栏常驻，详情栏由选中驱动

`NavigationSplitView` 三栏，详情栏**始终可见**，由 `List(selection:)` 驱动，无选中时显示概览。

*现状*：侧栏 272 / 列表弹性 / 检视器 324，检视器**默认关闭**，点行才展开，
开关持久化在 `@AppStorage("inspectorVisible")`。
*否掉的备选*：保留可折叠检视器（行为不变但多一个自造状态）；
侧栏 230 / 列表 320 / 详情自适应（几何照抄参考项目，但列表列太窄放不下元信息）。

注：此选择比参考项目**更原生** —— DefaultAppManager 自己刻意手搓 `HStack` 并用
`Spacer().frame(height: 38)` 垫开标题栏。本项目不复制这一点。

### D3 · 标题栏与全局元素全部交给系统

去掉 `.windowStyle(.hiddenTitleBar)`、自绘 46pt 标题栏、`.padding(.leading, 76)` 红绿灯避让、
`ignoresSafeArea(edges: .top)`。搜索用 `.searchable`，全局动作用 `.toolbar`。

*否掉的备选*：搜索留在列表列顶部（参考项目 `ExtensionListView` 的做法）；
保留自绘头部只换配色。

### D4 · 侧栏纯导航 + 路径 footer

侧栏只保留 Agent 分类导航，底部一个当前分类的存储路径 + Finder 入口。

*现状*：侧栏是 4 分区仪表盘（Agent 分类 / 统计概览 / 存储分布 / 当前分类存储路径）。
参考项目的侧栏是纯导航（导航模式 / 格式分类 / 备份与工具）。
在 230pt 宽度下，堆叠条 + 4 行图例 + 折行路径框挤不下 —— 分区 2–4 是**信息**不是导航，
不该占导航栏。

### D5 · 统计信息进详情栏，做上下文切换

统计概览与存储分布搬进详情栏：未选中会话时显示概览，选中时显示会话元数据。

*否掉的备选*：侧栏加「概览」导航项（多一层导航）；
不新建仪表盘、只把总数收进现有文案（存储分布会被整块删掉，信息有净损失）。

详情栏比侧栏宽得多，存储分布图例终于不用压缩。

### D6 · 恢复原生 Settings 窗口 + 跟随系统强调色

- 恢复 `Settings` scene，菜单里出现「设置…」，⌘, 生效。
- 主色用 `.tint(\.accentColor)`，跟随系统强调色。

*否掉的备选*：设置只留 `.sheet`（参考项目的做法）；
保留品牌绿 `.tint(CC.accent)`；用红色做强调色。

**强调色理由**：现状是绿色强调色 `#299236` + 另一支成功绿 `#14874E`，
两个绿已经在竞争同一语义位置。跟随系统强调色后，强调色 / 成功绿 / 危险红三者彻底分开。
用红色则会让「一键扫描」这个非破坏性操作看起来像破坏性操作。

---

## 4. 架构

### 4.1 窗口外壳

```swift
WindowGroup {
    ContentView()
        .environmentObject(viewModel)
        .frame(minWidth: 1000, minHeight: 640)
        .task { await viewModel.scanOnLaunchIfEnabled() }
}
.defaultSize(width: 1280, height: 820)
.windowResizability(.contentMinSize)
.commands { appCommands }

Settings {
    SettingsView().environmentObject(viewModel)
}
```

- 删 `.windowStyle(.hiddenTitleBar)`。
- `NavigationSplitView` 自带工具栏，**旧 `WindowGeometryBridge` 的绕行方案不再需要**
  （该文件此前已删除，注释保留在 `ConversationCleanApp.swift` 末尾，本次一并清理）。
- 最小尺寸从 `1100×680` 降到 `1000×640`：新布局的侧栏更窄、详情栏更宽。

### 4.2 三栏

```swift
NavigationSplitView(columnVisibility: $columnVisibility) {
    SidebarView()                                        // 纯导航 + 路径 footer
} content: {
    ConversationListView()                               // List(selection:)
} detail: {
    DetailView()                                         // 上下文切换
}
.navigationSplitViewStyle(.balanced)
```

三栏都用系统默认材质与分隔线，**不再手搓 `Divider()` 或发丝线**。

### 4.3 侧栏

```
┌─ 导航模式（原型的「Agent 分类」）
│  全部会话            128
│  Claude Code          42
│  Codex                17
│  …                    …
├─ 工具
│  设置…                ⌘,
```

- `List` + `.listStyle(.sidebar)`，选中行由系统填 `.accentColor`。
- 计数用 `.badge()` 或尾部小字，不再自绘胶囊。
- **底部 footer**：当前分类的存储路径（`.truncationMode(.middle)`）+
  「在 Finder 中打开」`Button`。
- 保留 `hideEmptyCategories`（"仅显示有数据"）过滤与 installed 过滤。
  installed 判定仍读 `AgentInfo.isInstalled`，**不恢复任何硬编码名单**。
- 「仅显示有数据」开关的**落点**：从当前的分区标题文字按钮（原型的 `.sb-h button`）
  改为侧栏「工具」区里一个 `.toggleStyle(.checkbox)` 的 `Toggle` ——
  `.sidebar` 样式的 section header 放不下自定义控件，而工具区已有同类条目。
- 工具区条目：设置…、仅显示有数据、在 Finder 中打开当前分类。

### 4.4 会话列表

- `List(selection: $viewModel.selectedConversationID)` +
  `.listStyle(.inset(alternatesRowBackgrounds: true))`（与参考项目一致）。
- 行内容：标题（`.headline`）+ 摘要（`.subheadline`，1 行）+ 元信息行
  （项目路径末两级 · Git 分支 · 轮数 · 相对时间 · 会话 ID）+ 右侧体积。
- 多选勾选框：`.toggleStyle(.checkbox)` 挂在行上，**`ConversationItem.isSelected` 保留**
  —— 批量勾选与列表 selection 是两件独立的事。
- 右键菜单四项（在 Finder 中显示 / 复制项目路径 / 复制会话 ID / 删除此会话）保留。
- 排序：`.toolbar` 里的 `Picker`，三档（最近更新 / 占用空间 / 对话轮数），
  仍持久化在 `listSortMode`。
- 底部批量条（已选中 N 项 · X / 取消选择 / 在 Finder 中显示 / 清理选中项（N））保留。
  清理按钮用 `.borderedProminent` + `.tint(.red)`。
- `.searchable(text: $viewModel.searchText)` + `.searchFocused($searchFocused)`。

### 4.5 详情栏（上下文切换）

```
selectedConversationID == nil        selectedConversationID != nil
┌──────────────────────────┐        ┌──────────────────────────┐
│  总缓存占用   12.4 GB    │        │ 标题 + 分类 + 体积        │
│  总会话数      286       │        ├──────────────────────────┤
├──────────────────────────┤        │ 元数据（Grid/LabeledContent）│
│  存储分布                │        │ 摘要                     │
│  ▓▓▓▓▓▓░░░░░░            │        │ 原子清理说明              │
│  ● Claude Code  48% 5.9G │        │ 关联文件（点击复制）       │
│  ● Codex         22% 2.7G│       │ 操作（4 个按钮）          │
└──────────────────────────┘        └──────────────────────────┘
```

- 概览内容 = 从侧栏搬来的统计概览两格 + 存储分布堆叠条与图例。
- 从未扫描过时，概览位置改为调用扫描的空态。
- **零额外状态**：全部由 `selectedConversationID` 派生。
- 6 款双层索引 Agent 的「原子清理」说明表（`idxNote` / `idxPath`）原样保留 ——
  这是产品的核心卖点，不是原型装饰。

### 4.6 设置

`TabView`（通用 / Agent 路径 / 关于）+ 系统 `Form` / `LabeledContent`。

- 4 个开关用系统 `Toggle(.switch)`，**删掉自绘的 `CCSwitch`**
  （原型是 38×22 黑绿手绘开关，系统开关在深色模式下自动正确）。
- Agent 路径页保留状态胶囊与 Finder 按钮。
- 关于页保留版本号（读 `CFBundleShortVersionString`）与三项 facts。

### 4.7 清理确认

**只换皮，不砍内容。** 改为 `.sheet`，保留全部估算逻辑：

- 预计释放 hero（`Fmt.bytes` 拆值/单位）
- 收益位置（占全部可清理空间 / 占卷总容量）
- 卷占用前后对比（`CapRow`，真比例）
- `VolumeInfo` 真实卷容量与已用量（**读真值，不用演示数字**）
- 空间构成 + 斜纹「估算」标记（`HatchedFill`）
- 索引层估算（每会话 34 KB）
- 提示块与页脚

这 861 行里的估算是**产品价值**：用户在按下不可撤销的删除前，需要知道能回收多少、
占卷多少、哪些是实测哪些是估算。全部保留，只把颜色与控件换成系统语义色。

---

## 5. 文件计划

| 文件 | 动作 | 约行数 |
|---|---|---|
| `ConversationCleanApp.swift` | 重写外壳，恢复 `Settings` scene，清理失效注释 | 80 → ~70 |
| `ContentView.swift` | 重写为 `NavigationSplitView` 骨架 + `Modals` | 257 → ~90 |
| `Views/SidebarView.swift` | 重写：`List` + `.listStyle(.sidebar)` | 485 → ~150 |
| `Views/ConversationListView.swift` | 重写：`List(selection:)` + 行视图 + 批量条 | 805 → ~280 |
| `Views/DetailView.swift` | 保留文件名与「详情栏」职责，内部改为上下文切换；会话元数据部分留在本文件的私有 struct 里 | 377 → ~280 |
| `Views/OverviewView.swift` | **新增** —— 概览（统计 + 存储分布），从 `SidebarView` 搬来 | ~130 |
| `Views/SettingsView.swift` | 重写：`TabView` + `Form` | 433 → ~230 |
| `Views/CleanConfirmSheet.swift` | 换皮：语义色 + 系统按钮，逻辑全留 | 861 → ~700 |
| `DesignSystem/CCTheme.swift` | **删除** | −174 |
| `DesignSystem/CCComponents.swift` | **删除** | −665 |
| `Core/Formatting.swift` | **新增** —— `Fmt` 从 `CCTheme.swift` 搬来 | ~90 |
| `ViewModels/CleanViewModel.swift` | 加 `selectedConversationID`，删 2 个字段，修 1 处进制 | 343 → ~350 |

净变化：删 839 行设计系统，新增约 200 行（概览视图 + 原生设置页 + `Formatting.swift`）。

### 5.1 `Fmt` 搬家（测试套件的唯一 UI 耦合）

`scripts/run_tests.sh` 显式 glob 了 `DesignSystem/`，只因为
`ConversationItem.formattedSize` 依赖 `Fmt.bytes`：

```bash
APP_SOURCES=$(find "$APP_DIR/Models" "$APP_DIR/Core" "$APP_DIR/Scanners" "$APP_DIR/DesignSystem" -name '*.swift' | sort)
# DesignSystem 必须包含：ConversationItem.formattedSize 走的是 Fmt.bytes（1024 进制…）
```

`Fmt` 是纯格式化逻辑，不是设计系统。搬到 `Core/Formatting.swift` 后，
`Core` 已在 glob 里，脚本只需删掉 `DesignSystem` 路径并更新注释。

`Fmt` 全部保留：`bytes`（1024 进制）、`full`、`relative`、`abbreviateHome`、`pathTail`。

### 5.2 `project.pbxproj` 手工编辑

工程是 `objectVersion = 56`、40 条显式 `PBXBuildFile`、**没有** `PBXFileSystemSynchronizedRootGroup`。
新增/删除文件必须手工改 `project.pbxproj`。

- **尽量复用现有文件名**（`DetailView.swift` 保留原名，只改内容）。
- 需登记：`Core/Formatting.swift`、`Views/OverviewView.swift`。
- 需注销：`DesignSystem/CCTheme.swift`、`DesignSystem/CCComponents.swift`。
- **不迁移到 Xcode 16 同步组** —— 会放弃 Xcode 15 支持，与 README 声明冲突。

---

## 6. 状态模型

### 新增

- `CleanViewModel.selectedConversationID: UUID?`
  驱动详情栏上下文切换与列表选中高亮。替代 `.ccFocusConversation` 通知 ——
  该通知存在的唯一理由是「列表与检视器各持一份焦点状态」，selection 驱动后不再需要。

### 删除

| 字段 / 机制 | 原因 |
|---|---|
| `CleanViewModel.settingsPresented` | 改用 `Settings` scene |
| `CleanViewModel.searchFieldFocused` | `.searchFocused` 可直接绑本地状态，⌘F 不必跨 `.commands` 传递 |
| `Notification.Name.ccFocusConversation` | 同上，由 selection 取代 |
| `@AppStorage("inspectorVisible")` | 检视器常驻 |
| `InspectorPanel` 的 `@State focused` / 关闭按钮 | 由 selection 取代 |
| `ModalScrim` | 改用 `.sheet` |

### 保留不动

- `listSortMode`（排序持久化）
- `hideEmptyCategories`
- 4 个设置键：`autoScanOnLaunch` / `confirmBeforeClean` /
  `cleanFileHistorySnapshots` / `cleanEmptyProjectFolders`
- `ConversationItem.isSelected`（批量勾选，与列表 selection 独立）
- `CleanPrefs`（Core 层唯一读取入口，键名不得漂移）

---

## 7. 验收清单（零功能回归）

实现完成后逐项确认：

**导航与统计**
- [ ] 15 款 Agent 分类，两道过滤（本机未安装不列 / 仅显示有数据）
- [ ] 每类会话计数
- [ ] 侧栏底部：当前分类存储路径 + Finder 打开
- [ ] 详情栏概览：总缓存占用、总会话数、存储分布堆叠条与图例

**列表**
- [ ] 搜索（120ms 防抖，跨标题 / 摘要 / 项目路径 / 会话 ID）
- [ ] 三种排序：最近更新 / 占用空间 / 对话轮数
- [ ] 多选勾选框、全选 / 取消全选
- [ ] 批量条：已选中 N 项 · 体积、取消选择、在 Finder 中显示、清理选中项（N）
- [ ] 行右键菜单四项：Finder / 复制项目路径 / 复制会话 ID / 删除此会话
- [ ] 行内悬浮删除
- [ ] 忙碌进度条

**反馈**
- [ ] 扫描完成横幅（命中 N 个会话，合计 X）
- [ ] 清理完成横幅（删除 N 个会话，释放 X，剩余 N 个）
- [ ] 四种空态：扫描中 / 从未扫描 / 无记录 / 无匹配

**详情**
- [ ] 元数据网格（会话 ID / 项目路径 / Git 分支 / 轮数 / 最后更新 / 存储路径）
- [ ] 摘要
- [ ] 6 款双层索引 Agent 的「原子清理」说明
- [ ] 关联文件列表，点击复制路径
- [ ] 操作四按钮，复制会话 ID 有 1.5s 文案反馈
- [ ] 删除单条会话

**确认弹层**
- [ ] 预计释放 hero
- [ ] 收益位置两条（占全部可清理 / 占卷总容量）
- [ ] 卷占用清理前后对比
- [ ] 真实 `VolumeInfo`（读不到时整块不渲染，不用演示数字）
- [ ] 空间构成 + 斜纹「估算」标记
- [ ] 索引层 34 KB/会话 估算
- [ ] 提示块随设置开关变化

**设置**
- [ ] 通用页 4 个开关
- [ ] Agent 路径页（状态胶囊 + Finder 按钮）
- [ ] Agent 路径页的安装状态与侧栏一致（统一读 `AgentInfo.isInstalled`）
- [ ] 关于页（版本号 + facts）

**键盘与持久化**
- [ ] ⌘R 扫描、⌘⌫ 清除、⌘F 聚焦搜索、Space 切换勾选、Return 打开详情
- [ ] 全部 `@AppStorage` 键跨启动保持

**新增收益**
- [ ] 深色模式正确（浅色 / 深色各过一遍）
- [ ] 跟随系统强调色

---

## 8. 顺手修掉的两处不一致

1. **`ViewModels/CleanViewModel.swift:15`** — `CategoryStats.formattedSize` 用
   `ByteCountFormatter`（**1000** 进制），而全应用其它地方用 `Fmt.bytes`（**1024** 进制）。
   同一屏会出现两套单位。统一到 `Fmt.bytes`。

2. **`Views/CleanConfirmSheet.swift:467`** — 注释写着
   *"「34 KB」必须按 1024 进制写：Fmt.bytes 是 1000 进制，会打成 34.8 KB"*，
   与 `CCTheme.swift:107` 明确写着的「不能用 `ByteCountFormatter`，它是 1000 进制」
   **直接矛盾**。注释是陈旧的，代码是对的 —— 删注释。

3. **Agent 安装状态的两套判定** — `SidebarView.swift:19-23` 已经改成读
   `AgentInfo.isInstalled` 并把硬编码名单清空（注释：*"早期版本据此硬编码了一个 4 款名单
   ……会把真实装了的情况误报成「未安装」"*），但 `SettingsView.swift:24` 的
   `settingsUndetectable = [.aider, .openViking, .zed, .openHands]` 还在按硬编码名单
   把这 4 款钉死成「未发现」并隐藏 Finder 按钮。同一个事实有两套答案，
   装了这 4 款的用户会在设置页看到与侧栏矛盾的结论。统一读 `AgentInfo.isInstalled`，
   删掉 `settingsUndetectable`。

---

## 9. 风险

| 风险 | 应对 |
|---|---|
| `project.pbxproj` 手工编辑出错 | 复用现有文件名；每步 `xcodebuild` 验证；不迁移工程格式 |
| `.searchFocused` 在部署目标上不可用 | macOS 14 部署目标下应可用；若编译不过，退回 ViewModel Bool + `@FocusState` 同步方案 |
| 深色模式首次暴露对比度问题 | 全部走语义色（`.primary` / `.secondary` / `Color(NSColor.controlBackgroundColor)`），不自己算灰阶 |
| `NavigationSplitView` 行为与旧手搓三栏不同 | 这是目标本身；列宽可拖拽 / 可折叠属于收益，不是回归 |
| 改动量大（约 3200 行视图层重写） | 分步落地，每步单独 `xcodebuild` 通过，`run_tests.sh` 全程绿 |

---

## 10. 验证

**每一步**
```bash
xcodebuild -scheme ConversationClean -configuration Debug build
./scripts/run_tests.sh
```

**收尾手工回归**
- 浅色 × 深色
- 未扫描 / 扫描中 / 已有结果 / 空结果 / 搜索无匹配
- ⌘R / ⌘⌫ / ⌘F / Space / Return
- 设置窗口 ⌘, 与 4 个开关的即时生效
- 确认弹层的真实卷数据

---

## 11. 注释策略

原型逐行对照注释（`原型 .est-sec`、`原型的 .cr`、`原型的 .cat.on::before{left:-6px}`）
在重构后**全部失效**，因为代码不再追随原型。处理方式：

- **删除**：对原型 CSS/JS 的逐行引用、对原型像素值的逐点说明。
- **保留**：真正的工程笔记，例如
  - `.help()` 在 macOS 上会叠 tooltip 展示层并吃掉点击（`ConversationListView.swift`）
  - macOS 26.3 起手动插 `NSWindow.styleMask` 会出现不可缩放 / 事件穿透
    （`ConversationCleanApp.swift`）
  - `Fmt.bytes` 必须 1024 进制以对齐 `du`/`df`（`CCTheme.swift` → `Core/Formatting.swift`）
  - `WindowGroup` 每开新窗口都会重跑 `.task`，启动扫描需要幂等闸门
  - 行修饰符链过长会导致 Swift 编译器 `unable to type-check this expression`

`docs/prototype.html` 作为历史参考保留在仓库里，不再是实现依据。
