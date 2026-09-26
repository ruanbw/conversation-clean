import Foundation
import SQLite3

final class AntigravityScanner: AgentScanner, @unchecked Sendable {
    let category: ConversationCategory = .antigravity
    let customStorageURL: URL?

    init(storageURL: URL? = nil) {
        self.customStorageURL = storageURL
    }

    convenience init(baseURL: URL?) {
        self.init(storageURL: baseURL)
    }

    var storageURL: URL {
        let base: URL
        if let custom = customStorageURL {
            base = custom
        } else if let env = ProcessInfo.processInfo.environment["ANTIGRAVITY_HOME"], !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/antigravity")
        }
        return (try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? base.standardized
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: storageURL.path)
    }

    /// Identify the currently active conversation ID (e.g. during live pair programming) to prevent accidental suicide
    var activeConversationId: String? {
        if let envId = ProcessInfo.processInfo.environment["ANTIGRAVITY_CONVERSATION_ID"], !envId.isEmpty {
            return envId
        }
        return "d72aac4b-eb6f-4cdc-af17-bb25a2d18e19"
    }

    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Scan

    func scan() async throws -> [ConversationItem] {
        guard isInstalled else { return [] }

        var items: [ConversationItem] = []
        var scannedIds: Set<String> = []

        let fm = FileManager.default
        let dbURL = storageURL.appendingPathComponent("conversation_summaries.db")
        let brainDir = storageURL.appendingPathComponent("brain")
        let conversationsDir = storageURL.appendingPathComponent("conversations")
        let annotationsDir = storageURL.appendingPathComponent("annotations")

        // 1. Scan from conversation_summaries.db (SQLite UI index)
        if fm.fileExists(atPath: dbURL.path) {
            var db: OpaquePointer?
            if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                let sql = "SELECT conversation_id, title, preview, step_count, last_modified_time, workspace_uris FROM conversation_summaries;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        guard let idPtr = sqlite3_column_text(stmt, 0) else { continue }
                        let convId = String(cString: idPtr)
                        scannedIds.insert(convId)

                        var rawTitle = ""
                        if let titlePtr = sqlite3_column_text(stmt, 1) {
                            rawTitle = String(cString: titlePtr).trimmingCharacters(in: .whitespacesAndNewlines)
                        }

                        var preview = ""
                        if let prevPtr = sqlite3_column_text(stmt, 2) {
                            preview = String(cString: prevPtr).trimmingCharacters(in: .whitespacesAndNewlines)
                        }

                        let stepCount = Int(sqlite3_column_int(stmt, 3))

                        var updatedAt = Date()
                        if let timePtr = sqlite3_column_text(stmt, 4) {
                            let timeStr = String(cString: timePtr)
                            if let d = Self.isoFormatterWithFractional.date(from: timeStr) ?? Self.isoFormatter.date(from: timeStr) {
                                updatedAt = d
                            }
                        }

                        var projectPath: String? = nil
                        if let wsPtr = sqlite3_column_text(stmt, 5) {
                            let wsStr = String(cString: wsPtr).trimmingCharacters(in: .whitespacesAndNewlines)
                            projectPath = Self.parseWorkspacePath(wsStr)
                        }

                        // Collect associated files
                        var associatedPaths: [String] = []
                        let brainConv = brainDir.appendingPathComponent(convId)
                        if fm.fileExists(atPath: brainConv.path) {
                            associatedPaths.append(brainConv.path)
                        }

                        let convDb = conversationsDir.appendingPathComponent("\(convId).db")
                        if fm.fileExists(atPath: convDb.path) {
                            associatedPaths.append(convDb.path)
                            let wal = conversationsDir.appendingPathComponent("\(convId).db-wal")
                            if fm.fileExists(atPath: wal.path) { associatedPaths.append(wal.path) }
                            let shm = conversationsDir.appendingPathComponent("\(convId).db-shm")
                            if fm.fileExists(atPath: shm.path) { associatedPaths.append(shm.path) }
                        }

                        let annotationFile = annotationsDir.appendingPathComponent("\(convId).pbtxt")
                        if fm.fileExists(atPath: annotationFile.path) {
                            associatedPaths.append(annotationFile.path)
                        }

                        let totalSize = associatedPaths.reduce(0) { $0 + FileSizeHelper.sizeOf(path: $1) }
                        let displayTitle = !rawTitle.isEmpty ? rawTitle : (!preview.isEmpty ? preview : "Antigravity 对话 (\(String(convId.prefix(8))))")

                        items.append(ConversationItem(
                            id: UUID(),
                            sessionId: convId,
                            title: displayTitle,
                            category: .antigravity,
                            projectPath: projectPath,
                            gitBranch: nil,
                            messageCount: max(stepCount, 1),
                            sizeInBytes: totalSize,
                            updatedAt: updatedAt,
                            isSelected: false,
                            snippet: preview.isEmpty ? displayTitle : preview,
                            associatedPaths: associatedPaths
                        ))
                    }
                    sqlite3_finalize(stmt)
                }
                sqlite3_close(db)
            }
        }

        // 2. Scan orphaned sessions in brain/ not present in conversation_summaries.db
        if fm.fileExists(atPath: brainDir.path),
           let entries = try? fm.contentsOfDirectory(at: brainDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for entry in entries {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let convId = entry.lastPathComponent
                guard !scannedIds.contains(convId) else { continue }

                let totalSize = FileSizeHelper.sizeOf(path: entry.path)
                let attrs = try? fm.attributesOfItem(atPath: entry.path)
                let modDate = attrs?[.modificationDate] as? Date ?? Date()

                items.append(ConversationItem(
                    id: UUID(),
                    sessionId: convId,
                    title: "孤立的 Antigravity 记忆工件 (\(String(convId.prefix(8))))",
                    category: .antigravity,
                    projectPath: nil,
                    gitBranch: nil,
                    messageCount: 1,
                    sizeInBytes: totalSize,
                    updatedAt: modDate,
                    isSelected: false,
                    snippet: "未被会话数据库索引的本地残留工件",
                    associatedPaths: [entry.path]
                ))
            }
        }

        return items.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    // MARK: - Delete & Clean

    func delete(items: [ConversationItem]) async throws -> Int64 {
        guard !items.isEmpty else { return 0 }

        var totalFreed: Int64 = 0
        var sessionIdsToDeleteFromDB: [String] = []

        let activeId = activeConversationId

        for item in items {
            // Safety guard: skip active conversation
            if let activeId = activeId, item.sessionId == activeId {
                continue
            }

            totalFreed += item.sizeInBytes

            for path in item.associatedPaths {
                _ = FileSizeHelper.removeIfExists(path: path)
            }

            sessionIdsToDeleteFromDB.append(item.sessionId)
        }

        // Atomically remove rows from conversation_summaries.db so Antigravity UI sidebar never shows ghost menus
        if !sessionIdsToDeleteFromDB.isEmpty {
            deleteFromSummariesDatabase(sessionIds: sessionIdsToDeleteFromDB)
        }

        return totalFreed
    }

    func cleanAll() async throws -> Int64 {
        let items = try await scan()
        let activeId = activeConversationId
        let cleanable = items.filter { item in
            if let activeId = activeId, item.sessionId == activeId {
                return false
            }
            return true
        }
        return try await delete(items: cleanable)
    }

    // MARK: - SQLite Helpers

    private func deleteFromSummariesDatabase(sessionIds: [String]) {
        let dbURL = storageURL.appendingPathComponent("conversation_summaries.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db = db else { return }
        defer { sqlite3_close(db) }

        let deleteSQL = "DELETE FROM conversation_summaries WHERE conversation_id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteSQL, -1, &stmt, nil) == SQLITE_OK {
            for sid in sessionIds {
                sqlite3_bind_text(stmt, 1, (sid as NSString).utf8String, -1, nil)
                _ = sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
            sqlite3_finalize(stmt)
        }

        _ = sqlite3_exec(db, "VACUUM;", nil, nil, nil)
    }

    private static func parseWorkspacePath(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("file://") {
            if let url = URL(string: raw) {
                return url.path
            }
            return String(raw.dropFirst(7))
        }
        if raw.hasPrefix("[") {
            // JSON array of URIs
            if let data = raw.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
               let first = arr.first {
                return parseWorkspacePath(first)
            }
        }
        return raw.hasPrefix("/") ? raw : nil
    }
}
