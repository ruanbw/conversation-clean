import Foundation
import SQLite3

func testMockRooCodeScanner() async {
    let t = TestCase("MockRooCodeScan", section: "Test 7: Mock Roo Code Scanner (Fixture Directory)")

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_roocode_scan")
    defer { try? fm.removeItem(at: tempDir) }

    let tasksDir = tempDir.appendingPathComponent("tasks")
    let stateDir = tempDir.appendingPathComponent("state")
    let checkpointsDir = tempDir.appendingPathComponent("checkpoints")
    Fixture.dir(tasksDir)
    Fixture.dir(stateDir)
    Fixture.dir(checkpointsDir)

    let rooTaskId = "roo-task-001"
    let rooTaskDir = tasksDir.appendingPathComponent(rooTaskId)
    Fixture.dir(rooTaskDir)

    let uiMsg = """
    [
      {"ts": 1789200000000, "type": "say", "say": "task", "text": "Migrate database schema to PostgreSQL"},
      {"ts": 1789200005000, "type": "say", "say": "text", "text": "Generated migrations in # Current Working Directory (/Users/tester/data-store) Files"}
    ]
    """
    Fixture.write(uiMsg, to: rooTaskDir.appendingPathComponent("ui_messages.json"))

    let scanner = RooCodeScanner(storageURL: tempDir)
    t.assert(scanner.isInstalled, "RooCodeScanner.isInstalled is true for fixture")
    t.assert(scanner.category == .rooCode, "Category is .rooCode")

    do {
        let items = try await scanner.scan()
        t.assert(items.count == 1, "Detected 1 Roo Code task")
        if let item = items.first {
            t.assert(item.category == .rooCode, "Item category is .rooCode")
            t.assert(item.title == "Migrate database schema to PostgreSQL", "Title matches prompt (\(item.title))")
            t.assert(item.projectPath == "/Users/tester/data-store", "Extracted cwd matches /Users/tester/data-store")
            t.assert(item.messageCount == 2, "Message count is 2")
        }

        // Test delete
        let freed = try await scanner.delete(items: items)
        t.assert(freed > 0, "RooCodeScanner.delete freed bytes (\(freed))")
        let remaining = try await scanner.scan()
        t.assert(remaining.isEmpty, "Rescan after delete returns 0 items")
    } catch {
        t.assert(false, "Mock Roo Code scan threw error: \(error)")
    }
}

func testMockContinueScanner() async {
    let t = TestCase("MockContinueScan", section: "Test 8: Mock Continue.dev Scanner (Fixture Directory)")

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_continue_scan")
    defer { try? fm.removeItem(at: tempDir) }

    t.sub("Setting up Mock ~/.continue Structure")
    let sessionsDir = tempDir.appendingPathComponent("sessions")
    let indexDir = tempDir.appendingPathComponent("index")
    let cacheDir = tempDir.appendingPathComponent("cache")
    Fixture.dir(sessionsDir)
    Fixture.dir(indexDir)
    Fixture.dir(cacheDir)

    // User configuration file (must NOT be deleted by cleanAll!)
    let configFile = tempDir.appendingPathComponent("config.json")
    Fixture.write("{\"models\":[{\"title\":\"GPT-4o\"}]}", to: configFile)

    // Session 1: explicit title, ISO 8601 date, history with message objects
    let s1Id = "continue-session-001"
    let s1File = sessionsDir.appendingPathComponent("\(s1Id).json")
    let s1Content = """
    {
      "sessionId": "\(s1Id)",
      "title": "Implement Redis Caching Layer",
      "workspaceDirectory": "/Users/tester/api-gateway",
      "dateCreated": "2026-09-20T14:30:00.000Z",
      "history": [
        {"message": {"role": "user", "content": "How do I configure Redis cache eviction policy?"}},
        {"message": {"role": "assistant", "content": "You can configure volatile-lru in redis.conf."}}
      ]
    }
    """
    Fixture.write(s1Content, to: s1File)

    // Session 2: no title (inferred from first prompt), timestamp date, direct history objects
    let s2Id = "continue-session-002"
    let s2File = sessionsDir.appendingPathComponent("\(s2Id).json")
    let s2Content = """
    {
      "sessionId": "\(s2Id)",
      "workspaceDirectory": "/Users/tester/web-client",
      "dateCreated": 1789500000000,
      "history": [
        {"role": "user", "content": "Create a responsive sidebar navigation with SwiftUI"},
        {"role": "assistant", "content": "Here is a SidebarView implementation..."}
      ]
    }
    """
    Fixture.write(s2Content, to: s2File)

    // Index data
    Fixture.write("sqlite index data", to: indexDir.appendingPathComponent("index.db"))

    t.sub("Executing Mock Continue.dev Scanner")
    let scanner = ContinueScanner(storageURL: tempDir)
    t.assert(scanner.isInstalled, "ContinueScanner.isInstalled is true for fixture")
    t.assert(scanner.category == .continueDev, "Category is .continueDev")

    do {
        var items = try await scanner.scan()
        t.assert(items.count == 2, "Detected exactly 2 Continue sessions (found \(items.count))")

        // Verify session 1
        if let item1 = items.first(where: { $0.sessionId == s1Id }) {
            t.assert(item1.category == .continueDev, "Session 1 category is .continueDev")
            t.assert(item1.title == "Implement Redis Caching Layer", "Session 1 title matches explicit title (\(item1.title))")
            t.assert(item1.projectPath == "/Users/tester/api-gateway", "Session 1 workspace matches /Users/tester/api-gateway")
            t.assert(item1.messageCount == 2, "Session 1 message count is 2")
            t.assert(item1.sizeInBytes == FileSizeHelper.sizeOf(path: s1File.path), "Session 1 size matches file size")
        } else {
            t.assert(false, "Session 1 not found")
        }

        // Verify session 2
        if let item2 = items.first(where: { $0.sessionId == s2Id }) {
            t.assert(item2.title == "Create a responsive sidebar navigation with SwiftUI", "Session 2 title inferred from user prompt (\(item2.title))")
            t.assert(item2.projectPath == "/Users/tester/web-client", "Session 2 workspace matches /Users/tester/web-client")
            t.assert(item2.messageCount == 2, "Session 2 message count is 2")
        } else {
            t.assert(false, "Session 2 not found")
        }

        // Deletion test: delete item 1
        print("  \u{001B}[34m[INFO] Deleting Continue session 1...\u{001B}[0m")
        if let item1 = items.first(where: { $0.sessionId == s1Id }) {
            let freed = try await scanner.delete(items: [item1])
            t.assert(freed == item1.sizeInBytes, "Freed size (\(freed)) matches item 1 size (\(item1.sizeInBytes))")
            t.assert(!fm.fileExists(atPath: s1File.path), "Session 1 file removed from disk")
            t.assert(fm.fileExists(atPath: s2File.path), "Session 2 file still exists on disk")

            items = try await scanner.scan()
            t.assert(items.count == 1 && items.first?.sessionId == s2Id, "Rescan shows 1 session remaining")
        }

        // Clean all test
        print("  \u{001B}[34m[INFO] Calling Continue cleanAll()...\u{001B}[0m")
        let freedAll = try await scanner.cleanAll()
        t.assert(freedAll > 0, "cleanAll() returned freed bytes (\(freedAll))")

        // Verify sessions cleared
        items = try await scanner.scan()
        t.assert(items.isEmpty, "Rescan after cleanAll returns 0 sessions")

        // Verify config.json preserved!
        t.assert(fm.fileExists(atPath: configFile.path), "config.json was safely preserved and NOT deleted")

    } catch {
        t.assert(false, "Mock Continue scan threw error: \(error)")
    }
}
