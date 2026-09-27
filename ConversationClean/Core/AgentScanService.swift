import Foundation

struct AgentInfo: Identifiable {
    let category: ConversationCategory
    let isInstalled: Bool
    let storagePath: String
    var sessionCount: Int = 0
    var totalBytes: Int64 = 0

    var id: String { category.rawValue }
}

final class AgentScanService {
    static let shared = AgentScanService()

    let scanners: [AgentScanner]

    init(scanners: [AgentScanner]? = nil) {
        self.scanners = scanners ?? [
            ClaudeCodeScanner(),
            CodexScanner(),
            ClineScanner(),
            RooCodeScanner(),
            ContinueScanner(),
            PiAgentScanner(),
            VSCodeChatScanner(),
            CursorScanner(),
            WindsurfScanner(),
            TraeScanner(),
            OpenVikingScanner(),
            AiderScanner(),
            ZedScanner(),
            OpenHandsScanner(),
            AntigravityScanner()
        ]
    }

    func scanAll() async -> [ConversationItem] {
        await withTaskGroup(of: [ConversationItem].self) { group in
            for scanner in scanners {
                group.addTask {
                    do {
                        return try await scanner.scan()
                    } catch {
                        print("Error scanning \(scanner.category.rawValue): \(error)")
                        return []
                    }
                }
            }

            var allItems: [ConversationItem] = []
            for await items in group {
                allItems.append(contentsOf: items)
            }
            return allItems.sorted(by: { $0.updatedAt > $1.updatedAt })
        }
    }

    func delete(items: [ConversationItem]) async -> Int64 {
        guard !items.isEmpty else { return 0 }

        let grouped = Dictionary(grouping: items, by: { $0.category })
        var totalFreed: Int64 = 0

        for (category, categoryItems) in grouped {
            if let scanner = scanners.first(where: { $0.category == category }) {
                do {
                    let freed = try await scanner.delete(items: categoryItems)
                    totalFreed += freed
                } catch {
                    print("Error deleting items for \(category.rawValue): \(error)")
                }
            }
        }

        return totalFreed
    }

    func cleanAll(for category: ConversationCategory? = nil) async -> Int64 {
        var totalFreed: Int64 = 0

        for scanner in scanners {
            if category == nil || category == .all || scanner.category == category {
                do {
                    let freed = try await scanner.cleanAll()
                    totalFreed += freed
                } catch {
                    print("Error cleaning all for \(scanner.category.rawValue): \(error)")
                }
            }
        }

        return totalFreed
    }

    func getAgentInfos(from items: [ConversationItem]) -> [AgentInfo] {
        return scanners.map { scanner in
            let categoryItems = items.filter { $0.category == scanner.category }
            let bytes = categoryItems.reduce(0) { $0 + $1.sizeInBytes }
            return AgentInfo(
                category: scanner.category,
                isInstalled: scanner.isInstalled,
                storagePath: scanner.storageURL.path,
                sessionCount: categoryItems.count,
                totalBytes: bytes
            )
        }
    }
}
