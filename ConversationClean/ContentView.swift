import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
        }
        .searchable(text: $viewModel.searchText, prompt: "搜索提示词、项目路径或会话ID...")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if viewModel.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                }

                Button {
                    Task {
                        await viewModel.scanConversations()
                    }
                } label: {
                    Label(viewModel.isScanning ? "正在扫描..." : "一键扫描", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isScanning)
                .help("一键扫描本地 Claude Code 及 Codex 会话记录")

                Button(role: .destructive) {
                    viewModel.requestCleanAll()
                } label: {
                    Label("一键清除", systemImage: "trash")
                }
                .disabled(viewModel.isScanning || viewModel.filteredConversations.isEmpty || viewModel.isCleaning)
                .help("一键清除当前分类下的所有会话")
            }
        }
        .alert("确认清除会话？", isPresented: $viewModel.showCleanConfirmAlert) {
            Button("确认清除", role: .destructive) {
                Task {
                    await viewModel.executeClean()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .alert("清理完成", isPresented: $viewModel.showCleanSuccessAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("成功释放 \(ByteCountFormatter.string(fromByteCount: viewModel.lastCleanedBytes, countStyle: .file)) 本地磁盘存储空间。")
        }
        .task {
            await viewModel.scanConversations()
        }
    }

    private var confirmMessage: String {
        switch viewModel.cleanTarget {
        case .selected:
            let count = viewModel.selectedItems.count
            let size = ByteCountFormatter.string(fromByteCount: viewModel.selectedSize, countStyle: .file)
            return "即将删除选中的 \(count) 个会话文件及关联快照，预计释放 \(size) 空间。\n此操作不可撤销，是否继续？"
        case .allInCurrentCategory:
            let count = viewModel.filteredConversations.count
            let size = ByteCountFormatter.string(fromByteCount: viewModel.currentCategorySize, countStyle: .file)
            return "即将清除 [\(viewModel.selectedCategory.rawValue)] 下的所有 \(count) 个会话及关联快照，预计释放 \(size) 空间。\n此操作不可撤销，是否继续？"
        }
    }
}
