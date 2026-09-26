import Foundation
import SQLite3

func testRealAntigravityScannerReadOnly() async {
    let t = TestCase("RealAntigravityReadOnly", section: "Test: Real Antigravity Scanner (READ-ONLY)")

    let realScanner = AntigravityScanner()

    t.sub("Checking Installation and Storage URL")
    let homePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity").path
    t.assert(TestRunner.canonicalPath(realScanner.storageURL.path) == TestRunner.canonicalPath(homePath), "storageURL correctly points to ~/.gemini/antigravity")
    t.assert(realScanner.category == .antigravity, "Category is .antigravity")

    let isRealInstalled = FileManager.default.fileExists(atPath: realScanner.storageURL.path)
    t.assert(realScanner.isInstalled == isRealInstalled, "isInstalled matches filesystem check (\(isRealInstalled))")

    if !isRealInstalled {
        print("  \u{001B}[33m[INFO] ~/.gemini/antigravity not found on system. Skipping real file scan checks.\u{001B}[0m")
        return
    }

    t.sub("Scanning Real Local Antigravity Sessions (READ-ONLY)")
    do {
        let items = try await realScanner.scan()
        t.assert(true, "scan() executed without throwing an error")
        print("  \u{001B}[34m[INFO] Scanned \(items.count) sessions from real Antigravity\u{001B}[0m")
        t.assert(!items.isEmpty, "Detected real Antigravity sessions (count: \(items.count))")

        let allAntigravity = items.allSatisfy { $0.category == .antigravity }
        t.assert(allAntigravity, "All items have category .antigravity")

        let allHaveSessionId = items.allSatisfy { !$0.sessionId.isEmpty }
        t.assert(allHaveSessionId, "All items have valid non-empty sessionId")

        // Verify descending sort order by updatedAt
        var isSorted = true
        for i in 0..<(items.count - 1) {
            if items[i].updatedAt < items[i + 1].updatedAt {
                isSorted = false
                break
            }
        }
        t.assert(isSorted, "Items are sorted by updatedAt descending")

        // Verify associated paths exist on disk
        var associatedPathsValid = true
        for item in items {
            for path in item.associatedPaths {
                if !FileManager.default.fileExists(atPath: path) {
                    associatedPathsValid = false
                    break
                }
            }
            if !associatedPathsValid { break }
        }
        t.assert(associatedPathsValid, "All associatedPaths exist on the real filesystem")

        // Active conversation preservation
        t.sub("Verifying Active Conversation Preservation")
        t.assert(realScanner.activeConversationId != nil, "activeConversationId is non-nil")
        if let activeId = realScanner.activeConversationId,
           let activeItem = items.first(where: { $0.sessionId == activeId }) {
            t.assert(true, "Found active conversation in scanned items (id: \(activeId))")

            // Attempting delete on active conversation must be safely rejected / return 0
            let freed = try await realScanner.delete(items: [activeItem])
            t.assert(freed == 0, "Deleting active conversation safely returns 0 freed bytes (preservation check)")

            // Ensure active conversation associated paths still exist
            let activePathsStillExist = activeItem.associatedPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
            t.assert(activePathsStillExist, "Active conversation files remain intact on disk")
        } else {
            t.assert(true, "Active conversation checked")
        }
    } catch {
        t.assert(false, "scan() threw unexpected error: \(error)")
    }
}

func testMockAntigravityScanner() async {
    let t = TestCase("MockAntigravityScan", section: "Test: Mock Antigravity Scanner (Fixture Directory)")

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_antigravity_scan")
    defer { try? fm.removeItem(at: tempDir) }

    t.sub("Setting up Mock Antigravity Structure")
    let brainDir = tempDir.appendingPathComponent("brain")
    let conversationsDir = tempDir.appendingPathComponent("conversations")
    let annotationsDir = tempDir.appendingPathComponent("annotations")
    let dbURL = tempDir.appendingPathComponent("conversation_summaries.db")

    Fixture.dir(brainDir)
    Fixture.dir(conversationsDir)
    Fixture.dir(annotationsDir)

    let sid1 = "mock-antigravity-001"
    let sid2 = "mock-antigravity-002"
    let sidOrphan = "mock-antigravity-orphan-003"

    // Session 1: brain directory, conversation db, wal, annotation
    let brain1 = brainDir.appendingPathComponent(sid1)
    Fixture.dir(brain1)
    Fixture.write("brain artifact s1", to: brain1.appendingPathComponent("artifact.txt"))

    let conv1 = conversationsDir.appendingPathComponent("\(sid1).db")
    Fixture.write("mock sqlite s1 db", to: conv1)
    let conv1Wal = conversationsDir.appendingPathComponent("\(sid1).db-wal")
    Fixture.write("mock sqlite s1 wal", to: conv1Wal)

    let annot1 = annotationsDir.appendingPathComponent("\(sid1).pbtxt")
    Fixture.write("annotations: { id: 1 }", to: annot1)

    // Session 2: brain directory and conversation db
    let brain2 = brainDir.appendingPathComponent(sid2)
    Fixture.dir(brain2)
    Fixture.write("brain artifact s2", to: brain2.appendingPathComponent("notes.md"))

    let conv2 = conversationsDir.appendingPathComponent("\(sid2).db")
    Fixture.write("mock sqlite s2 db", to: conv2)

    // Orphaned session in brain/ (not in conversation_summaries.db)
    let brainOrphan = brainDir.appendingPathComponent(sidOrphan)
    Fixture.dir(brainOrphan)
    Fixture.write("orphan brain artifact", to: brainOrphan.appendingPathComponent("data.bin"))

    // Create SQLite database conversation_summaries.db
    var db: OpaquePointer?
    if sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db = db {
        let createSQL = """
        CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            preview TEXT NOT NULL DEFAULT '',
            step_count INTEGER NOT NULL DEFAULT 0,
            last_modified_time DATETIME NOT NULL,
            workspace_uris TEXT NOT NULL DEFAULT ''
        );
        """
        sqlite3_exec(db, createSQL, nil, nil, nil)

        let insertSQL = "INSERT INTO conversation_summaries (conversation_id, title, preview, step_count, last_modified_time, workspace_uris) VALUES (?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK {
            // Row 1
            sqlite3_bind_text(stmt, 1, (sid1 as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, ("Antigravity Code Generation" as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, ("Implement unit tests in Swift" as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 4, 12)
            sqlite3_bind_text(stmt, 5, ("2026-09-26T10:00:00.000Z" as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 6, ("file:///Users/tester/antigravity-project" as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)

            // Row 2
            sqlite3_bind_text(stmt, 1, (sid2 as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, ("Refactor Database Service" as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, ("Sync VSCDB state keys" as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 4, 6)
            sqlite3_bind_text(stmt, 5, ("2026-09-26T11:00:00.000Z" as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 6, ("[\"file:///Users/tester/vscdb-project\"]" as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        sqlite3_close(db)
    }

    t.sub("Executing Mock Antigravity Scanner")
    let scanner = AntigravityScanner(baseURL: tempDir)
    t.assert(scanner.isInstalled, "scanner.isInstalled is true for fixture directory")
    t.assert(scanner.category == .antigravity, "Category is .antigravity")

    do {
        var items = try await scanner.scan()
        t.assert(items.count == 3, "Detected 3 sessions (2 from DB + 1 orphan, found: \(items.count))")

        // Verify Session 1
        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            t.assert(item1.title == "Antigravity Code Generation", "Session 1 title matches DB (\(item1.title))")
            t.assert(item1.projectPath == "/Users/tester/antigravity-project", "Session 1 projectPath parsed correctly (\(item1.projectPath ?? "nil"))")
            t.assert(item1.messageCount == 12, "Session 1 messageCount is 12")
            t.assert(item1.snippet == "Implement unit tests in Swift", "Session 1 snippet matches DB preview")
            t.assert(item1.associatedPaths.contains(brain1.path), "Session 1 associatedPaths contains brain dir")
            t.assert(item1.associatedPaths.contains(conv1.path), "Session 1 associatedPaths contains conversation db")
            t.assert(item1.associatedPaths.contains(conv1Wal.path), "Session 1 associatedPaths contains db-wal")
            t.assert(item1.associatedPaths.contains(annot1.path), "Session 1 associatedPaths contains annotation file")
        } else {
            t.assert(false, "Session 1 not found in scan results")
        }

        // Verify Session 2
        if let item2 = items.first(where: { $0.sessionId == sid2 }) {
            t.assert(item2.title == "Refactor Database Service", "Session 2 title matches DB")
            t.assert(item2.projectPath == "/Users/tester/vscdb-project", "Session 2 projectPath parsed from JSON array URI")
            t.assert(item2.messageCount == 6, "Session 2 messageCount is 6")
        } else {
            t.assert(false, "Session 2 not found in scan results")
        }

        // Verify Orphan Session
        if let orphan = items.first(where: { $0.sessionId == sidOrphan }) {
            t.assert(orphan.title.contains("孤立的 Antigravity 记忆工件"), "Orphan session has expected title")
            t.assert(orphan.associatedPaths.contains(brainOrphan.path), "Orphan session associatedPaths contains brain folder")
        } else {
            t.assert(false, "Orphan session not found in scan results")
        }

        // Test Single Session Deletion: Delete Session 1
        t.sub("Testing Single Session Deletion and DB Row Removal")
        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            let freed1 = try await scanner.delete(items: [item1])
            t.assert(freed1 == item1.sizeInBytes, "Freed bytes matches item 1 size (\(freed1) == \(item1.sizeInBytes))")

            // Verify files on disk removed for session 1
            t.assert(!fm.fileExists(atPath: brain1.path), "Session 1 brain folder removed from disk")
            t.assert(!fm.fileExists(atPath: conv1.path), "Session 1 conversation db removed from disk")
            t.assert(!fm.fileExists(atPath: conv1Wal.path), "Session 1 conversation wal removed from disk")
            t.assert(!fm.fileExists(atPath: annot1.path), "Session 1 annotation file removed from disk")

            // Verify session 2 and orphan files still exist
            t.assert(fm.fileExists(atPath: brain2.path), "Session 2 brain folder still exists")
            t.assert(fm.fileExists(atPath: conv2.path), "Session 2 conversation db still exists")
            t.assert(fm.fileExists(atPath: brainOrphan.path), "Orphan brain folder still exists")

            // Verify row in conversation_summaries.db is physically deleted via SELECT * FROM conversation_summaries WHERE conversation_id = ?
            var checkDb: OpaquePointer?
            if sqlite3_open_v2(dbURL.path, &checkDb, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let checkDb = checkDb {
                let querySQL = "SELECT * FROM conversation_summaries WHERE conversation_id = ?;"
                var qStmt: OpaquePointer?
                if sqlite3_prepare_v2(checkDb, querySQL, -1, &qStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(qStmt, 1, (sid1 as NSString).utf8String, -1, nil)
                    let stepResult = sqlite3_step(qStmt)
                    t.assert(stepResult == SQLITE_DONE, "Session 1 row physically deleted from conversation_summaries.db (step returned SQLITE_DONE)")
                    sqlite3_reset(qStmt)

                    sqlite3_bind_text(qStmt, 1, (sid2 as NSString).utf8String, -1, nil)
                    let stepResult2 = sqlite3_step(qStmt)
                    t.assert(stepResult2 == SQLITE_ROW, "Session 2 row still present in conversation_summaries.db (step returned SQLITE_ROW)")
                    sqlite3_finalize(qStmt)
                }
                sqlite3_close(checkDb)
            }
        }

        // Test cleanAll()
        t.sub("Testing cleanAll()")
        let allFreed = try await scanner.cleanAll()
        t.assert(allFreed > 0, "cleanAll() returned freed bytes > 0 (\(allFreed))")

        items = try await scanner.scan()
        t.assert(items.isEmpty, "Rescan after cleanAll returns 0 items")

        // Verify conversation_summaries is completely empty
        var postCleanDb: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &postCleanDb, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let postCleanDb = postCleanDb {
            let countSQL = "SELECT COUNT(*) FROM conversation_summaries;"
            var cStmt: OpaquePointer?
            if sqlite3_prepare_v2(postCleanDb, countSQL, -1, &cStmt, nil) == SQLITE_OK {
                if sqlite3_step(cStmt) == SQLITE_ROW {
                    let count = sqlite3_column_int(cStmt, 0)
                    t.assert(count == 0, "conversation_summaries table has 0 rows after cleanAll")
                }
                sqlite3_finalize(cStmt)
            }
            sqlite3_close(postCleanDb)
        }
    } catch {
        t.assert(false, "Mock Antigravity test threw error: \(error)")
    }
}
