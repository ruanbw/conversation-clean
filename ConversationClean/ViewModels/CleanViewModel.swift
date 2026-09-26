import Foundation
import Combine
import AppKit

enum CleanTarget {
    case selected
    case allInCurrentCategory
}

struct CategoryStats: Equatable {
    var count: Int = 0
    var sizeInBytes: Int64 = 0

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
    }
}

@MainActor
class CleanViewModel: ObservableObject {
    @Published var conversations: [ConversationItem] = [] {
        didSet {
            updateCachedStats()
            updateFilteredConversations()
        }
    }
    @Published var selectedCategory: ConversationCategory = .all {
        didSet {
            updateFilteredConversations()
        }
    }
    @Published var searchText: String = "" {
        didSet {
            searchSubject.send(searchText)
        }
    }

    @Published private(set) var filteredConversations: [ConversationItem] = []
    @Published private(set) var categoryStats: [ConversationCategory: CategoryStats] = [:]
    @Published private(set) var totalSize: Int64 = 0

    @Published var isScanning: Bool = false
    @Published var isCleaning: Bool = false
    @Published var lastCleanedBytes: Int64 = 0
    @Published var showCleanSuccessAlert: Bool = false
    @Published var showCleanConfirmAlert: Bool = false
    @Published var cleanTarget: CleanTarget = .selected
    @Published var agentInfos: [AgentInfo] = []

    private let scanService = AgentScanService.shared
    private let searchSubject = PassthroughSubject<String, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var debouncedSearchText: String = ""

    init() {
        setupSearchDebounce()
        updateCachedStats()
        Task {
            await scanConversations()
        }
    }

    private func setupSearchDebounce() {
        searchSubject
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] debouncedQuery in
                guard let self = self else { return }
                self.debouncedSearchText = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                self.updateFilteredConversations()
            }
            .store(in: &cancellables)
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
        updateFilteredConversations()
    }

    func setItemSelected(_ id: UUID, selected: Bool) {
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].isSelected = selected
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

    // MARK: - State Caching & Filtering Optimization

    private func updateCachedStats() {
        var stats: [ConversationCategory: CategoryStats] = [:]
        for cat in ConversationCategory.allCases {
            stats[cat] = CategoryStats()
        }

        var total: Int64 = 0
        for item in conversations {
            total += item.sizeInBytes
            stats[item.category, default: CategoryStats()].count += 1
            stats[item.category, default: CategoryStats()].sizeInBytes += item.sizeInBytes
            stats[.all, default: CategoryStats()].count += 1
            stats[.all, default: CategoryStats()].sizeInBytes += item.sizeInBytes
        }

        self.categoryStats = stats
        self.totalSize = total
    }

    private func updateFilteredConversations() {
        let query = debouncedSearchText.isEmpty ? searchText.trimmingCharacters(in: .whitespacesAndNewlines) : debouncedSearchText
        let targetCategory = selectedCategory

        if query.isEmpty {
            if targetCategory == .all {
                filteredConversations = conversations
            } else {
                filteredConversations = conversations.filter { $0.category == targetCategory }
            }
        } else {
            filteredConversations = conversations.filter { item in
                let matchesCategory = (targetCategory == .all || item.category == targetCategory)
                guard matchesCategory else { return false }
                return item.title.localizedCaseInsensitiveContains(query) ||
                    item.snippet.localizedCaseInsensitiveContains(query) ||
                    (item.projectPath?.localizedCaseInsensitiveContains(query) ?? false) ||
                    item.sessionId.localizedCaseInsensitiveContains(query)
            }
        }
    }
}
