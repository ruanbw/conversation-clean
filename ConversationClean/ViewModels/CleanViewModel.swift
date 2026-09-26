import Foundation
import Combine

@MainActor
class CleanViewModel: ObservableObject {
    @Published var conversations: [ConversationItem] = []
    @Published var selectedCategory: ConversationCategory = .all
    @Published var searchText: String = ""
    @Published var isScanning: Bool = false
    @Published var isCleaning: Bool = false
    @Published var lastCleanedBytes: Int64 = 0
    @Published var showCleanSuccessAlert: Bool = false

    init() {
        loadSampleData()
    }

    var filteredConversations: [ConversationItem] {
        conversations.filter { item in
            let matchesCategory = (selectedCategory == .all || item.category == selectedCategory)
            let matchesSearch = searchText.isEmpty ||
                item.title.localizedCaseInsensitiveContains(searchText) ||
                item.snippet.localizedCaseInsensitiveContains(searchText)
            return matchesCategory && matchesSearch
        }
    }

    var totalSize: Int64 {
        conversations.reduce(0) { $0 + $1.sizeInBytes }
    }

    var selectedItems: [ConversationItem] {
        conversations.filter { $0.isSelected }
    }

    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeInBytes }
    }

    func selectAll(_ select: Bool) {
        let currentFilteredIds = Set(filteredConversations.map { $0.id })
        for index in conversations.indices {
            if currentFilteredIds.contains(conversations[index].id) {
                conversations[index].isSelected = select
            }
        }
    }

    func scanConversations() async {
        isScanning = true
        // 模拟扫描耗时
        try? await Task.sleep(nanoseconds: 800_000_000)
        loadSampleData()
        isScanning = false
    }

    func cleanSelected() async {
        let itemsToDelete = selectedItems
        guard !itemsToDelete.isEmpty else { return }

        isCleaning = true
        try? await Task.sleep(nanoseconds: 600_000_000)

        let cleaned = itemsToDelete.reduce(0) { $0 + $1.sizeInBytes }
        let idsToDelete = Set(itemsToDelete.map { $0.id })
        conversations.removeAll { idsToDelete.contains($0.id) }

        lastCleanedBytes = cleaned
        isCleaning = false
        showCleanSuccessAlert = true
    }

    private func loadSampleData() {
        let calendar = Calendar.current
        let now = Date()

        conversations = [
            ConversationItem(
                id: UUID(),
                title: "SwiftUI macOS 架构设计探讨",
                category: .claude,
                messageCount: 42,
                sizeInBytes: 1024 * 340,
                updatedAt: calendar.date(byAdding: .hour, value: -2, to: now) ?? now,
                snippet: "关于如何组织 View、ViewModel 以及状态管理的深入讨论..."
            ),
            ConversationItem(
                id: UUID(),
                title: "Xcode 工程自动生成脚本排错",
                category: .chatGPT,
                messageCount: 18,
                sizeInBytes: 1024 * 180,
                updatedAt: calendar.date(byAdding: .day, value: -1, to: now) ?? now,
                snippet: "分析 project.pbxproj 的各个 UUID 与 buildConfiguration..."
            ),
            ConversationItem(
                id: UUID(),
                title: "Gemini 2.5 Pro 多模态能力评测",
                category: .gemini,
                messageCount: 56,
                sizeInBytes: 1024 * 720,
                updatedAt: calendar.date(byAdding: .day, value: -3, to: now) ?? now,
                snippet: "对长上下文以及图像识别 benchmark 进行统计对比..."
            ),
            ConversationItem(
                id: UUID(),
                title: "Cursor 全局快捷键与工作流配置",
                category: .cursor,
                messageCount: 25,
                sizeInBytes: 1024 * 210,
                updatedAt: calendar.date(byAdding: .day, value: -5, to: now) ?? now,
                snippet: "整理常用的提示词模版和键盘快捷键绑定..."
            ),
            ConversationItem(
                id: UUID(),
                title: "本地临时历史日志归档",
                category: .other,
                messageCount: 88,
                sizeInBytes: 1024 * 1024 * 4,
                updatedAt: calendar.date(byAdding: .day, value: -14, to: now) ?? now,
                snippet: "已过期的旧会话本地缓存与草稿文件，建议定期清理释放空间。"
            )
        ]
    }
}
