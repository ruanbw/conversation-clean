# UI 重构：转向原生控件 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 ConversationClean 的界面从 HTML 原型的逐像素移植，改写为系统控件 + 语义色的原生实现，获得深色模式，同时保持现有全部可见行为不变。

**Architecture:** 三栏由 `NavigationSplitView` 承载，详情栏常驻并由 `List(selection:)` 驱动；`CleanViewModel` 新增 `selectedConversationID` 取代原先跨模块的 `.ccFocusConversation` 通知。删掉 839 行自绘设计系统（`CCTheme.swift` / `CCComponents.swift`），只把纯格式化逻辑 `Fmt` 搬到 `Core/Formatting.swift`——因为扫描器测试套件通过 glob `Core` 编译它，而 `DesignSystem` 会被删掉。

**Tech Stack:** Swift 6 / SwiftUI (macOS 14.0+) / AppKit / Xcode 26.5 / 无第三方依赖

**Spec:** `docs/superpowers/specs/2026-09-27-native-ui-refactor-design.md`

## Global Constraints

以下每一条都适用于**所有** task，无需在单个 task 里重复：

- **部署目标 macOS 14.0**，Xcode 15+ / 16+ 可打开。**不得**迁移 `project.pbxproj` 到 `objectVersion = 77`（会放弃 Xcode 15 支持，与 README 冲突）。
- **不新增第三方依赖。**
- **不改任何扫描器、Core 层扫描/删除逻辑、数据模型。**（`Core/` 只允许新增 `Formatting.swift` 这一个纯格式化文件。）
- **不改 `scripts/tests/` 下已有的 18 个测试用例的断言语义。**（可以新增文件与注册项。）
- **字节数一律 1024 进制**，走 `Fmt.bytes`。**禁止** `ByteCountFormatter`（1000 进制，与 `du`/`df` 对不上）。
- **颜色一律语义色**：`.primary` / `.secondary` / `.tertiary` / `.accentColor` / `Color(NSColor.controlBackgroundColor)` / `Color(NSColor.windowBackgroundColor)` / `Color(NSColor.separatorColor)`。**禁止** `Color(hex:)` 字面量。
- **破坏性操作用红色**：`.tint(.red)` 或 `.foregroundStyle(.red)`。非破坏性主操作跟随 `.accentColor`。
- **不删 `docs/prototype.html`**，只是代码不再参照它。
- **用户可见文案逐字保留**，不重写、不润色（除非 spec 明确要求）。
- 每个 task 结束前必须 `xcodebuild` 通过**且** `./scripts/run_tests.sh` 退出码为 0。

## Review Focus

spec 是愿景文档，它对下列输入只字未提，而它们最可能咬到真实使用者。每个 task 的步骤里都有对应的一条测试或检查：

1. **任何残留的硬编码色值** → 深色模式下出现不可读文字或黑底黑字。（Task 10 收尾 grep 扫描）
2. **`.searchFocused` 在部署目标上不可用** → ⌘F 静默失效，搜索框再也聚焦不了。（Task 6 编译验证 + 备选方案）
3. **`VolumeInfo.current()` 返回 nil**（读不到卷容量）→ 确认弹层要么整块不渲染，要么用假分母编出占比。用户会看到一个凭空来的百分比。（Task 8）
4. **Agent 已安装但 0 会话** → 侧栏该行应显示「空闲」且可点；`hideEmptyCategories` 打开时才隐藏。当前 `hideEmpty` 过滤写在 `SidebarView` 里，重写时最容易丢掉。（Task 3）
5. **`UserDefaults` 里存着本机没装的分类**（用户换机 / 卸载了 Cursor）→ 侧栏选不中、列表空。`reconcileSelectedCategory()` 是唯一的兜底，重写时不能丢。（Task 2 + Task 3）

---

## File Structure

**新增**

| 文件 | 职责 |
|---|---|
| `ConversationClean/Core/Formatting.swift` | `Fmt` enum：`bytes` / `full` / `relative` / `abbreviateHome` / `pathTail`。纯逻辑，无 SwiftUI 依赖。 |
| `ConversationClean/Views/OverviewView.swift` | 详情栏未选中态：总占用、总会话数、存储分布堆叠条与图例。从 `SidebarView` 搬来。 |
| `scripts/tests/FormattingTests.swift` | `Fmt` 的特征测试。 |

**重写**

| 文件 | 职责（之后） |
|---|---|
| `ConversationCleanApp.swift` | WindowGroup + Settings scene + 菜单命令。无 `hiddenTitleBar`。 |
| `ContentView.swift` | `NavigationSplitView` 骨架 + `.toolbar` + 确认弹层的 `.sheet`。 |
| `Views/SidebarView.swift` | `List(.sidebar)`：Agent 分类导航 + 工具区 + 路径 footer。 |
| `Views/ConversationListView.swift` | `List(selection:)` + `.searchable` + 行视图 + 底部批量条。 |
| `Views/DetailView.swift` | 详情栏容器：无选中 → `OverviewView`；有选中 → 会话元数据（现 `InspectorPanel` 的内容）。 |
| `Views/SettingsView.swift` | `TabView`（通用 / Agent 路径 / 关于）+ `Form`。 |
| `Views/CleanConfirmSheet.swift` | 估算内容不变，换成 `.sheet` + 语义色。 |

**删除**：`DesignSystem/CCTheme.swift`、`DesignSystem/CCComponents.swift`

**修改**：`ViewModels/CleanViewModel.swift`、`scripts/run_tests.sh`、`scripts/tests/TestSupport/TestRegistry.swift`、`ConversationClean.xcodeproj/project.pbxproj`

### 排序理由

视图先于外壳重写：旧 `ContentView` 的手搓 `HStack` 能直接托管新写的视图，每步都编译得过。`DesignSystem` 最后删——在 Task 9 之前每个视图都还在用 `CCButton` / `CCBadge` 等。

---

### Task 1: 把 `Fmt` 搬到 `Core`，并用测试钉住它的行为

`Fmt` 是扫描器测试套件与 UI 的唯一耦合点：`run_tests.sh` glob 了 `DesignSystem/`，而 `DesignSystem` 马上要删。`Fmt` 是纯格式化逻辑，不属于设计系统，搬进已在 glob 里的 `Core/` 即可解除耦合。

这些是**特征测试**（characterization tests）——`Fmt` 行为已经存在且正确，测试的作用是在搬家过程中锁住它，防止静默改变 1024 进制这类关键属性。

**Files:**
- Create: `ConversationClean/Core/Formatting.swift`
- Create: `scripts/tests/FormattingTests.swift`
- Modify: `ConversationClean/DesignSystem/CCTheme.swift`（删掉 `enum Fmt` 整段，文件保留到 Task 10）
- Modify: `scripts/tests/TestSupport/TestRegistry.swift`（注册 1 行）
- Modify: `scripts/run_tests.sh:10-14`（更新注释里的路径说明）

**Interfaces:**
- Consumes: 无（首个 task）
- Produces:
  ```swift
  enum Fmt {
      static func bytes(_ n: Int64) -> String
      static func full(_ date: Date) -> String
      static func relative(_ date: Date, now: Date = Date()) -> String
      static func abbreviateHome(_ path: String) -> String
      static func pathTail(_ path: String) -> String
  }
  ```
  位置 `ConversationClean/Core/Formatting.swift`。全应用共用，Task 2–10 全部依赖。

- [ ] **Step 1: 写特征测试文件**

创建 `scripts/tests/FormattingTests.swift`，照 `scripts/tests/DeletionTests.swift` 的既有风格（顶层 `func testXxx() async`、`TestRunner.printSection`、`TestCase` 断言）。实现 `func testFormatting() async`，断言以下**精确值**：

```swift
// Fmt.bytes —— 1024 进制，这是本次搬家最需要锁住的属性
t.assert(Fmt.bytes(0) == "0 KB", "0 → 0 KB")
t.assert(Fmt.bytes(1023) == "1.0 KB", "1023 → 1.0 KB（<10 保留 1 位小数）")
t.assert(Fmt.bytes(1024) == "1.0 KB", "1024 → 1.0 KB")
t.assert(Fmt.bytes(34 * 1024) == "34 KB", "34816 → 34 KB（≥10 四舍五入为整数）")
// 2_411_724 字节：1000 进制会打成 2.4 MB，1024 进制打成 2.3 MB，与 du/df 一致
t.assert(Fmt.bytes(2_411_724) == "2.3 MB", "2411724 → 2.3 MB（1024 而非 1000 进制）")
t.assert(Fmt.bytes(1024 * 1024 * 1024) == "1.0 GB", "1 GiB → 1.0 GB")

// Fmt.pathTail —— 只保留末两级
t.assert(Fmt.pathTail("/Users/tester/projects/conversation-clean") == "…/projects/conversation-clean", "长路径保留末两级")
t.assert(Fmt.pathTail("/a/b/c") == "…/b/c", "3 段路径保留末两级")
t.assert(Fmt.pathTail("/foo") == "/foo", "≤2 段原样返回")

// Fmt.abbreviateHome
t.assert(Fmt.abbreviateHome("/opt/x") == "/opt/x", "非 home 前缀原样返回")
// home 前缀：用 FileManager.default.homeDirectoryForCurrentUser.path 现场构造期望值，
// 不要把某个用户名写死在测试里

// Fmt.relative —— 显式传 now，保证确定性
let now = Date(timeIntervalSince1970: 1_800_000_000)
let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
// 期望 "3 天前"；另测一个 30 天前的日期 → 形如 "M月D日"（用 Calendar 算期望值，不写死月日）
// 今天的日期 → 以 "今天 " 开头
```

- [ ] **Step 2: 注册测试用例**

在 `scripts/tests/TestSupport/TestRegistry.swift` 的 `suite` 数组**末尾**（`MockVSCDBIndexSync` 那行之后）加一行，注释用 `// 格式化`：

```swift
TestEntry("Formatting", testFormatting),
```

- [ ] **Step 3: 运行，确认通过**

Run: `./scripts/run_tests.sh 2>&1 | tail -30`
Expected: 退出码 0，输出里出现 `Formatting` 这一节且无失败断言。

- [ ] **Step 4: 变异检查——证明测试不是空转**

临时把 `CCTheme.swift` 里 `Fmt.bytes` 的两处 `/ 1024` 改成 `/ 1000`，重跑：

Run: `./scripts/run_tests.sh 2>&1 | grep -A3 "Formatting"`
Expected: **失败**，报出 `2411724 → 2.3 MB` 断言不成立（1000 进制会得到 2.4 MB）。
然后**改回 `/ 1024`**，重跑确认恢复退出码 0。

- [ ] **Step 5: 搬家**

用 `git mv` 的等价操作把 `enum Fmt { ... }` 整段（含其上方的 `// MARK: - Formatting helpers` 注释）从 `ConversationClean/DesignSystem/CCTheme.swift` 剪切到新文件 `ConversationClean/Core/Formatting.swift`。

- 文件头写 `import Foundation`（`Date` / `Calendar` / `FileManager` / `DateFormatter` 需要）。
- `CCTheme.swift` 保留 `enum CC { ... }`，**不要**在本次删掉整个文件——Task 2–9 还在用。

- [ ] **Step 6: 更新 `run_tests.sh` 注释**

`scripts/run_tests.sh:10-14` 的注释块现在写着「DesignSystem 必须包含：ConversationItem.formattedSize 走的是 Fmt.bytes」。改为指向新位置，并说明 `DesignSystem` 会在后续 task 被删：

```bash
# 测试只覆盖「模型 + 共享基建 + 全部 scanner」，不含 SwiftUI 视图层。
# Core 必须包含：ConversationItem.formattedSize 走的是 Fmt.bytes（1024 进制，
# 与磁盘工具口径一致），它住在 Core/Formatting.swift 里。漏掉会直接编译不过。
# DesignSystem 已于 UI 原生化重构中删除，不再参与编译。
APP_SOURCES=$(find "$APP_DIR/Models" "$APP_DIR/Core" "$APP_DIR/Scanners" -name '*.swift' | sort)
```

- [ ] **Step 7: 验证**

Run: `./scripts/run_tests.sh 2>&1 | tail -5` → 退出码 0
Run: `xcodebuild -scheme ConversationClean -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`

- [ ] **Step 8: 提交**

```bash
git add ConversationClean/Core/Formatting.swift ConversationClean/DesignSystem/CCTheme.swift scripts/tests/FormattingTests.swift scripts/tests/TestSupport/TestRegistry.swift scripts/run_tests.sh
git commit -m "refactor: Fmt 搬到 Core 并补上特征测试

Fmt 是扫描器测试套件与 UI 的唯一耦合点（run_tests.sh glob 了 DesignSystem），
而设计系统即将整体删除。它是纯格式化逻辑，搬进已在 glob 里的 Core/ 即可解耦。

新增 FormattingTests 钉住 1024 进制这条关键属性：同一条 2411724 字节，
1000 进制会打成 2.4 MB，1024 进制打成 2.3 MB——后者才与 du/df 一致。"
```

---

### Task 2: ViewModel 加选中状态，删掉三处死代码

详情栏改为由选中驱动，需要一个共享的选择状态。同时清掉三处**从未被调用**的 1000 进制格式化死代码。

**Files:**
- Modify: `ConversationClean/ViewModels/CleanViewModel.swift`

**Interfaces:**
- Consumes: 无新增
- Produces:
  ```swift
  // CleanViewModel
  @Published var selectedConversationID: UUID?
  var selectedConversation: ConversationItem? { get }   // nil 当且仅当 selectedConversationID 为 nil
  ```
  Task 5（详情栏）、Task 6（列表选中）依赖。

- [ ] **Step 1: 加选中状态**

在 `CleanViewModel` 里，`searchFieldFocused` 声明**之前**插入：

```swift
/// 当前在详情栏展开的会话。由列表的 `List(selection:)` 写入、详情栏读取。
///
/// 它取代了原先跨模块的 `.ccFocusConversation` 通知——那份通知存在的唯一理由
/// 是「列表与检视器各持一份焦点状态」，两边刷新节奏还会打架（DetailView 曾经要
/// 在 `conversations` 变化时手工把 `focused` 换成最新快照）。selection 驱动后
/// 焦点只有一份，脏了就直接从 `conversations` 现取。
@Published var selectedConversationID: UUID? = nil

/// `selectedConversationID` 对应的会话快照。
///
/// 始终从 `conversations` 现取而不是缓存一份快照：会话被清理后自动变 nil，
/// 不需要视图侧再写同步代码。
var selectedConversation: ConversationItem? {
    guard let id = selectedConversationID else { return nil }
    return conversations.first { $0.id == id }
}
```

- [ ] **Step 2: 删掉 `CategoryStats.formattedSize`（死代码 + 1000 进制）**

`CleanViewModel.swift:14-16` 的 `formattedSize` 属性**全项目无任何调用点**（已 grep 确认），且用的是 1000 进制的 `ByteCountFormatter`。删除整个属性，`struct CategoryStats` 只留 `count` 与 `sizeInBytes`。

- [ ] **Step 3: 删掉 `AgentInfo.formattedSize`（同一处死代码）**

`ConversationClean/Core/AgentScanService.swift:12-14` 有**完全相同**的属性，同样无调用点、同样 1000 进制。删除它。

- [ ] **Step 4: 确认 `reconcileSelectedCategory()` 仍在扫描后被调用**

`scanConversations()` 末尾必须仍有 `reconcileSelectedCategory()`。这是 Review Focus 第 5 条的唯一兜底：`UserDefaults` 里存着本机没装的分类时，没有它就会出现「侧栏选不中、列表空」的死角。

grep 确认：

Run: `grep -n "reconcileSelectedCategory" ConversationClean/ViewModels/CleanViewModel.swift`
Expected: 两处命中——定义处 + `scanConversations()` 内的调用处。

- [ ] **Step 5: 验证**

Run: `xcodebuild -scheme ConversationClean -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`
Run: `./scripts/run_tests.sh 2>&1 | tail -3` → 退出码 0

- [ ] **Step 6: 提交**

```bash
git add ConversationClean/ViewModels/CleanViewModel.swift ConversationClean/Core/AgentScanService.swift
git commit -m "feat(ui): ViewModel 增加选中状态，删除两处 1000 进制死代码

selectedConversationID + selectedConversation 取代 .ccFocusConversation 通知：
焦点从「列表与检视器各持一份」收敛为一份，详情栏不必再手工同步过期快照。

CategoryStats.formattedSize 与 AgentInfo.formattedSize 全项目无调用点，
且都用 ByteCountFormatter（1000 进制）——与全应用其它地方走的 Fmt.bytes
（1024 进制）冲突，同屏会出现两套单位。直接删除而非转换。"
```

---

### Task 3: 侧栏改用 `List(.sidebar)`，只留导航 + 路径 footer

`List` + `.listStyle(.sidebar)`，选中行由系统填 `.accentColor`。统计概览与存储分布**不搬进侧栏**（Task 4 搬到详情栏），侧栏只留导航。

**Files:**
- Rewrite: `ConversationClean/Views/SidebarView.swift`（485 → 约 150 行）

**Interfaces:**
- Consumes: `CleanViewModel.selectedCategory`（读写）、`viewModel.categoryStats`、`viewModel.agentInfos`（均为既有）
- Produces: `struct SidebarView: View { @EnvironmentObject var viewModel: CleanViewModel }`——签名不变，Task 9 直接复用。

- [ ] **Step 1: 保留三样必须活着的数据源**

重写时下面这些**不能丢**，它们是 Review Focus 第 4、5 条的落点：

1. `sidebarAgentOrder`——15 款 Agent 的固定视觉顺序数组（`SidebarView.swift:14-17` 现有内容），`ConversationCategory.allCases` 把 Antigravity 放在最后，而设计顺序是 Trae → Antigravity → Aider。
2. `visibleCategories` 的**两道过滤**：本机未安装的不出现；`hideEmpty` 打开时再滤掉 `count == 0` 的。`.all` 恒在首位且不受 `hideEmpty` 影响。
3. `isInstalled(_:)` 读 `viewModel.agentInfos.first { $0.category == cat }?.isInstalled == true`。**不要**恢复任何硬编码 Agent 名单。

- [ ] **Step 2: 删掉 `unsupported` 死变量**

`SidebarView.swift:23` 的 `private let unsupported: Set<ConversationCategory> = []` 声明后从未被引用，直接删。

- [ ] **Step 3: 写新的 `SidebarView`**

结构（`List` + `.listStyle(.sidebar)`，不要手搓行高或发丝线）：

```swift
struct SidebarView: View {
    @EnvironmentObject var viewModel: CleanViewModel
    @AppStorage("hideEmptyCategories") private var hideEmpty = false

    var body: some View {
        List {
            Section("Agent 分类") {
                ForEach(visibleCategories) { cat in categoryRow(cat) }
            }
            Section("工具") {
                Toggle("仅显示有数据", isOn: $hideEmpty)
                    .toggleStyle(.checkbox)
                Button { openSettings() } label: { Label("设置…", systemImage: "gear") }
            }
            Section { pathFooter }
        }
        .listStyle(.sidebar)
    }
}
```

各部分要求：

- **分类行**：SF Symbol（`cat.iconName`）+ `cat.rawValue` + 尾部计数。有会话显示数字，0 会话显示「空闲」（`SidebarCategoryRow` 现有的 `rightText` 逻辑）。选中态交给系统，不要自绘 accent 底色。
- **`hideEmpty` 开关落点**：放进「工具」区的 `.toggleStyle(.checkbox)`。`.sidebar` 样式的 section header 放不下自定义控件（原先那个文字按钮是照原型 `.sb-h button` 做的，现在没有原型了）。
- **路径 footer**（Section 不带标题，放最后）：`当前分类存储路径` 的完整路径用 `.truncationMode(.middle)`，等宽字体，`.secondary`；下面一个「在 Finder 中打开」`Button`。沿用现有 `revealCurrentPath()` 的逻辑（目录存在就 `activateFileViewerSelecting`，否则退化为 `open`）。`.all` 分类时落到占用最大的那款 Agent（现有 `heaviestAgent` 逻辑）。
- **设置入口**：先用 `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` 打开原生设置窗口——`Settings` scene 在 Task 9 才加，本 task 先留这个调用（Task 9 之后即可用）。
- **颜色**：只用 `.primary` / `.secondary` / `.accentColor`。**禁止** `CC.*`。
- **保留 `pathNote` 语义**：路径下方那行说明跟着 `CleanPrefs.cleanEmptyProjectFolders` / `cleanFileHistorySnapshots` 走（现有 `viewModel.emptyFolderPolicyText` / `snapshotPolicyText`），不要写死。

- [ ] **Step 4: 验证**

Run: `xcodebuild -scheme ConversationClean -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`
Run: `./scripts/run_tests.sh 2>&1 | tail -3` → 退出码 0
Run: `grep -nE "CC\.|Color\(hex" ConversationClean/Views/SidebarView.swift` → 无输出

- [ ] **Step 5: 手工确认 Review Focus 第 4 条**

启动应用，扫一次，然后开/关「仅显示有数据」：已安装但 0 会话的 Agent（如未产生会话的某款）应在开关关闭时显示「空闲」且可点选中，在开关打开时消失。

- [ ] **Step 6: 提交**

```bash
git add ConversationClean/Views/SidebarView.swift
git commit -m "refactor(ui): 侧栏改用 List(.sidebar)，只留导航与路径 footer

统计概览与存储分布不再是侧栏内容——它们是信息不是导航，且在 230pt 宽度下
堆叠条与图例挤不开。搬进详情栏见后续 task（OverviewView）。

保留两道过滤（本机未安装不列 / 仅显示有数据）与 15 款固定视觉顺序；
安装状态一律读 AgentInfo.isInstalled，不恢复硬编码名单。"
```

---

### Task 4: 新增 `OverviewView`（统计与存储分布的新家）

总占用、总会话数、存储分布堆叠条与图例从侧栏搬进详情栏。详情栏比侧栏宽得多，图例不用再压缩。

**Files:**
- Create: `ConversationClean/Views/OverviewView.swift`（约 130 行）
- Modify: `ConversationClean.xcodeproj/project.pbxproj`（登记新文件）

**Interfaces:**
- Consumes: `CleanViewModel.categoryStats`（`[ConversationCategory: CategoryStats]`）、`viewModel.totalSize`、`viewModel.conversations`、`viewModel.hasScanned`、`viewModel.isScanning`
- Produces: `struct OverviewView: View { @EnvironmentObject var viewModel: CleanViewModel }`——Task 5 的详情栏会引用它。

- [ ] **Step 1: 登记到 `project.pbxproj`**

工程是 `objectVersion = 56`、无同步组，必须手工加 4 行。先确认 ID 未被占用：

Run: `grep -c "CC02D1052D00000100000001\|CC01D1052D00000100000001" ConversationClean.xcodeproj/project.pbxproj`
Expected: `0`

然后按既有 ID 约定（`CCxxD1NN2D00000100000001`）加：

- `PBXBuildFile` 段（约 44 行旁）：`CC01D1052D00000100000001 /* OverviewView.swift in Sources */ = {isa = PBXBuildFile; fileRef = CC02D1052D00000100000001 /* OverviewView.swift */; };`
- `PBXFileReference` 段（约 88 行旁）：`CC02D1052D00000100000001 /* OverviewView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OverviewView.swift; sourceTree = "<group>"; };`
- `Views` group 的 `children`（`project.pbxproj:155-166`）：加 `CC02D1052D00000100000001 /* OverviewView.swift */,`
- `PBXSourcesBuildPhase`（约 316 行旁）：加 `CC01D1052D00000100000001 /* OverviewView.swift in Sources */,`

- [ ] **Step 2: 写 `OverviewView`**

```swift
struct OverviewView: View {
    @EnvironmentObject var viewModel: CleanViewModel
    // 另有：@State private var copied = false（若含复制路径按钮）
}
```

内容与要求：

- **两个大数字**：`总缓存占用`（`Fmt.bytes(viewModel.totalSize)`）与 `总会话数`（`viewModel.conversations.count`）。用系统 `.title2` + `.bold()` + `.monospacedDigit()`，标签用 `.caption` + `.secondary`。
- **存储分布**：从 `SidebarView` 搬 `distSegments` 的算法——占用 > 0 的分类降序取前 5，其余合并成「其他 N 款」；`distRamp` 灰阶序列 `[1.00, 0.80, 0.63, 0.49, 0.38, 0.26, 0.20, 0.14]` 保留（超过 6 段继续往下取）。堆叠条 + 图例行（名称 / 百分比 / 字节）。
  - 灰阶改用 `.primary.opacity(ramp[i])`，**不要** `CC.fg.opacity(...)`。
  - `total == 0` 时显示「暂无可统计的会话。」的 `.secondary` 空态。
- **未扫描态**：`viewModel.hasScanned == false` 时，本视图整体改为调用扫描的空态（图标 + 说明 + 「扫描」`Button`，走 `Task { await viewModel.scanConversations() }`）。文案沿用现有 `ConversationListView.emptyState` 里「还没有扫描过会话」那一支的措辞。
- **策略说明**：把 `viewModel.emptyFolderPolicyText` 从侧栏搬到这里（它原本挂在侧栏「统计概览」下面）。
- **禁止** `CC.*` 与 `Color(hex:)`。**禁止**保留任何「原型」注释——这个功能是从侧栏搬来的，不是从原型搬的。

- [ ] **Step 3: 验证**

Run: `xcodebuild -scheme ConversationClean -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`
Run: `grep -nE "CC\.|Color\(hex|原型" ConversationClean/Views/OverviewView.swift` → 无输出

本 task 的视图还没被任何地方引用，属预期——Task 5 才接上。确认它编译即可。

- [ ] **Step 4: 提交**

```bash
git add ConversationClean/Views/OverviewView.swift ConversationClean.xcodeproj/project.pbxproj
git commit -m "feat(ui): 新增 OverviewView —— 统计与存储分布的新家

从侧栏搬来的总占用 / 总会话数 / 存储分布堆叠条与图例。详情栏比侧栏宽，
图例不必再挤在 272pt 里。未扫描时整体降级为调用扫描的空态。

灰阶序列保留原有的 8 级 ramp，改用 .primary.opacity 适配深色模式。"
```

---

### Task 5: 详情栏改为上下文切换

`InspectorPanel` 更名为 `DetailView`，无选中时显示 `OverviewView`，有选中时显示会话元数据（现有内容）。焦点从通知改为读 `viewModel.selectedConversation`。

**Files:**
- Rewrite: `ConversationClean/Views/DetailView.swift`（377 → 约 280 行）
- Modify: `ConversationClean/ContentView.swift:231`（`InspectorPanel()` → `DetailView()`，仅此一处引用）

**Interfaces:**
- Consumes: `OverviewView`（Task 4）、`viewModel.selectedConversation`（Task 2）、`viewModel.agentInfos`、`viewModel.conversations`
- Produces: `struct DetailView: View { @EnvironmentObject var viewModel: CleanViewModel }`——Task 9 的 `NavigationSplitView` 引用它。

- [ ] **Step 1: 改容器：上下文切换**

把 `struct InspectorPanel` 更名为 `struct DetailView`，`body` 改为：

```swift
var body: some View {
    Group {
        if let item = viewModel.selectedConversation {
            conversationDetail(item)
        } else {
            OverviewView()
        }
    }
    .background(Color(NSColor.windowBackgroundColor))
}
```

- [ ] **Step 2: 删掉通知驱动的焦点状态**

以下全部删除，它们都是 `.ccFocusConversation` 的配套：

- `@State private var focused: ConversationItem?`
- `@State private var copied = false` —— **保留**（复制会话 ID 的 1.5s 文案反馈仍需要它），但重置时机从 `.onChange(of: focused?.id)` 改为 `.onChange(of: viewModel.selectedConversationID)`
- `.onReceive(NotificationCenter.default.publisher(for: .ccFocusConversation))` 整段
- `.onChange(of: viewModel.selectedCategory) { focused = nil }`
- `.onChange(of: viewModel.conversations) { ...换成最新快照... }`——**这一段整个删掉**。`selectedConversation` 直接从 `conversations` 现取，不再需要手工同步；会话被删后自动变 nil。
- `private static let topAnchor` 与 `ScrollViewReader` 包装：换成 `.onChange(of: viewModel.selectedConversationID) { ... }` 触发 `scrollTo`。若实现上更简单，可保留 `ScrollViewReader`，但 anchor 常量保留。

- [ ] **Step 3: 删掉关闭按钮**

原 InspectorPanel 右上角的 `xmark` 关闭按钮（`DetailView.swift:97-106`）**删除**。详情栏常驻，不再有「收起」概念；关掉当前选中由列表取消选中完成。

- [ ] **Step 4: 会话元数据内容整体保留**

以下**逐项保留**，只把 `CC.*` 换成语义色：

- `header(_:)`——图标 + 标题（≤3 行）+ 分类 `Badge` + 体积
- `metadata(_:)`——`Grid` 六行：会话 ID / 项目路径 / Git 分支 / 对话轮数 / 最后更新 / 存储路径。空值回落 `—`，长路径在任意字符处折行
- `snippet(_:)`——摘要为空则整区不显示
- `atomicNote(_:)`——`idxNote` 字典命中的 6 款 Agent（piAgent / copilotChat / cursor / windsurf / trae / antigravity）才显示。**这是产品核心卖点，一条都不能少**
- `files(_:)`——`relatedPaths(for:)` 的三级兜底逻辑（真实 `associatedPaths` → `<project>/.session` → `<storagePath>/<sessionId>.jsonl` → `idxPath` 索引位置）保留；点击仍是**复制路径**
- `actions(_:)`——四按钮：在 Finder 中显示 / 复制项目路径 / 复制会话 ID（1.5s 后文案回落「已复制」）/ 删除此会话（`.tint(.red)`）

- [ ] **Step 5: 更新 `ContentView` 的引用**

`ContentView.swift:231` 的 `InspectorPanel()` 改为 `DetailView()`。检视器开关逻辑（`inspectorOn`）本 task **不动**——它要到 Task 9 才随外壳一起去掉。

- [ ] **Step 6: 验证**

Run: `xcodebuild -scheme ConversationClean -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`
Run: `grep -rn "ccFocusConversation\|InspectorPanel" ConversationClean/` → 无输出
Run: `./scripts/run_tests.sh 2>&1 | tail -3` → 退出码 0

- [ ] **Step 7: 提交**

```bash
git add ConversationClean/Views/DetailView.swift ConversationClean/ContentView.swift
git commit -m "refactor(ui): 详情栏改为上下文切换

无选中 → OverviewView（统计概览 + 存储分布）；有选中 → 会话元数据。
InspectorPanel 更名 DetailView。

焦点从 .ccFocusConversation 通知改为读 viewModel.selectedConversation，
连带删掉「conversations 变化时手工把 focused 换成最新快照」那段同步代码——
快照直接从 conversations 现取，会话被删后自动变 nil。
右上角关闭按钮一并删除：详情栏常驻，不再有收起概念。

会话元数据的六项内容（含 6 款双层索引 Agent 的原子清理说明）逐项保留。"
```

---

### Task 6: 会话列表改用 `List(selection:)`

`List` + `.listStyle(.inset(alternatesRowBackgrounds: true))`（与参考项目一致），选中由 `List(selection:)` 驱动，搜索交给 `.searchable`。

**Files:**
- Rewrite: `ConversationClean/Views/ConversationListView.swift`（805 → 约 280 行）

**Interfaces:**
- Consumes: `viewModel.selectedConversationID`（`$` 双向绑定，Task 2）、`viewModel.filteredConversations`、`viewModel.selectedItems` / `selectAll(_:)` / `setItemSelected(_:selected:)` / `deleteSingle(item:)` / `revealInFinder(item:)` / `copyToClipboard(text:)` / `requestCleanSelected()`（均为既有）
- Produces: `struct ConversationListView: View { @EnvironmentObject var viewModel: CleanViewModel }`——签名不变，Task 9 直接复用。

- [ ] **Step 1: 容器与选中绑定**

```swift
List(selection: $viewModel.selectedConversationID) {
    ForEach(sorted) { item in
        ConversationRow(item: item).tag(item.id)
    }
}
.listStyle(.inset(alternatesRowBackgrounds: true))
```

- [ ] **Step 2: 搜索改用 `.searchable`**

```swift
.searchable(text: $viewModel.searchText, placement: .toolbar, prompt: "搜索标题、摘要、项目路径或会话 ID")
.searchFocused($searchFocused)
```

`searchFocused` 是本 task 唯一的编译风险点（Review Focus 第 2 条）。若部署目标上不可用，**不要**退回 ViewModel Bool，改为在 `ContentView` 保留一个本地 `@FocusState` 并用 `onChange` 同步——但先试直接编译。⌘F 仍由 `ConversationCleanApp` 的 `.commands` 触发，写法在 Task 9 统一处理；本 task 先保证 `⌘F` 有路径可达。

- [ ] **Step 3: 行内容保留四层信息**

`ConversationRow` 里这几层**全部保留**，布局用 `VStack(alignment: .leading, spacing: 2)`：

1. 标题（`.headline`，1 行）
2. 摘要 `item.snippet`（`.subheadline` + `.foregroundStyle(.secondary)`，1 行）
3. 元信息行（`.caption` + `.secondary`，`·` 分隔）：项目路径（`Fmt.pathTail`）、Git 分支（空则整项省略）、`\(messageCount) 轮对话`、`Fmt.relative(updatedAt)`、会话 ID（`#\(shortSessionId)`）
4. 右侧体积 `item.formattedSize`——**必须 `.fixedSize()`**，否则会被标题抢压缩额度截断成「2...」

元信息行里的 SF Symbol 小图标（folder / arrow.triangle.branch / bubble.left / clock）可以保留，也可以去掉换更紧凑的纯文字分隔。保留图标更接近现状，默认保留。

- [ ] **Step 4: 勾选框保留，且与列表选中独立**

批量勾选走 `ConversationItem.isSelected`（ViewModel 既有），**不要**与 `selectedConversationID` 混用：

- 行首 `.toggleStyle(.checkbox)` 的 `Toggle`，绑定 `viewModel` 上的选中态（照现有 `selection` 绑定写法：以数据层为准读取，避免行值过期）
- `全选当前 / 取消全选` 按钮调 `viewModel.selectAll(_:)`
- 「全选」的判定沿用现有 `allSelected`：`!rows.isEmpty && rows.allSatisfy { $0.isSelected }`

用系统 checkbox 替掉自绘的 16×16 `RoundedRectangle` 勾选框。

- [ ] **Step 5: 右键菜单四项保留**

顺序照旧：在 Finder 中显示 / 复制项目路径 / 复制会话 ID / `Divider()` / 删除此会话（`role: .destructive`）。行内悬浮删除按钮可去掉——右键菜单已覆盖，且 `List` 行内自绘悬浮控件容易与系统选中高亮打架。

- [ ] **Step 6: 底部批量条保留**

常驻底栏（0 选中时按钮禁用灰态、文案照常显示 0）：

- 左：`已选中 N 项 · X`
- 右：`取消选择` / `在 Finder 中显示`（`folder`）/ `清理选中项（N）`——最后一个用 `.buttonStyle(.borderedProminent)` + `.tint(.red)`

- [ ] **Step 7: 排序与内容头**

- 三档排序（最近更新 / 占用空间 / 对话轮数）保留，`@AppStorage("listSortMode")` 键名不变，非法值回落 `.date`。控件改成 `Picker` + `.pickerStyle(.menu)`，放在列表列的 `.toolbar` 里。
- 原 `.content-head` 那行大标题 + 「共 N 个会话项，占用 X · 已选中 Y 项（Z）」的富文本副标题**删掉**——`NavigationSplitView` 的列头已经有标题，而这条信息在批量条与详情栏已有呈现。这是本 task 唯一的信息删减，已在 spec §4.4 认可范围内。

- [ ] **Step 8: 四种空态与两个横幅保留**

空态（`CCEmptyState` 替成系统 `ContentUnavailableView`，macOS 14+）四种分支逐字保留：扫描中 / 从未扫描（含存储路径行）/ 无记录 / 无匹配。

横幅（`CCRichBanner` 替成系统样式）两个都保留：扫描完成（命中 N 个会话，合计 X）、清理完成（删除 N 个会话，释放 X，剩余 N 个）。两个横幅互斥的逻辑在 ViewModel 里，不动。

- [ ] **Step 9: 删掉焦点通知与键盘修饰器**

`RowInteractionModifier`、`.onKeyPress(.space)` / `.onKeyPress(.return)`、`RowCell` 的 `@FocusState keyboardFocused`、`focusedID` 状态、以及 `content.heading` 上方的 `.onReceive(.ccFocusConversation)` 全部删除——`List` 自带键盘导航与选中。

- [ ] **Step 10: 验证**

Run: `xcodebuild -scheme ConversationClean -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`
Run: `grep -nE "ccFocusConversation|CC\.|Color\(hex" ConversationClean/Views/ConversationListView.swift` → 无输出
Run: `./scripts/run_tests.sh 2>&1 | tail -3` → 退出码 0

- [ ] **Step 11: 手工确认 Review Focus 第 2 条**

启动应用，搜任意关键词后按 ⌘F：搜索框应获得焦点。若 ⌘F 无反应，说明 Step 2 的 `.searchFocused` 路径没接上，Task 9 处理。

- [ ] **Step 12: 提交**

```bash
git add ConversationClean/Views/ConversationListView.swift
git commit -m "refactor(ui): 会话列表改用 List(selection:) 与 .searchable

选中由 List(selection:) 直接驱动，批量勾选仍走 ConversationItem.isSelected
——两件事保持独立。排序改 Picker(.menu)，键名 listSortMode 不变。

用系统控件替掉自绘的 16x16 勾选框、CCEmptyState、CCRichBanner；
删掉 content-head 的富文本副标题（列头已有标题，数字在批量条与详情栏已有呈现）。

四层行信息、右键菜单四项、底部批量条、四种空态、两个横幅逐项保留。"
```

---

### Task 7: 设置面板改用 `TabView` + `Form`

**Files:**
- Rewrite: `ConversationClean/Views/SettingsView.swift`（433 → 约 230 行）

**Interfaces:**
- Consumes: `viewModel.agentInfos`、4 个 `@AppStorage` 键（`autoScanOnLaunch` / `confirmBeforeClean` / `cleanFileHistorySnapshots` / `cleanEmptyProjectFolders`，**键名不得改**，`CleanPrefs` 在 Core 层按同名读取）
- Produces: `struct SettingsView: View { @EnvironmentObject var viewModel: CleanViewModel }`——签名不变，Task 9 挂进 `Settings` scene。

- [ ] **Step 1: 结构换成 `TabView`**

```swift
TabView {
    generalTab.tabItem { Label("通用", systemImage: "gear") }
    pathsTab.tabItem   { Label("Agent 路径", systemImage: "folder") }
    aboutTab.tabItem   { Label("关于", systemImage: "info.circle") }
}
.frame(width: 620, height: 460)
```

删掉手绘的 `tabBar`（`SettingsView.swift:82-122`）与 `tab` / `hoveredTab` 状态。固定尺寸从 `760×560` 收到 `620×460`——手绘 tab 条占了 48pt，系统 tab 条更紧凑。

- [ ] **Step 2: 通用页用 `Form`**

```swift
Form {
    Section("扫描与清理") {
        Toggle("启动应用时自动扫描会话", isOn: $autoScanOnLaunch)
        Toggle("删除会话时同步清除快照与子代理数据", isOn: $cleanFileHistorySnapshots)
        Toggle("删除会话后自动移除空项目目录", isOn: $cleanEmptyProjectFolders)
    }
    Section("安全策略") {
        Toggle("执行清理操作前弹出二次确认", isOn: $confirmBeforeClean)
    }
}
.formStyle(.grouped)
```

- [ ] **Step 3: 删掉三个自绘控件**

- `SettingsToggleStyle`（整行可点的 toggle）——系统 `Toggle` 在 `Form` 里本身就是整行可点
- `CCSwitch`（38×22 手绘开关）——用 `.toggleStyle(.switch)`，它在深色模式下自动正确
- `settingsGroup` / `prefRow` / 发丝线——`Form` 的 `Section` 已提供分组与分隔

**四个开关的标题与副标题文案逐字保留**（副标题用 `Text(...).font(.caption).foregroundStyle(.secondary)` 挂在标题下）。

- [ ] **Step 4: 统一安装状态来源（Review Focus 第 3 条的延伸）**

删除 `settingsUndetectable`（`SettingsView.swift:24`，硬编码 `[.aider, .openViking, .zed, .openHands]`）与全部 `settingsUndetectable.contains(...)` 判断。

现状是同一个事实有两套答案：`SidebarView` 已经改成读 `AgentInfo.isInstalled`（其注释明说硬编码名单「会把真实装了的情况误报成『未安装』」），而本页还按名单把这 4 款钉死成「未发现」并隐藏 Finder 按钮。装了这 4 款的用户会在设置页看到与侧栏矛盾的结论。

统一写法：状态胶囊读 `agent.isInstalled`（未装 → 「未发现」；已装且 `sessionCount > 0` → 「N 会话」；已装且 0 → 「已检测到」），Finder 按钮在 `agent.isInstalled` 时显示。

- [ ] **Step 5: 路径页与关于页保留**

- 路径页：15 款按 `settingsAgentOrder` 排序（保留该数组）、`AgentPathRow` 的「图标 + 名称 + 状态胶囊 + 路径 + Finder 按钮」结构，改为 `List` 或 `Form(.grouped)`。`agents.isEmpty` 时保留「尚未扫描到 Agent 信息，请先回到主窗口执行一次扫描。」
- 关于页：`tray.2` 图标 + 产品名 + `版本 \(appVersion) · macOS 14.0 Sonoma 及以上` + 简介 + `factsRow`（受支持 Agent / 双层索引同步 / 并发扫描任务组）。`appVersion` 读 `CFBundleShortVersionString`、取不到回落 `"dev"` 的逻辑保留。`settingsIndexNotes` 字典保留（`factsRow` 的「双层索引同步」数字来自它）。

- [ ] **Step 6: 验证**

Run: `xcodebuild -scheme ConversationClean -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`
Run: `grep -nE "settingsUndetectable|CCSwitch|CC\.|Color\(hex" ConversationClean/Views/SettingsView.swift` → 无输出
Run: `./scripts/run_tests.sh 2>&1 | tail -3` → 退出码 0

- [ ] **Step 7: 提交**

```bash
git add ConversationClean/Views/SettingsView.swift
git commit -m "refactor(ui): 设置面板改用 TabView + Form，并统一安装状态来源

删掉手绘 tab 条、SettingsToggleStyle、38x22 自绘开关与发丝线分组，
改用系统 Form(.grouped)——自绘开关在深色模式下是错的。

修一处真实 bug：settingsUndetectable 硬编码了 4 款 Agent 为「未发现」
并隐藏其 Finder 按钮，而 SidebarView 早已改成读 AgentInfo.isInstalled。
装了这 4 款的用户会在设置页看到与侧栏矛盾的结论。统一读 isInstalled。

4 个设置键名一字未改（CleanPrefs 在 Core 层按同名读取）。"
```

---

### Task 8: 清理确认弹层换皮

**只换皮，不砍内容。** 这 861 行里的估算是产品价值：用户在按下不可撤销的删除前，需要知道能回收多少、占卷多少、哪些是实测哪些是估算。

**Files:**
- Rewrite: `ConversationClean/Views/CleanConfirmSheet.swift`（861 → 约 700 行）

**Interfaces:**
- Consumes: `viewModel.estimateTargets(for:)` / `cleanTarget` / `estimateCategory` / `isCleaning` / `executeClean()` / `cancelClean()` / `totalSize` / `conversations`、`CleanPrefs.cleanFileHistorySnapshots` / `cleanEmptyProjectFolders`（均为既有）
- Produces: `struct CleanConfirmSheet: View { @EnvironmentObject var viewModel: CleanViewModel; let availableHeight: CGFloat }`——`availableHeight` 本 task **保留**（旧 `ModalScrim` 仍在传），Task 9 换成 `.sheet` 时再删。

- [ ] **Step 1: 全部计算逻辑逐字保留**

以下**一个都不许改**，它们是行为不是装饰：

- `idxPer = 34 * 1024`（第二层索引行每会话估算）
- `indexLayer(for:)`——piAgent → `"context-mode"`；copilotChat / cursor / windsurf / trae / antigravity → `"state.vscdb"`
- `indexHit`（命中会话数 + 去重层名）、`idxBytes`、`totalBytes`
- `allBytes`（全库主文件 + 同口径索引估算）
- `shares` 聚合（降序；同字节按名称排，保证渲染顺序稳定）、`mainRows`(前 5) / `restRows` / `restCount`（**是会话条数，不是 Agent 数**）
- `scopeLabel`（整类清理时带范围名；取 `estimateCategory` 而非当前 `selectedCategory`）
- `split(_:)`（`Fmt.bytes` 拆值/单位）、`fmtVol(_:)`（GB 两位小数）
- `VolumeInfo.current()` 整个类型

- [ ] **Step 2: Review Focus 第 3 条——`VolumeInfo` 为 nil 时整块不渲染**

现有代码已经是这个行为（`volumeSection` 与 `benefitSection` 的卷容量行都有 `if let vol = volume` / `if let volume` 守卫），**保留它**。

不要为了「布局完整」给 nil 兜一个假容量或 0 分母——那会让用户看到一个凭空来的百分比。真值读不到就不显示这一节。

手动验证：临时把 `VolumeInfo.current()` 改成 `return nil`，跑起应用触发确认弹层，确认「卷占用」整节消失、「收益位置」只剩「占全部可清理空间」一条、**没有**任何编造的百分比。然后改回。

- [ ] **Step 3: 换皮**

| 原 | 换成 |
|---|---|
| `CCButton(kind: .danger)` | `.buttonStyle(.borderedProminent)` + `.tint(.red)` |
| `CCButton(kind: .ghost)` | `.buttonStyle(.borderless)` |
| `CC.surface` / `CC.bg.opacity(0.45)` | `Color(NSColor.controlBackgroundColor)` / `.bar` |
| `CC.fg` / `CC.muted` | `.primary` / `.secondary` |
| `CC.danger` / `CC.dangerSoft` | `.red` / `Color(NSColor.systemRed).opacity(0.12)` |
| `CC.fillSoft` | `Color(NSColor.controlBackgroundColor)` |
| `CC.border` | `Color(NSColor.separatorColor)` |
| `CC.F.num(_:)` | `.monospacedDigit()` + `.font(.system(size:design:.monospaced))` |
| `ccHairline(.top)` | `Divider()` |
| `CCBadge` | `Text(...).padding(...).background(Capsule().fill(...))`（约 8 行） |
| `Text.figureEmphasis(size:)` | 保留，换成 `.font(.system(size: size, design: .monospaced)).foregroundStyle(.primary)` |
| `LevelBadge` | 保留，换语义色 |
| `HatchedFill` | **保留**——135° 斜纹是「这段不是实测」的唯一记号，是信息不是装饰 |

- [ ] **Step 4: 删掉失效的原型注释**

`CleanConfirmSheet.swift:467` 的注释

```
// 「34 KB」必须按 1024 进制写：Fmt.bytes 是 1000 进制，会打成 34.8 KB
```

是**错的**——`Fmt.bytes` 正是 1024 进制（`Core/Formatting.swift` 里有测试钉住），这句与代码直接矛盾。删掉。

其余「原型 `.est-sec`」「原型的 `.cr`」这类逐行 CSS 对照注释，按 spec §11 全部删除；保留解释**为什么**这么写的工程笔记（如「1px 描边画在内侧，填充只能落在剩下的内宽里」「斜纹只在 8pt 高的条里出现，不值得引渐变资源」）。

- [ ] **Step 5: 验证**

Run: `xcodebuild -scheme ConversationClean -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`
Run: `grep -nE "CC\.|Color\(hex|原型" ConversationClean/Views/CleanConfirmSheet.swift` → 仅剩允许保留的工程笔记中提及处；`Color(hex` 与 `CC.` 必须为 0
Run: `grep -n "idxPer\|indexLayer\|restCount\|VolumeInfo" ConversationClean/Views/CleanConfirmSheet.swift` → 四个符号都在
Run: `./scripts/run_tests.sh 2>&1 | tail -3` → 退出码 0

- [ ] **Step 6: 提交**

```bash
git add ConversationClean/Views/CleanConfirmSheet.swift
git commit -m "refactor(ui): 清理确认弹层换皮，估算逻辑与真实卷信息全留

只换控件与颜色：idxPer / indexLayer / shares / restCount（会话条数不是 Agent 数）
/ split / fmtVol / VolumeInfo 全部逐字保留。斜纹「估算」标记也保留——
它是「这段不是实测」的唯一记号，属信息不属装饰。

VolumeInfo 读不到时整块不渲染的既有行为保留，不给假分母兜底。

顺带删掉一句与代码矛盾的陈旧注释：它称 Fmt.bytes 是 1000 进制，
而 Fmt.bytes 正是 1024 进制（Task 1 已加测试钉住）。"
```

---

### Task 9: 应用外壳换成 `NavigationSplitView` + 原生标题栏 + `Settings` scene

**Files:**
- Rewrite: `ConversationClean/ContentView.swift`（257 → 约 90 行）
- Rewrite: `ConversationClean/ConversationCleanApp.swift`（80 → 约 70 行）

**Interfaces:**
- Consumes: `SidebarView`（Task 3）、`ConversationListView`（Task 6）、`DetailView`（Task 5）、`SettingsView`（Task 7）、`CleanConfirmSheet`（Task 8）、`viewModel.searchText` / `searchFieldFocused`（既有，本 task 删后者）
- Produces: `struct ContentView: View { @EnvironmentObject var viewModel: CleanViewModel }`

- [ ] **Step 1: `ContentView` 换成三栏骨架**

```swift
struct ContentView: View {
    @EnvironmentObject var viewModel: CleanViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } content: {
            ConversationListView()
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { /* Step 3 */ }
        .sheet(isPresented: $viewModel.showCleanConfirmAlert) {
            CleanConfirmSheet()
                .environmentObject(viewModel)
        }
    }
}
```

删掉：`titleBar`（自绘 46pt）、`workspaceToolbar`（自绘跨全宽工具条）、`split`（手搓 `HStack`）、`modals(viewportHeight:)`（`ModalScrim` 宿主）、`searchFocus` 的 `@FocusState` 与那条 `onChange`、`inspectorOn` 的 `@AppStorage`、`canCleanAll`、以及文件末尾整段关于启动扫描与 `WindowGeometryBridge` 的注释（后者描述的 hack 随 `NavigationSplitView` 一起失去存在理由）。

**删掉 `@AppStorage("hideEmptyCategories")`** —— 它现在只归 `SidebarView` 用，`ContentView` 里那份是重复声明。

- [ ] **Step 2: 确认弹层改 `.sheet`，删 `availableHeight`**

`CleanConfirmSheet` 的 `availableHeight` 参数与 `bodyMaxHeight = min(availableHeight * 0.58, 520)` 是 `ModalScrim` 传进来的。`.sheet` 不提供视口高度，所以：

- `CleanConfirmSheet` 去掉 `let availableHeight: CGFloat`
- `bodyMaxHeight` 改为固定 `520`
- `VStack` 外层的 `.frame(maxHeight: availableHeight)` 删掉
- `HeroFigure` 等内部对 `availableHeight` 的引用一并清掉

- [ ] **Step 3: 工具条放全局动作**

`.toolbar` 里放（绑在**真实按钮**上，⌘R / ⌘⌫ 才不会有两个响应者）：

- `一键扫描` / `正在扫描…`（`arrow.clockwise` / `arrow.triangle.2.circlepath`）→ `Task { await viewModel.scanConversations() }`，`.keyboardShortcut("r", modifiers: .command)`，`enabled: !isBusy`
- `清除全部` / `清除本分类`（`trash`，文案随 `viewModel.selectedCategory` 变）→ `viewModel.requestCleanAll()`，`.keyboardShortcut(.delete, modifiers: .command)`，`enabled: !viewModel.filteredConversations.isEmpty && !isBusy`
- `设置…`（`gear`）→ `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`

三个按钮都用 `.buttonStyle(.borderless)` 或系统默认；`清除全部` 用 `.tint(.red)`。

- [ ] **Step 4: `ConversationCleanApp` 去掉 `hiddenTitleBar`，加 `Settings` scene**

- 删 `.windowStyle(.hiddenTitleBar)`
- `.defaultSize(width: 1280, height: 820)`（原 1440×900 是原型尺寸）
- `.frame(minWidth: 1000, minHeight: 640)`（原 1100×680 是为旧三栏几何设的）
- 新增：
  ```swift
  Settings {
      SettingsView().environmentObject(viewModel)
  }
  ```

- ⌘F：`searchFieldFocused` 删掉后，`⌘F` 直接绑到列表列的 `.searchFocused`。做法是在 `ConversationListView` 暴露一个 `@FocusState`，或用 `FocusedValueKey`。**最简可行做法**：在 `.commands` 里保留 `Button("聚焦搜索框")`，但改为 `NotificationCenter` 广播，列表侧 `.onReceive` 收下后置 `searchFocused = true`。若 Task 6 的 `.searchFocused` 直接可用且 ⌘F 已由系统提供，就把这条 `CommandGroup` 整个删掉。
- 删掉文件末尾整段 `WindowGeometryBridge` 的历史注释

- [ ] **Step 5: 删掉三处过期状态与通知**

| 删除 | 位置 |
|---|---|
| `CleanViewModel.searchFieldFocused` | `CleanViewModel.swift:85` 及其上方注释 |
| `CleanViewModel.settingsPresented` | `CleanViewModel.swift:89` 及其上方注释 |
| `extension Notification.Name { static let ccFocusConversation }` | `ConversationListView.swift:8-10`（Task 6 已删订阅方，Task 5 删了发布方，这里删定义） |

`CleanPrefs` 在 Core 层的读取**不动**。

- [ ] **Step 6: 验证**

Run: `xcodebuild -scheme ConversationClean -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`
Run: `grep -rn "searchFieldFocused\|settingsPresented\|ccFocusConversation\|ModalScrim\|hiddenTitleBar\|WindowGeometryBridge" ConversationClean/` → 无输出
Run: `./scripts/run_tests.sh 2>&1 | tail -3` → 退出码 0

- [ ] **Step 7: 手工过一遍**

浅色 + 深色各跑一次，确认：系统标题栏正常（无 76pt 空白）、三栏可拖可折叠、⌘R 扫描、⌘⌫ 清除、⌘F 聚焦搜索、⌘, 打开设置窗口、点行 → 详情栏出元数据、取消选中 → 详情栏回到概览、确认弹层的真实卷数据正常。

- [ ] **Step 8: 提交**

```bash
git add ConversationClean/ContentView.swift ConversationClean/ConversationCleanApp.swift ConversationClean/ViewModels/CleanViewModel.swift ConversationClean/Views/CleanConfirmSheet.swift ConversationClean/Views/ConversationListView.swift
git commit -m "refactor(ui): 外壳换成 NavigationSplitView，恢复原生标题栏与 Settings 窗口

删掉自绘 46pt 标题栏、.padding(.leading, 76) 红绿灯避让、ignoresSafeArea(.top)、
跨全宽工具条、手搓三栏 HStack 与 ModalScrim。NavigationSplitView 自带工具栏，
旧 WindowGeometryBridge 那套绕行方案彻底失去存在理由。

恢复 Settings scene 接 ⌘,；确认弹层改 .sheet，CleanConfirmSheet 去掉
availableHeight 参数。

删除 searchFieldFocused / settingsPresented / ccFocusConversation 三处过期状态。"
```

---

### Task 10: 删除 `DesignSystem/`，清理 `project.pbxproj`，深色模式收尾扫描

**Files:**
- Delete: `ConversationClean/DesignSystem/CCTheme.swift`、`ConversationClean/DesignSystem/CCComponents.swift`
- Delete: `ConversationClean/DesignSystem/`（空目录）
- Modify: `ConversationClean.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Task 1–9 全部产出
- Produces: 无（收尾 task）

- [ ] **Step 1: 确认无人再引用设计系统**

Run: `grep -rn "CC\.\|CCButton\|CCBadge\|CCSearchField\|CCSegmented\|CCEmptyState\|CCBanner\|CCStatCell\|CCStackBar\|CCProgressLine\|CCSectionHeader\|CCIconButton\|ccHairline\|ModalScrim\|CC\." ConversationClean/`
Expected: 无输出。

有命中就说明还有视图没重写完——**回到对应 task 修完再继续**，不要在这里临时注释掉。

- [ ] **Step 2: 从 `project.pbxproj` 摘掉两个文件**

删 4 处（行号以当前文件为准，Task 4 已加过行）：

- `PBXBuildFile` 段：`CC01D1012D00000100000001 /* CCTheme.swift in Sources */` 与 `CC01D1022D00000100000001 /* CCComponents.swift in Sources */` 两行
- `PBXFileReference` 段：`CC02D1012D00000100000001` 与 `CC02D1022D00000100000001` 两行
- `DesignSystem` group 的 `children`（`project.pbxproj:139-142`）两行
- `PBXSourcesBuildPhase`（约 316-317 行）两行
- `ConversationClean` group 的 `children` 里的 `CC04D1002D00000100000001 /* DesignSystem */,`（约 118 行）
- 整个 `CC04D1002D00000100000001 /* DesignSystem */ = { ... };` group 定义（约 137-145 行）

- [ ] **Step 3: 删文件与目录**

```bash
git rm ConversationClean/DesignSystem/CCTheme.swift ConversationClean/DesignSystem/CCComponents.swift
rmdir ConversationClean/DesignSystem 2>/dev/null || true
```

- [ ] **Step 4: Review Focus 第 1 条——硬编码色值收尾扫描**

Run:
```bash
grep -rnE "Color\(hex:|Color\(red:|0x[0-9A-Fa-f]{6}" ConversationClean/
```
Expected: 无输出。

再扫一遍直接写死的尺寸色：

Run: `grep -rn "\.white\|\.black" ConversationClean/Views/`
Expected: 只允许出现在确实需要固定对比度的地方（如 `HatchedFill` 的斜纹、`checkmark` 在 accent 底上的反白）。每一处都要能说明为什么语义色不行。

- [ ] **Step 5: 验证**

Run: `xcodebuild -scheme ConversationClean -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`
Run: `./scripts/run_tests.sh 2>&1 | tail -3` → 退出码 0
Run: `xcodebuild -list -project ConversationClean.xcodeproj` → 正常列出 scheme（确认 pbxproj 没被改坏）
Run: `git status --short` → 无意外改动

- [ ] **Step 6: 打开工程确认 Xcode 能解析**

Run: `open ConversationClean.xcodeproj`
确认：Xcode 打开无警告、工程树里 `DesignSystem` 组已消失、`Core/Formatting.swift` 与 `Views/OverviewView.swift` 都在且**不是**红色（红色表示未登记在编译阶段）。

- [ ] **Step 7: 跑一遍 spec §7 验收清单**

逐项打勾。重点：15 款分类导航、搜索三字段、三种排序、批量条数字、右键菜单四项、四种空态、两个横幅、六款双层索引 Agent 的原子清理说明、确认弹层卷数据、设置三页、⌘R/⌘⌫/⌘F/Space/Return、全部 `@AppStorage` 跨启动保持。

- [ ] **Step 8: 更新 README 的目录结构**

`README.md:56-58` 的目录树里 `Views/` 与 `DesignSystem/` 两行已过时（`DesignSystem` 已删，新增了 `Core/Formatting.swift` 与 `Views/OverviewView.swift`）。同步更新，并把「现代 macOS 设计规范」那条特性描述从「统一工具栏」改为反映 `NavigationSplitView` + 系统控件 + 深色模式。

- [ ] **Step 9: 提交**

```bash
git add -A
git commit -m "refactor(ui): 删除自绘设计系统，界面完全落到系统控件与语义色

CCTheme.swift + CCComponents.swift 共 839 行删除。Fmt 已在 Task 1 搬到
Core/Formatting.swift，扫描器测试套件通过 glob Core 继续编译它。

界面现在 100% 走 List / Picker / Form / TabView / .sheet / NavigationSplitView，
颜色 100% 走语义色——深色模式因此自动成立，无需为它单独做任何事。

净变化：视图层 -2900 行，设计系统 -839 行。"
```

---

## 收尾

10 个 task 全部完成后：

```bash
git log --oneline -11
```

应能看到 10 个粒度清晰的 commit，每个都能独立编译、独立通过回归套件。

**建议的下一步**（不在本计划范围内，需另开 spec）：

- 把 `scripts/tests/` 从手写 `TestRunner` 迁到 SwiftPM + XCTest，顺带获得测试发现与并行。
- 若 `Core/` 里再出现可测的纯逻辑（分布段计算、清理估算），补对应测试。
