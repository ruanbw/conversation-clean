import SwiftUI
import AppKit

// MARK: - ContentView · 三栏骨架
//
// 全部交给系统：NavigationSplitView 承载三栏与工具栏，.searchable 提供搜索，
// .sheet 承载清理确认弹层。不再自绘标题栏、工具条、遮罩或发丝线。
//
// 侧栏 / 列表 / 详情栏各自画自己的内容，本文件只管这一层几何与全局动作。

struct ContentView: View {
    @EnvironmentObject var viewModel: CleanViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } content: {
            ConversationListView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 420)
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { toolbarItems }
        .sheet(isPresented: $viewModel.showCleanConfirmAlert) {
            CleanConfirmSheet()
                .environmentObject(viewModel)
        }
    }

    private var isBusy: Bool { viewModel.isScanning || viewModel.isCleaning }

    // MARK: - 全局动作
    //
    // 快捷键绑在真实按钮上（⌘R / ⌘⌫），否则同一快捷键会出现在两个响应者上。
    // ⌘F 不在这里 —— 它由 .searchable 自带。

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                viewModel.requestCleanAll()
            } label: {
                Label(
                    viewModel.selectedCategory == .all ? "清除全部" : "清除本分类",
                    systemImage: "trash"
                )
            }
            .help(viewModel.selectedCategory == .all
                  ? "清除当前列表中的全部会话"
                  : "清除当前分类下的全部会话")
            .disabled(viewModel.filteredConversations.isEmpty || isBusy)
            .keyboardShortcut(.delete, modifiers: .command)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await viewModel.scanConversations() }
            } label: {
                Label(
                    viewModel.isScanning ? "正在扫描…" : "一键扫描",
                    systemImage: viewModel.isScanning ? "arrow.triangle.2.circlepath" : "arrow.clockwise"
                )
            }
            .help(viewModel.isScanning ? "正在扫描本机会话缓存" : "扫描本机全部 Agent 的会话缓存")
            .disabled(isBusy)
            .keyboardShortcut("r", modifiers: .command)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("设置", systemImage: "gear")
            }
            .help("设置")
        }
    }
}
