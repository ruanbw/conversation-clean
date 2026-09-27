import SwiftUI
import AppKit

// MARK: - Sidebar
//
// 逐像素移植原型 `.sidebar`：Agent 分类 / 统计概览 / 存储分布 / 当前分类存储路径。
//
// 铁律：只画原型里存在的元素 —— 17pt 线性图标、两列数字、灰阶堆叠条。
// 圆环、圆形徽章、绿色 ramp 在原型里都不存在，不要"改良"。
// 不用 List：macOS List 的行高与背景跟原型的紧凑 32pt 行冲突，这里手搓 ScrollView。

/// 原型 `AGENTS` 数组的固定顺序。`ConversationCategory.allCases` 把 Antigravity 放在最后，
/// 而原型的视觉顺序是 Trae → Antigravity → Aider，这里显式声明一次。
private let sidebarAgentOrder: [ConversationCategory] = [
    .claudeCode, .codex, .piAgent, .cline, .rooCode, .continueDev, .copilotChat,
    .cursor, .windsurf, .trae, .antigravity, .aider, .openViking, .zed, .openHands,
]

/// 判定「本机有没有装」直接问 `AgentInfo.isInstalled`，不靠硬编码名单。
/// 原型 AGENTS 里的 `det:false` 只表示「脚本不做存储目录探测」，而原生应用本来就能探测；
/// 早期版本据此硬编码了一个 4 款名单（aider/openViking/zed/openHands），会把真实装了的情况
/// 误报成「未安装」，所以整套判定改成读扫描结果。
private let unsupported: Set<ConversationCategory> = []

/// 原型 `renderDist()` 的 RAMP：前景色的灰阶序列（100/80/63/49/38/26%），
/// 段数多于 6 时继续往下取 20% / 14%。
private let distRamp: [Double] = [1.00, 0.80, 0.63, 0.49, 0.38, 0.26, 0.20, 0.14]

struct SidebarView: View {
    @EnvironmentObject var viewModel: CleanViewModel
    /// 原型 `P.zero`：控制是否只列出有会话数据的分类，持久化到 `localStorage`。
    /// 无论开关如何，**本机没装的 Agent 都不列** —— 列一个永远选不出内容的分类只是噪音。
    @AppStorage("hideEmptyCategories") private var hideEmpty = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                categorySection
                overviewSection
                distributionSection
                pathSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 16)   // 原型 `.sidebar{padding-bottom:16px}`
        }
        .background(CC.panel)
        .ccHairline(.trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 派生数据

    /// 参与渲染的分类：`.all` 恒在首位（原型 `catBtn(ALL, all)` 不受 `P.zero` 影响）。
    /// 两道过滤：
    ///   1. 本机未安装的 Agent 直接不出现（不显示「未安装」占位行）
    ///   2. `hideEmpty` 打开时再滤掉「已安装但一个会话都没有」的分类
    private var visibleCategories: [ConversationCategory] {
        let installed = sidebarAgentOrder.filter(isInstalled)
        let agents = hideEmpty
            ? installed.filter { (viewModel.categoryStats[$0]?.count ?? 0) > 0 }
            : installed
        return [.all] + agents
    }

    private var total: Int64 { viewModel.totalSize }

    private var installedCount: Int {
        viewModel.agentInfos.filter { $0.isInstalled }.count
    }

    private var agentTotal: Int { sidebarAgentOrder.count }

    private func isInstalled(_ cat: ConversationCategory) -> Bool {
        viewModel.agentInfos.first { $0.category == cat }?.isInstalled == true
    }

    /// 存储分布的有序段：占用 > 0 的分类降序取前 5，剩余合并成「其他 N 款」。
    private var distSegments: [SidebarDistSegment] {
        let ranked = sidebarAgentOrder
            .compactMap { cat -> (ConversationCategory, Int64)? in
                let bytes = viewModel.categoryStats[cat]?.sizeInBytes ?? 0
                return bytes > 0 ? (cat, bytes) : nil
            }
            .sorted { $0.1 > $1.1 }

        var out = ranked.prefix(5).enumerated().map { index, item in
            SidebarDistSegment(
                id: item.0.rawValue,
                name: item.0.rawValue,
                bytes: item.1,
                tint: CC.fg.opacity(distRamp[min(index, distRamp.count - 1)])
            )
        }
        if ranked.count > 5 {
            let rest = ranked.dropFirst(5).reduce(Int64(0)) { $0 + $1.1 }
            out.append(
                SidebarDistSegment(
                    id: "other",
                    // 原型 `segs.push({n:"其他 "+(ranked.length-5)+" 款", b:rest})`
                    name: "其他 \(ranked.count - 5) 款",
                    bytes: rest,
                    tint: CC.fg.opacity(distRamp[min(out.count, distRamp.count - 1)])
                )
            )
        }
        return Array(out)
    }

    private var heaviestAgent: AgentInfo? {
        viewModel.agentInfos.max { $0.totalBytes < $1.totalBytes }
    }

    /// 路径区展示的 Agent：`.all` 时落到占用最大的那款（原型此处是占位文案，这里给真实路径）。
    private var pathAgent: AgentInfo? {
        viewModel.selectedCategory == .all
            ? heaviestAgent
            : viewModel.agentInfos.first { $0.category == viewModel.selectedCategory }
    }

    private var currentStoragePath: String { pathAgent?.storagePath ?? "" }

    // MARK: - 1 · Agent 分类

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CCSectionHeader(title: "Agent 分类") {
                SidebarTextToggle(
                    title: hideEmpty ? "显示全部" : "仅显示有数据",
                    help: hideEmpty ? "显示全部 15 个 Agent 分类" : "只显示有会话数据的分类"
                ) {
                    withAnimation(CC.Mv.base) { hideEmpty.toggle() }
                }
            }
            .sidebarHeader()

            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(visibleCategories) { cat in
                    categoryRow(cat)
                }
            }
        }
        .sidebarSection(dividerAbove: false)
    }

    private func categoryRow(_ cat: ConversationCategory) -> some View {
        SidebarCategoryRow(
            category: cat,
            count: viewModel.categoryStats[cat]?.count ?? 0,
            isSelected: viewModel.selectedCategory == cat
        ) {
            viewModel.selectedCategory = cat
        }
    }

    // MARK: - 2 · 统计概览

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CCSectionHeader(title: "统计概览") {
                Text("\(installedCount) / \(agentTotal) 已安装")
                    .font(CC.F.monoSm)
                    .foregroundStyle(CC.muted)
            }
            .sidebarHeader()

            HStack(alignment: .top, spacing: 10) {
                // 原型 `.ov-cell` 是「标签在上、数字在下」，与「关于」页 `.about .facts`
                // 的上下顺序相反，所以由 labelFirst 参数区分
                CCStatCell(
                    value: Fmt.bytes(total),
                    label: "总缓存占用",
                    labelFirst: true
                )
                .tracking(-0.57)                 // 原型 `letter-spacing:-.03em`
                CCStatCell(
                    value: "\(viewModel.conversations.count)",
                    label: "总会话数",
                    labelFirst: true
                )
                .tracking(-0.57)
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 10)

            // 原型 `renderOverview()`：这句跟着「删除空项目目录」设置走。
            Text(viewModel.emptyFolderPolicyText)
                .font(CC.F.caption)
                .foregroundStyle(CC.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .sidebarSection(dividerAbove: true)
    }

    // MARK: - 3 · 存储分布

    private var distributionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CCSectionHeader(title: "存储分布") {
                Text(total > 0 ? Fmt.bytes(total) : "—")
                    .font(CC.F.monoSm)
                    .foregroundStyle(CC.muted)
            }
            .sidebarHeader()

            if total > 0, !distSegments.isEmpty {
                CCStackBar(
                    slices: distSegments.map {
                        CCStackBar.Slice(id: $0.id, value: Double($0.bytes), tint: $0.tint)
                    },
                    height: 10
                )
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .help("各 Agent 存储占比")

                VStack(spacing: 0) {
                    ForEach(Array(distSegments.enumerated()), id: \.element.id) { index, seg in
                        SidebarLegendRow(segment: seg, total: total)
                            .padding(.vertical, 2)
                            .overlay(alignment: .top) {
                                if index > 0 {
                                    Rectangle().fill(CC.border).frame(height: CC.M.hairline)
                                }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            } else {
                // 原型空态：`<p class="ov-note" style="padding:0">`，所以这里不额外加内边距。
                Text("暂无可统计的会话。")
                    .font(CC.F.caption)
                    .foregroundStyle(CC.muted)
            }
        }
        .sidebarSection(dividerAbove: true)
    }

    // MARK: - 4 · 当前分类存储路径

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CCSectionHeader("当前分类存储路径")
                .sidebarHeader()

            Text(currentStoragePath.isEmpty ? "—" : currentStoragePath)
                .font(CC.F.mono)
                .foregroundStyle(CC.fg)
                // 原型 `word-break:break-all`：路径不截断，逐字符换行。
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
.padding(.vertical, 6)
.background(RoundedRectangle(cornerRadius: CC.R.sm, style: .continuous).fill(CC.fillSoft))
.padding(.horizontal, 8)
                .help(currentStoragePath)

            Text(pathNote)
                .font(CC.F.caption)
                .foregroundStyle(CC.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.top, 7)
                .padding(.bottom, 2)

            CCButton(
                title: "在 Finder 中打开",
                systemImage: "arrow.up.forward.square",
                kind: .outline,
                // 原型 `#btnRevealPath` 是 `btn-ghost btn-sm`（28pt 高），但它又是侧栏里
                // 唯一的主操作，保留 outline 描边以便识别，尺寸对齐 btn-sm
                compact: true,
                enabled: !currentStoragePath.isEmpty,
                help: "在 Finder 中打开当前分类的存储目录"
            ) {
                revealCurrentPath()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .sidebarSection(dividerAbove: true)
    }

    private var pathNote: String {
        guard let agent = pathAgent, isInstalled(agent.category) else {
            return "未在本机检测到该 Agent 的存储目录，列表为空。"
        }
        // 快照策略随设置开关变化，不能写死：开关关掉时这句「同步删除」就是错的。
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

// MARK: - 私有子视图

/// 分类行：32pt 高、左 6 / 右 8 内边距、选中时左侧 2pt 竖条 —— 原型 `.cat`。
private struct SidebarCategoryRow: View {
    let category: ConversationCategory
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    private var isEmpty: Bool { count == 0 }

    /// 原型 `catBtn()`：有会话时显示数字，无会话时显示「空闲」。
    /// （本机未装的 Agent 已被过滤掉、根本不出现在列表里，所以不需要「未安装」那一档。）
    private var rightText: String { count > 0 ? "\(count)" : "空闲" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                // 原型 `.cat .gi{width:17px}`：17pt 线性 SF Symbol，选中时才变前景色。
                Image(systemName: category.iconName)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isSelected ? CC.fg : CC.muted)
                    .frame(width: 17, height: 17)

                Text(category.rawValue)
                    // 选中态 600 字重，对应原型 `.cat.on .nm{font-weight:600}`
                    .font(isSelected ? CC.F.body.weight(.semibold) : CC.F.body)
                    .foregroundStyle(isEmpty ? CC.muted : CC.fg)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(rightText)
                    .font(CC.F.num(11, .regular))
                    .foregroundStyle(countTextColor)
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: CC.R.sm, style: .continuous)
                    .fill(isSelected ? CC.fillSoft : (hovering ? CC.fillHair : .clear))
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    // 原型 `.cat.on::before{left:-6px;top:7px;bottom:7px;width:2px}`
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(CC.fg)
                        .frame(width: 2, height: 16)
                        .offset(x: -6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(CC.Mv.quick, value: isSelected)
        .animation(CC.Mv.quick, value: hovering)
        .help("\(category.rawValue) · \(count) 个会话")
        .accessibilityLabel(category.rawValue)
        .accessibilityValue("\(count) 个会话")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// `.cat.zero .ct` 的优先级高于 `.cat.on .ct`：计数为 0 的行即使选中也保持更淡的一档。
    private var countTextColor: Color {
        if isEmpty { return CC.muted.opacity(0.7) }
        return isSelected ? CC.fg : CC.muted
    }
}

/// 概览两列中的一格 —— 原型 `.ov-cell`（**标签在上、数字在下**）。
/// 共享的 `CCStatCell` 是「数字在上、标签在下」，顺序与原型相反，故这里就地复刻一份。

/// 分布图例行：原型 `.d-leg`（grid `8px 1fr 30px 54px`，gap 9）。
private struct SidebarLegendRow: View {
    let segment: SidebarDistSegment
    let total: Int64

    private var percentText: String {
        guard total > 0 else { return "0%" }
        return "\(Int((Double(segment.bytes) / Double(total) * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(segment.tint)
                .frame(width: 8, height: 8)

            Text(segment.name)
                .font(.system(size: 11.5))
                .foregroundStyle(CC.fg)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(percentText)
                .font(CC.F.num(10.5, .regular))
                .foregroundStyle(CC.muted)
                .frame(width: 30, alignment: .trailing)

            Text(Fmt.bytes(segment.bytes))
                .font(CC.F.num(10.5, .regular))
                .foregroundStyle(CC.muted)
                .frame(width: 54, alignment: .trailing)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(segment.name)
        .accessibilityValue("\(percentText) · \(Fmt.bytes(segment.bytes))")
    }
}

/// 分布段：名称 + 字节 + 灰阶色。
private struct SidebarDistSegment: Identifiable {
    let id: String
    let name: String
    let bytes: Int64
    let tint: Color
}

/// 区块标题右侧的纯文字小开关（原型 `.sb-h button`）。
private struct SidebarTextToggle: View {
    let title: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(CC.F.monoSm)
                .foregroundStyle(hovering ? CC.fg : CC.muted)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(CC.Mv.quick, value: hovering)
    }
}

// MARK: - 布局修饰

private extension View {
    /// 分区容器：原型的 `.sb-sec`（左右 12pt）+ `.sb-sec + .sb-sec`（1px 上边线 + 6pt 间距）。
    func sidebarSection(dividerAbove: Bool) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.top, dividerAbove ? 6 : 12)
            .padding(.bottom, 2)
            .overlay(alignment: .top) {
                if dividerAbove {
                    Rectangle()
                        .fill(CC.border)
                        .frame(height: CC.M.hairline)
                }
            }
    }

    /// 区块标题：原型的 `.sb-h{padding:0 8px 8px}`。
    func sidebarHeader() -> some View {
        self
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
    }
}
