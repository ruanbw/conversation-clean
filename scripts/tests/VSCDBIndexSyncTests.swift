import Foundation
import SQLite3

func testMockVSCDBIndexSync() async {
    let t = TestCase("MockVSCDBIndexSync", section: "Test: Mock VSCDB Index Sync (VSCodeChatScanner & VSCDBHelper)")

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_vscdb_sync")
    defer { try? fm.removeItem(at: tempDir) }

    t.sub("Setting up Workspace Storage and Mock state.vscdb")
    let wsStorage = tempDir.appendingPathComponent("workspaceStorage")
    let wsHashDir = wsStorage.appendingPathComponent("mock-ws-hash-123")
    let chatSessionsDir = wsHashDir.appendingPathComponent("chatSessions")
    let stateDbURL = wsHashDir.appendingPathComponent("state.vscdb")

    Fixture.dir(chatSessionsDir)

    // workspace.json
    let wsJson = "{\"folder\":\"file:///Users/tester/synced-vsc-project\"}"
    Fixture.write(wsJson, to: wsHashDir.appendingPathComponent("workspace.json"))

    let sid1 = "vsc-sync-001"
    let sid2 = "vsc-sync-002"

    // Session 1 & 2 jsonl files
    let s1File = chatSessionsDir.appendingPathComponent("\(sid1).jsonl")
    let s1Content = """
    {"kind":0,"v":{"version":3,"creationDate":1789000000000,"sessionId":"\(sid1)","requests":[]}}
    {"kind":2,"k":["requests"],"v":[{"requestId":"r1","message":{"text":"First prompt in session 1"}}]}
    """
    Fixture.write(s1Content, to: s1File)

    let s2File = chatSessionsDir.appendingPathComponent("\(sid2).jsonl")
    let s2Content = """
    {"kind":0,"v":{"version":3,"creationDate":1789100000000,"sessionId":"\(sid2)","requests":[]}}
    {"kind":2,"k":["requests"],"v":[{"requestId":"r2","message":{"text":"Second prompt in session 2"}}]}
    """
    Fixture.write(s2Content, to: s2File)

    // Create state.vscdb with ItemTable and all index keys
    var db: OpaquePointer?
    if sqlite3_open(stateDbURL.path, &db) == SQLITE_OK, let db = db {
        Fixture.exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);")

        let initialIndexJSON = """
        {
          "version": 1,
          "entries": {
            "\(sid1)": {
              "sessionId": "\(sid1)",
              "title": "First prompt in session 1",
              "lastMessageDate": 1789000000000
            },
            "\(sid2)": {
              "sessionId": "\(sid2)",
              "title": "Second prompt in session 2",
              "lastMessageDate": 1789100000000
            }
          }
        }
        """

        let enc1 = Data(sid1.utf8).base64EncodedString()
        let enc2 = Data(sid2.utf8).base64EncodedString()

        let mementoJSON = "{\"sessionResource\":{\"external\":\"vscode-chat-session://local/\(enc1)\"}}"
        let interactiveSessionsJSON = "[\"\(sid1)\",\"\(sid2)\"]"
        let panelChatJSON = "{\"activeSession\":\"\(sid1)\"}"
        let agentStateCacheJSON = "[{\"resource\":\"vscode-chat-session://local/\(enc1)\",\"read\":1},{\"resource\":\"vscode-chat-session://local/\(enc2)\",\"read\":1}]"
        let agentModelCacheJSON = "[{\"resource\":\"vscode-chat-session://local/\(enc1)\",\"label\":\"m1\"},{\"resource\":\"vscode-chat-session://local/\(enc2)\",\"label\":\"m2\"}]"
        let composerDataJSON = "{\"allComposers\":[{\"composerId\":\"\(sid1)\",\"name\":\"c1\"},{\"composerId\":\"\(sid2)\",\"name\":\"c2\"}]}"
        let aiChatDataJSON = "{\"tabs\":[{\"id\":\"\(sid1)\",\"chatTitle\":\"t1\"},{\"id\":\"\(sid2)\",\"chatTitle\":\"t2\"}]}"

        let insertItems: [(String, String)] = [
            ("chat.ChatSessionStore.index", initialIndexJSON),
            ("memento/interactive-session-view-copilot", mementoJSON),
            ("interactive.sessions", interactiveSessionsJSON),
            ("workbench.panel.chat", panelChatJSON),
            ("agentSessions.state.cache", agentStateCacheJSON),
            ("agentSessions.model.cache", agentModelCacheJSON),
            ("composer.composerData", composerDataJSON),
            ("workbench.panel.aichat.view.aichat.chatdata", aiChatDataJSON)
        ]

        for (k, v) in insertItems {
            let insertSQL = "INSERT INTO ItemTable (key, value) VALUES (?, ?);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (k as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (v as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
        sqlite3_close(db)
    }

    // Set up globalStorage/github.copilot-chat/session-store.db
    let copilotGlobalDir = tempDir.appendingPathComponent("globalStorage/github.copilot-chat")
    Fixture.dir(copilotGlobalDir)
    let sessionStoreDbURL = copilotGlobalDir.appendingPathComponent("session-store.db")
    var cdb: OpaquePointer?
    if sqlite3_open(sessionStoreDbURL.path, &cdb) == SQLITE_OK, let cdb = cdb {
        Fixture.exec(cdb, "CREATE TABLE sessions (id TEXT PRIMARY KEY, summary TEXT);")
        Fixture.exec(cdb, "CREATE TABLE turns (id INTEGER PRIMARY KEY, session_id TEXT, user_message TEXT);")
        Fixture.exec(cdb, "INSERT INTO sessions (id, summary) VALUES ('\(sid1)', 'summary1');")
        Fixture.exec(cdb, "INSERT INTO sessions (id, summary) VALUES ('\(sid2)', 'summary2');")
        Fixture.exec(cdb, "INSERT INTO turns (session_id, user_message) VALUES ('\(sid1)', 'msg1');")
        Fixture.exec(cdb, "INSERT INTO turns (session_id, user_message) VALUES ('\(sid2)', 'msg2');")
        sqlite3_close(cdb)
    }

    t.sub("Executing Scan and Deletion with VSCDB Sync Verification")
    let scanner = VSCodeChatScanner(baseURL: tempDir)
    t.assert(scanner.isInstalled, "scanner.isInstalled is true")

    do {
        let items = try await scanner.scan()
        t.assert(items.count == 2, "Scanned exactly 2 sessions (found: \(items.count))")

        guard let item1 = items.first(where: { $0.sessionId == sid1 }),
              items.contains(where: { $0.sessionId == sid2 }) else {
            t.assert(false, "Could not find expected items sid1 and sid2")
            return
        }

        // Verify item1 is associated with chatSessions file
        t.assert(item1.associatedPaths.contains(s1File.path), "Item 1 associatedPaths contains session file")

        // Delete item1 via scanner.delete(items:)
        print("  \u{001B}[34m[INFO] Deleting session 1 (\(sid1)) via VSCodeChatScanner.delete(items:)...\u{001B}[0m")
        let freed = try await scanner.delete(items: [item1])
        t.assert(freed == item1.sizeInBytes, "Freed bytes matches item 1 size")
        t.assert(!fm.fileExists(atPath: s1File.path), "Session 1 file removed from disk")
        t.assert(fm.fileExists(atPath: s2File.path), "Session 2 file still exists on disk")

        // Assert that all index keys in state.vscdb were appropriately synced!
        var verifyDb: OpaquePointer?
        if sqlite3_open_v2(stateDbURL.path, &verifyDb, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let verifyDb = verifyDb {
            func queryKey(_ key: String) -> String? {
                let sql = "SELECT value FROM ItemTable WHERE key = ?;"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(verifyDb, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW, let ptr = sqlite3_column_text(stmt, 0) {
                    return String(cString: ptr)
                }
                return nil
            }

            // 1. chat.ChatSessionStore.index
            if let updatedJSON = queryKey("chat.ChatSessionStore.index"),
               let data = updatedJSON.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let entries = root["entries"] as? [String: Any] {
                t.assert(entries[sid1] == nil, "Session 1 (\(sid1)) was successfully removed from chat.ChatSessionStore.index")
                t.assert(entries[sid2] != nil, "Session 2 (\(sid2)) is preserved in chat.ChatSessionStore.index")
            } else {
                t.assert(false, "Failed to verify chat.ChatSessionStore.index")
            }

            // 2. memento/interactive-session-view-copilot
            let mementoVal = queryKey("memento/interactive-session-view-copilot")
            t.assert(mementoVal == nil, "memento/interactive-session-view-copilot was removed for deleted session")

            // 3. interactive.sessions
            if let intVal = queryKey("interactive.sessions"),
               let data = intVal.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                t.assert(!arr.contains(sid1), "interactive.sessions removed sid1")
                t.assert(arr.contains(sid2), "interactive.sessions preserved sid2")
            } else {
                t.assert(false, "Failed to verify interactive.sessions")
            }

            // 4. workbench.panel.chat
            let panelVal = queryKey("workbench.panel.chat")
            t.assert(panelVal == nil, "workbench.panel.chat referencing sid1 was removed")

            // 5. agentSessions.state.cache
            if let stateVal = queryKey("agentSessions.state.cache"),
               let data = stateVal.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let enc1 = Data(sid1.utf8).base64EncodedString()
                let enc2 = Data(sid2.utf8).base64EncodedString()
                let contains1 = arr.contains { ($0["resource"] as? String)?.contains(enc1) == true }
                let contains2 = arr.contains { ($0["resource"] as? String)?.contains(enc2) == true }
                t.assert(!contains1, "agentSessions.state.cache removed sid1 resource")
                t.assert(contains2, "agentSessions.state.cache preserved sid2 resource")
            } else {
                t.assert(false, "Failed to verify agentSessions.state.cache")
            }

            // 6. agentSessions.model.cache
            if let modelVal = queryKey("agentSessions.model.cache"),
               let data = modelVal.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let enc1 = Data(sid1.utf8).base64EncodedString()
                let enc2 = Data(sid2.utf8).base64EncodedString()
                let contains1 = arr.contains { ($0["resource"] as? String)?.contains(enc1) == true }
                let contains2 = arr.contains { ($0["resource"] as? String)?.contains(enc2) == true }
                t.assert(!contains1, "agentSessions.model.cache removed sid1 resource")
                t.assert(contains2, "agentSessions.model.cache preserved sid2 resource")
            } else {
                t.assert(false, "Failed to verify agentSessions.model.cache")
            }

            // 7. composer.composerData
            if let composerVal = queryKey("composer.composerData"),
               let data = composerVal.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let allComposers = root["allComposers"] as? [[String: Any]] {
                let contains1 = allComposers.contains { ($0["composerId"] as? String) == sid1 }
                let contains2 = allComposers.contains { ($0["composerId"] as? String) == sid2 }
                t.assert(!contains1, "composer.composerData removed sid1 from allComposers")
                t.assert(contains2, "composer.composerData preserved sid2 in allComposers")
            } else {
                t.assert(false, "Failed to verify composer.composerData")
            }

            // 8. workbench.panel.aichat.view.aichat.chatdata
            if let aichatVal = queryKey("workbench.panel.aichat.view.aichat.chatdata"),
               let data = aichatVal.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tabs = root["tabs"] as? [[String: Any]] {
                let contains1 = tabs.contains { ($0["id"] as? String) == sid1 }
                let contains2 = tabs.contains { ($0["id"] as? String) == sid2 }
                t.assert(!contains1, "workbench.panel.aichat.view.aichat.chatdata removed sid1 tab")
                t.assert(contains2, "workbench.panel.aichat.view.aichat.chatdata preserved sid2 tab")
            } else {
                t.assert(false, "Failed to verify workbench.panel.aichat.view.aichat.chatdata")
            }

            sqlite3_close(verifyDb)
        } else {
            t.assert(false, "Failed to open state.vscdb for verification")
        }

        // Verify session-store.db
        var verifyCdb: OpaquePointer?
        if sqlite3_open_v2(sessionStoreDbURL.path, &verifyCdb, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let verifyCdb = verifyCdb {
            var s1Count = 0
            var s2Count = 0
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(verifyCdb, "SELECT id FROM sessions;", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let ptr = sqlite3_column_text(stmt, 0) {
                        let id = String(cString: ptr)
                        if id == sid1 { s1Count += 1 }
                        if id == sid2 { s2Count += 1 }
                    }
                }
                sqlite3_finalize(stmt)
            }
            t.assert(s1Count == 0, "session-store.db removed sid1 from sessions table")
            t.assert(s2Count == 1, "session-store.db preserved sid2 in sessions table")
            sqlite3_close(verifyCdb)
        } else {
            t.assert(false, "Failed to open session-store.db for verification")
        }

        // Test clearAllChatSessions
        VSCDBHelper.clearAllChatSessions(from: stateDbURL)
        if sqlite3_open_v2(stateDbURL.path, &verifyDb, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let verifyDb = verifyDb {
            var rowCount = 0
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(verifyDb, "SELECT COUNT(*) FROM ItemTable;", -1, &countStmt, nil) == SQLITE_OK {
                if sqlite3_step(countStmt) == SQLITE_ROW {
                    rowCount = Int(sqlite3_column_int(countStmt, 0))
                }
                sqlite3_finalize(countStmt)
            }
            t.assert(rowCount == 0, "clearAllChatSessions purged all index keys from ItemTable")
            sqlite3_close(verifyDb)
        }
    } catch {
        t.assert(false, "VSCDB sync test threw error: \(error)")
    }
}
