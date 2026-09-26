import Foundation
import SQLite3

enum VSCDBHelper {
    /// Removes specific session IDs from all known IDE index keys inside `state.vscdb`.
    /// Handles VS Code, Cursor, Windsurf, and Trae index structures.
    static func removeChatSessions(from dbURL: URL, sessionIds: Set<String>) {
        guard !sessionIds.isEmpty, FileManager.default.fileExists(atPath: dbURL.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db = db else {
            return
        }
        defer { sqlite3_close(db) }

        let encodedSessionIds = Set(sessionIds.map { Data($0.utf8).base64EncodedString() })

        // 1. Update chat.ChatSessionStore.index (remove sid from entries)
        updateChatSessionStoreIndex(db: db, sessionIds: sessionIds)

        // 2. Remove or clean memento/interactive-session-view-copilot and memento/interactive-session%
        cleanMementoInteractiveSessions(db: db, sessionIds: sessionIds, encodedSessionIds: encodedSessionIds)

        // 3. Remove or clean interactive.sessions
        cleanInteractiveSessions(db: db, sessionIds: sessionIds, encodedSessionIds: encodedSessionIds)

        // 4. Remove or clean workbench.panel.chat
        cleanWorkbenchPanelChat(db: db, sessionIds: sessionIds, encodedSessionIds: encodedSessionIds)

        // 5. Update agentSessions.state.cache
        cleanAgentSessionsStateCache(db: db, sessionIds: sessionIds, encodedSessionIds: encodedSessionIds)

        // 6. Update agentSessions.model.cache
        cleanAgentSessionsModelCache(db: db, sessionIds: sessionIds, encodedSessionIds: encodedSessionIds)

        // 7. Update composer.composerData (for Cursor: remove sid from allComposers)
        cleanComposerData(db: db, sessionIds: sessionIds)

        // 8. Update workbench.panel.aichat.view.aichat.chatdata (for Cursor)
        cleanAiChatData(db: db, sessionIds: sessionIds)

        // 9. Compact database
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
            "DELETE FROM ItemTable WHERE key = 'memento/interactive-session-view-copilot';",
            "DELETE FROM ItemTable WHERE key LIKE 'memento/interactive-session%';",
            "DELETE FROM ItemTable WHERE key = 'interactive.sessions';",
            "DELETE FROM ItemTable WHERE key = 'workbench.panel.chat';",
            "DELETE FROM ItemTable WHERE key LIKE 'workbench.panel.chat%';",
            "DELETE FROM ItemTable WHERE key = 'agentSessions.state.cache';",
            "DELETE FROM ItemTable WHERE key = 'agentSessions.model.cache';",
            "DELETE FROM ItemTable WHERE key = 'composer.composerData';",
            "DELETE FROM ItemTable WHERE key = 'workbench.panel.aichat.view.aichat.chatdata';",
            "VACUUM;"
        ]

        for sql in deleteKeys {
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    /// Removes specific composers from Cursor's `composer.composerData` in `state.vscdb`.
    static func removeComposers(from dbURL: URL, composerIds: Set<String>) {
        removeChatSessions(from: dbURL, sessionIds: composerIds)
    }

    // MARK: - GitHub Copilot Chat Session Store (globalStorage)

    /// Removes records matching session IDs from GitHub Copilot Chat's `session-store.db`.
    static func removeCopilotSessionStore(from dbURL: URL, sessionIds: Set<String>) {
        guard !sessionIds.isEmpty, FileManager.default.fileExists(atPath: dbURL.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db = db else { return }
        defer { sqlite3_close(db) }

        for sid in sessionIds {
            let deleteQueries = [
                "DELETE FROM turns WHERE session_id = ?;",
                "DELETE FROM checkpoints WHERE session_id = ?;",
                "DELETE FROM session_files WHERE session_id = ?;",
                "DELETE FROM session_refs WHERE session_id = ?;",
                "DELETE FROM search_index WHERE session_id = ?;",
                "DELETE FROM sessions WHERE id = ?;"
            ]
            for query in deleteQueries {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (sid as NSString).utf8String, -1, nil)
                    _ = sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
            }
        }
        _ = sqlite3_exec(db, "VACUUM;", nil, nil, nil)
    }

    /// Clears all session records from GitHub Copilot Chat's `session-store.db`.
    static func clearCopilotSessionStore(from dbURL: URL) {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db = db else { return }
        defer { sqlite3_close(db) }

        let clearQueries = [
            "DELETE FROM turns;",
            "DELETE FROM checkpoints;",
            "DELETE FROM session_files;",
            "DELETE FROM session_refs;",
            "DELETE FROM search_index;",
            "DELETE FROM sessions;",
            "VACUUM;"
        ]
        for query in clearQueries {
            _ = sqlite3_exec(db, query, nil, nil, nil)
        }
    }

    // MARK: - Private Index Cleaners

    private static func updateChatSessionStoreIndex(db: OpaquePointer, sessionIds: Set<String>) {
        let selectSQL = "SELECT value FROM ItemTable WHERE key = 'chat.ChatSessionStore.index';"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(selectStmt) }

        if sqlite3_step(selectStmt) == SQLITE_ROW, let textPtr = sqlite3_column_text(selectStmt, 0) {
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

    private static func cleanMementoInteractiveSessions(db: OpaquePointer, sessionIds: Set<String>, encodedSessionIds: Set<String>) {
        for sid in sessionIds {
            let encodedSid = Data(sid.utf8).base64EncodedString()
            let deleteMementoSQL = "DELETE FROM ItemTable WHERE (key = 'memento/interactive-session-view-copilot' OR key LIKE 'memento/interactive-session%') AND (value LIKE ? OR value LIKE ?);"
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
    }

    private static func cleanInteractiveSessions(db: OpaquePointer, sessionIds: Set<String>, encodedSessionIds: Set<String>) {
        let selectSQL = "SELECT value FROM ItemTable WHERE key = 'interactive.sessions';"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(selectStmt) }

        if sqlite3_step(selectStmt) == SQLITE_ROW, let textPtr = sqlite3_column_text(selectStmt, 0) {
            let jsonString = String(cString: textPtr)
            var matched = false
            for sid in sessionIds {
                if jsonString.contains(sid) { matched = true; break }
            }
            if !matched {
                for enc in encodedSessionIds {
                    if jsonString.contains(enc) { matched = true; break }
                }
            }
            guard matched else { return }

            if let data = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                if var arr = json as? [Any] {
                    let originalCount = arr.count
                    arr.removeAll { elem in
                        if let sidStr = elem as? String {
                            return sessionIds.contains(sidStr) || encodedSessionIds.contains(sidStr)
                        } else if let dict = elem as? [String: Any] {
                            if let id = dict["id"] as? String, sessionIds.contains(id) { return true }
                            if let id = dict["sessionId"] as? String, sessionIds.contains(id) { return true }
                            if let res = dict["resource"] as? String {
                                for sid in sessionIds where res.contains(sid) { return true }
                                for enc in encodedSessionIds where res.contains(enc) { return true }
                            }
                        }
                        return false
                    }
                    if arr.isEmpty {
                        _ = sqlite3_exec(db, "DELETE FROM ItemTable WHERE key = 'interactive.sessions';", nil, nil, nil)
                    } else if arr.count != originalCount {
                        if let updatedData = try? JSONSerialization.data(withJSONObject: arr),
                           let updatedString = String(data: updatedData, encoding: .utf8) {
                            let updateSQL = "UPDATE ItemTable SET value = ? WHERE key = 'interactive.sessions';"
                            var updateStmt: OpaquePointer?
                            if sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK {
                                sqlite3_bind_text(updateStmt, 1, (updatedString as NSString).utf8String, -1, nil)
                                _ = sqlite3_step(updateStmt)
                                sqlite3_finalize(updateStmt)
                            }
                        }
                    }
                } else if var dict = json as? [String: Any] {
                    var mutated = false
                    for sid in sessionIds {
                        if dict.removeValue(forKey: sid) != nil { mutated = true }
                    }
                    if var entries = dict["entries"] as? [String: Any] {
                        for sid in sessionIds {
                            if entries.removeValue(forKey: sid) != nil { mutated = true }
                        }
                        dict["entries"] = entries
                    }
                    if dict.isEmpty {
                        _ = sqlite3_exec(db, "DELETE FROM ItemTable WHERE key = 'interactive.sessions';", nil, nil, nil)
                    } else if mutated {
                        if let updatedData = try? JSONSerialization.data(withJSONObject: dict),
                           let updatedString = String(data: updatedData, encoding: .utf8) {
                            let updateSQL = "UPDATE ItemTable SET value = ? WHERE key = 'interactive.sessions';"
                            var updateStmt: OpaquePointer?
                            if sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK {
                                sqlite3_bind_text(updateStmt, 1, (updatedString as NSString).utf8String, -1, nil)
                                _ = sqlite3_step(updateStmt)
                                sqlite3_finalize(updateStmt)
                            }
                        }
                    }
                } else {
                    _ = sqlite3_exec(db, "DELETE FROM ItemTable WHERE key = 'interactive.sessions';", nil, nil, nil)
                }
            } else {
                _ = sqlite3_exec(db, "DELETE FROM ItemTable WHERE key = 'interactive.sessions';", nil, nil, nil)
            }
        }
    }

    private static func cleanWorkbenchPanelChat(db: OpaquePointer, sessionIds: Set<String>, encodedSessionIds: Set<String>) {
        for sid in sessionIds {
            let encodedSid = Data(sid.utf8).base64EncodedString()
            let deleteSQL = "DELETE FROM ItemTable WHERE (key = 'workbench.panel.chat' OR key LIKE 'workbench.panel.chat%') AND (value LIKE ? OR value LIKE ?);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteSQL, -1, &stmt, nil) == SQLITE_OK {
                let pattern1 = "%\(sid)%"
                let pattern2 = "%\(encodedSid)%"
                sqlite3_bind_text(stmt, 1, (pattern1 as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (pattern2 as NSString).utf8String, -1, nil)
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    private static func cleanAgentSessionsStateCache(db: OpaquePointer, sessionIds: Set<String>, encodedSessionIds: Set<String>) {
        let selectSQL = "SELECT value FROM ItemTable WHERE key = 'agentSessions.state.cache';"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(selectStmt) }

        if sqlite3_step(selectStmt) == SQLITE_ROW, let textPtr = sqlite3_column_text(selectStmt, 0) {
            let jsonString = String(cString: textPtr)
            if let data = jsonString.data(using: .utf8),
               var arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let originalCount = arr.count
                arr.removeAll { dict in
                    if let res = dict["resource"] as? String {
                        for sid in sessionIds where res.contains(sid) { return true }
                        for enc in encodedSessionIds where res.contains(enc) { return true }
                    }
                    if let sid = dict["sessionId"] as? String, sessionIds.contains(sid) { return true }
                    if let id = dict["id"] as? String, sessionIds.contains(id) { return true }
                    return false
                }
                if arr.count != originalCount {
                    if let updatedData = try? JSONSerialization.data(withJSONObject: arr),
                       let updatedString = String(data: updatedData, encoding: .utf8) {
                        let updateSQL = "UPDATE ItemTable SET value = ? WHERE key = 'agentSessions.state.cache';"
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

    private static func cleanAgentSessionsModelCache(db: OpaquePointer, sessionIds: Set<String>, encodedSessionIds: Set<String>) {
        let selectSQL = "SELECT value FROM ItemTable WHERE key = 'agentSessions.model.cache';"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(selectStmt) }

        if sqlite3_step(selectStmt) == SQLITE_ROW, let textPtr = sqlite3_column_text(selectStmt, 0) {
            let jsonString = String(cString: textPtr)
            if let data = jsonString.data(using: .utf8),
               var arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let originalCount = arr.count
                arr.removeAll { dict in
                    if let res = dict["resource"] as? String {
                        for sid in sessionIds where res.contains(sid) { return true }
                        for enc in encodedSessionIds where res.contains(enc) { return true }
                    }
                    if let sid = dict["sessionId"] as? String, sessionIds.contains(sid) { return true }
                    if let id = dict["id"] as? String, sessionIds.contains(id) { return true }
                    return false
                }
                if arr.count != originalCount {
                    if let updatedData = try? JSONSerialization.data(withJSONObject: arr),
                       let updatedString = String(data: updatedData, encoding: .utf8) {
                        let updateSQL = "UPDATE ItemTable SET value = ? WHERE key = 'agentSessions.model.cache';"
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

    private static func cleanComposerData(db: OpaquePointer, sessionIds: Set<String>) {
        let selectSQL = "SELECT value FROM ItemTable WHERE key = 'composer.composerData';"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(selectStmt) }

        if sqlite3_step(selectStmt) == SQLITE_ROW, let textPtr = sqlite3_column_text(selectStmt, 0) {
            let jsonString = String(cString: textPtr)
            if let data = jsonString.data(using: .utf8),
               var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               var allComposers = root["allComposers"] as? [[String: Any]] {
                let originalCount = allComposers.count
                allComposers.removeAll { dict in
                    if let cid = dict["composerId"] as? String, sessionIds.contains(cid) { return true }
                    if let id = dict["id"] as? String, sessionIds.contains(id) { return true }
                    return false
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

    private static func cleanAiChatData(db: OpaquePointer, sessionIds: Set<String>) {
        let selectSQL = "SELECT value FROM ItemTable WHERE key = 'workbench.panel.aichat.view.aichat.chatdata';"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(selectStmt) }

        if sqlite3_step(selectStmt) == SQLITE_ROW, let textPtr = sqlite3_column_text(selectStmt, 0) {
            let jsonString = String(cString: textPtr)
            if let data = jsonString.data(using: .utf8),
               var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               var tabs = root["tabs"] as? [[String: Any]] {
                let originalCount = tabs.count
                tabs.removeAll { dict in
                    if let tid = dict["id"] as? String, sessionIds.contains(tid) { return true }
                    if let tid = dict["tabId"] as? String, sessionIds.contains(tid) { return true }
                    return false
                }

                if tabs.count != originalCount {
                    root["tabs"] = tabs
                    if let updatedData = try? JSONSerialization.data(withJSONObject: root),
                       let updatedString = String(data: updatedData, encoding: .utf8) {
                        let updateSQL = "UPDATE ItemTable SET value = ? WHERE key = 'workbench.panel.aichat.view.aichat.chatdata';"
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
}
