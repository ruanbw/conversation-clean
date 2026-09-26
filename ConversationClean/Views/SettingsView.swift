import SwiftUI

struct SettingsView: View {
    @AppStorage("autoScanOnLaunch") private var autoScanOnLaunch = true
    @AppStorage("confirmBeforeClean") private var confirmBeforeClean = true
    @AppStorage("cleanFileHistorySnapshots") private var cleanFileHistorySnapshots = true
    @AppStorage("cleanEmptyProjectFolders") private var cleanEmptyProjectFolders = true

    var body: some View {
        TabView {
            Form {
                Section("扫描与清理") {
                    Toggle("启动应用时自动扫描会话", isOn: $autoScanOnLaunch)
                    Toggle("删除会话时同步清除快照与子代理数据", isOn: $cleanFileHistorySnapshots)
                    Toggle("删除会话后自动移除空项目目录", isOn: $cleanEmptyProjectFolders)
                }

                Section("安全策略") {
                    Toggle("执行清理操作前弹出二次确认", isOn: $confirmBeforeClean)
                }
            }
            .padding(20)
            .tabItem {
                Label("通用", systemImage: "gear")
            }

            Form {
                Section("受支持的 Local Agents (15 款)") {
                    AgentPathRow(
                        name: "Claude Code",
                        icon: "terminal.fill",
                        color: .orange,
                        path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
                    )

                    AgentPathRow(
                        name: "Codex",
                        icon: "chevron.left.forwardslash.chevron.right",
                        color: .green,
                        path: (ProcessInfo.processInfo.environment["CODEX_HOME"] != nil)
                            ? ProcessInfo.processInfo.environment["CODEX_HOME"]!
                            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
                    )

                    AgentPathRow(
                        name: "Pi Agent",
                        icon: "cpu",
                        color: .pink,
                        path: PiAgentScanner().storageURL.path
                    )

                    AgentPathRow(
                        name: "Cline",
                        icon: "bolt.horizontal.fill",
                        color: .blue,
                        path: ClineScanner().storageURL.path
                    )

                    AgentPathRow(
                        name: "Roo Code",
                        icon: "sparkles",
                        color: .purple,
                        path: RooCodeScanner().storageURL.path
                    )

                    AgentPathRow(
                        name: "Continue",
                        icon: "play.rectangle.fill",
                        color: .cyan,
                        path: ContinueScanner().storageURL.path
                    )

                    AgentPathRow(
                        name: "Copilot / VS Code",
                        icon: "bubble.left.and.exclamationmark.bubble.right.fill",
                        color: .indigo,
                        path: VSCodeChatScanner().storageURL.path
                    )

                    AgentPathRow(
                        name: "Cursor",
                        icon: "cursorarrow.rays",
                        color: .teal,
                        path: CursorScanner().storageURL.path
                    )

                    AgentPathRow(
                        name: "Windsurf",
                        icon: "wind",
                        color: .mint,
                        path: WindsurfScanner().storageURL.path
                    )

                    AgentPathRow(
                        name: "Trae",
                        icon: "bolt.ring.closed",
                        color: .yellow,
                        path: TraeScanner().storageURL.path
                    )

                    AgentPathRow(
                        name: "Aider",
                        icon: "terminal",
                        color: .red,
                        path: AiderScanner().storageURL.path
                    )

                    AgentPathRow(
                        name: "OpenViking",
                        icon: "shield.lefthalf.filled",
                        color: .brown,
                        path: OpenVikingScanner().storageURL.path
                    )

                    AgentPathRow(
                        name: "Zed AI",
                        icon: "character.textbox",
                        color: .gray,
                        path: ZedScanner().storageURL.path
                    )

                    AgentPathRow(
                        name: "OpenHands",
                        icon: "hand.raised.fill",
                        color: .orange,
                        path: OpenHandsScanner().storageURL.path
                    )

                    AgentPathRow(
                        name: "Antigravity",
                        icon: "sparkles.rectangle.stack",
                        color: .purple,
                        path: AntigravityScanner().storageURL.path
                    )
                }
            }
            .padding(20)
            .tabItem {
                Label("Agent 路径", systemImage: "folder.badge.gearshape")
            }

            VStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("ConversationClean")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("版本 1.0.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("全面支持 15 款本地 CLI、IDE 插件、AI 原生编辑器及自主 Agent 框架（Claude Code、Codex、Pi Agent、Cline、Roo Code、Continue、GitHub Copilot、Cursor、Windsurf、Trae、Aider、OpenViking、Zed AI、OpenHands、Antigravity）的会话扫描与安全清理。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(30)
            .tabItem {
                Label("关于", systemImage: "info.circle")
            }
        }
        .frame(width: 520, height: 420)
    }
}

struct AgentPathRow: View {
    let name: String
    let icon: String
    let color: Color
    let path: String

    var isDetected: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(name)
                        .fontWeight(.medium)
                    Text(isDetected ? "已检测到" : "未发现")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isDetected ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                        .foregroundColor(isDetected ? .green : .secondary)
                        .clipShape(Capsule())
                }

                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if isDetected {
                Button("在 Finder 中打开") {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
