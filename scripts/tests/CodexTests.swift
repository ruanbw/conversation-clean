import Foundation
import SQLite3

func testMockCodexScanner() async {
    let t = TestCase("MockCodexScan", section: "Test 3: Mock Codex Scanner (Fixture Directory)")

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_codex_scan")

    defer {
        try? fm.removeItem(at: tempDir)
    }

    t.sub("Setting up Mock ~/.codex Structure")
    let sessionsDir = tempDir.appendingPathComponent("sessions")
    let archivedDir = tempDir.appendingPathComponent("archived_sessions")

    // Date nested folders: sessions/YYYY/MM/DD/
    let day1Dir = sessionsDir.appendingPathComponent("2026/09/20")
    let day2Dir = sessionsDir.appendingPathComponent("2026/09/25")
    let day3Dir = sessionsDir.appendingPathComponent("2026/09/26")
    let archiveDayDir = archivedDir.appendingPathComponent("2026/08/15")

    Fixture.dir(day1Dir)
    Fixture.dir(day2Dir)
    Fixture.dir(day3Dir)
    Fixture.dir(archiveDayDir)

    // Session 1: sessions/2026/09/20/session-codex-001.jsonl
    let sid1 = "session-codex-001"
    let s1File = day1Dir.appendingPathComponent("\(sid1).jsonl")
    let s1Content = """
    {"cwd":"/Users/tester/backend","role":"user","content":"Optimize SQL database query indexing"}
    {"role":"assistant","content":"I have analyzed the query plan and added indexes."}
    """
    Fixture.write(s1Content, to: s1File)

    // Session 2: sessions/2026/09/25/session-codex-002.jsonl
    let sid2 = "session-codex-002"
    let s2File = day2Dir.appendingPathComponent("\(sid2).jsonl")
    let s2Content = """
    {"project":"/Users/tester/auth-service","messages":[{"role":"user","content":"Implement JWT token expiration check"}]}
    {"role":"assistant","content":"Added expiration validation logic."}
    """
    Fixture.write(s2Content, to: s2File)

    // Session 3: sessions/2026/09/26/session-codex-003.jsonl
    let sid3 = "session-codex-003"
    let s3File = day3Dir.appendingPathComponent("\(sid3).jsonl")
    let s3Content = """
    {"working_directory":"/Users/tester/ios-cleaner","prompt":"Add dark mode support to SwiftUI sidebar"}
    """
    Fixture.write(s3Content, to: s3File)

    // Session 4: archived_sessions/2026/08/15/session-codex-archived.jsonl
    let sid4 = "session-codex-archived"
    let s4File = archiveDayDir.appendingPathComponent("\(sid4).jsonl")
    let s4Content = """
    {"role":"user","content":"Initial project scaffolding"}
    """
    Fixture.write(s4Content, to: s4File)

    // session_index.jsonl
    let indexFile = tempDir.appendingPathComponent("session_index.jsonl")
    let indexContent = """
    {"id":"\(sid1)","title":"SQL Index Optimization","cwd":"/Users/tester/backend","updated_at":1789900000000}
    {"id":"\(sid2)","filename":"\(sid2).jsonl","title":"Auth Service JWT Refresh","project":"/Users/tester/auth-service","timestamp":1790300000000}
    {"id":"\(sid3)","filename":"2026/09/26/\(sid3).jsonl","title":"SwiftUI Dark Mode","cwd":"/Users/tester/ios-cleaner","updated_at":1790400000000}
    """
    Fixture.write(indexContent, to: indexFile)

    t.sub("Executing Mock Codex Scanner")
    let scanner = CodexScanner(storageURL: tempDir)
    t.assert(scanner.isInstalled, "scanner.isInstalled is true for mock ~/.codex directory")
    t.assert(scanner.category == .codex, "Category is .codex")

    do {
        let items = try await scanner.scan()
        t.assert(items.count == 4, "Detected exactly 4 Codex sessions (found \(items.count))")

        // Verify session 1 (matched by id)
        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            t.assert(item1.title == "SQL Index Optimization", "Session 1 title matches index entry (\(item1.title))")
            t.assert(item1.projectPath == "/Users/tester/backend", "Session 1 projectPath matches index cwd")
            let canonAssociated = Set(item1.associatedPaths.map { TestRunner.canonicalPath($0) })
            t.assert(canonAssociated.contains(TestRunner.canonicalPath(s1File.path)), "Session 1 associatedPaths contains file")
            t.assert(item1.sizeInBytes == FileSizeHelper.sizeOf(path: s1File.path), "Session 1 sizeInBytes matches file size")
        } else {
            t.assert(false, "Session 1 (\(sid1)) not found")
        }

        // Verify session 2 (matched by filename)
        if let item2 = items.first(where: { $0.sessionId == sid2 }) {
            t.assert(item2.title == "Auth Service JWT Refresh", "Session 2 title matches index title (\(item2.title))")
            t.assert(item2.projectPath == "/Users/tester/auth-service", "Session 2 projectPath matches index project")
        } else {
            t.assert(false, "Session 2 (\(sid2)) not found")
        }

        // Verify session 3 (matched with nested date relative path in index)
        if let item3 = items.first(where: { $0.sessionId == sid3 }) {
            t.assert(item3.title == "SwiftUI Dark Mode", "Session 3 title matches index title with relative path (\(item3.title))")
            t.assert(item3.projectPath == "/Users/tester/ios-cleaner", "Session 3 projectPath matches working_directory")
        } else {
            t.assert(false, "Session 3 (\(sid3)) not found")
        }

        // Verify session 4 (from archived_sessions directory)
        if let item4 = items.first(where: { $0.sessionId == sid4 }) {
            t.assert(item4.title.contains("Initial project scaffolding"), "Archived session title parsed from user role content (\(item4.title))")
        } else {
            t.assert(false, "Archived session (\(sid4)) not found")
        }

        // Verify descending sort order
        var isSorted = true
        for i in 0..<(items.count - 1) {
            if items[i].updatedAt < items[i + 1].updatedAt {
                isSorted = false
                break
            }
        }
        t.assert(isSorted, "Codex items are sorted by updatedAt descending")

    } catch {
        t.assert(false, "Mock Codex scan threw error: \(error)")
    }
}
