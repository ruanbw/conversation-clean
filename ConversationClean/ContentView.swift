import SwiftUI

// MARK: - CCWorkbench · 三栏工作台骨架 + 全局编排
//
// 严格对应原型 `.desk > .window` 的纵向结构（docs/prototype.html 68-105 行）：
//
//   header.titlebar   46px  跨全宽   [标题 · 副标题]        ......  [检视器] [设置]
//   div.toolbar       52px  跨全宽   [搜索............]  [清除全部] [一键扫描]
//   div.split                三栏     sidebar | content | inspector
//
// 关键点：**标题栏和工具条都跨越整个窗口宽度，位于三栏之上**。
// 早期版本把工具条塞在中间栏内部，结果侧栏和搜索框并排显示 —— 与原型的
// 「搜索条压在整个侧栏之上」完全不同，这是结构性差异，不是细节差异。
//
// 本文件只负责窗口这一层：三栏几何、标题栏、工具条、sheet 编排、最小尺寸。
// 侧栏 / 列表 / 检视器各自画自己的分区内容，本文件不重复实现。

struct ContentView: View {

    @EnvironmentObject var viewModel: CleanViewModel

    /// 对应原型 `.split` 的第三列：grid-template-columns 第三列是 `0` 与 `324px`
    /// 两种状态，`.doubleColumn` 即「第三列 0」。
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// 标题栏「检视器」按钮的开关态（对应原型 `#btnPanel` 的 `aria-pressed`）。
    @State private var inspectorOn: Bool = true

    /// 标题栏「设置」按钮的弹层开关（对应原型 `#btnSettings` → `.settings` 弹层）。
    @State private var settingsOn: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            workspaceToolbar
            split
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 关键的一行：让内容从窗口**顶端** y=0 开始铺，而不是从标题栏下沿开始。
        //
        // 配合 App 层的 `.windowStyle(.hiddenTitleBar)`，系统标题栏变成透明浮层，
        // 红黄绿压在自绘 titleBar 上（46pt 行内），于是顶部总共就一行，和原型的
        // `header.titlebar{height:46px}` 一一对应。
        //
        // 不用 `NSWindow.styleMask.insert(.fullSizeContentView)` 去拿全尺寸：
        // 那个 mask 由 SwiftUI 自己持有，手动插入会被回写（macOS 26.3 起 custom
        // styleMask 还有已知的交互异常），而 `ignoresSafeArea` 是受支持的官方路径。
        .ignoresSafeArea(edges: .top)
        .background(CC.bg)
        // 确认清除用 sheet 而非 alert：alert 是系统材质弹层，和原型的自定义面板不是一套观感，
        // 而且弹层外观由 CleanConfirmSheet 自己负责，这里不插手。
        .sheet(isPresented: $viewModel.showCleanConfirmAlert) {
            CleanConfirmSheet()
                .environmentObject(viewModel)
                // 这里不能再套 frame：sheet 窗口按内容的 fixed 宽度开窗，
                // 外层再加一层 minWidth/minHeight 会让窗口尺寸与内容实际宽度脱钩，
                // 表现为内容被居中后两侧裁掉。
                // 面板的 520 宽由 CleanConfirmSheet 自身的 .frame(width: 520) 决定。
        }
    }

    // MARK: - 标题栏（原型 `.titlebar`）

    /// 窗口用 `.windowStyle(.hiddenTitleBar)` + `WindowGeometryBridge` 打开的全尺寸内容，
    /// 所以这一行就是窗口最顶端的一行：系统红黄绿浮在它上面，靠左侧 82pt 让位避让。
    /// 82 = 原型 `padding:0 16px` + 三个 12pt 圆点 + 两个 8px gap + 14px gap，
    /// 即自绘标题与红黄绿的水平间距与原型逐像素对齐。
    ///
    /// 这里的标题是应用的真实身份，**不画原型那个「演示数据」标签** ——
    /// 原型是假数据演示，本应用扫的是本机真实会话，挂演示标签属于误导。
    private var titleBar: some View {
        HStack(spacing: 14) {
            // `.appname`：13pt 600 的产品名 + 13pt 400 muted 的副标题，同一行
            Text("ConversationClean")
                .font(CC.F.bodyEm)
                .foregroundStyle(CC.fg)
            + Text(" · 会话清理")
                .foregroundStyle(CC.muted)

            Spacer(minLength: 12)

            // `#btnPanel`：ghost + 面板图标，切换第三栏显隐
            CCButton(
                title: "检视器",
                systemImage: "sidebar.right",
                kind: .ghost,
                compact: true,
                help: "显示/隐藏检视器"
            ) {
                toggleInspector()
            }
            .accessibilityAddTraits(inspectorOn ? .isSelected : [])

            // `#btnSettings`：ghost + 齿轮图标，打开设置弹层
            CCButton(
                title: "设置",
                systemImage: "gear",
                kind: .ghost,
                compact: true,
                help: "设置"
            ) {
                settingsOn = true
            }
        }
        .padding(.leading, 76)
        .padding(.trailing, 14)
        .frame(height: 46)          // 原型 .titlebar{height:46px}
        // 原型 `color-mix(in oklch, var(--bg) 55%, var(--surface))` ≈ #FAFCFD
        .background(CC.panel)
        .ccHairline(.bottom)
    }

    // MARK: - 工具条（原型 `.toolbar`，跨全宽）

    /// 搜索框 + 清除全部 + 一键扫描，横跨整个窗口宽度，压在侧栏和列表之上。
    private var workspaceToolbar: some View {
        HStack(spacing: 10) {
            // 不传 width：对应 `.search{flex:1; max-width:420px}`
            CCSearchField(
                text: $viewModel.searchText,
                placeholder: "搜索标题、摘要、项目路径或会话 ID"
            )

            Spacer(minLength: 8)

            CCButton(
                title: "清除全部",
                systemImage: "trash",
                kind: .outline,
                enabled: canCleanAll,
                help: "清除当前列表中的全部会话"
            ) {
                viewModel.requestCleanAll()
            }
            .keyboardShortcut(.delete, modifiers: .command)

            CCButton(
                title: viewModel.isScanning ? "正在扫描…" : "一键扫描",
                systemImage: viewModel.isScanning ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                kind: .primary,
                enabled: !viewModel.isScanning,
                help: viewModel.isScanning ? "正在扫描本机会话缓存" : "扫描本机全部 Agent 的会话缓存"
            ) {
                Task { await viewModel.scanConversations() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)           // 原型 .toolbar{height:52px}
        .background(CC.surface)
        .ccHairline(.bottom)
    }

    // MARK: - 三栏（原型 `.split`）

    private var split: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: CC.M.sidebar, max: 340)
        } content: {
            ConversationListView()
                // 中栏在原型里是纯 --surface（.list 没有自己的底色），
                // 这里补一层兜底底色，避免子视图未铺满时漏出系统材质。
                .background(CC.surface)
                .navigationSplitViewColumnWidth(min: 460, ideal: 720)
        } detail: {
            InspectorPanel()
                .navigationSplitViewColumnWidth(min: 280, ideal: CC.M.inspector, max: 420)
        }
        .background(CC.bg)
        // 三栏各自画了头部，窗口顶部只保留自绘的 titleBar。
        // `.sidebarToggle` 是 macOS 14 起 `toolbar(removing:)` 唯一可用的默认项，
        // 去掉它，窗口顶部就不会多出一个系统侧栏按钮。
        //
        // 为什么没有 `.toolbar(removing: .primaryAction)`：
        // `ToolbarDefaultItemKind` 在 macOS 14 只有 `.sidebarToggle`，
        // `.title` 是 macOS 15、`.search` 是 macOS 26，压根没有 `.primaryAction`
        // （`.primaryAction` 是 `ToolbarItemPlacement` 的 case，不是可移除的默认项）。
        //
        // 挂在 NavigationSplitView 外层而不是分栏内部：三栏各自挂 toolbar(removing:)
        // 会让移除指令只对该栏生效、作用域过窄。
        .toolbar(removing: .sidebarToggle)
        // 设置弹层挂在这一层（与外层「清理确认」sheet 不是同一棵 view），
        // 避免两个 `.sheet` 挂在同一棵 view 上互相顶掉。
        // 容器 760×560 由 SettingsView 自己画，这里不设 frame。
        .sheet(isPresented: $settingsOn) {
            SettingsView()
                .environmentObject(viewModel)
        }
    }

    // MARK: - 派生状态

    /// 标题栏「检视器」按钮：切 `columnVisibility` 即切 `.split` 第三列的 0 / 324px。
    private func toggleInspector() {
        inspectorOn.toggle()
        columnVisibility = inspectorOn ? .all : .doubleColumn
    }

    private var canCleanAll: Bool {
        !viewModel.filteredConversations.isEmpty && !viewModel.isCleaning && !viewModel.isScanning
    }
}

// 注意：启动扫描**不在本文件发起**。
// 设在这里的 `.task` 会无条件跑 scanConversations()，把设置面板里
// 「启动应用时自动扫描会话」这个开关彻底绕过去（scanConversations() 自身的
// isCleaning/isScanning 只防并发，不看开关）。
// 唯一入口是 ConversationCleanApp 里的 `.task { await viewModel.scanOnLaunchIfEnabled() }`，
// 它会先读 CleanPrefs.autoScanOnLaunch，并用 hasAttemptedLaunchScan 做幂等
// （WindowGroup 每开一个新窗口都会重跑一次 .task）。
//
// ⌘R（扫描）/ ⌘⌫（清除）快捷键挂在上面 workspaceToolbar 的真实按钮上，
// 不另造代理按钮，否则同一快捷键会出现在两个响应者上。
