import SwiftUI
import AppKit

// MARK: - 设置窗口
//
// 逐像素移植原型 `#setScrim > .settings`。唯一权威依据是 `renderSettings()`（约 1250 行）
// 与 385–470 行的 `.settings / .set-tabs / .set-body / .set-group / .tgl / .sw /
// .path-row / .pill / .about / .facts`。
//
// 铁律：原型里没有的元素一律不加。上一版的「存储路径总览」卡片与路径页脚注都已删除。
// 运行在 macOS Settings scene 里，容器 / tab 条 / 滚动区全部手绘，
// 不用 TabView / Form / List —— 系统默认行高与底色跟原型的 1px 发丝线语言冲突。

/// 原型 AGENTS 的视觉顺序。`AgentScanService.scanners` 的注册顺序不同
/// （Pi 排在 Cline 之后、Antigravity 排在最后），原型固定是 Trae → Antigravity → Aider，
/// 所以路径页按这张表重排一次。
private let settingsAgentOrder: [ConversationCategory] = [
    .claudeCode, .codex, .piAgent, .cline, .rooCode, .continueDev, .copilotChat,
    .cursor, .windsurf, .trae, .antigravity, .aider, .openViking, .zed, .openHands,
]

/// 原型 AGENTS 表里 `det:false` 的 4 款 —— 不做本机存储目录检测：
/// pill 恒为「未发现」，且不渲染「在 Finder 中打开」按钮。
private let settingsUndetectable: Set<ConversationCategory> = [.aider, .openViking, .zed, .openHands]

/// 原型 AGENTS 表里带 `idx` / `idxNote` 的那批 Agent（会话文件 + 第二层 SQLite 索引），
/// 是「关于」页「双层索引同步」那个数字的唯一来源：增删一款 Agent，这里跟着变，
/// 不再像原型那样把 6 写死在 DOM 里。
private let settingsIndexNotes: [ConversationCategory: String] = [
    .piAgent:     "context-mode SQLite 索引行同步删除",
    .copilotChat: "state.vscdb 索引行同步删除",
    .cursor:      "state.vscdb 索引行同步删除",
    .windsurf:    "state.vscdb 索引行同步删除",
    .trae:        "state.vscdb 索引行同步删除",
    .antigravity: "state.vscdb 索引行同步删除",
]

struct SettingsView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    // 键名与 Core/CleanPrefs.Key 逐字一致（服务层在读），不能改。
    @AppStorage("autoScanOnLaunch") private var autoScanOnLaunch = true
    @AppStorage("confirmBeforeClean") private var confirmBeforeClean = true
    @AppStorage("cleanFileHistorySnapshots") private var cleanFileHistorySnapshots = true
    @AppStorage("cleanEmptyProjectFolders") private var cleanEmptyProjectFolders = true

    @State private var tab: SettingsTab = .general
    @State private var hoveredTab: SettingsTab?

    private enum SettingsTab: String, CaseIterable {
        case general, paths, about

        var title: String {
            switch self {
            case .general: return "通用"
            case .paths:   return "Agent 路径"
            case .about:   return "关于"
            }
        }

        /// 原型 `.set-tabs button svg`：15px 线性图标。
        var icon: String {
            switch self {
            case .general: return "gear"
            case .paths:   return "folder"
            case .about:   return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            contentArea
        }
        .frame(width: 760, height: 560)
        .background(CC.surface)
    }

    // MARK: - 顶部 tab 条

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { item in
                let on = item == tab
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.icon)
                            .font(.system(size: 15))
                        Text(item.title)
                            .font(.system(size: 13, weight: on ? .semibold : .regular))
                    }
                    // 原型 `.set-tabs button:hover{color:var(--fg)}`
                    .foregroundStyle(on || hoveredTab == item ? CC.fg : CC.muted)
                    .frame(height: 36)
                    .padding(.horizontal, 13)
                    .overlay(alignment: .bottom) {
                        if on {
                            // 原型 `.set-tabs button.on{border-bottom:2px solid var(--fg); margin-bottom:-1px}`：
                            // 指示线要压住 tab 条自己那条 1px 边框，所以下移 1pt。
                            // 因此分隔线必须画在按钮「下面」，不能用 ccHairline（overlay 在内容之上）。
                            Rectangle()
                                .fill(CC.fg)
                                .frame(height: 2)
                                .offset(y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredTab = $0 ? item : nil }
                .help("设置 · " + item.title)
            }
            Spacer(minLength: 0)
        }
        .padding(.init(top: 12, leading: 14, bottom: 0, trailing: 14))
        .background(alignment: .bottom) {
            Rectangle().fill(CC.border).frame(height: CC.M.hairline)
        }
    }

    // MARK: - 内容区

    /// 三个 tab 共用 `.set-body` 的 `padding: 22px 26px 26px`。
    private var bodyPadding: EdgeInsets {
        .init(top: 22, leading: 26, bottom: 26, trailing: 26)
    }

    @ViewBuilder
    private var contentArea: some View {
        if tab == .about {
            // 原型 `.about{height:100%}`：关于页不滚动，直接吃满剩余高度才能真正垂直居中。
            // 走 ScrollView 的话 VStack 里的 Spacer 会被压成 0。
            aboutTab
                .padding(bodyPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 不加 transition：切换 tab 时旧内容淡出会闪一下
                    if tab == .general { generalTab } else { pathsTab }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(bodyPadding)
            }
        }
    }

    // MARK: - 通用

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsGroup("扫描与清理", isFirst: true) {
                prefRow("启动应用时自动扫描会话",
                        "沿用 CleanViewModel 初始化时的首次扫描行为",
                        $autoScanOnLaunch, divider: false)
                prefRow("删除会话时同步清除快照与子代理数据",
                        "关闭后仅删除主会话文件，快照与子代理目录将保留",
                        $cleanFileHistorySnapshots, divider: true)
                prefRow("删除会话后自动移除空项目目录",
                        "清理后递归移除不再包含任何会话的空目录",
                        $cleanEmptyProjectFolders, divider: true)
            }
            settingsGroup("安全策略") {
                prefRow("执行清理操作前弹出二次确认",
                        "关闭后清理将立即执行，不可撤销",
                        $confirmBeforeClean, divider: false)
            }
        }
    }

    /// 复刻 `.set-group`：mono 小标题 + 组内行；非首组自带
    /// `margin-top:26px; padding-top:22px; border-top:1px`。
    private func settingsGroup<Content: View>(
        _ title: String,
        isFirst: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {   // 12 = h3 的 margin-bottom
            CCSectionHeader(title)
            content()
        }
        .padding(.top, isFirst ? 0 : 22)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle()
                    .fill(CC.border)
                    .frame(height: CC.M.hairline)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// 一条 `.tgl`：整行可点（原型是 `<label>` 包住 input），右侧自绘开关。
    private func prefRow(
        _ title: String,
        _ subtitle: String,
        _ binding: Binding<Bool>,
        divider: Bool
    ) -> some View {
        Toggle(isOn: binding) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(CC.F.bodyEm)
                        .foregroundStyle(CC.fg)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(CC.muted)
                        .lineSpacing(3.4)          // ≈ 1.5 行高
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 原型 `.tgl .tt{flex:1; min-width:0}`：文案必须撑满，
                // 否则行底发丝线的长度会随文案长短逐行变化。
                .frame(maxWidth: .infinity, alignment: .leading)

                CCSwitch(isOn: binding.wrappedValue)
                    .padding(.top, 1)           // 原型 `.sw{margin-top:1px}`
            }
            .padding(.vertical, 10)             // 原型 `.tgl{padding:10px 0}`
            .contentShape(Rectangle())
        }
        .toggleStyle(SettingsToggleStyle())
        .frame(maxWidth: .infinity, alignment: .leading)   // 撑满，行底发丝线才等长
        .ccHairline(divider ? .top : [])        // 原型 `.tgl + .tgl{border-top}`
    }

    // MARK: - Agent 路径

    private var pathsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            CCSectionHeader("受支持的 Local Agents（\(agentCount) 款）")

            if agents.isEmpty {
                Text("尚未扫描到 Agent 信息，请先回到主窗口执行一次扫描。")
                    .font(CC.F.caption)
                    .foregroundStyle(CC.muted)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                        AgentPathRow(agent: agent)
                            // 原型 `.path-row + .path-row{border-top}`
                            .ccHairline(index == 0 ? [] : .top)
                    }
                }
            }
        }
    }

    // MARK: - 关于

    private var aboutTab: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                // 原型 `.about .gi{width:52px;height:52px;color:var(--fg)}`：
                // 是线性托盘图标，不是圆形徽章
                Image(systemName: "tray.2")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(CC.fg)
                    .padding(.bottom, 16)

                Text("ConversationClean")
                    .font(CC.F.display)
                    .foregroundStyle(CC.fg)

                // 原型把版本写死成 1.0.0；真机应当显示 Info.plist 里的真实版本，
                // 否则每次发版「关于」页都还写着 1.0.0。取不到时回落 dev。
                Text("版本 \(appVersion) · macOS 14.0 Sonoma 及以上")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(CC.muted)
                    .padding(.top, 5)

                Text("全面支持 15 款本地 CLI、IDE 插件、AI 原生编辑器及自主 Agent 框架的会话扫描与安全清理。对同时维护「会话文件 + SQLite 索引」的 Agent，删除会话时同步清理索引行，避免幽灵会话残留。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(CC.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3.75)      // ≈ 1.65 行高
                    // 原型 `max-width:44ch`；SwiftUI 没有 ch 单位，12.5pt 下折算约 360pt
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)

                factsRow
                    .padding(.top, 24)
                    .ccHairline(.top)
                    .padding(.top, 20)
            }
            .frame(maxWidth: .infinity)
            .padding(20)                 // 原型 `.about{padding:20px}`，facts 的 1px 线据此横贯 668pt
            Spacer(minLength: 0)
        }
    }

    /// 原型 `.about .facts{display:flex;gap:26px;width:100%;justify-content:center}`：
    /// 行是满宽的（顶线因此横贯整条内容区），三项按自身宽度居中成簇、彼此间隔 26pt，
    /// 而不是三等分铺开 —— 照抄 CSS 就是这个几何。
    private var factsRow: some View {
        HStack(alignment: .top, spacing: 26) {
            fact("\(agentCount)", "受支持 Agent")
            fact("\(settingsIndexNotes.count)", "双层索引同步")
            fact("1", "并发扫描任务组")
        }
        .frame(maxWidth: .infinity)
    }

    private func fact(_ value: String, _ label: String) -> some View {
        CCStatCell(value: value, label: label, size: 20)
            // 原型 `.about .facts .n{font-size:20px;letter-spacing:-.03em}`
            .tracking(-0.6)
    }

    // MARK: - 数据

    /// 原型 AGENTS 的条数。`ConversationCategory.allCases` 里 `.all` 是「全部会话」，
    /// 不是一款 Agent，要减掉。
    private var agentCount: Int { ConversationCategory.allCases.count - 1 }

    /// 按原型顺序排列的 Agent 列表；表里没有的（理论上不会有）沉到末尾。
    private var agents: [AgentInfo] {
        let rank = Dictionary(uniqueKeysWithValues: settingsAgentOrder.enumerated().map { ($1, $0) })
        return viewModel.agentInfos.sorted { a, b in
            let ra = rank[a.category] ?? Int.max
            let rb = rank[b.category] ?? Int.max
            return ra == rb ? a.category.rawValue < b.category.rawValue : ra < rb
        }
    }

    private var appVersion: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return v
        }
        return "dev"   // 未注入 Info.plist（如 SwiftPM 预览）时兜底
    }
}

// MARK: - 开关

/// 整行可点的 toggle：原型 `.tgl` 是 `<label>` 包住隐藏的 checkbox，
/// 点标题/副标题/开关任意位置都生效。套 Toggle 是为了保住焦点与辅助功能语义。
private struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(.plain)
    }
}

/// 原型 `.sw` 的自绘开关。
///
/// 不用共享的 `CCSwitchRow`：它走系统 `SwitchToggleStyle(tint: CC.accent)`，
/// 而原型是「关 = fg 20% 透明底 / 开 = 满色 fg（近黑）」、滑块也只有 18pt（系统的是 22pt），
/// 两者在截图上是绿黑两种颜色 + 粗细不同的滑块。所以这里按 38×22 / 圆角 11 / 18pt 滑块手绘，
/// 共享组件保持不动。
private struct CCSwitch: View {
    var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? AnyShapeStyle(CC.fg) : AnyShapeStyle(CC.fg.opacity(0.2)))
                .frame(width: 38, height: 22)
            Circle()
                .fill(CC.surface)
                .frame(width: 18, height: 18)
                // 原型 `box-shadow:0 1px 3px var(--fg-hair)`，fg-hair = fg 4%
                .shadow(color: CC.fg.opacity(0.04), radius: 3, x: 0, y: 1)
                .padding(.horizontal, 2)     // 关 = 2pt，开 = 38-18-2 = 18pt
        }
        .frame(width: 38, height: 22)
        .animation(CC.Mv.quick, value: isOn)
    }
}

// MARK: - .path-row

/// 原型 `.path-row`：17pt 线性图标 + 名称 + 状态胶囊 + 路径 + Finder 按钮。
/// `det:false` 的 4 款（Aider / OpenViking / Zed AI / OpenHands）没有 Finder 按钮。
private struct AgentPathRow: View {
    let agent: AgentInfo

    /// 原型 `a.det ? (st.n ? st.n+" 会话" : "已检测到") : "未发现"`
    private var pill: (text: String, tone: CCBadge.Tone) {
        guard !settingsUndetectable.contains(agent.category) else { return ("未发现", .neutral) }
        let n = agent.sessionCount
        return (n > 0 ? "\(n) 会话" : "已检测到", .accent)
    }

    var body: some View {
        HStack(spacing: 11) {
            // 原型 `.path-row .gi{width:17px;height:17px}`：17pt 线性 SF Symbol，不是圆形徽章
            Image(systemName: agent.category.iconName)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(CC.muted)
                .frame(width: 17, height: 17)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {                 // 原型 `.path-row .pt .n{gap:7px}`
                    Text(agent.category.rawValue)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(CC.fg)
                        .lineLimit(1)
                    // 原型 `.pill`：mono 10px / 水平 6px 垂直 1px / 圆角 999
                    CCBadge(text: pill.text, tone: pill.tone, mono: true, cornerRadius: CC.R.pill)
                }
                Text(agent.storagePath)
                    .font(CC.F.mono)
                    .foregroundStyle(CC.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(agent.storagePath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !settingsUndetectable.contains(agent.category) {
                CCIconButton(
                    systemImage: "arrow.up.forward.square",   // 原型 i-external
                    size: 28,
                    help: "在 Finder 中打开 \(agent.category.rawValue) 的存储目录"
                ) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: agent.storagePath))
                }
            }
        }
        .padding(.vertical, 10)   // 原型 `.path-row{padding:10px 0}`
    }
}
