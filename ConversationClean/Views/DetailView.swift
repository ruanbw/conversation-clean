import SwiftUI

struct DetailView: View {
    @EnvironmentObject var viewModel: CleanViewModel
    @State private var selectedConversation: ConversationItem?

    var body: some View {
        VStack(spacing: 0) {
            // 操作栏
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.selectedCategory.iconName)
                            .foregroundColor(categoryColor(viewModel.selectedCategory))
                        Text(viewModel.selectedCategory.rawValue)
                            .font(.title2)
                            .fontWeight(.bold)
                    }

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
                    viewModel.requestCleanSelected()
                } label: {
                    Label(
                        viewModel.isCleaning ? "清理中..." : "清理选中项 (\(viewModel.selectedItems.count))",
                        systemImage: "trash"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(viewModel.selectedItems.isEmpty || viewModel.isCleaning)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if viewModel.filteredConversations.isEmpty {
                emptyStateView
            } else {
                List(selection: $selectedConversation) {
                    ForEach(viewModel.filteredConversations) { item in
                        ConversationRowView(
                            item: item,
                            isSelected: Binding(
                                get: { item.isSelected },
                                set: { viewModel.setItemSelected(item.id, selected: $0) }
                            )
                        )
                        .tag(item)
                                    .contextMenu {
                                        Button {
                                            viewModel.revealInFinder(item: item)
                                        } label: {
                                            Label("在 Finder 中显示", systemImage: "folder")
                                        }

                                        if let path = item.projectPath {
                                            Button {
                                                viewModel.copyToClipboard(text: path)
                                            } label: {
                                                Label("复制项目路径", systemImage: "doc.on.doc")
                                            }
                                        }

                                        Button {
                                            viewModel.copyToClipboard(text: item.sessionId)
                                        } label: {
                                            Label("复制会话 ID", systemImage: "number")
                                        }

                                        Divider()

                                        Button(role: .destructive) {
                                            Task {
                                                await viewModel.deleteSingle(item: item)
                                            }
                                        } label: {
                                            Label("删除此会话", systemImage: "trash")
                                        }
                                    }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: viewModel.selectedCategory.iconName)
                .font(.system(size: 54))
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                Text("暂无 \(viewModel.selectedCategory.rawValue) 会话记录")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(emptyDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Button {
                Task {
                    await viewModel.scanConversations()
                }
            } label: {
                Label("重新扫描", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyDescription: String {
        switch viewModel.selectedCategory {
        case .all:
            return "未在本地检测到 agent 历史会话文件，或所有会话均已被清理。"
        case .claudeCode:
            return "未在 ~/.claude/projects/ 检测到 Claude Code 会话历史记录。"
        case .codex:
            return "未在 ~/.codex/sessions/ 检测到 OpenAI Codex 会话历史记录。"
        case .cline:
            return "未在 Cline 存储目录检测到会话任务记录。"
        case .rooCode:
            return "未在 Roo Code 存储目录检测到会话任务记录。"
        case .continueDev:
            return "未在 ~/.continue/sessions/ 检测到 Continue.dev 会话记录。"
        case .piAgent:
            return "未在 ~/.pi/agent/sessions/ 检测到 Pi Agent 会话历史记录。"
        }
    }

    private func categoryColor(_ category: ConversationCategory) -> Color {
        switch category {
        case .all: return .accentColor
        case .claudeCode: return .orange
        case .codex: return .green
        case .cline: return .blue
        case .rooCode: return .purple
        case .continueDev: return .cyan
        case .piAgent: return .pink
        }
    }
}

struct ConversationRowView: View {
    let item: ConversationItem
    @Binding var isSelected: Bool
    @EnvironmentObject var viewModel: CleanViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $isSelected)
                .labelsHidden()
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                // Header line: Category tag + Title + Size badge
                HStack(alignment: .center, spacing: 8) {
                    Text(item.category.rawValue)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(tagBackground)
                        .foregroundColor(tagForeground)
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    Text(item.title)
                        .font(.body)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Spacer()

                    Text(item.formattedSize)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                }

                // Snippet line
                Text(item.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                // Footer line: Project / Branch / Message count / Date / Session ID
                HStack(spacing: 8) {
                    if !item.displayProjectPath.isEmpty {
                        Label(item.displayProjectPath, systemImage: "folder")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let branch = item.gitBranch, !branch.isEmpty {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Text("•")
                        .foregroundStyle(.tertiary)

                    Label("\(item.messageCount) 轮对话", systemImage: "bubble.left.and.bubble.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text("•")
                        .foregroundStyle(.tertiary)

                    Text(item.formattedDate)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("#\(item.shortSessionId)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var tagBackground: Color {
        switch item.category {
        case .all: return .accentColor.opacity(0.15)
        case .claudeCode: return .orange.opacity(0.18)
        case .codex: return .green.opacity(0.18)
        case .cline: return .blue.opacity(0.18)
        case .rooCode: return .purple.opacity(0.18)
        case .continueDev: return .cyan.opacity(0.18)
        case .piAgent: return .pink.opacity(0.18)
        }
    }

    private var tagForeground: Color {
        switch item.category {
        case .all: return .accentColor
        case .claudeCode: return .orange
        case .codex: return .green
        case .cline: return .blue
        case .rooCode: return .purple
        case .continueDev: return .cyan
        case .piAgent: return .pink
        }
    }
}
