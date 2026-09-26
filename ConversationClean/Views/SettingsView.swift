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
                Section("受支持的 Local Agents") {
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
                Text("一键扫描并清理本地 AI Agent（Claude Code、Codex）产生的会话历史、上下文快照与缓存垃圾。")
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
        .frame(width: 480, height: 320)
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
