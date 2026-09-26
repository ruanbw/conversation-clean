import Foundation
import SQLite3

func testMockDeletion() async {
    TestRunner.printSection("Test 4: Mock Deletion Verification")

    let fm = FileManager.default

    // ------------------------------------------------------------------------
    // Part 4A: Claude Code Deletion Test
    // ------------------------------------------------------------------------
    let claudeDel = TestCase("ClaudeDeletion", subsection: "Part 4A: Claude Code Deletion Verification")
    let claudeDir = TestRunner.createTempDirectory(prefix: "mock_claude_del")
    defer { try? fm.removeItem(at: claudeDir) }

    let pDir = claudeDir.appendingPathComponent("projects/-Users-tester-deltest")
    let fHistDir = claudeDir.appendingPathComponent("file-history")
    let plansDir = claudeDir.appendingPathComponent("plans")
    let envDir = claudeDir.appendingPathComponent("session-env")

    Fixture.dir(pDir)
    Fixture.dir(fHistDir)
    Fixture.dir(plansDir)
    Fixture.dir(envDir)

    let cIdA = "claude-del-A"
    let cIdB = "claude-del-B"

    // Session A files
    let fileA = pDir.appendingPathComponent("\(cIdA).jsonl")
    Fixture.write("{\"type\":\"user\",\"message\":{\"content\":\"Delete test session A\"}}\n", to: fileA)
    let subagentA = pDir.appendingPathComponent(cIdA)
    Fixture.dir(subagentA)
    Fixture.write("subagent log", to: subagentA.appendingPathComponent("log.txt"))
    let histA = fHistDir.appendingPathComponent(cIdA)
    Fixture.dir(histA)
    Fixture.write("backup data", to: histA.appendingPathComponent("file.txt"))
    let planA = plansDir.appendingPathComponent(cIdA)
    Fixture.dir(planA)
    Fixture.write("plan data", to: planA.appendingPathComponent("plan.md"))
    let envA = envDir.appendingPathComponent(cIdA)
    Fixture.dir(envA)
    Fixture.write("env data", to: envA.appendingPathComponent("env.json"))

    // Session B files (simple)
    let fileB = pDir.appendingPathComponent("\(cIdB).jsonl")
    Fixture.write("{\"type\":\"user\",\"message\":{\"content\":\"Keep test session B\"}}\n", to: fileB)

    // history.jsonl
    let cHistoryFile = claudeDir.appendingPathComponent("history.jsonl")
    let cHistContent = """
    {"sessionId":"\(cIdA)","display":"Delete test session A","project":"/Users/tester/deltest","timestamp":1700000000000}
    {"sessionId":"\(cIdB)","display":"Keep test session B","project":"/Users/tester/deltest","timestamp":1700001000000}
    """
    Fixture.write(cHistContent, to: cHistoryFile)

    let claudeScanner = ClaudeCodeScanner(storageURL: claudeDir)
    do {
        var items = try await claudeScanner.scan()
        claudeDel.assert(items.count == 2, "Initial scan detected 2 Claude sessions")

        guard let itemA = items.first(where: { $0.sessionId == cIdA }),
              let itemB = items.first(where: { $0.sessionId == cIdB }) else {
            claudeDel.assert(false, "Could not find expected items A and B")
            return
        }

        let expectedFreedA = itemA.sizeInBytes

        // Step 1: Delete item A only
        print("  \u{001B}[34m[INFO] Deleting session A (expected size: \(expectedFreedA) bytes)...\u{001B}[0m")
        let freedA = try await claudeScanner.delete(items: [itemA])
        claudeDel.assert(freedA == expectedFreedA, "Bytes freed (\(freedA)) matches item A size (\(expectedFreedA))")

        // Verify session A files deleted
        claudeDel.assert(!fm.fileExists(atPath: fileA.path), "Session A jsonl removed")
        claudeDel.assert(!fm.fileExists(atPath: subagentA.path), "Session A subagent dir removed")
        claudeDel.assert(!fm.fileExists(atPath: histA.path), "Session A file-history dir removed")
        claudeDel.assert(!fm.fileExists(atPath: planA.path), "Session A plan dir removed")
        claudeDel.assert(!fm.fileExists(atPath: envA.path), "Session A session-env dir removed")

        // Verify session B still exists
        claudeDel.assert(fm.fileExists(atPath: fileB.path), "Session B jsonl still exists")

        // Verify history.jsonl cleaned
        let updatedHist = (try? String(contentsOf: cHistoryFile, encoding: .utf8)) ?? ""
        claudeDel.assert(!updatedHist.contains(cIdA), "history.jsonl no longer contains session A")
        claudeDel.assert(updatedHist.contains(cIdB), "history.jsonl still contains session B")

        // Rescan: exactly 1 item remaining
        items = try await claudeScanner.scan()
        claudeDel.assert(items.count == 1 && items.first?.sessionId == cIdB, "Rescan shows exactly 1 session remaining (session B)")

        // Step 2: Delete item B
        print("  \u{001B}[34m[INFO] Deleting session B...\u{001B}[0m")
        let freedB = try await claudeScanner.delete(items: [itemB])
        claudeDel.assert(freedB == itemB.sizeInBytes, "Bytes freed (\(freedB)) matches item B size")
        claudeDel.assert(!fm.fileExists(atPath: fileB.path), "Session B jsonl removed")

        // Empty project directory should be cleaned up
        claudeDel.assert(!fm.fileExists(atPath: pDir.path), "Empty project directory was cleaned up")

        // Rescan: 0 items
        items = try await claudeScanner.scan()
        claudeDel.assert(items.isEmpty, "Rescan after deleting all items returns 0 sessions")

    } catch {
        claudeDel.assert(false, "Claude deletion test threw error: \(error)")
    }

    // ------------------------------------------------------------------------
    // Part 4B: Codex Deletion Test
    // ------------------------------------------------------------------------
    let codexDel = TestCase("CodexDeletion", subsection: "Part 4B: Codex Deletion Verification")
    let codexDir = TestRunner.createTempDirectory(prefix: "mock_codex_del")
    defer { try? fm.removeItem(at: codexDir) }

    let codexSessionsDir = codexDir.appendingPathComponent("sessions")
    let cDay1 = codexSessionsDir.appendingPathComponent("2026/09/01")
    let cDay2 = codexSessionsDir.appendingPathComponent("2026/09/02")
    Fixture.dir(cDay1)
    Fixture.dir(cDay2)

    let codexId1 = "codex-del-001"
    let codexId2 = "codex-del-002"

    let cFile1 = cDay1.appendingPathComponent("\(codexId1).jsonl")
    let cFile2 = cDay2.appendingPathComponent("\(codexId2).jsonl")

    Fixture.write("{\"role\":\"user\",\"content\":\"Codex deletion test 1\"}\n", to: cFile1)
    Fixture.write("{\"role\":\"user\",\"content\":\"Codex deletion test 2\"}\n", to: cFile2)

    let codexIndexFile = codexDir.appendingPathComponent("session_index.jsonl")
    let codexIndexContent = """
    {"id":"\(codexId1)","title":"Deletion Test 1","filename":"\(codexId1).jsonl","updated_at":1789000000000}
    {"id":"\(codexId2)","title":"Deletion Test 2","filename":"\(codexId2).jsonl","updated_at":1789100000000}
    """
    Fixture.write(codexIndexContent, to: codexIndexFile)

    let codexScanner = CodexScanner(storageURL: codexDir)
    do {
        var items = try await codexScanner.scan()
        codexDel.assert(items.count == 2, "Initial scan detected 2 Codex sessions")

        guard let item1 = items.first(where: { $0.sessionId == codexId1 }),
              let item2 = items.first(where: { $0.sessionId == codexId2 }) else {
            codexDel.assert(false, "Could not find expected items 1 and 2")
            return
        }

        // Delete item 1
        print("  \u{001B}[34m[INFO] Deleting Codex session 1...\u{001B}[0m")
        let freed1 = try await codexScanner.delete(items: [item1])
        codexDel.assert(freed1 == item1.sizeInBytes, "Bytes freed (\(freed1)) matches item 1 size (\(item1.sizeInBytes))")
        codexDel.assert(!fm.fileExists(atPath: cFile1.path), "Session 1 jsonl file removed")

        // Verify empty date folder removed
        codexDel.assert(!fm.fileExists(atPath: cDay1.path), "Empty date folder 2026/09/01 cleaned up")

        // Verify session 2 file still exists
        codexDel.assert(fm.fileExists(atPath: cFile2.path), "Session 2 jsonl file still exists")

        // Verify session_index.jsonl cleaned
        let updatedIndex = (try? String(contentsOf: codexIndexFile, encoding: .utf8)) ?? ""
        codexDel.assert(!updatedIndex.contains(codexId1), "session_index.jsonl no longer contains session 1")
        codexDel.assert(updatedIndex.contains(codexId2), "session_index.jsonl still contains session 2")

        // Rescan: exactly 1 item remaining
        items = try await codexScanner.scan()
        codexDel.assert(items.count == 1 && items.first?.sessionId == codexId2, "Rescan shows exactly 1 session remaining (session 2)")

        // Delete item 2
        print("  \u{001B}[34m[INFO] Deleting Codex session 2...\u{001B}[0m")
        let freed2 = try await codexScanner.delete(items: [item2])
        codexDel.assert(freed2 == item2.sizeInBytes, "Bytes freed (\(freed2)) matches item 2 size")
        codexDel.assert(!fm.fileExists(atPath: cFile2.path), "Session 2 jsonl file removed")

        // Verify empty date folders cleaned up up to sessions root
        codexDel.assert(!fm.fileExists(atPath: cDay2.path), "Empty date folder 2026/09/02 cleaned up")
        codexDel.assert(!fm.fileExists(atPath: codexSessionsDir.appendingPathComponent("2026").path), "Empty parent year folder cleaned up")

        // Rescan: 0 items
        items = try await codexScanner.scan()
        codexDel.assert(items.isEmpty, "Rescan after deleting all Codex items returns 0 sessions")

    } catch {
        codexDel.assert(false, "Codex deletion test threw error: \(error)")
    }

    // ------------------------------------------------------------------------
    // Part 4C: AgentScanService Unified Multi-Agent Deletion
    // ------------------------------------------------------------------------
    let serviceCase = TestCase("AgentScanServiceUnified", subsection: "Part 4C: AgentScanService Unified Scan & Deletion")

    let unifiedClaudeDir = TestRunner.createTempDirectory(prefix: "unified_claude")
    let unifiedCodexDir = TestRunner.createTempDirectory(prefix: "unified_codex")
    defer {
        try? fm.removeItem(at: unifiedClaudeDir)
        try? fm.removeItem(at: unifiedCodexDir)
    }

    // Claude setup
    let uProj = unifiedClaudeDir.appendingPathComponent("projects/-Users-tester-app")
    Fixture.dir(uProj)
    let uClaudeFile = uProj.appendingPathComponent("u-claude-1.jsonl")
    Fixture.write("{\"type\":\"user\",\"message\":{\"content\":\"Unified test claude\"}}\n", to: uClaudeFile)

    // Codex setup
    let uCodexDay = unifiedCodexDir.appendingPathComponent("sessions/2026/09/10")
    Fixture.dir(uCodexDay)
    let uCodexFile = uCodexDay.appendingPathComponent("u-codex-1.jsonl")
    Fixture.write("{\"role\":\"user\",\"content\":\"Unified test codex\"}\n", to: uCodexFile)

    let mockClaude = ClaudeCodeScanner(storageURL: unifiedClaudeDir)
    let mockCodex = CodexScanner(storageURL: unifiedCodexDir)
    let scanService = AgentScanService(scanners: [mockClaude, mockCodex])

    // Scan all
    let allItems = await scanService.scanAll()
    serviceCase.assert(allItems.count == 2, "AgentScanService.scanAll() detected 2 items across both scanners")

    let agentInfos = scanService.getAgentInfos(from: allItems)
    let claudeInfo = agentInfos.first(where: { $0.category == .claudeCode })
    let codexInfo = agentInfos.first(where: { $0.category == .codex })

    serviceCase.assert(claudeInfo?.sessionCount == 1, "AgentInfo for Claude Code shows 1 session")
    serviceCase.assert(codexInfo?.sessionCount == 1, "AgentInfo for Codex shows 1 session")

    let totalExpectedSize = allItems.reduce(0) { $0 + $1.sizeInBytes }
    let totalFreed = await scanService.delete(items: allItems)
    serviceCase.assert(totalFreed == totalExpectedSize, "AgentScanService.delete() freed all bytes (\(totalFreed) == \(totalExpectedSize))")

    // Verify disk files removed
    serviceCase.assert(!fm.fileExists(atPath: uClaudeFile.path), "Unified Claude session file removed from disk")
    serviceCase.assert(!fm.fileExists(atPath: uCodexFile.path), "Unified Codex session file removed from disk")

    // Rescan all
    let remaining = await scanService.scanAll()
    serviceCase.assert(remaining.isEmpty, "AgentScanService.scanAll() after deletion returns 0 items")
}
