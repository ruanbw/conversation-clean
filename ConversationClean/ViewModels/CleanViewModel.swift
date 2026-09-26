import Foundation
import Combine
import AppKit

enum CleanTarget {
    case selected
    case allInCurrentCategory
}

@MainActor
class CleanViewModel: ObservableObject {
    @Published var conversations: [ConversationItem] = []
    @Published var selectedCategory: ConversationCategory = .all
    @Published var searchText: String = ""
    @Published var isScanning: Bool = false
    @Published var isCleaning: Bool = false
    @Published var lastCleanedBytes: Int64 = 0
    @Published var showCleanSuccessAlert: Bool = false
    @Published var showCleanConfirmAlert: Bool = false
    @Published var cleanTarget: CleanTarget = .selected
    @Published var agentInfos: [AgentInfo] = []

    private let scanService = AgentScanService.shared

    init() {
        Task {
            await scanConversations()
        }
    }

    var filteredConversations: [ConversationItem] {
        conversations.filter { item in
            let matchesCategory = (selectedCategory == .all || item.category == selectedCategory)
            let matchesSearch = searchText.isEmpty ||
                item.title.localizedCaseInsensitiveContains(searchText) ||
                item.snippet.localizedCaseInsensitiveContains(searchText) ||
                (item.projectPath?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                item.sessionId.localizedCaseInsensitiveContains(searchText)
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

    var currentCategorySize: Int64 {
        filteredConversations.reduce(0) { $0 + $1.sizeInBytes }
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
        guard !isScanning else { return }
        isScanning = true
        let scanned = await scanService.scanAll()
        conversations = scanned
        agentInfos = scanService.getAgentInfos(from: scanned)
        isScanning = false
    }

    func requestCleanSelected() {
        guard !selectedItems.isEmpty else { return }
        cleanTarget = .selected
        showCleanConfirmAlert = true
    }

    func requestCleanAll() {
        guard !filteredConversations.isEmpty else { return }
        cleanTarget = .allInCurrentCategory
        showCleanConfirmAlert = true
    }

    func executeClean() async {
        guard !isCleaning else { return }
        isCleaning = true

        let itemsToDelete: [ConversationItem]
        switch cleanTarget {
        case .selected:
            itemsToDelete = selectedItems
        case .allInCurrentCategory:
            itemsToDelete = filteredConversations
        }

        guard !itemsToDelete.isEmpty else {
            isCleaning = false
            return
        }

        let freedBytes = await scanService.delete(items: itemsToDelete)
        let idsToDelete = Set(itemsToDelete.map { $0.id })
        conversations.removeAll { idsToDelete.contains($0.id) }
        agentInfos = scanService.getAgentInfos(from: conversations)

        lastCleanedBytes = freedBytes > 0 ? freedBytes : itemsToDelete.reduce(0) { $0 + $1.sizeInBytes }
        isCleaning = false
        showCleanSuccessAlert = true
    }

    func deleteSingle(item: ConversationItem) async {
        let freedBytes = await scanService.delete(items: [item])
        conversations.removeAll { $0.id == item.id }
        agentInfos = scanService.getAgentInfos(from: conversations)
        lastCleanedBytes = freedBytes > 0 ? freedBytes : item.sizeInBytes
        showCleanSuccessAlert = true
    }

    func revealInFinder(item: ConversationItem) {
        if let firstPath = item.associatedPaths.first, FileManager.default.fileExists(atPath: firstPath) {
            NSWorkspace.shared.selectFile(firstPath, inFileViewerRootedAtPath: "")
        } else if let projectPath = item.projectPath, FileManager.default.fileExists(atPath: projectPath) {
            NSWorkspace.shared.selectFile(projectPath, inFileViewerRootedAtPath: "")
        }
    }

    func copyToClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
