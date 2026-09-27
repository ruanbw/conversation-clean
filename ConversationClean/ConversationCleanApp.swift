import SwiftUI
import AppKit

@main
struct ConversationCleanApp: App {
    @StateObject private var viewModel = CleanViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                // 三栏最小宽度之和（272 + 460 + 324 = 1056）再留一点伸缩余量。
                // 窗口级最小尺寸统一在这里声明，ContentView 不再重复。
                .frame(minWidth: 1100, minHeight: 680)
                // 启动扫描的发起点。`scanOnLaunchIfEnabled()` 内部带幂等闸门，
                // 所以后续新开窗口重跑这份 `.task` 也只会真扫一遍。
                // 启动扫描不能留在 ContentView 里：那里的 `.task` 无条件跑
                // scanConversations()，会把设置里的「启动时自动扫描」彻底绕过去。
                .task {
                    await viewModel.scanOnLaunchIfEnabled()
                }
        }
        // 隐藏系统标题栏：原型 `.titlebar` 是一行自绘的 46pt 横条（标题、检视器、设置
        // 都在同一行），而系统标题栏会把标题拆成两行、还给工具栏项加一层胶囊背景，
        // 两处都对不上。隐藏后由 ContentView 自绘这一行，系统红黄绿仍浮在内容之上。
        .windowStyle(.hiddenTitleBar)
        // 原型窗口尺寸 1440×900，三栏 272 / 844 / 324。
        .defaultSize(width: 1440, height: 900)
        .defaultPosition(.center)
        // 缩到 1100×680 就停：再窄中栏（min 460）会把会话标题挤成两行。
        .windowResizability(.contentMinSize)
        .commands { appCommands }

        // 原型**没有独立的设置窗口**，只有一个居中的弹层，入口是标题栏那颗齿轮按钮。
        // 这里曾经声明过 `Settings { }` scene，于是菜单里会多出一个「设置…」，
        // 打开的是另一个带窗口边框的 SettingsView —— 同一份 UI、两个入口、两种形态。
        // 删掉 scene，弹层统一由 ContentView 的 `ModalScrim` 承载。
    }

    // MARK: - 菜单命令
    //
    // 只留原型定义过的快捷键。`SidebarCommands()` 随 NavigationSplitView 一起去掉了：
    // ⇧⌘S「显示/隐藏边栏」指向的侧栏现在没有可折叠状态，命令会变成空操作。
    /// 注意：这里是 `@CommandsBuilder`，**不是** `@ViewBuilder`。
    /// 两者都能包住 `CommandGroup`，但 `Commands` 走的是自己的 result builder；
    /// 误加 `@ViewBuilder` 会让它按 View 的规则求值，编译报
    /// 「`buildExpression` requires that `CommandGroup<EmptyView>` conform to `View`」。
    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .newItem) {}

        // 原型末尾 keydown 里的 ⌘F 分支：聚焦搜索框并全选现有内容。
        // 放在 `textEditing` 组里，紧挨系统自带的查找类命令。
        CommandGroup(after: .textEditing) {
            Button("聚焦搜索框") {
                viewModel.searchFieldFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}

// 这里曾经有一个 `WindowGeometryBridge`（NSViewRepresentable），用来把
// `NavigationSplitView` 自动挂上的 NSToolbar 藏起来：
//
//   0 ──── ~52pt 系统工具栏带（sidebarToggle 按钮孤零零浮在中间）────
//  52 ──── 46pt 自绘标题栏（产品名 + 检视器 + 设置）──────────
//
// `.toolbar(removing: .sidebarToggle)` 删得掉按钮、删不掉工具栏本身，
// 所以只能从 `window.toolbar.isVisible` 下手，还要在 `viewDidMoveToWindow`
// 之后连补两拍 `DispatchQueue.main.async` 才压得住 SwiftUI 建 toolbar 的时序。
//
// 现在三栏改成手搓 `HStack`（见 `ContentView.split`），没有任何 view 会再
// 触发 toolbar 自动挂载，这套 hack 连带它的时序注释一起失去存在理由 —— 删。
//
// 顺带说明一件仍然保留的事：让内容铺到窗口顶端走的是
// `ignoresSafeArea(edges: .top)`，不是往 `NSWindow.styleMask` 插
// `fullSizeContentView`。Apple 开发者论坛报告 macOS 26.3 起 custom styleMask
// 的窗口会出现不可缩放、鼠标事件穿透等异常，而该 mask 由 SwiftUI 自己持有，
// 手动插入必然被回退。
