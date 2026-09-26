import SwiftUI

@main
struct ConversationCleanApp: App {
    @StateObject private var viewModel = CleanViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 800, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {}
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(viewModel)
        }
        #endif
    }
}
