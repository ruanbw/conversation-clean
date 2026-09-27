import SwiftUI
import AppKit

@main
struct ConversationCleanApp: App {
    @StateObject private var viewModel = CleanViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 1000, minHeight: 640)
                // 启动扫描的唯一发起点。`scanOnLaunchIfEnabled()` 内部带幂等闸门，
                // 所以后续新开窗口重跑这份 `.task` 也只会真扫一遍。
                //
                // 不能设在 ContentView 里：那里的 `.task` 会无条件跑
                // scanConversations()，把设置里的「启动时自动扫描」彻底绕过去。
                .task {
                    await viewModel.scanOnLaunchIfEnabled()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .commands { appCommands }

        // 原生设置窗口，接 ⌘,。之前刻意删掉了这个 scene（为了对齐原型弹层），
        // 现在恢复。
        Settings {
            SettingsView()
                .environmentObject(viewModel)
        }
    }

    /// 注意：这里是 `@CommandsBuilder`，**不是** `@ViewBuilder`。
    /// 两者都能包住 `CommandGroup`，但 `Commands` 走自己的 result builder。
    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .newItem) {}
    }
}
