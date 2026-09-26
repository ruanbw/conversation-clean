import Foundation
import SQLite3

func testRealZedScannerReadOnly() async {
    let t = TestCase("RealZedReadOnly", section: "Test: Real Local Zed AI Scanner (READ-ONLY)")

    let scanner = ZedScanner()
    t.assert(scanner.category == .zed, "Category is .zed")

    let homePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Zed").path
    t.assert(TestRunner.canonicalPath(scanner.storageURL.path) == TestRunner.canonicalPath(homePath), "storageURL correctly points to Zed directory")
    t.assert(scanner.isInstalled, "scanner.isInstalled is true on this Mac")

    do {
        let items = try await scanner.scan()
        t.assert(true, "Zed scan() executed without throwing error")
        print("  \u{001B}[34m[INFO] Scanned \(items.count) Zed items from real filesystem\u{001B}[0m")

        if let hangItem = items.first(where: { $0.sessionId == "zed-hang-traces" }) {
            t.assert(hangItem.category == .zed, "Hang traces item category is .zed")
            t.assert(hangItem.messageCount >= 4, "Detected at least 4 hang trace files on machine (found: \(hangItem.messageCount))")
            print("  \u{001B}[34m[INFO] Real Hang Traces: \(hangItem.title), Size: \(hangItem.formattedSize)\u{001B}[0m")
        }
    } catch {
        t.assert(false, "Real Zed scan threw error: \(error)")
    }
}

func testMockZedScanner() async {
    let t = TestCase("MockZed", section: "Test: Mock Zed Scanner (Fixture Directory)")

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_zed")
    defer { try? fm.removeItem(at: tempDir) }

    let threadsDir = tempDir.appendingPathComponent("threads")
    let convDir = tempDir.appendingPathComponent("conversations")
    let hangDir = tempDir.appendingPathComponent("hang_traces")

    Fixture.dir(threadsDir)
    Fixture.dir(convDir)
    Fixture.dir(hangDir)

    let dbURL = threadsDir.appendingPathComponent("threads.db")
    var db: OpaquePointer?
    if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK {
        let schema = """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            summary TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            data_type TEXT NOT NULL,
            data BLOB NOT NULL,
            parent_id TEXT,
            folder_paths TEXT,
            folder_paths_order TEXT,
            created_at TEXT
        );
        INSERT INTO threads (id, summary, updated_at, data_type, data, folder_paths, created_at)
        VALUES ('zed-th-001', 'Build AST Parser in Rust', '2026-09-26T17:00:00Z', 'text', 'dummyblob', '["/Users/tester/ast-parser"]', '2026-09-26T16:00:00Z');
        INSERT INTO threads (id, summary, updated_at, data_type, data, folder_paths, created_at)
        VALUES ('zed-th-002', 'Optimize Metal rendering backend', '2026-09-26T17:30:00Z', 'text', 'dummyblob2', '["/Users/tester/metal-engine"]', '2026-09-26T17:15:00Z');
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, schema, nil, nil, &errMsg)
        if let errMsg = errMsg { sqlite3_free(errMsg) }
        sqlite3_close(db)
    }

    let conv1 = convDir.appendingPathComponent("conv-001.json")
    Fixture.write("{\"id\":\"conv-001\",\"title\":\"Fix tree-sitter syntax highlighting\",\"messages\":[{},{}]}", to: conv1)

    let hang1 = hangDir.appendingPathComponent("hang-2026-09-26_17-47-36.miniprof.json")
    Fixture.write("[{\"thread_name\":\"main\",\"timings\":[]}]", to: hang1)

    let scanner = ZedScanner(storageURL: tempDir)
    t.assert(scanner.isInstalled, "Mock scanner isInstalled is true")

    do {
        var items = try await scanner.scan()
        t.assert(items.count == 4, "Detected exactly 4 Zed items (2 DB threads, 1 conv, 1 hang traces group, found: \(items.count))")

        if let th1 = items.first(where: { $0.sessionId == "zed-th-001" }) {
            t.assert(th1.title == "Build AST Parser in Rust", "Thread 1 title matches summary")
            t.assert(th1.projectPath == "/Users/tester/ast-parser", "Thread 1 projectPath matches folder_paths")
        } else {
            t.assert(false, "Thread zed-th-001 not found")
        }

        if let cItem = items.first(where: { $0.sessionId == "conv-001" }) {
            t.assert(cItem.title == "Fix tree-sitter syntax highlighting", "Conv title matches")
            t.assert(cItem.messageCount == 2, "Conv message count is 2")
        } else {
            t.assert(false, "Conversation conv-001 not found")
        }

        if let th1 = items.first(where: { $0.sessionId == "zed-th-001" }) {
            let freed = try await scanner.delete(items: [th1])
            t.assert(freed == th1.sizeInBytes, "Freed size matches th1 size")

            if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                var stmt: OpaquePointer?
                sqlite3_prepare_v2(db, "SELECT count(*) FROM threads WHERE id = 'zed-th-001';", -1, &stmt, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let count = sqlite3_column_int(stmt, 0)
                    t.assert(count == 0, "Thread zed-th-001 deleted from SQLite DB")
                }
                sqlite3_finalize(stmt)

                sqlite3_prepare_v2(db, "SELECT count(*) FROM threads WHERE id = 'zed-th-002';", -1, &stmt, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let count = sqlite3_column_int(stmt, 0)
                    t.assert(count == 1, "Thread zed-th-002 still preserved in DB")
                }
                sqlite3_finalize(stmt)
                sqlite3_close(db)
            }
        }

        let allFreed = try await scanner.cleanAll()
        t.assert(allFreed > 0, "cleanAll freed bytes > 0")
        items = try await scanner.scan()
        t.assert(items.isEmpty, "Rescan after cleanAll returns 0 items")
    } catch {
        t.assert(false, "Mock Zed test threw error: \(error)")
    }
}
