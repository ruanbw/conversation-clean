import Foundation
import SQLite3

enum VSCDBHelper {
    /// Removes specific session IDs from `chat.ChatSessionStore.index` and interactive session memento inside `state.vscdb`.
    static func removeChatSessions(from dbURL: URL, sessionIds: Set<String>) {
        guard !sessionIds.isEmpty, FileManager.default.fileExists(atPath: dbURL.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db = db else {
            return
        }
        defer { sqlite3_close(db) }

        // 1. Update chat.ChatSessionStore.index
        let selectSQL = "SELECT value FROM ItemTable WHERE key = 'chat.ChatSessionStore.index';"
        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK {
            if sqlite3_step(selectStmt) == SQLITE_ROW {
                if let textPtr = sqlite3_column_text(selectStmt, 0) {
                    let jsonString = String(cString: textPtr)
                    if let data = jsonString.data(using: .utf8),
                       var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       var entries = root["entries"] as? [String: Any] {
                        var mutated = false
                        for sid in sessionIds {
                            if entries.removeValue(forKey: sid) != nil {
                                mutated = true
                            }
                        }

                        if mutated {
                            root["entries"] = entries
                            if let updatedData = try? JSONSerialization.data(withJSONObject: root),
                               let updatedString = String(data: updatedData, encoding: .utf8) {
                                let updateSQL = "UPDATE ItemTable SET value = ? WHERE key = 'chat.ChatSessionStore.index';"
                                var updateStmt: OpaquePointer?
                                if sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK {
                                    sqlite3_bind_text(updateStmt, 1, (updatedString as NSString).utf8String, -1, nil)
                                    _ = sqlite3_step(updateStmt)
                                    sqlite3_finalize(updateStmt)
                                }
                            }
                        }
                    }
                }
            }
            sqlite3_finalize(selectStmt)
        }

        // 2. Remove or clean interactive session view memento if pointing to deleted session
        for sid in sessionIds {
            let encodedSid = Data(sid.utf8).base64EncodedString()
            let deleteMementoSQL = "DELETE FROM ItemTable WHERE key LIKE 'memento/interactive-session%' AND (value LIKE ? OR value LIKE ?);"
            var mementoStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteMementoSQL, -1, &mementoStmt, nil) == SQLITE_OK {
                let pattern1 = "%\(sid)%"
                let pattern2 = "%\(encodedSid)%"
                sqlite3_bind_text(mementoStmt, 1, (pattern1 as NSString).utf8String, -1, nil)
                sqlite3_bind_text(mementoStmt, 2, (pattern2 as NSString).utf8String, -1, nil)
                _ = sqlite3_step(mementoStmt)
                sqlite3_finalize(mementoStmt)
            }
        }

        // 3. Compact database
        _ = sqlite3_exec(db, "VACUUM;", nil, nil, nil)
    }

    /// Clears all chat session indexes from `state.vscdb`.
    static func clearAllChatSessions(from dbURL: URL) {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db = db else { return }
        defer { sqlite3_close(db) }

        let deleteKeys = [
            "DELETE FROM ItemTable WHERE key = 'chat.ChatSessionStore.index';",
            "DELETE FROM ItemTable WHERE key LIKE 'memento/interactive-session%';",
            "DELETE FROM ItemTable WHERE key = 'workbench.panel.chat';",
            "DELETE FROM ItemTable WHERE key = 'agentSessions.model.cache';",
            "DELETE FROM ItemTable WHERE key = 'agentSessions.state.cache';",
            "VACUUM;"
        ]

        for sql in deleteKeys {
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    /// Removes specific composers from Cursor's `composer.composerData` in `state.vscdb`.
    static func removeComposers(from dbURL: URL, composerIds: Set<String>) {
        guard !composerIds.isEmpty, FileManager.default.fileExists(atPath: dbURL.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db = db else { return }
        defer { sqlite3_close(db) }

        let selectSQL = "SELECT value FROM ItemTable WHERE key = 'composer.composerData';"
        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK {
            if sqlite3_step(selectStmt) == SQLITE_ROW {
                if let textPtr = sqlite3_column_text(selectStmt, 0) {
                    let jsonString = String(cString: textPtr)
                    if let data = jsonString.data(using: .utf8),
                       var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       var allComposers = root["allComposers"] as? [[String: Any]] {
                        let originalCount = allComposers.count
                        allComposers.removeAll { dict in
                            guard let cid = dict["composerId"] as? String else { return false }
                            return composerIds.contains(cid)
                        }

                        if allComposers.count != originalCount {
                            root["allComposers"] = allComposers
                            if let updatedData = try? JSONSerialization.data(withJSONObject: root),
                               let updatedString = String(data: updatedData, encoding: .utf8) {
                                let updateSQL = "UPDATE ItemTable SET value = ? WHERE key = 'composer.composerData';"
                                var updateStmt: OpaquePointer?
                                if sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK {
                                    sqlite3_bind_text(updateStmt, 1, (updatedString as NSString).utf8String, -1, nil)
                                    _ = sqlite3_step(updateStmt)
                                    sqlite3_finalize(updateStmt)
                                }
                            }
                        }
                    }
                }
            }
            sqlite3_finalize(selectStmt)
        }

        _ = sqlite3_exec(db, "VACUUM;", nil, nil, nil)
    }
}
