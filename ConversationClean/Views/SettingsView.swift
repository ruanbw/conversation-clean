import SwiftUI

struct SettingsView: View {
    @AppStorage("autoScanOnLaunch") private var autoScanOnLaunch = true
    @AppStorage("confirmBeforeClean") private var confirmBeforeClean = true
    @AppStorage("keepRecentDays") private var keepRecentDays = 30

    var body: some View {
        TabView {
            Form {
                Section("扫描偏好") {
                    Toggle("启动应用时自动扫描会话", isOn: $autoScanOnLaunch)
                    Stepper("保留最近 \(keepRecentDays) 天的会话记录", value: $keepRecentDays, in: 1...365)
                }

                Section("安全策略") {
                    Toggle("执行清理操作前弹出二次确认", isOn: $confirmBeforeClean)
                }
            }
            .padding()
            .tabItem {
                Label("通用", systemImage: "gear")
            }

            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("ConversationClean")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("版本 1.0.0 (Build 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("专为 macOS 设计的现代化会话记录清理工具模板。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(30)
            .tabItem {
                Label("关于", systemImage: "info.circle")
            }
        }
        .frame(width: 450, height: 280)
    }
}
