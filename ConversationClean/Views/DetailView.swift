import SwiftUI

struct DetailView: View {
    @EnvironmentObject var viewModel: CleanViewModel
    @State private var selectedConversation: ConversationItem?

    var body: some View {
        VStack(spacing: 0) {
            // 操作栏
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.selectedCategory.rawValue)
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("共 \(viewModel.filteredConversations.count) 个会话项，已选中 \(viewModel.selectedItems.count) 项 (\(ByteCountFormatter.string(fromByteCount: viewModel.selectedSize, countStyle: .file)))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    let allSelected = viewModel.filteredConversations.allSatisfy { $0.isSelected }
                    viewModel.selectAll(!allSelected)
                } label: {
                    let allSelected = !viewModel.filteredConversations.isEmpty && viewModel.filteredConversations.allSatisfy { $0.isSelected }
                    Label(allSelected ? "取消全选" : "全选当前", systemImage: allSelected ? "checkmark.circle.fill" : "circle")
                }
                .disabled(viewModel.filteredConversations.isEmpty)

                Button(role: .destructive) {
                    Task {
                        await viewModel.cleanSelected()
                    }
                } label: {
                    Label(viewModel.isCleaning ? "清理中..." : "清理选中项", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(viewModel.selectedItems.isEmpty || viewModel.isCleaning)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if viewModel.filteredConversations.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("暂无匹配的会话记录")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedConversation) {
                    ForEach($viewModel.conversations) { $item in
                        if viewModel.selectedCategory == .all || item.category == viewModel.selectedCategory {
                            if viewModel.searchText.isEmpty ||
                               item.title.localizedCaseInsensitiveContains(viewModel.searchText) ||
                               item.snippet.localizedCaseInsensitiveContains(viewModel.searchText) {
                                ConversationRowView(item: $item)
                                    .tag(item)
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }
}

struct ConversationRowView: View {
    @Binding var item: ConversationItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $item.isSelected)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.title)
                        .font(.body)
                        .fontWeight(.medium)

                    Spacer()

                    Text(item.formattedSize)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                }

                Text(item.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack {
                    Label("\(item.messageCount) 条消息", systemImage: "message")
                    Text("•")
                    Text(item.formattedDate)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
