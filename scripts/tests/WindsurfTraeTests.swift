import Foundation
import SQLite3

func testMockWindsurfScanner() async {
    let t = TestCase("MockWindsurf", section: "Test: Mock Windsurf Scanner (Fixture Directory)")

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_windsurf")
    defer { try? fm.removeItem(at: tempDir) }

    let userDir = tempDir.appendingPathComponent("User")
    let wsStorage = userDir.appendingPathComponent("workspaceStorage")
    let wsA = wsStorage.appendingPathComponent("wsWindsurf123")
    let wsAChat = wsA.appendingPathComponent("chatSessions")
    let codeiumWindsurf = tempDir.appendingPathComponent(".codeium/windsurf")
    let cascadesDir = codeiumWindsurf.appendingPathComponent("cascades")

    Fixture.dir(wsAChat)
    Fixture.dir(cascadesDir)

    // workspace.json
    Fixture.write("{\"folder\":\"file:///Users/tester/windsurf-app\"}", to: wsA.appendingPathComponent("workspace.json"))

    // Session 1 in workspaceStorage
    let wid1 = "windsurf-chat-001"
    let w1File = wsAChat.appendingPathComponent("\(wid1).jsonl")
    let w1Content = """
    {"kind":0,"v":{"version":3,"creationDate":1789400000000,"sessionId":"\(wid1)","requests":[]}}
    {"kind":2,"k":["requests"],"v":[{"requestId":"r1","message":{"text":"Generate Windsurf cascade rule"}}]}
    """
    Fixture.write(w1Content, to: w1File)

    // Session 2 in cascades/
    let cid2 = "cascade-session-002"
    let cascadeDir = cascadesDir.appendingPathComponent(cid2)
    Fixture.dir(cascadeDir)
    let metaContent = """
    {"title":"Optimize React components with memo","cwd":"/Users/tester/react-frontend"}
    """
    Fixture.write(metaContent, to: cascadeDir.appendingPathComponent("meta.json"))

    let scanner = WindsurfScanner(baseURL: tempDir)
    t.assert(scanner.isInstalled, "WindsurfScanner.isInstalled is true for fixture")
    t.assert(scanner.category == .windsurf, "Category is .windsurf")

    do {
        var items = try await scanner.scan()
        t.assert(items.count == 2, "Detected 2 Windsurf sessions (found: \(items.count))")

        if let item1 = items.first(where: { $0.sessionId == wid1 }) {
            t.assert(item1.title == "Generate Windsurf cascade rule", "Session 1 title matches prompt")
            t.assert(item1.projectPath == "/Users/tester/windsurf-app", "Session 1 projectPath matches workspace.json")
        } else {
            t.assert(false, "Session 1 not found")
        }

        if let item2 = items.first(where: { $0.sessionId == cid2 }) {
            t.assert(item2.title == "Optimize React components with memo", "Cascade session title parsed from meta.json")
            t.assert(item2.projectPath == "/Users/tester/react-frontend", "Cascade session projectPath matches meta cwd")
        } else {
            t.assert(false, "Cascade session 2 not found")
        }

        // Delete item 1
        if let item1 = items.first(where: { $0.sessionId == wid1 }) {
            let freed = try await scanner.delete(items: [item1])
            t.assert(freed == item1.sizeInBytes, "Freed size matches item 1")
            t.assert(!fm.fileExists(atPath: w1File.path), "Session 1 file removed")
        }

        // cleanAll
        let allFreed = try await scanner.cleanAll()
        t.assert(allFreed > 0, "cleanAll freed bytes > 0")
        items = try await scanner.scan()
        t.assert(items.isEmpty, "Rescan after cleanAll returns 0 items")
    } catch {
        t.assert(false, "Mock Windsurf scan threw error: \(error)")
    }
}

func testMockTraeScanner() async {
    let t = TestCase("MockTrae", section: "Test: Mock Trae Scanner (Fixture Directory)")

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_trae")
    defer { try? fm.removeItem(at: tempDir) }

    let userDir = tempDir.appendingPathComponent("User")
    let wsStorage = userDir.appendingPathComponent("workspaceStorage")
    let wsA = wsStorage.appendingPathComponent("wsTrae123")
    let wsAChat = wsA.appendingPathComponent("chatSessions")
    let globalStorage = userDir.appendingPathComponent("globalStorage")
    let emptyWindow = globalStorage.appendingPathComponent("emptyWindowChatSessions")

    Fixture.dir(wsAChat)
    Fixture.dir(emptyWindow)

    // workspace.json
    Fixture.write("{\"folder\":\"file:///Users/tester/trae-project\"}", to: wsA.appendingPathComponent("workspace.json"))

    // Session 1 in workspace
    let tid1 = "trae-chat-001"
    let t1File = wsAChat.appendingPathComponent("\(tid1).jsonl")
    let t1Content = """
    {"kind":0,"v":{"version":3,"creationDate":1789500000000,"sessionId":"\(tid1)","requests":[]}}
    {"kind":2,"k":["requests"],"v":[{"requestId":"r1","message":{"text":"Trae create microservice"}},{"requestId":"r2","message":{"text":"Next prompt"}}]}
    """
    Fixture.write(t1Content, to: t1File)

    // Session 2 in emptyWindow
    let tid2 = "trae-empty-002"
    let t2File = emptyWindow.appendingPathComponent("\(tid2).jsonl")
    let t2Content = """
    {"kind":0,"v":{"version":3,"creationDate":1789600000000,"sessionId":"\(tid2)","requests":[]}}
    """
    Fixture.write(t2Content, to: t2File)

    let scanner = TraeScanner(baseURL: tempDir)
    t.assert(scanner.isInstalled, "TraeScanner.isInstalled is true for fixture")
    t.assert(scanner.category == .trae, "Category is .trae")

    do {
        var items = try await scanner.scan()
        t.assert(items.count == 2, "Detected 2 Trae sessions (found: \(items.count))")

        if let item1 = items.first(where: { $0.sessionId == tid1 }) {
            t.assert(item1.title == "Trae create microservice", "Session 1 title matches prompt")
            t.assert(item1.messageCount == 2, "Session 1 messageCount is 2")
            t.assert(item1.projectPath == "/Users/tester/trae-project", "Session 1 projectPath matches workspace.json")
        } else {
            t.assert(false, "Session 1 not found")
        }

        if let item2 = items.first(where: { $0.sessionId == tid2 }) {
            t.assert(item2.title == "Trae 对话", "Session 2 has fallback title 'Trae 对话'")
            t.assert(item2.projectPath == nil, "Session 2 has nil projectPath")
        } else {
            t.assert(false, "Session 2 not found")
        }

        // Delete item 1
        if let item1 = items.first(where: { $0.sessionId == tid1 }) {
            let freed = try await scanner.delete(items: [item1])
            t.assert(freed == item1.sizeInBytes, "Freed size matches item 1")
            t.assert(!fm.fileExists(atPath: t1File.path), "Session 1 file removed")
        }

        // cleanAll
        let allFreed = try await scanner.cleanAll()
        t.assert(allFreed > 0, "cleanAll freed bytes > 0")
        items = try await scanner.scan()
        t.assert(items.isEmpty, "Rescan after cleanAll returns 0 items")
    } catch {
        t.assert(false, "Mock Trae scan threw error: \(error)")
    }
}
