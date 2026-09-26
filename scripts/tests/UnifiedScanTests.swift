import Foundation
import SQLite3

func testUnifiedMultiAgentScan() async {
    let t = TestCase("UnifiedFiveAgents", section: "Test 9: Unified Multi-Agent Scan (5 Scanners)")

    let fm = FileManager.default
    let tempClaude = TestRunner.createTempDirectory(prefix: "unified5_claude")
    let tempCodex = TestRunner.createTempDirectory(prefix: "unified5_codex")
    let tempCline = TestRunner.createTempDirectory(prefix: "unified5_cline")
    let tempRoo = TestRunner.createTempDirectory(prefix: "unified5_roo")
    let tempContinue = TestRunner.createTempDirectory(prefix: "unified5_cont")

    let tempPi = TestRunner.createTempDirectory(prefix: "unified6_pi")

    defer {
        try? fm.removeItem(at: tempClaude)
        try? fm.removeItem(at: tempCodex)
        try? fm.removeItem(at: tempCline)
        try? fm.removeItem(at: tempRoo)
        try? fm.removeItem(at: tempContinue)
        try? fm.removeItem(at: tempPi)
    }

    // 1. Claude session
    let claudeP = tempClaude.appendingPathComponent("projects/-Users-u5-claude")
    Fixture.dir(claudeP)
    Fixture.write("{\"type\":\"user\",\"message\":{\"content\":\"Claude 6-agent test\"}}\n", to: claudeP.appendingPathComponent("s-claude.jsonl"))

    // 2. Codex session
    let codexDay = tempCodex.appendingPathComponent("sessions/2026/09/20")
    Fixture.dir(codexDay)
    Fixture.write("{\"role\":\"user\",\"content\":\"Codex 6-agent test\"}\n", to: codexDay.appendingPathComponent("s-codex.jsonl"))

    // 3. Cline session
    let clineTasks = tempCline.appendingPathComponent("tasks/s-cline")
    Fixture.dir(clineTasks)
    Fixture.write("[{\"ts\":1789000000000,\"type\":\"say\",\"say\":\"task\",\"text\":\"Cline 6-agent test\"}]", to: clineTasks.appendingPathComponent("ui_messages.json"))

    // 4. Roo Code session
    let rooTasks = tempRoo.appendingPathComponent("tasks/s-roo")
    Fixture.dir(rooTasks)
    Fixture.write("[{\"ts\":1789000000000,\"type\":\"say\",\"say\":\"task\",\"text\":\"Roo Code 6-agent test\"}]", to: rooTasks.appendingPathComponent("ui_messages.json"))

    // 5. Continue session
    let contSessions = tempContinue.appendingPathComponent("sessions")
    Fixture.dir(contSessions)
    let contJson = "{\"sessionId\":\"s-cont\",\"title\":\"Continue 6-agent test\",\"workspaceDirectory\":\"/Users/u5/cont\",\"dateCreated\":\"2026-09-20T10:00:00Z\",\"history\":[]}"
    Fixture.write(contJson, to: contSessions.appendingPathComponent("s-cont.json"))

    // 6. Pi Agent session
    let piProj = tempPi.appendingPathComponent("agent/sessions/--Users-u6-pi--")
    Fixture.dir(piProj)
    let piSid = "01a00000-0000-7000-8000-000000000099"
    let piJson = """
    {"type":"session","version":3,"id":"\(piSid)","timestamp":"2026-09-20T10:00:00.000Z","cwd":"/Users/u6/pi"}
    {"type":"message","id":"msg1","message":{"role":"user","content":[{"type":"text","text":"Pi Agent 6-agent test"}]}}
    """
    Fixture.write(piJson, to: piProj.appendingPathComponent("2026-09-20T10-00-00-000Z_\(piSid).jsonl"))

    let scanners: [AgentScanner] = [
        ClaudeCodeScanner(storageURL: tempClaude),
        CodexScanner(storageURL: tempCodex),
        ClineScanner(storageURL: tempCline),
        RooCodeScanner(storageURL: tempRoo),
        ContinueScanner(storageURL: tempContinue),
        PiAgentScanner(storageURL: tempPi)
    ]
    let scanService = AgentScanService(scanners: scanners)

    let allItems = await scanService.scanAll()
    t.assert(allItems.count == 6, "scanAll() detected 6 items across all 6 scanners (found \(allItems.count))")

    let categoriesFound = Set(allItems.map { $0.category })
    t.assert(categoriesFound.contains(.claudeCode), "Contains .claudeCode")
    t.assert(categoriesFound.contains(.codex), "Contains .codex")
    t.assert(categoriesFound.contains(.cline), "Contains .cline")
    t.assert(categoriesFound.contains(.rooCode), "Contains .rooCode")
    t.assert(categoriesFound.contains(.continueDev), "Contains .continueDev")
    t.assert(categoriesFound.contains(.piAgent), "Contains .piAgent")

    let infos = scanService.getAgentInfos(from: allItems)
    t.assert(infos.count == 6, "AgentScanService.getAgentInfos() returned 6 infos")
    for info in infos {
        t.assert(info.sessionCount == 1, "\(info.category.rawValue) shows exactly 1 session")
    }

    let totalExpectedSize = allItems.reduce(0) { $0 + $1.sizeInBytes }
    let freed = await scanService.delete(items: allItems)
    t.assert(freed == totalExpectedSize, "scanService.delete() freed all bytes (\(freed) == \(totalExpectedSize))")

    let remaining = await scanService.scanAll()
    t.assert(remaining.isEmpty, "Rescan after deleting all 6 returns 0 items")
}
