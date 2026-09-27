import SwiftUI
import AppKit

// MARK: - Sidebar
//
// 纯导航：Agent 分类 + 工具区 + 当前分类的存储路径 footer。
// 统计概览与存储分布不在这里 —— 它们是信息不是导航，已搬进详情栏（OverviewView）。
//
// 两道过滤不能丢：① 本机未安装的 Agent 不出现；② 「仅显示有数据」打开时
// 再滤掉 0 会话的分类。`.all` 恒在首位且不受第二个开关影响。

/// 15 款 Agent 的固定视觉顺序。`ConversationCategory.allCases` 把 Antigravity 放在最后，
/// 而设计顺序是 Trae → Antigravity → Aider，这里显式声明一次。
private let sidebarAgentOrder: [ConversationCategory] = [
    .claudeCode, .codex, .piAgent, .cline, .rooCode, .continueDev, .copilotChat,
    .cursor, .windsurf, .trae, .antigravity, .aider, .openViking, .zed, .openHands,
]

struct SidebarView: View {
    @EnvironmentObject var viewModel: CleanViewModel
    @AppStorage("hideEmptyCategories") private var hideEmpty = false

    var body: some View {
        List {
            Section("Agent 分类") {
                ForEach(visibleCategories) { cat in
                    categoryRow(cat)
                }
            }

            Section("工具") {
                Toggle("仅显示有数据", isOn: $hideEmpty)
                    .toggleStyle(.checkbox)
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    Label("设置…", systemImage: "gear")
                }
            }

            Section {
                pathFooter
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - 分类

    /// 参与渲染的分类：`.all` 恒在首位，两道过滤只作用于具体 Agent。
    private var visibleCategories: [ConversationCategory] {
        let installed = sidebarAgentOrder.filter(isInstalled)
        let agents = hideEmpty
            ? installed.filter { (viewModel.categoryStats[$0]?.count ?? 0) > 0 }
            : installed
        return [.all] + agents
    }

    /// 安装状态一律读扫描结果，不靠硬编码名单。
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

    /// 路径区展示的 Agent：`.all` 时落到占用最大的那款，给一个真实路径而不是占位符。
    private var pathAgent: AgentInfo? {
        if viewModel.selectedCategory == .all {
            return viewModel.agentInfos.max { $0.totalBytes < $1.totalBytes }
        }
        return viewModel.agentInfos.first { $0.category == viewModel.selectedCategory }
    }

    private var currentStoragePath: String {
        pathAgent?.storagePath ?? ""
    }

    private var pathFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当前分类存储路径")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(currentStoragePath.isEmpty ? "—" : Fmt.abbreviateHome(currentStoragePath))
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

            Button {
                revealCurrentPath()
            } label: {
                Label("在 Finder 中打开", systemImage: "arrow.up.forward.square")
                    .font(.callout)
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

private struct CategoryRow: View {
    let category: ConversationCategory
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    /// 有会话显示数字，没有显示「空闲」——本机未装的 Agent 已被过滤掉，不进列表。
    private var trailing: String { count > 0 ? "\(count)" : "空闲" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: category.iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                    .frame(width: 16)

                Text(category.rawValue)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(trailing)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(category.rawValue) · \(count) 个会话")
        .accessibilityLabel(category.rawValue)
        .accessibilityValue("\(count) 个会话")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
