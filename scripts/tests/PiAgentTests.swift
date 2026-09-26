import Foundation
import SQLite3

func testRealPiAgentScannerReadOnly() async {
    let t = TestCase("RealPiReadOnly", section: "Test: Real Local ~/.pi Scanner (READ-ONLY)")

    let realScanner = PiAgentScanner()

    t.sub("Checking Installation and Storage URL")
    let homePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi").path
    t.assert(TestRunner.canonicalPath(realScanner.storageURL.path) == TestRunner.canonicalPath(homePath), "storageURL correctly points to ~/.pi")
    t.assert(realScanner.category == .piAgent, "Category is .piAgent")

    let isRealInstalled = FileManager.default.fileExists(atPath: realScanner.storageURL.path)
    t.assert(realScanner.isInstalled == isRealInstalled, "isInstalled matches filesystem check (\(isRealInstalled))")

    if !isRealInstalled {
        print("  \u{001B}[33m[INFO] ~/.pi not found on system. Skipping real file scan checks.\u{001B}[0m")
        return
    }

    t.sub("Scanning Real Local ~/.pi Sessions (READ-ONLY)")
    do {
        let items = try await realScanner.scan()
        t.assert(true, "scan() executed without throwing an error")
        print("  \u{001B}[34m[INFO] Scanned \(items.count) sessions from real ~/.pi\u{001B}[0m")

        if !items.isEmpty {
            let totalBytes = items.reduce(0) { $0 + $1.sizeInBytes }
            let formattedTotal = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            print("  \u{001B}[34m[INFO] Total size of real Pi sessions: \(formattedTotal) (\(totalBytes) bytes)\u{001B}[0m")

            // Verify category
            let allArePi = items.allSatisfy { $0.category == .piAgent }
            t.assert(allArePi, "All items have category .piAgent")

            // Verify non-empty sessionIds
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

            // Verify title extraction
            let withTitle = items.filter { !$0.title.isEmpty }
            t.assert(withTitle.count == items.count, "All items have non-empty titles")

            // Verify messageCount > 0
            let validMsgCount = items.allSatisfy { $0.messageCount > 0 }
            t.assert(validMsgCount, "All items have messageCount > 0")

            // Verify associated paths exist
            let sample = items.prefix(20)
            var pathsValid = true
            for item in sample {
                for path in item.associatedPaths {
                    if !FileManager.default.fileExists(atPath: path) {
                        pathsValid = false
                        break
                    }
                }
            }
            t.assert(pathsValid, "Associated paths for sampled items exist on disk")

            print("  \u{001B}[34m[INFO] Sample Session #1:\u{001B}[0m")
            print("    ID: \(items[0].sessionId)")
            print("    Title: \(items[0].title)")
            print("    Project: \(items[0].displayProjectPath)")
            print("    Messages: \(items[0].messageCount)")
            print("    Size: \(items[0].formattedSize)")
            print("    Date: \(items[0].formattedDate)")
            print("    Paths: \(items[0].associatedPaths.count) path(s)")
        }
    } catch {
        t.assert(false, "scan() threw error: \(error)")
    }
}

func testMockPiAgentScanner() async {
    let t = TestCase("MockPiAgent", section: "Test: Mock Pi Agent Scanner & Cleanup")

    let tempDir = TestRunner.createTempDirectory(prefix: "pi_mock")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fm = FileManager.default

    let projA = tempDir.appendingPathComponent("agent/sessions/--Users-mock-projectA--")
    let projB = tempDir.appendingPathComponent("agent/sessions/--Users-mock-projectB--")
    let tasksDir = tempDir.appendingPathComponent("tasks")
    let contextModeDir = tempDir.appendingPathComponent("context-mode")
    let webCacheDir = tempDir.appendingPathComponent("web-search-cache")

    Fixture.dir(projA)
    Fixture.dir(projB)
    Fixture.dir(tasksDir)
    Fixture.dir(contextModeDir)
    Fixture.dir(webCacheDir)

    // Session 1 in projA: with subfolder and matching task
    let sid1 = "01a00000-0000-7000-8000-000000000001"
    let fileBase1 = "2026-09-01T10-00-00-000Z_\(sid1)"
    let jsonl1 = projA.appendingPathComponent("\(fileBase1).jsonl")
    let subfolder1 = projA.appendingPathComponent(fileBase1)
    Fixture.dir(subfolder1)
    Fixture.write("subfolder-data-bytes-123456789", to: subfolder1.appendingPathComponent("subdata.txt"))

    let session1Content = """
    {"type":"session","version":3,"id":"\(sid1)","timestamp":"2026-09-01T10:00:00.000Z","cwd":"/Users/mock/projectA"}
    {"type":"model_change","id":"m1","parentId":null,"timestamp":"2026-09-01T10:00:01.000Z","provider":"cli-proxy","modelId":"gemini"}
    {"type":"message","id":"msg1","parentId":"m1","timestamp":"2026-09-01T10:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"Implement Pi Agent Scanner feature"}]}}
    {"type":"message","id":"msg2","parentId":"msg1","timestamp":"2026-09-01T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Feature implemented."}]}}
    """
    Fixture.write(session1Content, to: jsonl1)

    // Task directory matching sid1: <sid1>-99999
    let task1Dir = tasksDir.appendingPathComponent("\(sid1)-99999")
    Fixture.dir(task1Dir)
    Fixture.write("{\"id\":\"t1\",\"status\":\"completed\"}", to: task1Dir.appendingPathComponent("task.json"))

    // Session 2 in projB: no subfolder, no matching task
    let sid2 = "01a00000-0000-7000-8000-000000000002"
    let fileBase2 = "2026-09-02T12-00-00-000Z_\(sid2)"
    let jsonl2 = projB.appendingPathComponent("\(fileBase2).jsonl")
    let session2Content = """
    {"type":"session","version":3,"id":"\(sid2)","timestamp":"2026-09-02T12:00:00.000Z","cwd":"/Users/mock/projectB"}
    {"type":"message","id":"msg2_1","parentId":null,"timestamp":"2026-09-02T12:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"Fix bug in project B"}]}}
    """
    Fixture.write(session2Content, to: jsonl2)

    // Unmatched task
    let unmatchedTaskDir = tasksDir.appendingPathComponent("session-12345-12345")
    Fixture.dir(unmatchedTaskDir)
    Fixture.write("unmatched-task-content", to: unmatchedTaskDir.appendingPathComponent("out.txt"))

    // Context mode DB
    Fixture.write("mock-sqlite-db", to: contextModeDir.appendingPathComponent("context.db"))

    // Run history
    let runHistoryURL = tempDir.appendingPathComponent("agent/run-history.jsonl")
    Fixture.write("{\"agent\":\"worker\",\"status\":\"ok\"}\n", to: runHistoryURL)

    let scanner = PiAgentScanner(storageURL: tempDir)
    t.assert(scanner.isInstalled, "Mock scanner isInstalled == true")

    do {
        let items = try await scanner.scan()
        t.assert(items.count == 2, "Mock scan detected 2 sessions (found \(items.count))")

        // Session 1 checks
        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            t.assert(item1.title == "Implement Pi Agent Scanner feature", "Session 1 title matches first user message")
            t.assert(item1.projectPath == "/Users/mock/projectA", "Session 1 projectPath matches")
            t.assert(item1.messageCount >= 2, "Session 1 messageCount is >= 2 (found: \(item1.messageCount))")
            t.assert(item1.associatedPaths.contains(jsonl1.path), "Session 1 associatedPaths includes .jsonl")
            t.assert(item1.associatedPaths.contains(subfolder1.path), "Session 1 associatedPaths includes subfolder")
            t.assert(item1.associatedPaths.contains(task1Dir.path), "Session 1 associatedPaths includes matching task dir")
        } else {
            t.assert(false, "Session 1 not found in scan results")
        }

        // Test selective deletion: delete item1
        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            let freed = try await scanner.delete(items: [item1])
            t.assert(freed == item1.sizeInBytes, "delete([item1]) freed item1.sizeInBytes")
            t.assert(!fm.fileExists(atPath: jsonl1.path), "jsonl1 removed from disk")
            t.assert(!fm.fileExists(atPath: subfolder1.path), "subfolder1 removed from disk")
            t.assert(!fm.fileExists(atPath: task1Dir.path), "task1Dir removed from disk")
            t.assert(!fm.fileExists(atPath: projA.path), "Empty projectA folder was removed")
            t.assert(fm.fileExists(atPath: projB.path), "projectB folder still exists")
        }

        // Test cleanAll: clears projectB, tasks, context-mode, web-search-cache
        let allFreed = try await scanner.cleanAll()
        t.assert(allFreed > 0, "cleanAll() returned freed bytes > 0 (\(allFreed))")
        let postScan = try await scanner.scan()
        t.assert(postScan.isEmpty, "scan() after cleanAll returns 0 items")
        t.assert(!fm.fileExists(atPath: jsonl2.path), "jsonl2 removed from disk")
        t.assert(!fm.fileExists(atPath: unmatchedTaskDir.path), "Unmatched task directory removed in cleanAll")
        t.assert(fm.fileExists(atPath: tasksDir.path), "tasksDir recreated as clean directory")
        t.assert(fm.fileExists(atPath: contextModeDir.path), "contextModeDir recreated as clean directory")
    } catch {
        t.assert(false, "Mock PiAgentScanner threw error: \(error)")
    }
}
