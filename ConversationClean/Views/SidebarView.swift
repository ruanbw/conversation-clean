import SwiftUI
import AppKit

// MARK: - Sidebar
//
// 两道过滤不能丢：① 本机未安装的 Agent 不出现；② 「仅显示有数据」打开时
// 再滤掉 0 会话的分类。`.all` 恒在首位且不受第二个开关影响。
//
// 视觉按 ui-a-precision.html 重做。修掉的三处：
//   ① 顶部 38pt 的 Spacer 是多余空白 —— 它当初是给红绿灯让位，但红绿灯浮在
//      顶栏（48pt）上，窗口几何是 VStack{topBar; columns}，侧栏从顶栏**下方**
//      才开始，根本轮不到它让位。旧代码在顶栏下面又空 38pt，侧栏开头 86pt 全白。
//   ② 下方 500pt 是纯空白（只装了 4 款 Agent 却有 15 个分类位）。现在填成
//      「可回收空间」体检卡 + 存储路径卡，把空白换成决策信息。
//   ③ 行高 28pt（原 5pt padding 撑出 ~30pt 但基线不对齐），计数改等宽数字。

private let sidebarAgentOrder: [ConversationCategory] = [
    .claudeCode, .codex, .piAgent, .cline, .rooCode, .continueDev, .copilotChat,
    .cursor, .windsurf, .trae, .antigravity, .aider, .openViking, .zed, .openHands,
]

struct SidebarView: View {
    @EnvironmentObject var viewModel: CleanViewModel
    @AppStorage("hideEmptyCategories") private var hideEmpty = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Agent 分类", paddingTop: Theme.Space.l)

                ForEach(visibleCategories) { cat in
                    categoryRow(cat)
                }

                SectionLabel(text: "工具")
                toolRow("仅显示有数据", hideEmpty) {
                    withAnimation(.easeOut(duration: 0.14)) { hideEmpty.toggle() }
                }
                toolRow("设置…", nil) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }

                SectionLabel(text: "当前分类")
                storageCard
                recoveryGauge
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, Theme.Space.xl)
        }
        .background(Theme.sidebar)
    }

    // MARK: - 可回收空间体检卡
    //
    // 侧栏那块空白最好的用途不是装饰，是一个能直接回答"我现在能省多少"的读数。
    // 大号 22pt 数字 —— 母题是体积的重量感，数字就该是全侧栏最重的元素。

    private var recoveryGauge: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("可回收空间")
                .font(Theme.Typo.sectionHead)
                .tracking(0.4)
                .foregroundStyle(Theme.t3)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(gaugeValue)
                    .font(Theme.Typo.gauge)
                    .foregroundStyle(Theme.t1)
                Text(gaugeUnit)
                    .font(Theme.Typo.gaugeUnit)
                    .foregroundStyle(Theme.t2)
            }
            .padding(.top, 6)

            // 占比条：当前分类占它自己 Agent 全量的比例。
            // 100% 说明"这条分类下的全是可删的历史"，比一个绝对值更有决策价值。
            ShareBar(percent: gaugeShare, width: nil, height: 4)
                .frame(height: 4)
                .padding(.top, Theme.Space.m)

            HStack(spacing: Theme.Space.xs) {
                Text(gaugeCaption)
                    .font(Theme.Typo.rowSub)
                    .foregroundStyle(Theme.t2)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.xs)
                Text(gaugeCount)
                    .font(Theme.Typo.num(11, .semibold))
                    .foregroundStyle(Theme.danger)
            }
            .padding(.top, Theme.Space.s)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .padding(.top, Theme.Space.m)
    }

    /// 当前选中分类的会话数
    private var currentStats: CategoryStats? {
        viewModel.categoryStats[viewModel.selectedCategory]
    }

    /// 卡片上那支大数字。跟着当前分类走：全部会话显示全量，选中某款显示该款。
    private var gaugeValue: String {
        Fmt.splitValue(currentStats?.sizeInBytes ?? 0).0
    }
    private var gaugeUnit: String {
        Fmt.splitValue(currentStats?.sizeInBytes ?? 0).1
    }
    /// 「占 Pi Agent 全量 100%」—— 有具体 Agent 名才有占比，否则说明是全量
    private var gaugeShare: Double {
        guard let s = currentStats, s.sizeInBytes > 0, s.sizeInBytes <= viewModel.totalSize else {
            return 0
        }
        return Double(s.sizeInBytes) / Double(viewModel.totalSize) * 100
    }
    private var gaugeCaption: String {
        let name = viewModel.selectedCategory == .all
            ? "全部 Agent 合计"
            : viewModel.selectedCategory.rawValue
        return "占 \(name) \(Int(gaugeShare.rounded()))%"
    }
    private var gaugeCount: String {
        "\(currentStats?.count ?? 0) 会话"
    }

    // MARK: - 存储路径卡

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("存储路径")
                .font(Theme.Typo.sectionHead)
                .tracking(0.4)
                .foregroundStyle(Theme.accent)

            Text(displayedPath.isEmpty ? "—" : displayedPath)
                .font(Theme.Typo.mono(11))
                .foregroundStyle(Theme.t2)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(currentStoragePath)

            // 说明跟着设置开关走：开关关掉时这句「同步删除」就是错的，不能写死。
            Text(pathNote)
                .font(Theme.Typo.rowSub)
                .foregroundStyle(Theme.t3)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: revealCurrentPath) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 10, weight: .medium))
                    Text("在 Finder 中打开")
                        .font(Theme.Typo.rowSub.weight(.medium))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(DrawnButtonStyle(
                variant: currentStoragePath.isEmpty ? .flat : .ghost,
                horizontalPadding: 0, compact: true))
            .disabled(currentStoragePath.isEmpty)
            .padding(.top, 2)
        }
        .padding(Theme.Space.l)
        .tintedSurface()
        .padding(.top, Theme.Space.m)
    }

    // MARK: - 分类行

    private func categoryRow(_ cat: ConversationCategory) -> some View {
        CategoryRow(
            category: cat,
            count: viewModel.categoryStats[cat]?.count ?? 0,
            isSelected: viewModel.selectedCategory == cat
        ) {
            viewModel.selectedCategory = cat
        }
    }

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

    // MARK: - 路径

    private var pathAgent: AgentInfo? {
        if viewModel.selectedCategory == .all {
            return viewModel.agentInfos.max { $0.totalBytes < $1.totalBytes }
        }
        return viewModel.agentInfos.first { $0.category == viewModel.selectedCategory }
    }

    private var currentStoragePath: String { pathAgent?.storagePath ?? "" }
    private var displayedPath: String { Fmt.abbreviateHome(currentStoragePath) }

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

    // MARK: - 工具行
    //
    // 20pt 图标位：checked 非 nil 时画手绘勾选框，否则留空位保持文字左对齐。
    private func toolRow(_ title: String, _ checked: Bool?,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Group {
                    if let checked {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .font(Theme.Typo.body12)
                            .foregroundStyle(checked ? Theme.accent : Theme.t3)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16)
                Text(title)
                    .font(Theme.Typo.navItem)
                    .foregroundStyle(Theme.t1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: Theme.Size.rowCompact)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 分类行
//
// 选中态：靛蓝渐变实心 + 白字（设计稿 A 的做法）。
// 计数用等宽数字，右侧对齐才不会因位数变化跳动。

private struct CategoryRow: View {
    let category: ConversationCategory
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                AgentIconView(category: category, size: 16)

                Text(category.rawValue)
                    .font(isSelected ? Theme.Typo.navItemActive : Theme.Typo.navItem)
                    .foregroundStyle(isSelected ? .white : Theme.t1)
                    .lineLimit(1)

                Spacer(minLength: Theme.Space.xs)

                if count > 0 {
                    Text("\(count)")
                        .font(Theme.Typo.num(11, .medium))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.92) : Theme.t3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule().fill(isSelected
                                           ? Color.white.opacity(0.24)
                                           : Color.primary.opacity(0.055))
                        }
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: Theme.Size.rowCompact)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(fill)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(category.rawValue) · \(count) 个会话")
        .accessibilityLabel(category.rawValue)
        .accessibilityValue("\(count) 个会话")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 选中态是渐变、未选中是纯色，所以返回 AnyShapeStyle 而非 Color。
    private var fill: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(LinearGradient(colors: [Theme.accentHi, Theme.accent],
                                                startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(hovering ? Color.primary.opacity(0.045) : Color.clear)
    }
}
