import SwiftUI
import AppKit

// MARK: - Sidebar
//
// 版式照 DefaultAppManager 的 SidebarView：彩色图标 + 选中项蓝色实心填充白字
// + 右侧灰色计数胶囊。统计信息不在这里，已搬进详情栏（OverviewView）。
//
// 两道过滤不能丢：① 本机未安装的 Agent 不出现；② 「仅显示有数据」打开时
// 再滤掉 0 会话的分类。`.all` 恒在首位且不受第二个开关影响。

private let sidebarAgentOrder: [ConversationCategory] = [
    .claudeCode, .codex, .piAgent, .cline, .rooCode, .continueDev, .copilotChat,
    .cursor, .windsurf, .trae, .antigravity, .aider, .openViking, .zed, .openHands,
]

struct SidebarView: View {
    @EnvironmentObject var viewModel: CleanViewModel
    @AppStorage("hideEmptyCategories") private var hideEmpty = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 38pt 让给红绿灯：hiddenTitleBar 之后内容铺到 y=0，
            // 这段留白正好托住系统那三个圆点（照 DefaultAppManager 的 SidebarView）
            Spacer().frame(height: 38)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Agent 分类")
                    ForEach(visibleCategories) { cat in
                        categoryRow(cat)
                    }
                    sectionHeader("工具")
                    toolRow("仅显示有数据", hideEmpty) { withAnimation(.easeOut(duration: 0.14)) { hideEmpty.toggle() } }
                    toolRow("设置…", nil) {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                    sectionHeader("当前分类存储路径")
                    pathFooter
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 工具行：标题左侧一个 20pt 图标位。`checked` 非 nil 时画勾选框。
    private func toolRow(_ title: String, _ checked: Bool?,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let checked {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12))
                            .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 20)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分类

    private var visibleCategories: [ConversationCategory] {
        let installed = sidebarAgentOrder.filter(isInstalled)
        let agents = hideEmpty
            ? installed.filter { (viewModel.categoryStats[$0]?.count ?? 0) > 0 }
            : installed
        return [.all] + agents
    }

    private func isInstalled(_ cat: ConversationCategory) -> Bool {
        viewModel.agentInfos.first { $0.category == cat }?.isInstalled == true
    }

    private func categoryRow(_ cat: ConversationCategory) -> some View {
        CategoryRow(
            category: cat,
            count: viewModel.categoryStats[cat]?.count ?? 0,
            isSelected: viewModel.selectedCategory == cat
        ) {
            viewModel.selectedCategory = cat
        }
    }

    // MARK: - 路径 footer

    private var pathAgent: AgentInfo? {
        if viewModel.selectedCategory == .all {
            return viewModel.agentInfos.max { $0.totalBytes < $1.totalBytes }
        }
        return viewModel.agentInfos.first { $0.category == viewModel.selectedCategory }
    }

    private var currentStoragePath: String { pathAgent?.storagePath ?? "" }

    private var pathFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Fmt.abbreviateHome(currentStoragePath).isEmpty ? "—" : Fmt.abbreviateHome(currentStoragePath))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .help(currentStoragePath)

            // 说明跟着设置开关走：开关关掉时这句「同步删除」就是错的，不能写死。
            Text(pathNote)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button { revealCurrentPath() } label: {
                Label("在 Finder 中打开", systemImage: "arrow.up.forward.square").font(.callout)
            }
            .controlSize(.small)
            .disabled(currentStoragePath.isEmpty)
        }
        .padding(.vertical, 4)
    }

    private var pathNote: String {
        guard let agent = pathAgent, isInstalled(agent.category) else {
            return "未在本机检测到该 Agent 的存储目录。"
        }
        return viewModel.snapshotPolicyText
    }

    /// 目录存在就「选中」它，不存在则退化为「打开」，让 Finder 自己定位。
    private func revealCurrentPath() {
        let raw = currentStoragePath
        guard !raw.isEmpty else { return }
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        if FileManager.default.fileExists(atPath: expanded) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 分类行
//
// DefaultAppManager 的 sidebarRow：选中时整行填 accentColor、文字转白，
// 右侧计数在选中态是白字胶囊、未选中是灰字。逐项照抄。

private struct CategoryRow: View {
    let category: ConversationCategory
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: category.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : category.tint)
                    .frame(width: 20)

                Text(category.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(category.rawValue) · \(count) 个会话")
        .accessibilityLabel(category.rawValue)
        .accessibilityValue("\(count) 个会话")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
