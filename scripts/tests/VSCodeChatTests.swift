import Foundation
import SQLite3

func testRealVSCodeChatScannerReadOnly() async {
    let t = TestCase("RealVSCodeReadOnly", section: "Test: Real VS Code Chat Scanner (READ-ONLY)")

    let scanner = VSCodeChatScanner()
    t.assert(scanner.category == .copilotChat, "Category is .copilotChat")

    let homePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Code/User").path
    t.assert(TestRunner.canonicalPath(scanner.storageURL.path) == TestRunner.canonicalPath(homePath), "storageURL correctly points to Code/User directory")
    t.assert(scanner.isInstalled, "scanner.isInstalled is true on this Mac")

    do {
        let items = try await scanner.scan()
        t.assert(!items.isEmpty, "Detected real VS Code Chat sessions (count: \(items.count))")
        t.assert(items.count >= 44, "Detected at least 44 sessions (found: \(items.count))")

        let allCopilot = items.allSatisfy { $0.category == .copilotChat }
        t.assert(allCopilot, "All scanned items have category .copilotChat")

        // Find active session fc6c5632
        if let active = items.first(where: { $0.sessionId.contains("fc6c5632") }) {
            t.assert(active.title == "将这个文件改为中文。", "Session fc6c5632 title is '将这个文件改为中文。' (found: '\(active.title)')")
            t.assert(active.messageCount == 2, "Session fc6c5632 messageCount is 2 (found: \(active.messageCount))")
            t.assert(active.projectPath != nil && active.projectPath!.contains("video-play-frontend"), "Session fc6c5632 projectPath matches video-play-frontend (found: '\(active.projectPath ?? "nil")')")
            t.assert(active.associatedPaths.count >= 2, "Session fc6c5632 associatedPaths includes chatSessions and chatEditingSessions")
        } else {
            t.assert(false, "Session fc6c5632 not found in real scan")
        }

        // Verify all associated paths exist
        var pathsExist = true
        for item in items.prefix(20) {
            for p in item.associatedPaths {
                if !FileManager.default.fileExists(atPath: p) {
                    pathsExist = false
                    break
                }
            }
        }
        t.assert(pathsExist, "Sampled sessions associated paths exist on disk")
    } catch {
        t.assert(false, "Real VS Code scan threw error: \(error)")
    }
}

func testMockVSCodeChatScanner() async {
    let t = TestCase("MockVSCodeChat", section: "Test: Mock VS Code Chat Scanner (Fixture Directory)")

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_vscode_chat")
    defer { try? fm.removeItem(at: tempDir) }

    let wsStorage = tempDir.appendingPathComponent("workspaceStorage")
    let globalStorage = tempDir.appendingPathComponent("globalStorage")
    let emptyWindow = globalStorage.appendingPathComponent("emptyWindowChatSessions")
    let wsA = wsStorage.appendingPathComponent("hashA123")
    let wsAChat = wsA.appendingPathComponent("chatSessions")
    let wsAEdit = wsA.appendingPathComponent("chatEditingSessions")

    Fixture.dir(wsAChat)
    Fixture.dir(wsAEdit)
    Fixture.dir(emptyWindow)

    // workspace.json with folder URI
    let wsJson = "{\"folder\":\"file:///Users/tester/mock-web-app\"}"
    Fixture.write(wsJson, to: wsA.appendingPathComponent("workspace.json"))

    // Session 1 in workspace A: has prompt and matching editing session folder
    let sid1 = "session-vs-001"
    let s1File = wsAChat.appendingPathComponent("\(sid1).jsonl")
    let s1Content = """
    {"kind":0,"v":{"version":3,"creationDate":1789000000000,"sessionId":"\(sid1)","requests":[]}}
    {"kind":2,"k":["requests"],"v":[{"requestId":"r1","message":{"text":"Refactor SwiftUI navigation view"}}]}
    """
    Fixture.write(s1Content, to: s1File)

    let s1EditDir = wsAEdit.appendingPathComponent(sid1)
    Fixture.dir(s1EditDir)
    Fixture.write("state data", to: s1EditDir.appendingPathComponent("state.json"))

    // Session 2 in emptyWindow: empty session
    let sid2 = "session-vs-002"
    let s2File = emptyWindow.appendingPathComponent("\(sid2).jsonl")
    let s2Content = """
    {"kind":0,"v":{"version":3,"creationDate":1789100000000,"sessionId":"\(sid2)","requests":[]}}
    """
    Fixture.write(s2Content, to: s2File)

    let scanner = VSCodeChatScanner(baseURL: tempDir)
    t.assert(scanner.isInstalled, "scanner.isInstalled is true for fixture")
    t.assert(scanner.category == .copilotChat, "Category is .copilotChat")

    do {
        var items = try await scanner.scan()
        t.assert(items.count == 2, "Detected 2 mock sessions (found: \(items.count))")

        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            t.assert(item1.title == "Refactor SwiftUI navigation view", "Session 1 title matches prompt (\(item1.title))")
            t.assert(item1.projectPath == "/Users/tester/mock-web-app", "Session 1 projectPath matches workspace.json")
            t.assert(item1.messageCount == 1, "Session 1 messageCount is 1")
            t.assert(item1.associatedPaths.contains(s1File.path), "Session 1 associatedPaths contains jsonl")
            t.assert(item1.associatedPaths.contains(s1EditDir.path), "Session 1 associatedPaths contains editing folder")
        } else {
            t.assert(false, "Session 1 not found")
        }

        if let item2 = items.first(where: { $0.sessionId == sid2 }) {
            t.assert(item2.title == "GitHub Copilot 对话", "Session 2 has fallback title 'GitHub Copilot 对话'")
            t.assert(item2.projectPath == nil, "Session 2 has nil projectPath")
        } else {
            t.assert(false, "Session 2 not found")
        }

        // Test delete item1
        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            let freed = try await scanner.delete(items: [item1])
            t.assert(freed == item1.sizeInBytes, "Freed bytes matches item 1 size")
            t.assert(!fm.fileExists(atPath: s1File.path), "Session 1 jsonl removed from disk")
            t.assert(!fm.fileExists(atPath: s1EditDir.path), "Session 1 editing dir removed from disk")
            t.assert(fm.fileExists(atPath: s2File.path), "Session 2 jsonl still exists")
        }

        // Test cleanAll
        let allFreed = try await scanner.cleanAll()
        t.assert(allFreed > 0, "cleanAll freed bytes > 0")
        items = try await scanner.scan()
        t.assert(items.isEmpty, "Rescan after cleanAll returns 0 items")
    } catch {
        t.assert(false, "Mock VS Code Chat scan threw error: \(error)")
    }
}
