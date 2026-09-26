import Foundation
import SQLite3

func testRealOpenVikingScannerReadOnly() async {
    let t = TestCase("RealOpenVikingReadOnly", section: "Test: Real Local ~/.openviking Scanner (READ-ONLY)")

    let scanner = OpenVikingScanner()
    t.assert(scanner.category == .openViking, "Category is .openViking")

    let homePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openviking").path
    t.assert(TestRunner.canonicalPath(scanner.storageURL.path) == TestRunner.canonicalPath(homePath), "storageURL correctly points to ~/.openviking")
    t.assert(scanner.isInstalled, "scanner.isInstalled is true on this Mac")

    do {
        let items = try await scanner.scan()
        t.assert(!items.isEmpty, "Detected real OpenViking sessions (count: \(items.count))")
        t.assert(items.count == 28, "Detected exactly 28 sessions from 975 files (found: \(items.count))")

        let totalMessages = items.reduce(0) { $0 + $1.messageCount }
        t.assert(totalMessages == 975, "Total message count matches 975 files in pending/ (found: \(totalMessages))")

        let allOpenViking = items.allSatisfy { $0.category == .openViking }
        t.assert(allOpenViking, "All scanned items have category .openViking")

        let allHaveSessionId = items.allSatisfy { !$0.sessionId.isEmpty }
        t.assert(allHaveSessionId, "All items have non-empty sessionId")

        var isSorted = true
        for i in 0..<(items.count - 1) {
            if items[i].updatedAt < items[i + 1].updatedAt {
                isSorted = false
                break
            }
        }
        t.assert(isSorted, "Items are sorted by updatedAt descending")

        if let sample = items.first {
            print("  \u{001B}[34m[INFO] Sample OpenViking Session:\u{001B}[0m")
            print("    ID: \(sample.sessionId)")
            print("    Title: \(sample.title)")
            print("    Project: \(sample.displayProjectPath)")
            print("    Messages: \(sample.messageCount)")
            print("    Size: \(sample.formattedSize)")
            print("    Date: \(sample.formattedDate)")
            print("    Paths: \(sample.associatedPaths.count) path(s)")
        }
    } catch {
        t.assert(false, "Real OpenViking scan threw error: \(error)")
    }
}

func testMockOpenVikingScanner() async {
    let t = TestCase("MockOpenViking", section: "Test: Mock OpenViking Scanner (Fixture Directory)")

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_openviking")
    defer { try? fm.removeItem(at: tempDir) }

    let pendingDir = tempDir.appendingPathComponent("pending")
    Fixture.dir(pendingDir)

    let sid1 = "dsh-session-test-0001"
    let sid2 = "dsh-session-test-0002"

    let f1Content = """
    {"type":"addMessage","sessionId":"\(sid1)","payload":{"role":"user","parts":[{"type":"text","text":"Optimize database queries"}],"peer_id":"-Users-tester-projects-backend"},"createdAt":1786888290000}
    """
    Fixture.write(f1Content, to: pendingDir.appendingPathComponent("f1.json"))

    let f2Content = """
    {"type":"addMessage","sessionId":"\(sid1)","payload":{"role":"assistant","parts":[{"type":"tool","tool_name":"bash"}]},"createdAt":1786888300000}
    """
    Fixture.write(f2Content, to: pendingDir.appendingPathComponent("f2.json"))

    let f3Content = """
    {"type":"commitSession","sessionId":"\(sid2)","payload":{"keep_recent_count":5},"createdAt":1786888400000}
    """
    Fixture.write(f3Content, to: pendingDir.appendingPathComponent("f3.json"))

    let scanner = OpenVikingScanner(storageURL: tempDir)
    t.assert(scanner.isInstalled, "Mock scanner isInstalled is true")

    do {
        var items = try await scanner.scan()
        t.assert(items.count == 2, "Detected 2 mock sessions (found: \(items.count))")

        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            t.assert(item1.title == "Optimize database queries", "Session 1 title matches user prompt")
            t.assert(item1.messageCount == 2, "Session 1 message count is 2")
            t.assert(item1.associatedPaths.count == 2, "Session 1 associatedPaths has 2 files")
            t.assert(item1.sizeInBytes > 0, "Session 1 size > 0")
        } else {
            t.assert(false, "Session 1 not found")
        }

        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            let freed = try await scanner.delete(items: [item1])
            t.assert(freed == item1.sizeInBytes, "Freed size matches item1 size")
            t.assert(!fm.fileExists(atPath: pendingDir.appendingPathComponent("f1.json").path), "f1.json removed")
            t.assert(!fm.fileExists(atPath: pendingDir.appendingPathComponent("f2.json").path), "f2.json removed")
            t.assert(fm.fileExists(atPath: pendingDir.appendingPathComponent("f3.json").path), "f3.json still exists")
        }

        let allFreed = try await scanner.cleanAll()
        t.assert(allFreed > 0, "cleanAll freed bytes > 0")
        items = try await scanner.scan()
        t.assert(items.isEmpty, "Rescan after cleanAll returns 0 items")
        t.assert(fm.fileExists(atPath: pendingDir.path), "pending/ folder recreated")
    } catch {
        t.assert(false, "Mock OpenViking test threw error: \(error)")
    }
}
