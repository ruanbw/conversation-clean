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

    /// 标题栏「检视器」按钮的开关态（对应原型 `#btnPanel` 的 `aria-pressed`）。
    /// 原型 `P.panel = false`，默认关闭。
    ///
    /// 持久化到 `UserDefaults`（原型 `P.panel` 存 `cc.proto.v1`）：面板是纯观感偏好，
    /// 每次启动都重置会让「上次铺开的面板」这个心智模型失效。
    @AppStorage("inspectorVisible") private var inspectorOn: Bool = false
    /// 侧栏「仅显示有数据」开关（原型 `P.zero`），同样持久化。
    @AppStorage("hideEmptyCategories") private var hideEmpty: Bool = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                titleBar
                workspaceToolbar
                split
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { modals(viewportHeight: geo.size.height) }
        }
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
        // ⌘F 从 `.commands` 里改的是 `viewModel.searchFieldFocused`，
        // 这里把它翻译成本地 `@FocusState`，搜索框才会真的获得键盘焦点。
        .onChange(of: viewModel.searchFieldFocused) { _, wanted in
            guard wanted else { return }
            searchFocus = true
            // 复位，让下一次 ⌘F 能再次触发（否则值没变化，onChange 不再回调）。
            viewModel.searchFieldFocused = false
        }
    }

    /// 两层弹层都用窗口内遮罩，不用 `.sheet`。
    ///
    /// 之前是 `.sheet`，形态和原型差三处：① sheet 会另开一个附着窗口、从标题栏
    /// 滑下，而原型是窗口内一层 `position:fixed; inset:0` 的遮罩；② sheet 抢走
    /// 窗口的 key 状态；③ 两个 `.sheet` 挂在不同 view 上时彼此顶掉。
    /// 换成 `ModalScrim` 后交通灯保持可用，与原型的 `.scrim` 一致。
    ///
    /// Esc 的优先级对齐原型末尾那段 keydown：设置先关、确认面板后关。
    @ViewBuilder
    private func modals(viewportHeight: CGFloat) -> some View {
        if viewModel.settingsPresented {
            ModalScrim(viewportHeight: viewportHeight, onDismiss: {
                viewModel.settingsPresented = false
            }) { _ in
                SettingsView()
                    .environmentObject(viewModel)
            }
        } else if viewModel.showCleanConfirmAlert {
            ModalScrim(viewportHeight: viewportHeight, onDismiss: {
                viewModel.cancelClean()
            }) { available in
                CleanConfirmSheet(availableHeight: available)
                    .environmentObject(viewModel)
            }
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

            // `#btnPanel`：ghost + 面板图标，切换第三栏显隐。
            // `isOn` 给出原型的开启态（fg-soft 底 + fg 字色），
            // 之前只有无障碍 trait，视觉上看不出面板开着没有。
            CCButton(
                title: "检视器",
                systemImage: "sidebar.right",
                kind: .ghost,
                compact: true,
                isOn: inspectorOn,
                help: "显示/隐藏检视器"
            ) {
                withAnimation(CC.Mv.base) { inspectorOn.toggle() }
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
                viewModel.settingsPresented = true
            }
        }
        .padding(.leading, 76)
        .padding(.trailing, 14)
        .frame(height: 46)          // 原型 .titlebar{height:46px}
        // 原型 `color-mix(in oklch, var(--bg) 55%, var(--surface))` ≈ #FAFCFD
        .background(CC.panelStrong)
        .ccHairline(.bottom)
    }

    // MARK: - 工具条（原型 `.toolbar`，跨全宽）

    /// 搜索框 + 清除全部 + 一键扫描，横跨整个窗口宽度，压在侧栏和列表之上。
    private var workspaceToolbar: some View {
        HStack(spacing: 10) {
            // 不传 width：对应 `.search{flex:1; max-width:420px}`
            CCSearchField(
                text: $viewModel.searchText,
                placeholder: "搜索标题、摘要、项目路径或会话 ID",
                focusBinding: $searchFocus
            )

            Spacer(minLength: 8)

            // 原型 `#btnCleanAll`：ghost 样式 + 文案随分类切换
            // （"清除全部" / "清除本分类"），见 prototype.html renderList()
            CCButton(
                title: viewModel.selectedCategory == .all ? "清除全部" : "清除本分类",
                systemImage: "trash",
                kind: .ghost,
                enabled: canCleanAll,
                help: viewModel.selectedCategory == .all
                    ? "清除当前列表中的全部会话"
                    : "清除当前分类下的全部会话"
            ) {
                viewModel.requestCleanAll()
            }
            .keyboardShortcut(.delete, modifiers: .command)

            CCButton(
                title: viewModel.isScanning ? "正在扫描…" : "一键扫描",
                systemImage: viewModel.isScanning ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                kind: .primary,
                enabled: !isBusy,
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

    /// 搜索框的本地焦点态。
    ///
    /// 不直接绑到 `viewModel.searchFieldFocused`：`FocusState<Bool>.Binding`
    /// 没有公开构造器，只能由 `@FocusState` 属性包装器自己产出，没法手工造一个
    /// 把 ViewModel 的 Bool 接进来的绑定。所以改成「本地持有 + 双向同步」：
    /// `CCSearchField` 拿的是 `$searchFocus`（属性包装器生成的合法绑定），
    /// ⌘F 走 `.commands` 改的是 ViewModel 上的 Bool，这里 `onChange` 再把它推给本地态。
    @FocusState private var searchFocus: Bool

    /// 原型 `runBusy()` 期间会同时禁用扫描、清除本分类、清理选中三个入口。
    private var isBusy: Bool { viewModel.isScanning || viewModel.isCleaning }

    // MARK: - 三栏（原型 `.split`）
    //
    // 原型是 CSS Grid：
    //   .split          { grid-template-columns: 272px minmax(0,1fr) 0 }
    //   .split.inspect  { grid-template-columns: 272px minmax(0,1fr) 324px }
    //   transition: grid-template-columns .18s ease
    //
    // **这里手搓 HStack 而不用 `NavigationSplitView`。** 换掉的原因是后者带了一整套
    // 原型不存在的行为：自动向窗口挂一条 NSToolbar（顶部会多出 ~52pt 的带子，
    // 逼得 App 层写 WindowGeometryBridge 去藏它）、第一栏套 sidebar 材质、
    // 列宽可拖拽、可被系统折叠、还有自己的列宽记忆。这些都会让「像不像原型」失守。
    //
    // 宽度必须用 `.frame(width:)` 插值 0↔324 而不是 `.transition`：
    // transition 只让检视器自己淡入淡出，中栏宽度不变 —— 那就变成 overlay 了；
    // 原型动的是**第三列的列宽**，效果是中栏被推开、检视器从右缘顶进来。

    private var split: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: CC.M.sidebar)

            // 原型两栏之间都是 1px 边框。侧栏自画右侧发丝线、检视器自画左侧发丝线，
            // 所以这里不再插分隔条，避免双线。
            ConversationListView(onRequestInspector: {
                if !inspectorOn { withAnimation(CC.Mv.base) { inspectorOn = true } }
            })
            .frame(maxWidth: .infinity)
            .background(CC.surface)

            if inspectorOn {
                InspectorPanel()
                    .frame(width: CC.M.inspector)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(CC.bg)
    }

    // MARK: - 派生状态

    private var canCleanAll: Bool {
        !viewModel.filteredConversations.isEmpty && !isBusy
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
// ⌘F 例外：它必须定义在 App 的 `.commands` 里（原型挂在 `document` 的 keydown 上，
// 语义是「命令」而不是某个按钮的快捷键），焦点态因此经由 viewModel 传递。
