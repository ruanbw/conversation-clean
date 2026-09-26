import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    var body: some View {
        List(selection: $viewModel.selectedCategory) {
            Section("会话分类") {
                ForEach(ConversationCategory.allCases) { category in
                    NavigationLink(value: category) {
                        Label {
                            HStack {
                                Text(category.rawValue)
                                Spacer()
                                let count = category == .all
                                    ? viewModel.conversations.count
                                    : viewModel.conversations.filter { $0.category == category }.count
                                Text("\(count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: category.iconName)
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }

            Section("统计概览") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("总缓存占用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: viewModel.totalSize, countStyle: .file))
                        .font(.headline)
                        .fontWeight(.semibold)
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }
}
