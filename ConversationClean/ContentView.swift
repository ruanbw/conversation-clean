import SwiftUI
import AppKit

// MARK: - ContentView · 三栏工作台
//
// 结构照 DefaultAppManager 的 MainSplitView：**不是** NavigationSplitView。
// 原因就一条：红绿灯。
//
// 用系统标题栏时，红绿灯底下那块是系统画的原生标题栏，颜色不可控 —— 深色模式下
// 侧栏是深灰、标题栏是另一种灰，视觉上永远是"贴了块补丁"。`.windowStyle(.hiddenTitleBar)`
// 把那块变成我们自己的背景，深浅色自动跟着走，代价是得自己给红绿灯让出左侧 78pt。
//
// 另外三栏也是手搓 HStack + Divider，不是 NavigationSplitView：后者会自己往窗口上
// 挂一条 NSToolbar（多出 ~52pt 带子）、给侧栏套 sidebar 材质、列宽可拖拽且自带记忆，
// 这些都不是我们要的形态。
//
// 本文件只管窗口这一层：顶部条、三栏几何、全局动作、弹层编排。
// 侧栏 / 列表 / 详情栏各自画自己的内容。

struct ContentView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 230)
                Divider()
                ConversationListView()
                    .frame(minWidth: 340, idealWidth: 400, maxWidth: .infinity)
                Divider()
                DetailView()
                    .frame(minWidth: 300, maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // 让内容铺到窗口最顶端 y=0，红黄绿浮在我们自己的背景上。
        // 不用 NSWindow.styleMask 插 fullSizeContentView：那个 mask 由 SwiftUI 自己持有，
        // 手动插会被回退。
        .ignoresSafeArea(edges: .top)
        .sheet(isPresented: $viewModel.showCleanConfirmAlert) {
            CleanConfirmSheet()
                .environmentObject(viewModel)
        }
    }

    // MARK: - 顶部条
    //
    // 左侧 78pt 让给红绿灯（三个 12pt 圆点 + 两个 8pt gap + 16pt 外边距），
    // 之后是产品名，右侧是全局动作。

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("ConversationClean")
                .font(.system(size: 13, weight: .semibold))
            Text("· 会话清理")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            // 总量是常量信息，常驻顶栏即可；把它摊在详情栏整页里既占地方
            // 又给不出下一步动作，那一栏改成了「占用大户 Top 5」
            Divider().frame(height: 12).padding(.horizontal, 4)
            Text(Fmt.bytes(viewModel.totalSize))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text("· \(viewModel.conversations.count) 个会话")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            iconButton("trash", "清除当前列表中的全部会话",
                       enabled: !viewModel.filteredConversations.isEmpty && !isBusy) {
                viewModel.requestCleanAll()
            }
            .keyboardShortcut(.delete, modifiers: .command)

            Button {
                Task { await viewModel.scanConversations() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: viewModel.isScanning ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                    Text(viewModel.isScanning ? "正在扫描…" : "一键扫描")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(isBusy ? Color.secondary : Color.accentColor)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(isBusy ? 0.08 : 0.14))
                )
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .keyboardShortcut("r", modifiers: .command)
            .help("扫描本机全部 Agent 的会话缓存")

            iconButton("gear", "设置", enabled: true) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        .padding(.leading, 78)   // 红黄绿让位
        .padding(.trailing, 12)
        .frame(height: 44)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var isBusy: Bool { viewModel.isScanning || viewModel.isCleaning }

    private func iconButton(_ symbol: String, _ help: String,
                            enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.4))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}
