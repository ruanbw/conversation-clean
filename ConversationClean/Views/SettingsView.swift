import SwiftUI
import AppKit

// MARK: - 设置
//
// 运行在原生 `Settings` scene 里（⌘,）。系统 `Form` 已提供分组与分隔，
// 系统 `Toggle` 已提供整行可点与深色模式正确的开关 —— 不再手绘。

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

struct SettingsView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    // 键名与 Core/CleanPrefs.Key 逐字一致（服务层在读），不能改。
    @AppStorage("autoScanOnLaunch") private var autoScanOnLaunch = true
    @AppStorage("confirmBeforeClean") private var confirmBeforeClean = true
    @AppStorage("cleanFileHistorySnapshots") private var cleanFileHistorySnapshots = true
    @AppStorage("cleanEmptyProjectFolders") private var cleanEmptyProjectFolders = true

    var body: some View {
        TabView {
            generalTab.tabItem { Label("通用", systemImage: "gear") }
            pathsTab.tabItem { Label("Agent 路径", systemImage: "folder") }
            aboutTab.tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 440)
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Section("扫描与清理") {
                toggle("启动应用时自动扫描会话",
                       "启动时扫描一次本机全部 Agent 的会话缓存",
                       $autoScanOnLaunch)
                toggle("删除会话时同步清除快照与子代理数据",
                       "关闭后仅删除主会话文件，快照与子代理目录将保留",
                       $cleanFileHistorySnapshots)
                toggle("删除会话后自动移除空项目目录",
                       "清理后递归移除不再包含任何会话的空目录",
                       $cleanEmptyProjectFolders)
            }
            Section("安全策略") {
                toggle("执行清理操作前弹出二次确认",
                       "关闭后清理将立即执行，不可撤销",
                       $confirmBeforeClean)
            }
        }
        .formStyle(.grouped)
    }

    private func toggle(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Agent 路径

    private var pathsTab: some View {
        Form {
            Section("受支持的本地 Agent（\(agentCount) 款）") {
                if agents.isEmpty {
                    Text("尚未扫描到 Agent 信息，请先回到主窗口执行一次扫描。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(agents) { agent in
                        AgentPathRow(agent: agent)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 关于

    private var aboutTab: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                Image(systemName: "tray.2")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 14)

                Text("ConversationClean")
                    .font(.title2)
                    .fontWeight(.semibold)

                // 原型把版本写死成 1.0.0；真机应显示 Info.plist 里的真实版本。
                Text("版本 \(appVersion) · macOS 14.0 Sonoma 及以上")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                Text("全面支持 15 款本地 CLI、IDE 插件、AI 原生编辑器及自主 Agent 框架的会话扫描与安全清理。对同时维护「会话文件 + SQLite 索引」的 Agent，删除会话时同步清理索引行，避免幽灵会话残留。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.top, 14)

                HStack(alignment: .top, spacing: 26) {
                    fact("\(agentCount)", "受支持 Agent")
                    fact("\(settingsIndexNotes.count)", "双层索引同步")
                    fact("1", "并发扫描任务组")
                }
                .padding(.top, 20)
            }
            .padding(20)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fact(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    private var appVersion: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return v
        }
        return "dev"   // 未注入 Info.plist（如 SwiftPM 预览）时兜底
    }
}

// MARK: - .path-row

/// 安装状态一律读 `AgentInfo.isInstalled`。
/// 早期版本这里有一份硬编码的 4 款名单把 Aider / OpenViking / Zed / OpenHands
/// 钉死成「未发现」并隐藏 Finder 按钮，而侧栏早已改成读扫描结果 ——
/// 装了这几款的用户会在这里看到与侧栏矛盾的结论。该名单已删除。
private struct AgentPathRow: View {
    let agent: AgentInfo

    private var status: String {
        guard agent.isInstalled else { return "未发现" }
        return agent.sessionCount > 0 ? "\(agent.sessionCount) 会话" : "已检测到"
    }

    var body: some View {
        HStack(spacing: 10) {
            AgentIconView(category: agent.category, size: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.category.rawValue).fontWeight(.medium)
                    Text(status)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
                Text(agent.storagePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(agent.storagePath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if agent.isInstalled {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: agent.storagePath))
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中打开 \(agent.category.rawValue) 的存储目录")
            }
        }
        .padding(.vertical, 3)
    }
}
