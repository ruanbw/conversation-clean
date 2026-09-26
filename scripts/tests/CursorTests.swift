import Foundation
import SQLite3

func testMockCursorScanner() async {
    let t = TestCase("MockCursor", section: "Test: Mock Cursor Scanner (Fixture Directory)")

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_cursor")
    defer { try? fm.removeItem(at: tempDir) }

    let userDir = tempDir.appendingPathComponent("User")
    let wsStorage = userDir.appendingPathComponent("workspaceStorage")
    let wsA = wsStorage.appendingPathComponent("wsCursor123")
    let wsAChat = wsA.appendingPathComponent("chatSessions")
    let dotCursor = tempDir.appendingPathComponent(".cursor")
    let dotChats = dotCursor.appendingPathComponent("chats")

    Fixture.dir(wsAChat)
    Fixture.dir(dotChats)

    // workspace.json
    Fixture.write("{\"folder\":\"file:///Users/tester/cursor-project\"}", to: wsA.appendingPathComponent("workspace.json"))

    // Session 1 in chatSessions/
    let cid1 = "cursor-chat-001"
    let c1File = wsAChat.appendingPathComponent("\(cid1).jsonl")
    let c1Content = """
    {"kind":0,"v":{"version":3,"creationDate":1789200000000,"sessionId":"\(cid1)","requests":[]}}
    {"kind":2,"k":["requests"],"v":[{"requestId":"r1","message":{"text":"Cursor compose prompt 1"}}]}
    """
    Fixture.write(c1Content, to: c1File)

    // Session 2 in state.vscdb mock composer
    let stateDbURL = wsA.appendingPathComponent("state.vscdb")
    let composerJson = """
    {
      "allComposers": [
        {
          "composerId": "composer-001",
          "name": "Implement Cursor Composer Feature",
          "createdAt": 1789300000000,
          "conversation": [{"role":"user","text":"Implement feature"}]
        }
      ]
    }
    """
    Fixture.write(composerJson, to: stateDbURL)

    // Session 3 in ~/.cursor/chats/
    let cid3 = "cursor-dot-001"
    let c3File = dotChats.appendingPathComponent("\(cid3).json")
    Fixture.write("{\"id\":\"\(cid3)\"}", to: c3File)

    let scanner = CursorScanner(baseURL: tempDir)
    t.assert(scanner.isInstalled, "CursorScanner.isInstalled is true for fixture")
    t.assert(scanner.category == .cursor, "Category is .cursor")

    do {
        var items = try await scanner.scan()
        t.assert(items.count == 3, "Detected 3 Cursor sessions across workspace, state.vscdb, and .cursor (found: \(items.count))")

        if let item1 = items.first(where: { $0.sessionId == cid1 }) {
            t.assert(item1.title == "Cursor compose prompt 1", "Session 1 title matches prompt")
            t.assert(item1.projectPath == "/Users/tester/cursor-project", "Session 1 projectPath matches workspace.json")
        } else {
            t.assert(false, "Session 1 not found")
        }

        if let item2 = items.first(where: { $0.sessionId == "composer-001" }) {
            t.assert(item2.title == "Implement Cursor Composer Feature", "Composer session parsed from state.vscdb")
            t.assert(item2.projectPath == "/Users/tester/cursor-project", "Composer projectPath matches workspace.json")
        } else {
            t.assert(false, "Composer session not found")
        }

        // Delete item 1
        if let item1 = items.first(where: { $0.sessionId == cid1 }) {
            let freed = try await scanner.delete(items: [item1])
            t.assert(freed == item1.sizeInBytes, "Freed size matches item 1")
            t.assert(!fm.fileExists(atPath: c1File.path), "Session 1 file removed")
        }

        // cleanAll
        let allFreed = try await scanner.cleanAll()
        t.assert(allFreed > 0, "cleanAll freed bytes > 0")
        items = try await scanner.scan()
        t.assert(items.isEmpty, "Rescan after cleanAll returns 0 items")
    } catch {
        t.assert(false, "Mock Cursor scan threw error: \(error)")
    }
}
