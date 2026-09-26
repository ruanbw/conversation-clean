import Foundation
import SQLite3

func testRealOpenHandsScannerReadOnly() async {
    let t = TestCase("RealOpenHandsReadOnly", section: "Test: Real Local OpenHands Scanner (READ-ONLY)")

    let scanner = OpenHandsScanner()
    t.assert(scanner.category == .openHands, "Category is .openHands")
    do {
        let items = try await scanner.scan()
        t.assert(true, "OpenHands scan() executed without throwing error")
        print("  \u{001B}[34m[INFO] Scanned \(items.count) OpenHands items on current machine\u{001B}[0m")
    } catch {
        t.assert(false, "Real OpenHands scan threw error: \(error)")
    }
}

func testMockOpenHandsScanner() async {
    let t = TestCase("MockOpenHands", section: "Test: Mock OpenHands Scanner (Fixture Directory)")

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_openhands")
    defer { try? fm.removeItem(at: tempDir) }

    let sessionsDir = tempDir.appendingPathComponent("sessions")
    let logsDir = tempDir.appendingPathComponent("logs")
    let wsDir = tempDir.appendingPathComponent("workspace")

    Fixture.dir(sessionsDir)
    Fixture.dir(logsDir)
    Fixture.dir(wsDir)

    let sid1 = "session-oh-001"
    let s1Dir = sessionsDir.appendingPathComponent(sid1)
    Fixture.dir(s1Dir)

    let s1Meta = """
    {"session_id":"\(sid1)","title":"Implement Stripe webhook handler","directory":"/Users/tester/payment-api","created_at":"2026-09-20T10:00:00Z"}
    """
    Fixture.write(s1Meta, to: s1Dir.appendingPathComponent("metadata.json"))

    let s1Events = """
    {"action":"message","args":{"content":"Please implement stripe webhook verification"},"timestamp":"2026-09-20T10:00:05Z"}
    {"action":"run","args":{"command":"go test ./..."},"timestamp":"2026-09-20T10:00:10Z"}
    """
    Fixture.write(s1Events, to: s1Dir.appendingPathComponent("events.jsonl"))

    let s1Log = logsDir.appendingPathComponent("\(sid1).log")
    Fixture.write("session log entry line 1\nline 2\n", to: s1Log)

    let s1Ws = wsDir.appendingPathComponent(sid1)
    Fixture.dir(s1Ws)
    Fixture.write("package main", to: s1Ws.appendingPathComponent("webhook.go"))

    let sid2 = "session-oh-002"
    let s2File = sessionsDir.appendingPathComponent("\(sid2).json")
    let s2Json = """
    {"session_id":"\(sid2)","title":"Fix CSS grid responsiveness","events":[{},{},{}]}
    """
    Fixture.write(s2Json, to: s2File)

    let serverLog = logsDir.appendingPathComponent("openhands-server.log")
    Fixture.write("server starting on :3000\nready\n", to: serverLog)

    let scanner = OpenHandsScanner(storageURL: tempDir)
    t.assert(scanner.isInstalled, "Mock scanner isInstalled is true")

    do {
        var items = try await scanner.scan()
        t.assert(items.count == 3, "Detected 3 items (2 sessions + 1 orphaned log group, found: \(items.count))")

        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            t.assert(item1.title == "Implement Stripe webhook handler", "Session 1 title matches metadata")
            t.assert(item1.projectPath == "/Users/tester/payment-api", "Session 1 projectPath matches metadata")
            t.assert(item1.messageCount == 2, "Session 1 messageCount is 2")
            t.assert(item1.associatedPaths.contains(s1Dir.path), "Session 1 associatedPaths contains session dir")
            t.assert(item1.associatedPaths.contains(s1Log.path), "Session 1 associatedPaths contains log file")
            t.assert(item1.associatedPaths.contains(s1Ws.path), "Session 1 associatedPaths contains workspace dir")
        } else {
            t.assert(false, "Session 1 not found")
        }

        if let logItem = items.first(where: { $0.sessionId.hasPrefix("openhands-logs") }) {
            t.assert(logItem.associatedPaths.contains(serverLog.path), "Orphaned log group contains server log")
        } else {
            t.assert(false, "Orphaned log item not found")
        }

        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            let freed = try await scanner.delete(items: [item1])
            t.assert(freed == item1.sizeInBytes, "Freed size matches item1 size")
            t.assert(!fm.fileExists(atPath: s1Dir.path), "Session 1 dir removed")
            t.assert(!fm.fileExists(atPath: s1Log.path), "Session 1 log removed")
            t.assert(!fm.fileExists(atPath: s1Ws.path), "Session 1 workspace removed")
            t.assert(fm.fileExists(atPath: s2File.path), "Session 2 file still exists")
            t.assert(fm.fileExists(atPath: serverLog.path), "server.log still exists")
        }

        let allFreed = try await scanner.cleanAll()
        t.assert(allFreed > 0, "cleanAll freed bytes > 0")
        items = try await scanner.scan()
        t.assert(items.isEmpty, "Rescan after cleanAll returns 0 items")
    } catch {
        t.assert(false, "Mock OpenHands test threw error: \(error)")
    }
}
