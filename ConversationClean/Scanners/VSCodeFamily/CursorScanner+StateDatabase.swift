import Foundation
import SQLite3

extension CursorScanner {
    // MARK: - SQLite state.vscdb Parsing

    func parseStateDatabase(dbURL: URL, projectPath: String?) -> [ConversationItem] {
        var items: [ConversationItem] = []
        let dbPath = dbURL.path
        let fileSize = FileSizeHelper.sizeOf(path: dbPath)

        // Try SQLite first
        var db: OpaquePointer?
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            defer { sqlite3_close(db) }

            let query = "SELECT key, value FROM ItemTable WHERE key IN ('composer.composerData', 'workbench.panel.aichat.view.aichat.chatdata');"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }

                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let keyPtr = sqlite3_column_text(stmt, 0),
                          let valPtr = sqlite3_column_text(stmt, 1) else { continue }

                    let key = String(cString: keyPtr)
                    let valueStr = String(cString: valPtr)

                    if key == "composer.composerData" {
                        let parsed = parseComposerDataString(valueStr, dbURL: dbURL, totalDbSize: fileSize, projectPath: projectPath)
                        items.append(contentsOf: parsed)
                    } else if key == "workbench.panel.aichat.view.aichat.chatdata" {
                        let parsed = parseAiChatDataString(valueStr, dbURL: dbURL, totalDbSize: fileSize, projectPath: projectPath)
                        items.append(contentsOf: parsed)
                    }
                }
            }
        }

        // Fallback for mock test fixture files (plain JSON or non-SQLite)
        if items.isEmpty {
            if let data = try? Data(contentsOf: dbURL),
               let jsonStr = String(data: data, encoding: .utf8) {
                let parsed = parseComposerDataString(jsonStr, dbURL: dbURL, totalDbSize: fileSize, projectPath: projectPath)
                items.append(contentsOf: parsed)
            }
        }

        return items
    }

    private func parseComposerDataString(_ str: String, dbURL: URL, totalDbSize: Int64, projectPath: String?) -> [ConversationItem] {
        guard let data = str.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let composers = dict["allComposers"] as? [[String: Any]], !composers.isEmpty else {
            return []
        }

        var results: [ConversationItem] = []
        let count = Int64(composers.count)
        let perComposerSize = max(1, totalDbSize / count)

        for composer in composers {
            let cid = composer["composerId"] as? String ?? UUID().uuidString
            let name = composer["name"] as? String
            let text = composer["text"] as? String
            let richText = composer["richText"] as? String

            let rawTitle = name ?? text ?? richText ?? "Cursor Composer"
            let singleLine = rawTitle.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? rawTitle
            let title = singleLine.isEmpty ? "Cursor Composer" : String(singleLine.prefix(80))

            var msgCount = 1
            if let msgs = composer["conversation"] as? [Any] {
                msgCount = msgs.count
            } else if let msgs = composer["messages"] as? [Any] {
                msgCount = msgs.count
            }

            let date: Date
            if let lastUpdated = (composer["lastUpdatedAt"] as? NSNumber)?.doubleValue, lastUpdated > 0 {
                date = Date(timeIntervalSince1970: lastUpdated > 1_000_000_000_000 ? lastUpdated / 1000.0 : lastUpdated)
            } else if let created = (composer["createdAt"] as? NSNumber)?.doubleValue, created > 0 {
                date = Date(timeIntervalSince1970: created > 1_000_000_000_000 ? created / 1000.0 : created)
            } else {
                date = (try? dbURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            }

            results.append(ConversationItem(
                id: UUID(),
                sessionId: cid,
                title: title,
                category: self.category,
                projectPath: projectPath,
                gitBranch: nil,
                messageCount: msgCount,
                sizeInBytes: perComposerSize,
                updatedAt: date,
                isSelected: false,
                snippet: title,
                associatedPaths: [dbURL.path]
            ))
        }

        return results
    }

    private func parseAiChatDataString(_ str: String, dbURL: URL, totalDbSize: Int64, projectPath: String?) -> [ConversationItem] {
        guard let data = str.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tabs = dict["tabs"] as? [[String: Any]], !tabs.isEmpty else {
            return []
        }

        var results: [ConversationItem] = []
        let count = Int64(tabs.count)
        let perTabSize = max(1, totalDbSize / count)

        for tab in tabs {
            let tid = tab["id"] as? String ?? tab["tabId"] as? String ?? UUID().uuidString
            let chatTitle = tab["chatTitle"] as? String ?? "Cursor 对话"
            let bubbles = tab["bubbles"] as? [[String: Any]] ?? []

            results.append(ConversationItem(
                id: UUID(),
                sessionId: tid,
                title: String(chatTitle.prefix(80)),
                category: self.category,
                projectPath: projectPath,
                gitBranch: nil,
                messageCount: bubbles.count,
                sizeInBytes: perTabSize,
                updatedAt: (try? dbURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(),
                isSelected: false,
                snippet: chatTitle,
                associatedPaths: [dbURL.path]
            ))
        }

        return results
    }

    func deleteComposersFromStateDb(dbPath: String, sessionIds: Set<String>) {
        let dbURL = URL(fileURLWithPath: dbPath)
        VSCDBHelper.removeComposers(from: dbURL, composerIds: sessionIds)

        // Also handle plain JSON fixture files
        if let data = try? Data(contentsOf: dbURL),
           var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var composers = dict["allComposers"] as? [[String: Any]] {
            composers.removeAll { c in
                guard let id = c["composerId"] as? String else { return false }
                return sessionIds.contains(id)
            }
            if composers.isEmpty {
                _ = FileSizeHelper.removeIfExists(path: dbPath)
            } else {
                dict["allComposers"] = composers
                if let updatedData = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
                    try? updatedData.write(to: dbURL, options: .atomic)
                }
            }
        }
    }

    func clearStateDatabaseChatData(dbURL: URL) {
        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
            defer { sqlite3_close(db) }

            let query = "DELETE FROM ItemTable WHERE key IN ('composer.composerData', 'workbench.panel.aichat.view.aichat.chatdata');"
            if sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK {
                sqlite3_exec(db, "VACUUM;", nil, nil, nil)
                return
            }
        }
        _ = FileSizeHelper.removeIfExists(path: dbURL.path)
    }

}
