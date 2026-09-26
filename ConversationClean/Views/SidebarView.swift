import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    var body: some View {
        List(selection: $viewModel.selectedCategory) {
            Section("Agent 分类") {
                ForEach(ConversationCategory.allCases) { category in
                    HStack(spacing: 8) {
                        Image(systemName: category.iconName)
                            .foregroundColor(color(for: category))
                            .frame(width: 18)

                        Text(category.rawValue)
                            .font(.body)

                        Spacer()

                        let stat = viewModel.categoryStats[category] ?? CategoryStats()

                        if stat.count > 0 {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(stat.count)")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(Capsule())

                                Text(stat.formattedSize)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("0")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tag(category)
                    .padding(.vertical, 2)
                }
            }

            Section("Agent 状态") {
                ForEach(viewModel.agentInfos) { info in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle()
                                .fill(info.isInstalled ? Color.green : Color.secondary.opacity(0.5))
                                .frame(width: 7, height: 7)
                            Text(info.category.rawValue)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                            Text(info.isInstalled ? (info.sessionCount > 0 ? "\(info.sessionCount) 会话" : "空闲") : "未安装")
                                .font(.caption2)
                                .foregroundStyle(info.isInstalled ? .primary : .secondary)
                        }

                        Text(info.storagePath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 3)
                }
            }

            Section("统计概览") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("总缓存占用")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: viewModel.totalSize, countStyle: .file))
                                .font(.title3)
                                .fontWeight(.bold)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("总会话数")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(viewModel.conversations.count)")
                                .font(.title3)
                                .fontWeight(.bold)
                        }
                    }

                    if viewModel.totalSize > 0 {
                        Button(role: .destructive) {
                            viewModel.requestCleanAll()
                        } label: {
                            HStack {
                                Image(systemName: "trash.fill")
                                Text("一键清除全部")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red.opacity(0.85))
                        .controlSize(.small)
                        .padding(.top, 4)
                        .disabled(viewModel.isCleaning || viewModel.conversations.isEmpty)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 240)
    }

    private func color(for category: ConversationCategory) -> Color {
        switch category {
        case .all: return .accentColor
        case .claudeCode: return .orange
        case .codex: return .green
        }
    }
}
