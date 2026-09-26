import Foundation
import SQLite3
import CryptoKit

extension PiAgentScanner {
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
    static func jsonlPaths(under directoryURL: URL, limit: Int = 128) -> Set<String> {
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
    func purgeContextModeArtifacts(sessionFilePaths: Set<String>) {
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

}
