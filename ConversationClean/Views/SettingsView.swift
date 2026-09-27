import SwiftUI
import AppKit

// MARK: - 设置
//
// 运行在原生 `Settings` scene 里（⌘,）。
//
// 整页改成自绘：左侧导航栏 + 右侧分组卡片，与主窗口同一套视觉
// （Theme 的四级表面梯 / 1px 发丝线 / 靛蓝强调 / 8pt 圆角）。
// 换掉的两处系统外观：
//   ① 系统 `Form` + `.formStyle(.grouped)` —— 它自带 inset 分组底与材质，
//      深色模式下是另一块灰，与主窗口的卡片语言对不上；
//   ② 系统 `Toggle` —— macOS 的开关是系统蓝渐变 + 高光，和侧栏选中态
//      的靛蓝不是同一种蓝，两处一屏出现时颜色对不上。改为手绘 iOS 式开关。
//
// 业务侧一个字没动：四个 `@AppStorage` 的键名（服务层在读，改了就漂）、
// 15 款 Agent 的固定顺序、以及安装状态只认 `AgentInfo.isInstalled`
// （早期那份把 4 款钉死成「未发现」的硬编码名单已删除，不能再回来）。

/// 15 款 Agent 的视觉顺序。`AgentScanService.scanners` 的注册顺序不同，
/// 这里按固定顺序排一次。
private let settingsAgentOrder: [ConversationCategory] = [
    .claudeCode, .codex, .piAgent, .cline, .rooCode, .continueDev, .copilotChat,
    .cursor, .windsurf, .trae, .antigravity, .aider, .openViking, .zed, .openHands,
]

/// 有第二层索引载体的 Agent 数量 —— 「关于」页那个数字的唯一来源。
/// 增删一款双层索引 Agent，这里跟着变。
private let settingsIndexNotes: Set<ConversationCategory> = [
    .piAgent, .copilotChat, .cursor, .windsurf, .trae, .antigravity
]

/// 三个页签。用 `TabView` + `.tabItem` 会在原生设置窗口顶部压一条系统标签栏，
/// 那条栏是系统材质 + 系统选中指示，与全自绘的内容区割裂，所以自绘成左导航。
private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, paths, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .paths:   return "Agent 路径"
        case .about:   return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .paths:   return "folder"
        case .about:   return "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    // 键名与 Core/CleanPrefs.Key 逐字一致（服务层在读），不能改。
    @AppStorage("autoScanOnLaunch") private var autoScanOnLaunch = true
    @AppStorage("confirmBeforeClean") private var confirmBeforeClean = true
    @AppStorage("cleanFileHistorySnapshots") private var cleanFileHistorySnapshots = true
    @AppStorage("cleanEmptyProjectFolders") private var cleanEmptyProjectFolders = true

    @State private var tab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            rail
            pane
        }
        .frame(width: 640, height: 460)
    }

    // MARK: - 左导航

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "设置", paddingTop: Theme.Space.l)
            ForEach(SettingsTab.allCases) { item in
                railRow(item)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(width: 152, alignment: .leading)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.line).frame(width: 1)
        }
    }

    private func railRow(_ item: SettingsTab) -> some View {
        SettingsRailRow(title: item.title, symbol: item.symbol, isOn: tab == item) {
            tab = item
        }
    }

    // MARK: - 右内容

    private var pane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    paneBody
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
    }

    private var paneHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(tab.title)
                .font(Theme.Typo.cardTitle)
                .foregroundStyle(Theme.t1)
            Spacer(minLength: 0)
            Text(headerHint)
                .font(Theme.Typo.rowSub)
                .foregroundStyle(Theme.t3)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.xl)
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private var paneBody: some View {
        switch tab {
        case .general: generalPane
        case .paths:   pathsPane
        case .about:   aboutPane
        }
    }

    // MARK: - 通用

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            card("扫描与清理", symbol: "arrow.triangle.2.circlepath") {
                toggleRow("启动应用时自动扫描会话",
                          "启动时扫描一次本机全部 Agent 的会话缓存",
                          $autoScanOnLaunch)
                toggleRow("删除会话时同步清除快照与子代理数据",
                          "关闭后仅删除主会话文件，快照与子代理目录将保留",
                          $cleanFileHistorySnapshots)
                toggleRow("删除会话后自动移除空项目目录",
                          "清理后递归移除不再包含任何会话的空目录",
                          $cleanEmptyProjectFolders,
                          isLast: true)
            }

            card("安全策略", symbol: "shield.lefthalf.filled") {
                // 这一条是本页唯一的危险开关：关掉之后清理立即执行且不可撤销。
                // 平时按靛蓝走，关掉时整行转危险色（副标题 + 警示三角）。
                toggleRow("执行清理操作前弹出二次确认",
                          "关闭后清理将立即执行，不可撤销",
                          $confirmBeforeClean,
                          isRisk: true,
                          isLast: true)
            }
        }
    }

    private func toggleRow(_ title: String, _ subtitle: String,
                           _ binding: Binding<Bool>,
                           isRisk: Bool = false,
                           isLast: Bool = false) -> some View {
        let risky = isRisk && !binding.wrappedValue
        return Button {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                binding.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Typo.rowTitle)
                        .foregroundStyle(Theme.t1)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        if risky {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(Theme.Typo.num(8.5))
                                .foregroundStyle(Theme.danger)
                        }
                        Text(subtitle)
                            .font(Theme.Typo.rowSub)
                            .foregroundStyle(risky ? Theme.danger : Theme.t2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DrawnSwitch(isOn: binding.wrappedValue, onTint: isRisk ? Theme.danger : Theme.accent)
                    // 整行都可点，开关自己不再吃事件（否则会双触发）
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
        .accessibilityValue(binding.wrappedValue ? "已开启" : "已关闭")
        .accessibilityAddTraits(binding.wrappedValue ? [.isSelected] : [])
    }

    // MARK: - Agent 路径

    @ViewBuilder
    private var pathsPane: some View {
        if agents.isEmpty {
            DrawnEmptyState(
                symbol: "folder.badge.questionmark",
                title: "尚未扫描到 Agent 信息",
                message: "请先回到主窗口执行一次扫描。",
                actionTitle: nil,
                action: nil
            )
            .frame(minHeight: 260)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                summaryStrip
                card("受支持的本地 Agent（\(agentCount) 款）", symbol: "square.grid.2x2") {
                    ForEach(agents) { agent in
                        AgentPathRow(agent: agent, share: share(of: agent))
                    }
                }
            }
        }
    }

    /// 列表上方那三格读数：15 款里有几款装了、装出多少会话、总共占多大。
    /// 这三行原来是「15 行 Agent + 一条灰路径」，看不出哪个 Agent 是大户；
    /// 占比条和体积列才是这一页真正要看的东西。
    private var summaryStrip: some View {
        HStack(spacing: Theme.Space.l) {
            stat("\(installedCount)", "已安装", unit: "/ \(agentCount) 款")
            stat("\(totalSessionCount)", "会话", unit: "个")
            stat(Fmt.splitValue(totalBytes).0, "合计占用", unit: Fmt.splitValue(totalBytes).1)
        }
    }

    private func stat(_ value: String, _ label: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.Typo.num(15, .semibold))
                    .foregroundStyle(Theme.t1)
                Text(unit)
                    .font(Theme.Typo.num(10.5, .medium))
                    .foregroundStyle(Theme.t3)
            }
            Text(label)
                .font(Theme.Typo.rowSub)
                .foregroundStyle(Theme.t2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .cardSurface()
    }

    // MARK: - 关于

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            card("ConversationClean", symbol: "sparkles") {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    HStack(spacing: Theme.Space.l) {
                        ZStack {
                            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                .fill(Theme.accentSoft)
                            Image(systemName: "tray.2")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(Theme.accent)
                        }
                        .frame(width: 44, height: 44)
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                .strokeBorder(Theme.accentEdge, lineWidth: 1)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("ConversationClean")
                                .font(Theme.Typo.cardTitle)
                                .foregroundStyle(Theme.t1)
                            // 原型把版本写死成 1.0.0；真机应显示 Info.plist 里的真实版本。
                            Text("版本 \(appVersion) · macOS 14.0 Sonoma 及以上")
                                .font(Theme.Typo.mono(10.5))
                                .foregroundStyle(Theme.t3)
                        }
                        Spacer(minLength: 0)
                    }

                    Text("全面支持 15 款本地 CLI、IDE 插件、AI 原生编辑器及自主 Agent 框架的会话扫描与安全清理。对同时维护「会话文件 + SQLite 索引」的 Agent，删除会话时同步清理索引行，避免幽灵会话残留。")
                        .font(Theme.Typo.rowSub)
                        .foregroundStyle(Theme.t2)
                        .lineSpacing(2.6)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: Theme.Space.m) {
                        fact("\(agentCount)", "受支持 Agent")
                        fact("\(settingsIndexNotes.count)", "双层索引同步")
                        fact("1", "并发扫描任务组")
                    }
                    .padding(.top, Theme.Space.xs)
                }
                .padding(Theme.Space.l)
            }
        }
    }

    private func fact(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Theme.Typo.num(15, .semibold))
                .foregroundStyle(Theme.accent)
            Text(label)
                .font(Theme.Typo.rowSub)
                .foregroundStyle(Theme.t2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .tintedSurface(Theme.Radius.control)
    }

    // MARK: - 分组卡片

    /// 卡片头（靛蓝图标 + 12pt 半粗标题）+ 发丝线 + 内容。
    private func card<Content: View>(_ title: String, symbol: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(Theme.Typo.sectionHeadStrong)
                    .foregroundStyle(Theme.t1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(height: 34)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            VStack(spacing: 0) { content() }
        }
        .cardSurface()
    }

    // MARK: - 数据

    /// `ConversationCategory.allCases` 里 `.all` 是「全部会话」，不是一款 Agent，要减掉。
    private var agentCount: Int { ConversationCategory.allCases.count - 1 }

    private var agents: [AgentInfo] {
        let rank = Dictionary(uniqueKeysWithValues: settingsAgentOrder.enumerated().map { ($1, $0) })
        return viewModel.agentInfos.sorted { a, b in
            let ra = rank[a.category] ?? Int.max
            let rb = rank[b.category] ?? Int.max
            return ra == rb ? a.category.rawValue < b.category.rawValue : ra < rb
        }
    }

    private var installedCount: Int { agents.filter(\.isInstalled).count }
    private var totalSessionCount: Int { agents.reduce(0) { $0 + $1.sessionCount } }
    private var totalBytes: Int64 { agents.reduce(0) { $0 + $1.totalBytes } }

    /// 某款 Agent 占全库扫描结果的比例。分母为 0（没扫过）时返回 0，
    /// 让条空着而不是拿 0 当分母算出一个 NaN / 无穷大。
    private func share(of agent: AgentInfo) -> Double {
        guard totalBytes > 0 else { return 0 }
        return Double(agent.totalBytes) / Double(totalBytes) * 100
    }

    private var headerHint: String {
        switch tab {
        case .general: return "扫描策略与安全开关"
        case .paths:   return "已安装 \(installedCount) 款 · 存储路径与占用"
        case .about:   return "会话扫描与安全清理"
        }
    }

    private var appVersion: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return v
        }
        return "dev"   // 未注入 Info.plist（如 SwiftPM 预览）时兜底
    }
}

// MARK: - 导航行

/// 与主窗口侧栏同一套：选中态靛蓝渐变实心 + 白字，28pt 行高。
private struct SettingsRailRow: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: symbol)
                    .font(Theme.Typo.note)
                    .foregroundStyle(isOn ? Color.white : Theme.t2)
                    .frame(width: 14)
                Text(title)
                    .font(isOn ? Theme.Typo.navItemActive : Theme.Typo.navItem)
                    .foregroundStyle(isOn ? Color.white : Theme.t1)
                    .lineLimit(1)
                Spacer(minLength: 0)
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
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private var fill: AnyShapeStyle {
        if isOn {
            return AnyShapeStyle(LinearGradient(colors: [Theme.accentHi, Theme.accent],
                                                startPoint: .top, endPoint: .bottom))
        }
        if hovering { return AnyShapeStyle(Theme.line.opacity(0.7)) }
        return AnyShapeStyle(Color.clear)
    }
}

// MARK: - 手绘开关

/// iOS 式开关。系统 `Toggle` 那一套外观（轨道渐变 + 高光 + 焦点环）在深色
/// 模式下是另一种蓝，和侧栏选中态摆在一起颜色对不上，这里整块重画。
///
/// 纯绘制视图，不含 `Toggle`：开关画在整行那个 `Button` 里，行本身才是
/// 可点单元（点行即切换），所以开关只画不接管事件 —— 语音标注与
/// `accessibilityValue` 挂在行上，语义仍然是「开关」而不是「按钮」。
private struct DrawnSwitch: View {
    let isOn: Bool
    var onTint: Color = Theme.accent

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(track)
            Circle()
                .fill(Color.white)
                .frame(width: 13, height: 13)
                .shadow(color: Color.black.opacity(0.22), radius: 1.2, y: 0.5)
                .padding(2)
        }
        .frame(width: 30, height: 17)
        // 关闭态描一圈发丝线，轨道才不会在浅色背景上「消失」
        .overlay {
            Capsule().strokeBorder(Theme.line, lineWidth: 1)
                .opacity(isOn ? 0 : 1)
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: isOn)
        .animation(.easeOut(duration: 0.1), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityHidden(true)
    }

    private var track: AnyShapeStyle {
        if isOn {
            return AnyShapeStyle(LinearGradient(colors: [onTint.opacity(0.92), onTint],
                                                startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(hovering ? Theme.lineStrong : Theme.line)
    }
}

// MARK: - .path-row

/// 安装状态一律读 `AgentInfo.isInstalled`。
/// 早期版本这里有一份硬编码的 4 款名单把 Aider / OpenViking / Zed / OpenHands
/// 钉死成「未发现」并隐藏 Finder 按钮，而侧栏早已改成读扫描结果 ——
/// 装了这几款的用户会在这里看到与侧栏矛盾的结论。该名单已删除。
///
/// 40pt 行：图标 18pt（不是 48pt，15 行排下来 720pt 要滚三轮）+
/// 名称/状态 + 路径 + 占比条 + 体积 + Finder 按钮，一屏能扫完。
private struct AgentPathRow: View {
    let agent: AgentInfo
    /// 占全库扫描结果的比例，0...100
    let share: Double

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            AgentIconView(category: agent.category, size: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Space.s) {
                    Text(agent.category.rawValue)
                        .font(Theme.Typo.rowTitle)
                        .foregroundStyle(agent.isInstalled ? Theme.t1 : Theme.t3)
                    statusChip
                }
                Text(displayPath)
                    .font(Theme.Typo.mono(10.5))
                    .foregroundStyle(Theme.t3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(agent.storagePath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // ShareBar 内部有 `max(2, ...)` 的最小可见宽度，0% 也会留一个 2pt 短划；
            // 那一列右边写的是「— 0 KB」，留个非零的条是在说谎。0 字节干脆不画条。
            if agent.totalBytes > 0 {
                ShareBar(percent: share, width: 56, height: 4)
            } else {
                Color.clear.frame(width: 56, height: 4)
            }

            Text(shareText)
                .font(Theme.Typo.num(10.5))
                .foregroundStyle(Theme.t2)
                .frame(width: 32, alignment: .trailing)

            Text(Fmt.bytes(agent.totalBytes))
                .font(Theme.Typo.sizeNum)
                .foregroundStyle(agent.totalBytes > 0 ? Theme.t1 : Theme.t3)
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)

            // 占位保列宽：未安装的 Agent 也要和上面几行对齐
            if agent.isInstalled {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: agent.storagePath))
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(Theme.Typo.sectionHead)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(DrawnButtonStyle(variant: .flat, horizontalPadding: 0, compact: true))
                .help("在 Finder 中打开 \(agent.category.rawValue) 的存储目录")
            } else {
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: 40)
    }

    private var displayPath: String {
        Fmt.abbreviateHome(agent.storagePath)
    }

    private var shareText: String {
        guard share > 0 else { return "—" }
        // 0.4% 四舍五入成 0% 会读成「没占」，与左边的体积自相矛盾
        if share < 0.5 { return "<1%" }
        return "\(Int(share.rounded()))%"
    }

    private var status: String {
        guard agent.isInstalled else { return "未发现" }
        return agent.sessionCount > 0 ? "\(agent.sessionCount) 会话" : "已检测到"
    }

    private var statusChip: some View {
        Text(status)
            .font(Theme.Typo.num(9.5, .semibold))
            .foregroundStyle(agent.isInstalled ? Theme.successText : Theme.t3)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(agent.isInstalled ? Theme.successSoft : Theme.sunken)
            }
            .fixedSize()
    }
}
