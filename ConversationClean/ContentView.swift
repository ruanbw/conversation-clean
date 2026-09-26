import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
        }
        .searchable(text: $viewModel.searchText, prompt: "搜索会话标题或内容...")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task {
                        await viewModel.scanConversations()
                    }
                } label: {
                    Label(viewModel.isScanning ? "扫描中..." : "重新扫描", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isScanning)
                .help("重新扫描本地会话文件")
            }
        }
        .alert("清理完成", isPresented: $viewModel.showCleanSuccessAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("成功释放 \(ByteCountFormatter.string(fromByteCount: viewModel.lastCleanedBytes, countStyle: .file)) 存储空间。")
        }
    }
}
