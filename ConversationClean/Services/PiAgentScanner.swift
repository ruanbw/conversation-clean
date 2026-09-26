import CryptoKit
import Foundation
import SQLite3

final class PiAgentScanner: AgentScanner, @unchecked Sendable {
    let category: ConversationCategory = .piAgent
    let customStorageURL: URL?

    init(storageURL: URL? = nil) {
        self.customStorageURL = storageURL
    }

    var storageURL: URL {
        let base: URL
        if let custom = customStorageURL {
            base = custom
        } else if let env = ProcessInfo.processInfo.environment["PI_HOME"], !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi")
        }
        return (try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? base.standardized
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: storageURL.path)
    }

    private struct SessionTarget: Sendable {
        let fileURL: URL
        let projectDirURL: URL
        let baseName: String
        let fileSessionId: String
    }

    private struct TaskArtifacts: Sendable {
        var pathsBySessionId: [String: [String]] = [:]
        var sizeBySessionId: [String: Int64] = [:]
    }

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackIsoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func scan() async throws -> [ConversationItem] {
        guard isInstalled else { return [] }

        let fileManager = FileManager.default
        let sessionsURL = storageURL.appendingPathComponent("agent").appendingPathComponent("sessions")
        guard fileManager.fileExists(atPath: sessionsURL.path) else { return [] }

        let projectDirs = (try? fileManager.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var targets: [SessionTarget] = []

        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let entries = (try? fileManager.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries where entry.pathExtension == "jsonl" {
                let baseName = entry.deletingPathExtension().lastPathComponent
                guard !baseName.isEmpty else { continue }

                let fileSessionId: String
                if let lastUnderscore = baseName.range(of: "_", options: .backwards) {
                    fileSessionId = String(baseName[lastUnderscore.upperBound...])
                } else {
                    fileSessionId = baseName
                }

                targets.append(SessionTarget(
                    fileURL: entry,
                    projectDirURL: projectDir,
                    baseName: baseName,
                    fileSessionId: fileSessionId
                ))
            }
        }

        guard !targets.isEmpty else { return [] }

        let taskArtifacts = preIndexTasks()

        let items: [ConversationItem] = await withTaskGroup(of: ConversationItem.self) { group in
            for target in targets {
                group.addTask {
                    return self.parseSession(target: target, taskArtifacts: taskArtifacts)
                }
            }

            var collected: [ConversationItem] = []
            collected.reserveCapacity(targets.count)
            for await item in group {
                collected.append(item)
            }
            return collected
        }

        return items.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    func delete(items: [ConversationItem]) async throws -> Int64 {
        guard !items.isEmpty else { return 0 }

        let fileManager = FileManager.default
        var totalBytesFreed: Int64 = 0

        // 1. 先收集所有待删除的会话文件（含子目录里的子代理会话），再做物理删除
        var sessionFilePaths = Set<String>()
        var deletedPaths = Set<String>()

        for item in items {
            totalBytesFreed += item.sizeInBytes
            for path in item.associatedPaths {
                deletedPaths.insert(path)
                if path.hasSuffix(".jsonl") {
                    sessionFilePaths.insert(path)
                }
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    sessionFilePaths.formUnion(Self.jsonlPaths(under: URL(fileURLWithPath: path)))
                }
            }
        }

        for item in items {
            for path in item.associatedPaths {
                _ = FileSizeHelper.removeIfExists(path: path)
            }
        }

        // 2. 同步双层索引：context-mode SQLite 索引行 + pi-acp 会话映射表
        purgeContextModeArtifacts(sessionFilePaths: sessionFilePaths)
        pruneACPSessionMap(sessionIds: Set(items.map { $0.sessionId }), deletedPaths: deletedPaths)

        cleanEmptyProjectDirectories()

        return totalBytesFreed
    }

    func cleanAll() async throws -> Int64 {
        let items = try await scan()
        var freed = try await delete(items: items)

        let extraDirsToRecreate = [
            storageURL.appendingPathComponent("agent").appendingPathComponent("sessions"),
            storageURL.appendingPathComponent("tasks"),
            storageURL.appendingPathComponent("context-mode"),
            storageURL.appendingPathComponent("pi-acp"),
            storageURL.appendingPathComponent("web-search-cache"),
            storageURL.appendingPathComponent("agent").appendingPathComponent("web-search-cache")
        ]

        for dirURL in extraDirsToRecreate {
            let path = dirURL.path
            if FileManager.default.fileExists(atPath: path) {
                let size = FileSizeHelper.sizeOf(path: path)
                if FileSizeHelper.removeIfExists(path: path) {
                    freed += size
                    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                }
            }
        }

        let runHistoryURL = storageURL.appendingPathComponent("agent").appendingPathComponent("run-history.jsonl")
        if FileManager.default.fileExists(atPath: runHistoryURL.path) {
            let size = FileSizeHelper.sizeOf(path: runHistoryURL.path)
            if FileSizeHelper.removeIfExists(path: runHistoryURL.path) {
                freed += size
            }
        }

        return freed
    }

    // MARK: - Pre-Indexing Tasks

    private func preIndexTasks() -> TaskArtifacts {
        var artifacts = TaskArtifacts()
        let tasksURL = storageURL.appendingPathComponent("tasks")
        let fm = FileManager.default
        guard fm.fileExists(atPath: tasksURL.path),
              let entries = try? fm.contentsOfDirectory(at: tasksURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return artifacts
        }

        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let dirName = entry.lastPathComponent
            guard dirName.count >= 36 else { continue }

            let prefix = String(dirName.prefix(36))
            if dirName == prefix || dirName.hasPrefix(prefix + "-") {
                let path = entry.path
                let size = FileSizeHelper.sizeOf(path: path)
                artifacts.pathsBySessionId[prefix, default: []].append(path)
                artifacts.sizeBySessionId[prefix, default: 0] += size
            }
        }

        return artifacts
    }

    // MARK: - Parsing

    private func parseSession(target: SessionTarget, taskArtifacts: TaskArtifacts) -> ConversationItem {
        let fileManager = FileManager.default
        let fileAttrs = try? fileManager.attributesOfItem(atPath: target.fileURL.path)
        let mainFileSize = (fileAttrs?[.size] as? NSNumber)?.int64Value ?? FileSizeHelper.sizeOf(path: target.fileURL.path)

        var detectedSessionId = target.fileSessionId
        var detectedCwd: String?
        var detectedTimestamp: Date?
        var firstUserPrompt: String?
        var messageCount = 0
        var totalLineCount = 0

        if let fileHandle = try? FileHandle(forReadingFrom: target.fileURL) {
            defer { try? fileHandle.close() }
            let headerData = fileHandle.readData(ofLength: 512 * 1024)
            let headerString = String(decoding: headerData, as: UTF8.self)

            headerString.enumerateLines { line, _ in
                totalLineCount += 1
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    return
                }

                let type = json["type"] as? String

                if type == "session" {
                    if let sid = json["id"] as? String, !sid.isEmpty {
                        detectedSessionId = sid
                    }
                    if let cwd = json["cwd"] as? String, !cwd.isEmpty {
                        detectedCwd = cwd
                    }
                    if let tsStr = json["timestamp"] as? String {
                        detectedTimestamp = Self.isoDateFormatter.date(from: tsStr) ?? Self.fallbackIsoDateFormatter.date(from: tsStr)
                    }
                } else if type == "message" {
                    messageCount += 1
                    if firstUserPrompt == nil,
                       let msg = json["message"] as? [String: Any],
                       let role = msg["role"] as? String, role == "user" {
                        if let prompt = Self.extractText(from: msg["content"]) {
                            firstUserPrompt = prompt
                        }
                    }
                }
            }

            // If file is larger than 512KB, stream-count remaining newlines
            if mainFileSize > 512 * 1024 {
                while autoreleasepool(invoking: {
                    let chunk = fileHandle.readData(ofLength: 256 * 1024)
                    if chunk.isEmpty { return false }
                    let newlines = chunk.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
                    messageCount += newlines
                    return true
                }) {}
            }
        }

        if messageCount == 0 {
            messageCount = max(1, totalLineCount)
        }

        // Fallback for cwd based on project directory name (--Users-ruanbw-projects-bennett--)
        if detectedCwd == nil || detectedCwd?.isEmpty == true {
            let dirName = target.projectDirURL.lastPathComponent
            if dirName.hasPrefix("--") && dirName.hasSuffix("--") {
                let inner = String(dirName.dropFirst(2).dropLast(2))
                if inner.isEmpty {
                    detectedCwd = "/"
                } else {
                    detectedCwd = "/" + inner.replacingOccurrences(of: "-", with: "/")
                }
            }
        }

        let modDate = (fileAttrs?[.modificationDate] as? Date) ?? detectedTimestamp ?? Date()

        let title: String
        if let prompt = firstUserPrompt, !prompt.isEmpty {
            title = prompt.prefix(80).replacingOccurrences(of: "\n", with: " ")
        } else {
            title = "Pi 会话 \(detectedSessionId.prefix(8))"
        }

        let snippet: String
        if let prompt = firstUserPrompt, !prompt.isEmpty {
            snippet = prompt.prefix(120).replacingOccurrences(of: "\n", with: " ")
        } else {
            snippet = "项目: \(detectedCwd ?? "未知")"
        }

        var associatedPaths: [String] = [target.fileURL.path]
        var totalBytes = mainFileSize

        // 1. Session subfolder by baseName (e.g. 2026-09-14T..._<sid>)
        let subfolderByBase = target.projectDirURL.appendingPathComponent(target.baseName)
        var visitedDirs = Set<String>()
        var isDir: ObjCBool = false

        if fileManager.fileExists(atPath: subfolderByBase.path, isDirectory: &isDir), isDir.boolValue {
            associatedPaths.append(subfolderByBase.path)
            visitedDirs.insert(subfolderByBase.path)
            totalBytes += FileSizeHelper.sizeOf(path: subfolderByBase.path)
        }

        // 2. Session subfolder by sessionId (if different and exists)
        let subfolderBySid = target.projectDirURL.appendingPathComponent(detectedSessionId)
        if !visitedDirs.contains(subfolderBySid.path),
           fileManager.fileExists(atPath: subfolderBySid.path, isDirectory: &isDir), isDir.boolValue {
            associatedPaths.append(subfolderBySid.path)
            visitedDirs.insert(subfolderBySid.path)
            totalBytes += FileSizeHelper.sizeOf(path: subfolderBySid.path)
        }

        // 3. Matching tasks in tasks/
        var matchedTaskPaths = Set<String>()
        if let taskPaths = taskArtifacts.pathsBySessionId[detectedSessionId] {
            for path in taskPaths {
                if !matchedTaskPaths.contains(path) {
                    matchedTaskPaths.insert(path)
                    associatedPaths.append(path)
                }
            }
            totalBytes += taskArtifacts.sizeBySessionId[detectedSessionId] ?? 0
        }

        if target.fileSessionId != detectedSessionId,
           let taskPaths = taskArtifacts.pathsBySessionId[target.fileSessionId] {
            for path in taskPaths {
                if !matchedTaskPaths.contains(path) {
                    matchedTaskPaths.insert(path)
                    associatedPaths.append(path)
                    totalBytes += FileSizeHelper.sizeOf(path: path)
                }
            }
        }

        return ConversationItem(
            id: UUID(),
            sessionId: detectedSessionId,
            title: title,
            category: .piAgent,
            projectPath: detectedCwd,
            gitBranch: nil,
            messageCount: messageCount,
            sizeInBytes: totalBytes,
            updatedAt: modDate,
            isSelected: false,
            snippet: snippet,
            associatedPaths: associatedPaths
        )
    }

    private static func extractText(from content: Any?) -> String? {
        if let str = content as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let array = content as? [[String: Any]] {
            var texts: [String] = []
            for item in array {
                if let text = item["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        texts.append(trimmed)
                    }
                }
            }
            if !texts.isEmpty {
                return texts.joined(separator: " ")
            }
        }
        return nil
    }

    // MARK: - Context-Mode 双层索引同步

    /// context-mode 数据根目录：`~/.pi/context-mode`
    var contextModeURL: URL {
        storageURL.appendingPathComponent("context-mode")
    }

    /// context-mode 以 `sha256(会话文件绝对路径)` 的前 16 位小写十六进制作为 session_id
    /// （见 context-mode Pi adapter 的 `deriveSessionId`），因此可以精确映射到索引行。
    static func contextModeSessionId(forSessionFilePath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// 收集目录下所有 `.jsonl` 会话文件（用于子代理嵌套会话）
    private static func jsonlPaths(under directoryURL: URL, limit: Int = 128) -> Set<String> {
        var paths = Set<String>()
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return paths }

        for case let fileURL as URL in enumerator {
            if paths.count >= limit { break }
            if fileURL.pathExtension == "jsonl" {
                paths.insert(fileURL.path)
            }
        }
        return paths
    }

    /// 从被删除的会话文件推导 context-mode session_id，并同步清理所有索引载体
    private func purgeContextModeArtifacts(sessionFilePaths: Set<String>) {
        guard !sessionFilePaths.isEmpty else { return }

        var sessionIds = Set<String>()
        for path in sessionFilePaths {
            sessionIds.insert(Self.contextModeSessionId(forSessionFilePath: path))
            // 路径可能存在 /private 规范化差异，双写两种形态的哈希
            let canonical = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? path
            if canonical != path {
                sessionIds.insert(Self.contextModeSessionId(forSessionFilePath: canonical))
            }
        }

        purgeContextModeDatabases(sessionIds: sessionIds)
        purgeContextModeStatsFiles(sessionIds: sessionIds, sessionFilePaths: sessionFilePaths)
    }

    /// 遍历 context-mode 下所有 SQLite 索引（sessions/ 每项目一个库，content/ 内容库）
    private func purgeContextModeDatabases(sessionIds: Set<String>) {
        guard !sessionIds.isEmpty else { return }

        let targets: [(dir: URL, removeWhenEmpty: Bool)] = [
            (contextModeURL.appendingPathComponent("sessions"), true),
            (contextModeURL.appendingPathComponent("content"), false)
        ]

        for target in targets {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: target.dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries where entry.pathExtension == "db" {
                purgeContextModeDatabase(at: entry, sessionIds: sessionIds, removeWhenEmpty: target.removeWhenEmpty)
            }
        }
    }

    /// 清理单个库：删除所有含 session_id 列的表中的匹配行；库清空后连带 -wal/-shm 一起移除
    private func purgeContextModeDatabase(at dbURL: URL, sessionIds: Set<String>, removeWhenEmpty: Bool) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            if let handle = handle { sqlite3_close(handle) }
            return
        }
        _ = sqlite3_busy_timeout(db, 250)

        let tables = listTables(db: db)
        var deletedRows = 0
        if !tables.isEmpty {
            deletedRows = deleteSessionRows(db: db, tables: tables, sessionIds: sessionIds)
        }

        let emptiedDatabase = removeWhenEmpty
            && deletedRows > 0
            && tables.contains("session_meta")
            && databaseIsEmpty(db: db, tables: tables)

        sqlite3_close(db)

        guard emptiedDatabase else { return }
        for suffix in ["", "-wal", "-shm"] {
            let strayURL = URL(fileURLWithPath: dbURL.path + suffix)
            if FileManager.default.fileExists(atPath: strayURL.path) {
                try? FileManager.default.removeItem(at: strayURL)
            }
        }
    }

    private func listTables(db: OpaquePointer) -> [String] {
        var tables: [String] = []
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(stmt, 0) {
                tables.append(String(cString: namePtr))
            }
        }
        return tables
    }

    /// 返回表中承接会话主键的列名（session_id / sessionId），无则返回 nil
    private func sessionIdColumn(in db: OpaquePointer, table: String) -> String? {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\"\(table)\");"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(stmt, 1) else { continue }
            let name = String(cString: namePtr)
            let normalized = name.lowercased().replacingOccurrences(of: "_", with: "")
            if normalized == "sessionid" {
                return name
            }
        }
        return nil
    }

    private func deleteSessionRows(db: OpaquePointer, tables: [String], sessionIds: Set<String>) -> Int {
        let orderedIds = sessionIds.sorted()
        let placeholders = Array(repeating: "?", count: orderedIds.count).joined(separator: ",")
        var deletedRows = 0

        for table in tables {
            guard let column = sessionIdColumn(in: db, table: table) else { continue }
            let sql = "DELETE FROM \"\(table)\" WHERE \"\(column)\" IN (\(placeholders));"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }

            for (offset, sid) in orderedIds.enumerated() {
                sqlite3_bind_text(stmt, Int32(offset + 1), sid, -1, Self.sqliteTransient)
            }
            if sqlite3_step(stmt) == SQLITE_DONE {
                deletedRows += Int(sqlite3_changes(db))
            }
            sqlite3_finalize(stmt)
        }
        return deletedRows
    }

    private func databaseIsEmpty(db: OpaquePointer, tables: [String]) -> Bool {
        for table in tables {
            var stmt: OpaquePointer?
            let sql = "SELECT COUNT(*) FROM \"\(table)\" LIMIT 1;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int64(stmt, 0) > 0 {
                return false
            }
        }
        return true
    }

    /// 清理内容引用了被删除会话的 stats-pid-*.json 进程统计缓存
    private func purgeContextModeStatsFiles(sessionIds: Set<String>, sessionFilePaths: Set<String>) {
        let fm = FileManager.default
        let candidates = [
            contextModeURL.appendingPathComponent("sessions"),
            contextModeURL.appendingPathComponent("stats")
        ]

        for dir in candidates {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for entry in entries where entry.lastPathComponent.hasPrefix("stats-pid-") && entry.pathExtension == "json" {
                guard let text = try? String(contentsOf: entry, encoding: .utf8) else { continue }
                let linked = sessionIds.contains { text.contains($0) }
                    || sessionFilePaths.contains { text.contains($0) }
                if linked {
                    try? fm.removeItem(at: entry)
                }
            }
        }
    }

    // MARK: - pi-acp 会话映射表同步

    /// 裁剪 `~/.pi/pi-acp/session-map.json`，避免 ACP 客户端侧边栏残留幽灵会话
    private func pruneACPSessionMap(sessionIds: Set<String>, deletedPaths: Set<String>) {
        guard !sessionIds.isEmpty || !deletedPaths.isEmpty else { return }

        let mapURL = storageURL.appendingPathComponent("pi-acp").appendingPathComponent("session-map.json")
        guard let data = try? Data(contentsOf: mapURL),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessions = root["sessions"] as? [String: Any] else {
            return
        }

        var staleKeys: [String] = []
        for (key, value) in sessions {
            var isStale = sessionIds.contains(key)
            if !isStale, let entry = value as? [String: Any] {
                if let sid = entry["sessionId"] as? String, sessionIds.contains(sid) {
                    isStale = true
                } else if let file = entry["sessionFile"] as? String {
                    // 指向已删除或已不存在的会话文件的条目本身就是幽灵条目
                    if deletedPaths.contains(file) || (!file.isEmpty && !FileManager.default.fileExists(atPath: file)) {
                        isStale = true
                    }
                }
            }
            if isStale {
                staleKeys.append(key)
            }
        }

        guard !staleKeys.isEmpty else { return }

        var remaining = sessions
        for key in staleKeys {
            remaining.removeValue(forKey: key)
        }

        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: mapURL)
            return
        }

        root["sessions"] = remaining
        if let updated = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? updated.write(to: mapURL, options: .atomic)
        }
    }

    private func cleanEmptyProjectDirectories() {
        let sessionsURL = storageURL.appendingPathComponent("agent").appendingPathComponent("sessions")
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsURL.path),
              let projectDirs = try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return
        }

        for dir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            if let contents = try? fm.contentsOfDirectory(atPath: dir.path) {
                let sessionFiles = contents.filter { $0.hasSuffix(".jsonl") }
                if sessionFiles.isEmpty {
                    try? fm.removeItem(at: dir)
                }
            }
        }
    }
}
