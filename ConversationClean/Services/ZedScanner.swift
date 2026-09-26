import Foundation
import SQLite3

final class ZedScanner: AgentScanner, @unchecked Sendable {
    let category: ConversationCategory = .zed
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
        } else if let env = ProcessInfo.processInfo.environment["ZED_HOME"], !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Zed")
        }
        return (try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? base.standardized
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: storageURL.path)
    }

    private static let isoDateFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Scan

    func scan() async throws -> [ConversationItem] {
        guard isInstalled else { return [] }

        var items: [ConversationItem] = []

        // 1. Scan SQLite threads in threads/threads.db
        let dbThreads = scanThreadsDatabase()
        items.append(contentsOf: dbThreads)

        // 2. Scan standalone files in threads/ directory
        let fileThreads = scanThreadsDirectory()
        items.append(contentsOf: fileThreads)

        // 3. Scan conversations/ directory
        let conversations = scanConversationsDirectory()
        items.append(contentsOf: conversations)

        // 4. Scan hang_traces/ dump logs
        if let hangTracesItem = scanHangTraces() {
            items.append(hangTracesItem)
        }

        return items.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    // MARK: - Deletion & Clean

    func delete(items: [ConversationItem]) async throws -> Int64 {
        guard !items.isEmpty else { return 0 }

        var totalBytesFreed: Int64 = 0
        var threadIdsToDeleteFromDB: [String] = []

        let dbURL = storageURL.appendingPathComponent("threads/threads.db")
        let dbExists = FileManager.default.fileExists(atPath: dbURL.path)

        for item in items {
            totalBytesFreed += item.sizeInBytes

            var hasPhysicalFile = false
            for path in item.associatedPaths {
                // If path is a real file on disk and not threads.db itself
                if path != dbURL.path && !path.hasPrefix("zed-thread:") {
                    if FileSizeHelper.removeIfExists(path: path) {
                        hasPhysicalFile = true
                    }
                }
            }

            // If it's a thread from threads.db
            if dbExists && (item.associatedPaths.contains(where: { $0 == dbURL.path || $0.hasPrefix("zed-thread:") }) || !hasPhysicalFile) {
                threadIdsToDeleteFromDB.append(item.sessionId)
            }
        }

        if !threadIdsToDeleteFromDB.isEmpty && dbExists {
            deleteThreadsFromDB(dbURL: dbURL, threadIds: threadIdsToDeleteFromDB)
        }

        return totalBytesFreed
    }

    func cleanAll() async throws -> Int64 {
        guard isInstalled else { return 0 }

        var totalBytesFreed: Int64 = 0
        let fm = FileManager.default

        // 1. Clear threads from threads.db
        let dbURL = storageURL.appendingPathComponent("threads/threads.db")
        if fm.fileExists(atPath: dbURL.path) {
            let beforeSize = FileSizeHelper.sizeOf(path: dbURL.path)
            clearAllThreadsInDB(dbURL: dbURL)
            let afterSize = FileSizeHelper.sizeOf(path: dbURL.path)
            totalBytesFreed += max(0, beforeSize - afterSize)
        }

        // 2. Clear conversations/ directory
        let convURL = storageURL.appendingPathComponent("conversations")
        if fm.fileExists(atPath: convURL.path) {
            totalBytesFreed += FileSizeHelper.sizeOf(path: convURL.path)
            _ = FileSizeHelper.removeIfExists(path: convURL.path)
            try? fm.createDirectory(at: convURL, withIntermediateDirectories: true)
        }

        // 3. Clear hang_traces/ directory
        let hangURL = storageURL.appendingPathComponent("hang_traces")
        if fm.fileExists(atPath: hangURL.path) {
            totalBytesFreed += FileSizeHelper.sizeOf(path: hangURL.path)
            _ = FileSizeHelper.removeIfExists(path: hangURL.path)
            try? fm.createDirectory(at: hangURL, withIntermediateDirectories: true)
        }

        // 4. Remove any JSON files in threads/
        let threadsDir = storageURL.appendingPathComponent("threads")
        if fm.fileExists(atPath: threadsDir.path),
           let contents = try? fm.contentsOfDirectory(at: threadsDir, includingPropertiesForKeys: nil) {
            for file in contents where file.pathExtension.lowercased() == "json" {
                totalBytesFreed += FileSizeHelper.sizeOf(path: file.path)
                _ = FileSizeHelper.removeIfExists(path: file.path)
            }
        }

        return totalBytesFreed
    }

    // MARK: - SQLite Threads Scanning

    private func scanThreadsDatabase() -> [ConversationItem] {
        let dbURL = storageURL.appendingPathComponent("threads/threads.db")
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbURL.path) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db = db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        // Query columns from threads table
        let query = "SELECT id, summary, updated_at, data_type, folder_paths, created_at, length(data) FROM threads;"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var items: [ConversationItem] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString
            let summary = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let updatedAtStr = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            _ = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let folderPathsStr = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let createdAtStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let dataLength = sqlite3_column_int64(stmt, 6)

            let title: String
            let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSummary.isEmpty {
                title = String(trimmedSummary.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            } else {
                title = "Zed AI 会话 \(id.prefix(8))"
            }

            let snippet: String
            if !trimmedSummary.isEmpty {
                snippet = String(trimmedSummary.prefix(120)).replacingOccurrences(of: "\n", with: " ")
            } else {
                snippet = "Zed 助手对话记录"
            }

            // Parse project path from folder_paths JSON array
            var projectPath: String?
            if let folderPathsStr = folderPathsStr, let data = folderPathsStr.data(using: .utf8) {
                if let arr = try? JSONSerialization.jsonObject(with: data) as? [String], let first = arr.first {
                    projectPath = first
                } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for item in arr {
                        if let path = item["path"] as? String {
                            projectPath = path
                            break
                        }
                    }
                }
            }

            // Parse date
            let date = parseDate(updatedAtStr) ?? parseDate(createdAtStr ?? "") ?? Date()
            let size = max(dataLength + 256, 512)

            items.append(ConversationItem(
                id: UUID(),
                sessionId: id,
                title: title,
                category: .zed,
                projectPath: projectPath,
                gitBranch: nil,
                messageCount: max(1, Int(dataLength / 1024 / 2)),
                sizeInBytes: size,
                updatedAt: date,
                isSelected: false,
                snippet: snippet,
                associatedPaths: ["zed-thread:\(id)", dbURL.path]
            ))
        }

        return items
    }

    // MARK: - Threads Directory (File-based fallback)

    private func scanThreadsDirectory() -> [ConversationItem] {
        let threadsDir = storageURL.appendingPathComponent("threads")
        let fm = FileManager.default
        guard fm.fileExists(atPath: threadsDir.path),
              let files = try? fm.contentsOfDirectory(at: threadsDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return []
        }

        var items: [ConversationItem] = []

        for file in files where file.pathExtension.lowercased() == "json" {
            let sessionId = file.deletingPathExtension().lastPathComponent
            let size = FileSizeHelper.sizeOf(path: file.path)
            let attrs = try? fm.attributesOfItem(atPath: file.path)
            let modDate = (attrs?[.modificationDate] as? Date) ?? Date()

            var title = "Zed 线程 \(sessionId.prefix(8))"
            var snippet = "Zed AI 线程记录"

            if let data = try? Data(contentsOf: file),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let summary = json["summary"] as? String, !summary.isEmpty {
                    title = String(summary.prefix(80)).replacingOccurrences(of: "\n", with: " ")
                    snippet = String(summary.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                } else if let t = json["title"] as? String, !t.isEmpty {
                    title = String(t.prefix(80)).replacingOccurrences(of: "\n", with: " ")
                    snippet = String(t.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                }
            }

            items.append(ConversationItem(
                id: UUID(),
                sessionId: sessionId,
                title: title,
                category: .zed,
                projectPath: nil,
                gitBranch: nil,
                messageCount: 1,
                sizeInBytes: size,
                updatedAt: modDate,
                isSelected: false,
                snippet: snippet,
                associatedPaths: [file.path]
            ))
        }

        return items
    }

    // MARK: - Conversations Directory

    private func scanConversationsDirectory() -> [ConversationItem] {
        let convURL = storageURL.appendingPathComponent("conversations")
        let fm = FileManager.default
        guard fm.fileExists(atPath: convURL.path),
              let files = try? fm.contentsOfDirectory(at: convURL, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return []
        }

        var items: [ConversationItem] = []

        for file in files where file.pathExtension.lowercased() == "json" {
            let sessionId = file.deletingPathExtension().lastPathComponent
            let size = FileSizeHelper.sizeOf(path: file.path)
            let attrs = try? fm.attributesOfItem(atPath: file.path)
            let modDate = (attrs?[.modificationDate] as? Date) ?? Date()

            var title = "Zed 会话 \(sessionId.prefix(8))"
            var snippet = "Zed 会话存档"
            var count = 1

            if let data = try? Data(contentsOf: file),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let t = json["title"] as? String, !t.isEmpty {
                    title = String(t.prefix(80)).replacingOccurrences(of: "\n", with: " ")
                    snippet = String(t.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                } else if let s = json["summary"] as? String, !s.isEmpty {
                    title = String(s.prefix(80)).replacingOccurrences(of: "\n", with: " ")
                    snippet = String(s.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                }

                if let messages = json["messages"] as? [Any] {
                    count = max(1, messages.count)
                }
            }

            items.append(ConversationItem(
                id: UUID(),
                sessionId: sessionId,
                title: title,
                category: .zed,
                projectPath: nil,
                gitBranch: nil,
                messageCount: count,
                sizeInBytes: size,
                updatedAt: modDate,
                isSelected: false,
                snippet: snippet,
                associatedPaths: [file.path]
            ))
        }

        return items
    }

    // MARK: - Hang Traces Scanner

    private func scanHangTraces() -> ConversationItem? {
        let hangURL = storageURL.appendingPathComponent("hang_traces")
        let fm = FileManager.default
        guard fm.fileExists(atPath: hangURL.path),
              let files = try? fm.contentsOfDirectory(at: hangURL, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }

        let traceFiles = files.filter { $0.pathExtension.lowercased() == "json" || $0.lastPathComponent.hasPrefix("hang-") }
        guard !traceFiles.isEmpty else { return nil }

        var totalBytes: Int64 = 0
        var latestDate = Date.distantPast
        var paths: [String] = []

        for file in traceFiles {
            let size = FileSizeHelper.sizeOf(path: file.path)
            totalBytes += size
            paths.append(file.path)

            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let mod = attrs[.modificationDate] as? Date, mod > latestDate {
                latestDate = mod
            }
        }

        guard totalBytes > 0 else { return nil }
        let date = latestDate == Date.distantPast ? Date() : latestDate

        return ConversationItem(
            id: UUID(),
            sessionId: "zed-hang-traces",
            title: "Zed 挂起与崩溃转储日志 (\(traceFiles.count) 个文件)",
            category: .zed,
            projectPath: nil,
            gitBranch: nil,
            messageCount: traceFiles.count,
            sizeInBytes: totalBytes,
            updatedAt: date,
            isSelected: false,
            snippet: "Zed 编辑器无响应时的性能转储与堆栈快照 (miniprof)",
            associatedPaths: paths
        )
    }

    // MARK: - SQLite Helper Methods

    private func deleteThreadsFromDB(dbURL: URL, threadIds: [String]) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let db = db { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }

        for threadId in threadIds {
            var stmt: OpaquePointer?
            let query = "DELETE FROM threads WHERE id = ?;"
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (threadId as NSString).utf8String, -1, nil)
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }

        // Reclaim unused space
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "VACUUM;", nil, nil, &errMsg)
        if let errMsg = errMsg { sqlite3_free(errMsg) }
    }

    private func clearAllThreadsInDB(dbURL: URL) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let db = db { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }

        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "DELETE FROM threads; VACUUM;", nil, nil, &errMsg)
        if let errMsg = errMsg { sqlite3_free(errMsg) }
    }

    private func parseDate(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        return Self.isoDateFormatterWithFractional.date(from: string) ?? Self.isoDateFormatter.date(from: string)
    }
}
