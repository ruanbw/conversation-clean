import Foundation
import SQLite3

// ============================================================================
// Agent Scanner Test & Quality Verification Suite
// ============================================================================
// Tests:
// 1. ClaudeCodeScanner against real local ~/.claude (READ-ONLY)
// 2. ClaudeCodeScanner against a mock fixture directory
// 3. CodexScanner against a mock ~/.codex fixture directory with
//    sessions in `sessions/YYYY/MM/DD/*.jsonl` and `session_index.jsonl`
// 4. Mock deletion tests (Claude Code, Codex, and AgentScanService)
// ============================================================================

struct TestRunner {
    static var passedCount = 0
    static var failedCount = 0
    static var failures: [String] = []

    static func assertTest(_ condition: Bool, _ message: String, testName: String) {
        if condition {
            passedCount += 1
            print("  \u{001B}[32m[PASS]\u{001B}[0m \(message)")
        } else {
            failedCount += 1
            let failMsg = "[\(testName)] \(message)"
            failures.append(failMsg)
            print("  \u{001B}[31m[FAIL]\u{001B}[0m \(message)")
        }
    }

    static func printSection(_ title: String) {
        print("\n\u{001B}[1;36m==================================================================")
        print(">>> \(title)")
        print("==================================================================\u{001B}[0m")
    }

    static func printSubSection(_ title: String) {
        print("\n\u{001B}[1;33m--- \(title) ---\u{001B}[0m")
    }

    static func canonicalPath(_ path: String) -> String {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ??
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func createTempDirectory(prefix: String) -> URL {
        let raw = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(prefix)_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let resolved = (try? raw.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? raw
        return resolved
    }
}

// MARK: - Test 1: Real Local Claude Code Scanner (READ-ONLY)

func testRealClaudeCodeScannerReadOnly() async {
    TestRunner.printSection("Test 1: Real Local ~/.claude Scanner (READ-ONLY)")

    let realScanner = ClaudeCodeScanner()
    let testName = "RealClaudeReadOnly"

    TestRunner.printSubSection("Checking Installation and Storage URL")
    let homePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
    TestRunner.assertTest(TestRunner.canonicalPath(realScanner.storageURL.path) == TestRunner.canonicalPath(homePath), "storageURL correctly points to ~/.claude", testName: testName)
    TestRunner.assertTest(realScanner.category == .claudeCode, "Category is .claudeCode", testName: testName)

    let isRealInstalled = FileManager.default.fileExists(atPath: realScanner.storageURL.path)
    TestRunner.assertTest(realScanner.isInstalled == isRealInstalled, "isInstalled matches filesystem check (\(isRealInstalled))", testName: testName)

    if !isRealInstalled {
        print("  \u{001B}[33m[INFO] ~/.claude not found on system. Skipping real file scan checks.\u{001B}[0m")
        return
    }

    TestRunner.printSubSection("Scanning Real Local ~/.claude (READ-ONLY)")
    do {
        let items = try await realScanner.scan()
        TestRunner.assertTest(true, "scan() executed without throwing an error", testName: testName)
        print("  \u{001B}[34m[INFO] Scanned \(items.count) sessions from real ~/.claude\u{001B}[0m")

        if !items.isEmpty {
            let totalBytes = items.reduce(0) { $0 + $1.sizeInBytes }
            let formattedTotal = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            print("  \u{001B}[34m[INFO] Total size of real sessions: \(formattedTotal) (\(totalBytes) bytes)\u{001B}[0m")

            // Verify category
            let allAreClaude = items.allSatisfy { $0.category == .claudeCode }
            TestRunner.assertTest(allAreClaude, "All items have category .claudeCode", testName: testName)

            // Verify non-empty sessionIds
            let allHaveSessionId = items.allSatisfy { !$0.sessionId.isEmpty }
            TestRunner.assertTest(allHaveSessionId, "All items have valid non-empty sessionId", testName: testName)

            // Verify descending sort order by updatedAt
            var isSorted = true
            for i in 0..<(items.count - 1) {
                if items[i].updatedAt < items[i + 1].updatedAt {
                    isSorted = false
                    break
                }
            }
            TestRunner.assertTest(isSorted, "Items are sorted by updatedAt descending", testName: testName)

            // Verify associated paths exist on disk
            var associatedPathsValid = true
            for item in items {
                if item.associatedPaths.isEmpty {
                    associatedPathsValid = false
                    break
                }
                for path in item.associatedPaths {
                    if !FileManager.default.fileExists(atPath: path) {
                        associatedPathsValid = false
                        break
                    }
                }
                if !associatedPathsValid { break }
            }
            TestRunner.assertTest(associatedPathsValid, "All associatedPaths exist on the real filesystem", testName: testName)

            // Sample first 3 items
            print("  \u{001B}[34m[INFO] Sample real sessions:\u{001B}[0m")
            for (idx, item) in items.prefix(3).enumerated() {
                print("    [\(idx + 1)] ID: \(item.shortSessionId)... | Size: \(item.formattedSize) | Title: \(item.title.prefix(50)) | Project: \(item.displayProjectPath)")
            }
        }
    } catch {
        TestRunner.assertTest(false, "scan() threw unexpected error: \(error)", testName: testName)
    }
}

// MARK: - Test 2: Mock Claude Code Scanner

func testMockClaudeCodeScanner() async {
    TestRunner.printSection("Test 2: Mock Claude Code Scanner (Fixture Directory)")
    let testName = "MockClaudeScan"

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_claude_scan")

    defer {
        try? fm.removeItem(at: tempDir)
    }

    TestRunner.printSubSection("Setting up Mock ~/.claude Structure")
    let projectsDir = tempDir.appendingPathComponent("projects")
    let projectADir = projectsDir.appendingPathComponent("-Users-tester-projectA")
    let projectBDir = projectsDir.appendingPathComponent("-Users-tester-projectB")
    let directSessionsDir = tempDir.appendingPathComponent("sessions")
    let fileHistoryDir = tempDir.appendingPathComponent("file-history")
    let plansDir = tempDir.appendingPathComponent("plans")
    let sessionEnvDir = tempDir.appendingPathComponent("session-env")

    try? fm.createDirectory(at: projectADir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: projectBDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: directSessionsDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: fileHistoryDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: plansDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: sessionEnvDir, withIntermediateDirectories: true)

    // Session 1 in projectA: has subagent dir, file-history, plan, session-env
    let sid1 = "claude-session-001"
    let s1File = projectADir.appendingPathComponent("\(sid1).jsonl")
    let s1Content = """
    {"cwd":"/Users/tester/projectA","gitBranch":"feature/auth","slug":"auth-system","type":"user","message":{"content":"Build authentication system with OAuth2"}}
    {"type":"assistant","message":{"content":"I will help you implement OAuth2."}}
    """
    try? s1Content.write(to: s1File, atomically: true, encoding: .utf8)

    // Subagent directory for s1
    let s1SubagentDir = projectADir.appendingPathComponent(sid1)
    try? fm.createDirectory(at: s1SubagentDir, withIntermediateDirectories: true)
    try? "subagent log data".write(to: s1SubagentDir.appendingPathComponent("subagent-1.jsonl"), atomically: true, encoding: .utf8)

    // Associated file-history for s1
    let s1FileHistDir = fileHistoryDir.appendingPathComponent(sid1)
    try? fm.createDirectory(at: s1FileHistDir, withIntermediateDirectories: true)
    try? "history backup content".write(to: s1FileHistDir.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

    // Associated plan for s1
    let s1PlanDir = plansDir.appendingPathComponent(sid1)
    try? fm.createDirectory(at: s1PlanDir, withIntermediateDirectories: true)
    try? "# OAuth Plan".write(to: s1PlanDir.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)

    // Associated session-env for s1
    let s1EnvDir = sessionEnvDir.appendingPathComponent(sid1)
    try? fm.createDirectory(at: s1EnvDir, withIntermediateDirectories: true)
    try? "{\"NODE_ENV\":\"test\"}".write(to: s1EnvDir.appendingPathComponent("env.json"), atomically: true, encoding: .utf8)

    // Session 2 in projectB: normal session with memory folder alongside
    let sid2 = "claude-session-002"
    let s2File = projectBDir.appendingPathComponent("\(sid2).jsonl")
    let s2Content = """
    {"cwd":"/Users/tester/projectB","gitBranch":"main","type":"user","message":{"content":[{"text":"Fix payment retry logic in checkout"}]}}
    {"type":"assistant","message":{"content":"Checking retry parameters."}}
    """
    try? s2Content.write(to: s2File, atomically: true, encoding: .utf8)
    let memoryDir = projectBDir.appendingPathComponent("memory")
    try? fm.createDirectory(at: memoryDir, withIntermediateDirectories: true)
    try? "Project memory data".write(to: memoryDir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

    // Session 3 in direct sessions/
    let sid3 = "claude-session-003"
    let s3File = directSessionsDir.appendingPathComponent("\(sid3).jsonl")
    let s3Content = """
    {"type":"user","message":{"content":"Quick explanation of Swift Concurrency"}}
    """
    try? s3Content.write(to: s3File, atomically: true, encoding: .utf8)

    // history.jsonl
    let historyFile = tempDir.appendingPathComponent("history.jsonl")
    let historyContent = """
    {"sessionId":"\(sid1)","display":"Build authentication system with OAuth2","project":"/Users/tester/projectA","timestamp":1700000000000}
    {"sessionId":"\(sid1)","display":"Add refresh token support","project":"/Users/tester/projectA","timestamp":1700000050000}
    {"sessionId":"\(sid2)","display":"Fix payment retry logic in checkout","project":"/Users/tester/projectB","timestamp":1700001000000}
    {"sessionId":"\(sid3)","display":"Quick explanation of Swift Concurrency","project":null,"timestamp":1700002000000}
    """
    try? historyContent.write(to: historyFile, atomically: true, encoding: .utf8)

    TestRunner.printSubSection("Executing Mock Claude Code Scanner")
    let scanner = ClaudeCodeScanner(storageURL: tempDir)
    TestRunner.assertTest(scanner.isInstalled, "scanner.isInstalled is true for fixture directory", testName: testName)

    do {
        let items = try await scanner.scan()
        TestRunner.assertTest(items.count == 3, "Detected exactly 3 Claude Code sessions (found \(items.count))", testName: testName)

        // Find session 1
        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            TestRunner.assertTest(item1.projectPath == "/Users/tester/projectA", "Session 1 projectPath matches /Users/tester/projectA", testName: testName)
            TestRunner.assertTest(item1.gitBranch == "feature/auth", "Session 1 gitBranch matches feature/auth", testName: testName)
            TestRunner.assertTest(item1.title.contains("Build authentication system"), "Session 1 title parsed correctly (\(item1.title))", testName: testName)
            TestRunner.assertTest(item1.messageCount == 2, "Session 1 messageCount matches history displays (2)", testName: testName)

            // Verify associated paths for session 1
            let canonAssociated = Set(item1.associatedPaths.map { TestRunner.canonicalPath($0) })
            let hasSessionFile = canonAssociated.contains(TestRunner.canonicalPath(s1File.path))
            let hasSubagent = canonAssociated.contains(TestRunner.canonicalPath(s1SubagentDir.path))
            let hasFileHist = canonAssociated.contains(TestRunner.canonicalPath(s1FileHistDir.path))
            let hasPlan = canonAssociated.contains(TestRunner.canonicalPath(s1PlanDir.path))
            let hasEnv = canonAssociated.contains(TestRunner.canonicalPath(s1EnvDir.path))
            TestRunner.assertTest(hasSessionFile && hasSubagent && hasFileHist && hasPlan && hasEnv,
                                  "Session 1 associatedPaths includes session file, subagent dir, file-history, plan, and session-env",
                                  testName: testName)

            // Verify calculated size matches sum of associated paths
            var calculatedExpected: Int64 = 0
            for p in item1.associatedPaths {
                calculatedExpected += FileSizeHelper.sizeOf(path: p)
            }
            TestRunner.assertTest(item1.sizeInBytes == calculatedExpected,
                                  "Session 1 sizeInBytes (\(item1.sizeInBytes)) matches sum of all associated paths (\(calculatedExpected))",
                                  testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 1 (\(sid1)) not found in scanned items", testName: testName)
        }

        // Find session 2
        if let item2 = items.first(where: { $0.sessionId == sid2 }) {
            TestRunner.assertTest(item2.projectPath == "/Users/tester/projectB", "Session 2 projectPath matches /Users/tester/projectB", testName: testName)
            TestRunner.assertTest(item2.gitBranch == "main", "Session 2 gitBranch matches main", testName: testName)
            TestRunner.assertTest(item2.title.contains("Fix payment retry logic"), "Session 2 title parsed from user message array (\(item2.title))", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 2 (\(sid2)) not found in scanned items", testName: testName)
        }

        // Find session 3
        if let item3 = items.first(where: { $0.sessionId == sid3 }) {
            TestRunner.assertTest(item3.title.contains("Swift Concurrency"), "Session 3 title parsed from direct session (\(item3.title))", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 3 (\(sid3)) not found in scanned items", testName: testName)
        }

    } catch {
        TestRunner.assertTest(false, "Mock Claude scan threw error: \(error)", testName: testName)
    }
}

// MARK: - Test 3: Mock Codex Scanner

func testMockCodexScanner() async {
    TestRunner.printSection("Test 3: Mock Codex Scanner (Fixture Directory)")
    let testName = "MockCodexScan"

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_codex_scan")

    defer {
        try? fm.removeItem(at: tempDir)
    }

    TestRunner.printSubSection("Setting up Mock ~/.codex Structure")
    let sessionsDir = tempDir.appendingPathComponent("sessions")
    let archivedDir = tempDir.appendingPathComponent("archived_sessions")

    // Date nested folders: sessions/YYYY/MM/DD/
    let day1Dir = sessionsDir.appendingPathComponent("2026/09/20")
    let day2Dir = sessionsDir.appendingPathComponent("2026/09/25")
    let day3Dir = sessionsDir.appendingPathComponent("2026/09/26")
    let archiveDayDir = archivedDir.appendingPathComponent("2026/08/15")

    try? fm.createDirectory(at: day1Dir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: day2Dir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: day3Dir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: archiveDayDir, withIntermediateDirectories: true)

    // Session 1: sessions/2026/09/20/session-codex-001.jsonl
    let sid1 = "session-codex-001"
    let s1File = day1Dir.appendingPathComponent("\(sid1).jsonl")
    let s1Content = """
    {"cwd":"/Users/tester/backend","role":"user","content":"Optimize SQL database query indexing"}
    {"role":"assistant","content":"I have analyzed the query plan and added indexes."}
    """
    try? s1Content.write(to: s1File, atomically: true, encoding: .utf8)

    // Session 2: sessions/2026/09/25/session-codex-002.jsonl
    let sid2 = "session-codex-002"
    let s2File = day2Dir.appendingPathComponent("\(sid2).jsonl")
    let s2Content = """
    {"project":"/Users/tester/auth-service","messages":[{"role":"user","content":"Implement JWT token expiration check"}]}
    {"role":"assistant","content":"Added expiration validation logic."}
    """
    try? s2Content.write(to: s2File, atomically: true, encoding: .utf8)

    // Session 3: sessions/2026/09/26/session-codex-003.jsonl
    let sid3 = "session-codex-003"
    let s3File = day3Dir.appendingPathComponent("\(sid3).jsonl")
    let s3Content = """
    {"working_directory":"/Users/tester/ios-cleaner","prompt":"Add dark mode support to SwiftUI sidebar"}
    """
    try? s3Content.write(to: s3File, atomically: true, encoding: .utf8)

    // Session 4: archived_sessions/2026/08/15/session-codex-archived.jsonl
    let sid4 = "session-codex-archived"
    let s4File = archiveDayDir.appendingPathComponent("\(sid4).jsonl")
    let s4Content = """
    {"role":"user","content":"Initial project scaffolding"}
    """
    try? s4Content.write(to: s4File, atomically: true, encoding: .utf8)

    // session_index.jsonl
    let indexFile = tempDir.appendingPathComponent("session_index.jsonl")
    let indexContent = """
    {"id":"\(sid1)","title":"SQL Index Optimization","cwd":"/Users/tester/backend","updated_at":1789900000000}
    {"id":"\(sid2)","filename":"\(sid2).jsonl","title":"Auth Service JWT Refresh","project":"/Users/tester/auth-service","timestamp":1790300000000}
    {"id":"\(sid3)","filename":"2026/09/26/\(sid3).jsonl","title":"SwiftUI Dark Mode","cwd":"/Users/tester/ios-cleaner","updated_at":1790400000000}
    """
    try? indexContent.write(to: indexFile, atomically: true, encoding: .utf8)

    TestRunner.printSubSection("Executing Mock Codex Scanner")
    let scanner = CodexScanner(storageURL: tempDir)
    TestRunner.assertTest(scanner.isInstalled, "scanner.isInstalled is true for mock ~/.codex directory", testName: testName)
    TestRunner.assertTest(scanner.category == .codex, "Category is .codex", testName: testName)

    do {
        let items = try await scanner.scan()
        TestRunner.assertTest(items.count == 4, "Detected exactly 4 Codex sessions (found \(items.count))", testName: testName)

        // Verify session 1 (matched by id)
        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            TestRunner.assertTest(item1.title == "SQL Index Optimization", "Session 1 title matches index entry (\(item1.title))", testName: testName)
            TestRunner.assertTest(item1.projectPath == "/Users/tester/backend", "Session 1 projectPath matches index cwd", testName: testName)
            let canonAssociated = Set(item1.associatedPaths.map { TestRunner.canonicalPath($0) })
            TestRunner.assertTest(canonAssociated.contains(TestRunner.canonicalPath(s1File.path)), "Session 1 associatedPaths contains file", testName: testName)
            TestRunner.assertTest(item1.sizeInBytes == FileSizeHelper.sizeOf(path: s1File.path), "Session 1 sizeInBytes matches file size", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 1 (\(sid1)) not found", testName: testName)
        }

        // Verify session 2 (matched by filename)
        if let item2 = items.first(where: { $0.sessionId == sid2 }) {
            TestRunner.assertTest(item2.title == "Auth Service JWT Refresh", "Session 2 title matches index title (\(item2.title))", testName: testName)
            TestRunner.assertTest(item2.projectPath == "/Users/tester/auth-service", "Session 2 projectPath matches index project", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 2 (\(sid2)) not found", testName: testName)
        }

        // Verify session 3 (matched with nested date relative path in index)
        if let item3 = items.first(where: { $0.sessionId == sid3 }) {
            TestRunner.assertTest(item3.title == "SwiftUI Dark Mode", "Session 3 title matches index title with relative path (\(item3.title))", testName: testName)
            TestRunner.assertTest(item3.projectPath == "/Users/tester/ios-cleaner", "Session 3 projectPath matches working_directory", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 3 (\(sid3)) not found", testName: testName)
        }

        // Verify session 4 (from archived_sessions directory)
        if let item4 = items.first(where: { $0.sessionId == sid4 }) {
            TestRunner.assertTest(item4.title.contains("Initial project scaffolding"), "Archived session title parsed from user role content (\(item4.title))", testName: testName)
        } else {
            TestRunner.assertTest(false, "Archived session (\(sid4)) not found", testName: testName)
        }

        // Verify descending sort order
        var isSorted = true
        for i in 0..<(items.count - 1) {
            if items[i].updatedAt < items[i + 1].updatedAt {
                isSorted = false
                break
            }
        }
        TestRunner.assertTest(isSorted, "Codex items are sorted by updatedAt descending", testName: testName)

    } catch {
        TestRunner.assertTest(false, "Mock Codex scan threw error: \(error)", testName: testName)
    }
}

// MARK: - Test 4: Mock Deletion Verification

func testMockDeletion() async {
    TestRunner.printSection("Test 4: Mock Deletion Verification")

    let fm = FileManager.default

    // ------------------------------------------------------------------------
    // Part 4A: Claude Code Deletion Test
    // ------------------------------------------------------------------------
    TestRunner.printSubSection("Part 4A: Claude Code Deletion Verification")
    let testClaudeDel = "ClaudeDeletion"
    let claudeDir = TestRunner.createTempDirectory(prefix: "mock_claude_del")
    defer { try? fm.removeItem(at: claudeDir) }

    let pDir = claudeDir.appendingPathComponent("projects/-Users-tester-deltest")
    let fHistDir = claudeDir.appendingPathComponent("file-history")
    let plansDir = claudeDir.appendingPathComponent("plans")
    let envDir = claudeDir.appendingPathComponent("session-env")

    try? fm.createDirectory(at: pDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: fHistDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: plansDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: envDir, withIntermediateDirectories: true)

    let cIdA = "claude-del-A"
    let cIdB = "claude-del-B"

    // Session A files
    let fileA = pDir.appendingPathComponent("\(cIdA).jsonl")
    try? "{\"type\":\"user\",\"message\":{\"content\":\"Delete test session A\"}}\n".write(to: fileA, atomically: true, encoding: .utf8)
    let subagentA = pDir.appendingPathComponent(cIdA)
    try? fm.createDirectory(at: subagentA, withIntermediateDirectories: true)
    try? "subagent log".write(to: subagentA.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
    let histA = fHistDir.appendingPathComponent(cIdA)
    try? fm.createDirectory(at: histA, withIntermediateDirectories: true)
    try? "backup data".write(to: histA.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let planA = plansDir.appendingPathComponent(cIdA)
    try? fm.createDirectory(at: planA, withIntermediateDirectories: true)
    try? "plan data".write(to: planA.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
    let envA = envDir.appendingPathComponent(cIdA)
    try? fm.createDirectory(at: envA, withIntermediateDirectories: true)
    try? "env data".write(to: envA.appendingPathComponent("env.json"), atomically: true, encoding: .utf8)

    // Session B files (simple)
    let fileB = pDir.appendingPathComponent("\(cIdB).jsonl")
    try? "{\"type\":\"user\",\"message\":{\"content\":\"Keep test session B\"}}\n".write(to: fileB, atomically: true, encoding: .utf8)

    // history.jsonl
    let cHistoryFile = claudeDir.appendingPathComponent("history.jsonl")
    let cHistContent = """
    {"sessionId":"\(cIdA)","display":"Delete test session A","project":"/Users/tester/deltest","timestamp":1700000000000}
    {"sessionId":"\(cIdB)","display":"Keep test session B","project":"/Users/tester/deltest","timestamp":1700001000000}
    """
    try? cHistContent.write(to: cHistoryFile, atomically: true, encoding: .utf8)

    let claudeScanner = ClaudeCodeScanner(storageURL: claudeDir)
    do {
        var items = try await claudeScanner.scan()
        TestRunner.assertTest(items.count == 2, "Initial scan detected 2 Claude sessions", testName: testClaudeDel)

        guard let itemA = items.first(where: { $0.sessionId == cIdA }),
              let itemB = items.first(where: { $0.sessionId == cIdB }) else {
            TestRunner.assertTest(false, "Could not find expected items A and B", testName: testClaudeDel)
            return
        }

        let expectedFreedA = itemA.sizeInBytes

        // Step 1: Delete item A only
        print("  \u{001B}[34m[INFO] Deleting session A (expected size: \(expectedFreedA) bytes)...\u{001B}[0m")
        let freedA = try await claudeScanner.delete(items: [itemA])
        TestRunner.assertTest(freedA == expectedFreedA, "Bytes freed (\(freedA)) matches item A size (\(expectedFreedA))", testName: testClaudeDel)

        // Verify session A files deleted
        TestRunner.assertTest(!fm.fileExists(atPath: fileA.path), "Session A jsonl removed", testName: testClaudeDel)
        TestRunner.assertTest(!fm.fileExists(atPath: subagentA.path), "Session A subagent dir removed", testName: testClaudeDel)
        TestRunner.assertTest(!fm.fileExists(atPath: histA.path), "Session A file-history dir removed", testName: testClaudeDel)
        TestRunner.assertTest(!fm.fileExists(atPath: planA.path), "Session A plan dir removed", testName: testClaudeDel)
        TestRunner.assertTest(!fm.fileExists(atPath: envA.path), "Session A session-env dir removed", testName: testClaudeDel)

        // Verify session B still exists
        TestRunner.assertTest(fm.fileExists(atPath: fileB.path), "Session B jsonl still exists", testName: testClaudeDel)

        // Verify history.jsonl cleaned
        let updatedHist = (try? String(contentsOf: cHistoryFile, encoding: .utf8)) ?? ""
        TestRunner.assertTest(!updatedHist.contains(cIdA), "history.jsonl no longer contains session A", testName: testClaudeDel)
        TestRunner.assertTest(updatedHist.contains(cIdB), "history.jsonl still contains session B", testName: testClaudeDel)

        // Rescan: exactly 1 item remaining
        items = try await claudeScanner.scan()
        TestRunner.assertTest(items.count == 1 && items.first?.sessionId == cIdB, "Rescan shows exactly 1 session remaining (session B)", testName: testClaudeDel)

        // Step 2: Delete item B
        print("  \u{001B}[34m[INFO] Deleting session B...\u{001B}[0m")
        let freedB = try await claudeScanner.delete(items: [itemB])
        TestRunner.assertTest(freedB == itemB.sizeInBytes, "Bytes freed (\(freedB)) matches item B size", testName: testClaudeDel)
        TestRunner.assertTest(!fm.fileExists(atPath: fileB.path), "Session B jsonl removed", testName: testClaudeDel)

        // Empty project directory should be cleaned up
        TestRunner.assertTest(!fm.fileExists(atPath: pDir.path), "Empty project directory was cleaned up", testName: testClaudeDel)

        // Rescan: 0 items
        items = try await claudeScanner.scan()
        TestRunner.assertTest(items.isEmpty, "Rescan after deleting all items returns 0 sessions", testName: testClaudeDel)

    } catch {
        TestRunner.assertTest(false, "Claude deletion test threw error: \(error)", testName: testClaudeDel)
    }

    // ------------------------------------------------------------------------
    // Part 4B: Codex Deletion Test
    // ------------------------------------------------------------------------
    TestRunner.printSubSection("Part 4B: Codex Deletion Verification")
    let testCodexDel = "CodexDeletion"
    let codexDir = TestRunner.createTempDirectory(prefix: "mock_codex_del")
    defer { try? fm.removeItem(at: codexDir) }

    let codexSessionsDir = codexDir.appendingPathComponent("sessions")
    let cDay1 = codexSessionsDir.appendingPathComponent("2026/09/01")
    let cDay2 = codexSessionsDir.appendingPathComponent("2026/09/02")
    try? fm.createDirectory(at: cDay1, withIntermediateDirectories: true)
    try? fm.createDirectory(at: cDay2, withIntermediateDirectories: true)

    let codexId1 = "codex-del-001"
    let codexId2 = "codex-del-002"

    let cFile1 = cDay1.appendingPathComponent("\(codexId1).jsonl")
    let cFile2 = cDay2.appendingPathComponent("\(codexId2).jsonl")

    try? "{\"role\":\"user\",\"content\":\"Codex deletion test 1\"}\n".write(to: cFile1, atomically: true, encoding: .utf8)
    try? "{\"role\":\"user\",\"content\":\"Codex deletion test 2\"}\n".write(to: cFile2, atomically: true, encoding: .utf8)

    let codexIndexFile = codexDir.appendingPathComponent("session_index.jsonl")
    let codexIndexContent = """
    {"id":"\(codexId1)","title":"Deletion Test 1","filename":"\(codexId1).jsonl","updated_at":1789000000000}
    {"id":"\(codexId2)","title":"Deletion Test 2","filename":"\(codexId2).jsonl","updated_at":1789100000000}
    """
    try? codexIndexContent.write(to: codexIndexFile, atomically: true, encoding: .utf8)

    let codexScanner = CodexScanner(storageURL: codexDir)
    do {
        var items = try await codexScanner.scan()
        TestRunner.assertTest(items.count == 2, "Initial scan detected 2 Codex sessions", testName: testCodexDel)

        guard let item1 = items.first(where: { $0.sessionId == codexId1 }),
              let item2 = items.first(where: { $0.sessionId == codexId2 }) else {
            TestRunner.assertTest(false, "Could not find expected items 1 and 2", testName: testCodexDel)
            return
        }

        // Delete item 1
        print("  \u{001B}[34m[INFO] Deleting Codex session 1...\u{001B}[0m")
        let freed1 = try await codexScanner.delete(items: [item1])
        TestRunner.assertTest(freed1 == item1.sizeInBytes, "Bytes freed (\(freed1)) matches item 1 size (\(item1.sizeInBytes))", testName: testCodexDel)
        TestRunner.assertTest(!fm.fileExists(atPath: cFile1.path), "Session 1 jsonl file removed", testName: testCodexDel)

        // Verify empty date folder removed
        TestRunner.assertTest(!fm.fileExists(atPath: cDay1.path), "Empty date folder 2026/09/01 cleaned up", testName: testCodexDel)

        // Verify session 2 file still exists
        TestRunner.assertTest(fm.fileExists(atPath: cFile2.path), "Session 2 jsonl file still exists", testName: testCodexDel)

        // Verify session_index.jsonl cleaned
        let updatedIndex = (try? String(contentsOf: codexIndexFile, encoding: .utf8)) ?? ""
        TestRunner.assertTest(!updatedIndex.contains(codexId1), "session_index.jsonl no longer contains session 1", testName: testCodexDel)
        TestRunner.assertTest(updatedIndex.contains(codexId2), "session_index.jsonl still contains session 2", testName: testCodexDel)

        // Rescan: exactly 1 item remaining
        items = try await codexScanner.scan()
        TestRunner.assertTest(items.count == 1 && items.first?.sessionId == codexId2, "Rescan shows exactly 1 session remaining (session 2)", testName: testCodexDel)

        // Delete item 2
        print("  \u{001B}[34m[INFO] Deleting Codex session 2...\u{001B}[0m")
        let freed2 = try await codexScanner.delete(items: [item2])
        TestRunner.assertTest(freed2 == item2.sizeInBytes, "Bytes freed (\(freed2)) matches item 2 size", testName: testCodexDel)
        TestRunner.assertTest(!fm.fileExists(atPath: cFile2.path), "Session 2 jsonl file removed", testName: testCodexDel)

        // Verify empty date folders cleaned up up to sessions root
        TestRunner.assertTest(!fm.fileExists(atPath: cDay2.path), "Empty date folder 2026/09/02 cleaned up", testName: testCodexDel)
        TestRunner.assertTest(!fm.fileExists(atPath: codexSessionsDir.appendingPathComponent("2026").path), "Empty parent year folder cleaned up", testName: testCodexDel)

        // Rescan: 0 items
        items = try await codexScanner.scan()
        TestRunner.assertTest(items.isEmpty, "Rescan after deleting all Codex items returns 0 sessions", testName: testCodexDel)

    } catch {
        TestRunner.assertTest(false, "Codex deletion test threw error: \(error)", testName: testCodexDel)
    }

    // ------------------------------------------------------------------------
    // Part 4C: AgentScanService Unified Multi-Agent Deletion
    // ------------------------------------------------------------------------
    TestRunner.printSubSection("Part 4C: AgentScanService Unified Scan & Deletion")
    let testService = "AgentScanServiceUnified"

    let unifiedClaudeDir = TestRunner.createTempDirectory(prefix: "unified_claude")
    let unifiedCodexDir = TestRunner.createTempDirectory(prefix: "unified_codex")
    defer {
        try? fm.removeItem(at: unifiedClaudeDir)
        try? fm.removeItem(at: unifiedCodexDir)
    }

    // Claude setup
    let uProj = unifiedClaudeDir.appendingPathComponent("projects/-Users-tester-app")
    try? fm.createDirectory(at: uProj, withIntermediateDirectories: true)
    let uClaudeFile = uProj.appendingPathComponent("u-claude-1.jsonl")
    try? "{\"type\":\"user\",\"message\":{\"content\":\"Unified test claude\"}}\n".write(to: uClaudeFile, atomically: true, encoding: .utf8)

    // Codex setup
    let uCodexDay = unifiedCodexDir.appendingPathComponent("sessions/2026/09/10")
    try? fm.createDirectory(at: uCodexDay, withIntermediateDirectories: true)
    let uCodexFile = uCodexDay.appendingPathComponent("u-codex-1.jsonl")
    try? "{\"role\":\"user\",\"content\":\"Unified test codex\"}\n".write(to: uCodexFile, atomically: true, encoding: .utf8)

    let mockClaude = ClaudeCodeScanner(storageURL: unifiedClaudeDir)
    let mockCodex = CodexScanner(storageURL: unifiedCodexDir)
    let scanService = AgentScanService(scanners: [mockClaude, mockCodex])

    // Scan all
    let allItems = await scanService.scanAll()
    TestRunner.assertTest(allItems.count == 2, "AgentScanService.scanAll() detected 2 items across both scanners", testName: testService)

    let agentInfos = scanService.getAgentInfos(from: allItems)
    let claudeInfo = agentInfos.first(where: { $0.category == .claudeCode })
    let codexInfo = agentInfos.first(where: { $0.category == .codex })

    TestRunner.assertTest(claudeInfo?.sessionCount == 1, "AgentInfo for Claude Code shows 1 session", testName: testService)
    TestRunner.assertTest(codexInfo?.sessionCount == 1, "AgentInfo for Codex shows 1 session", testName: testService)

    let totalExpectedSize = allItems.reduce(0) { $0 + $1.sizeInBytes }
    let totalFreed = await scanService.delete(items: allItems)
    TestRunner.assertTest(totalFreed == totalExpectedSize, "AgentScanService.delete() freed all bytes (\(totalFreed) == \(totalExpectedSize))", testName: testService)

    // Verify disk files removed
    TestRunner.assertTest(!fm.fileExists(atPath: uClaudeFile.path), "Unified Claude session file removed from disk", testName: testService)
    TestRunner.assertTest(!fm.fileExists(atPath: uCodexFile.path), "Unified Codex session file removed from disk", testName: testService)

    // Rescan all
    let remaining = await scanService.scanAll()
    TestRunner.assertTest(remaining.isEmpty, "AgentScanService.scanAll() after deletion returns 0 items", testName: testService)
}

// MARK: - Test 5: Real Local Cline Scanner (READ-ONLY)

func testRealClineScannerReadOnly() async {
    TestRunner.printSection("Test 5: Real Local Cline Scanner (READ-ONLY)")

    let realScanner = ClineScanner()
    let testName = "RealClineReadOnly"

    TestRunner.printSubSection("Checking Installation and Storage URL")
    let homePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev").path
    TestRunner.assertTest(TestRunner.canonicalPath(realScanner.storageURL.path) == TestRunner.canonicalPath(homePath), "storageURL correctly points to Cline directory", testName: testName)
    TestRunner.assertTest(realScanner.category == .cline, "Category is .cline", testName: testName)

    let isRealInstalled = FileManager.default.fileExists(atPath: realScanner.storageURL.path)
    TestRunner.assertTest(realScanner.isInstalled == isRealInstalled, "isInstalled matches filesystem check (\(isRealInstalled))", testName: testName)

    if !isRealInstalled {
        print("  \u{001B}[33m[INFO] Cline storage not found on system. Skipping real file scan checks.\u{001B}[0m")
        return
    }

    TestRunner.printSubSection("Scanning Real Local Cline Tasks (READ-ONLY)")
    do {
        let items = try await realScanner.scan()
        TestRunner.assertTest(true, "scan() executed without throwing an error", testName: testName)
        print("  \u{001B}[34m[INFO] Scanned \(items.count) sessions from real Cline\u{001B}[0m")

        if !items.isEmpty {
            let totalBytes = items.reduce(0) { $0 + $1.sizeInBytes }
            let formattedTotal = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            print("  \u{001B}[34m[INFO] Total size of real Cline sessions: \(formattedTotal) (\(totalBytes) bytes)\u{001B}[0m")

            // Verify task 1790252321985
            if let task = items.first(where: { $0.sessionId == "1790252321985" }) {
                TestRunner.assertTest(task.title == "hello", "Task 1790252321985 title is 'hello' (found: '\(task.title)')", testName: testName)
                TestRunner.assertTest(task.projectPath == "/Users/ruanbw/projects/bennett-usage", "Task 1790252321985 cwd is '/Users/ruanbw/projects/bennett-usage' (found: '\(task.projectPath ?? "nil")')", testName: testName)
                TestRunner.assertTest(task.messageCount == 10, "Task 1790252321985 messageCount is 10 (found: \(task.messageCount))", testName: testName)
                TestRunner.assertTest(task.sizeInBytes > 0, "Task 1790252321985 sizeInBytes > 0 (\(task.sizeInBytes) bytes)", testName: testName)
                TestRunner.assertTest(task.category == .cline, "Task category is .cline", testName: testName)
                let calendar = Calendar.current
                let year = calendar.component(.year, from: task.updatedAt)
                TestRunner.assertTest(year >= 2024, "Task updatedAt has valid recent year (\(year))", testName: testName)
            } else {
                TestRunner.assertTest(false, "Did not find expected task 1790252321985 in real Cline scan", testName: testName)
            }

            // Verify all items have valid associatedPaths that exist on disk
            var associatedPathsValid = true
            for item in items {
                for path in item.associatedPaths {
                    if !FileManager.default.fileExists(atPath: path) {
                        associatedPathsValid = false
                        break
                    }
                }
            }
            TestRunner.assertTest(associatedPathsValid, "All associatedPaths exist on the real filesystem", testName: testName)

            // Print sample info
            for item in items {
                print("    ID: \(item.sessionId) | Title: \(item.title) | Cwd: \(item.displayProjectPath) | Msgs: \(item.messageCount) | Size: \(item.formattedSize) | Date: \(item.formattedDate)")
            }
        }
    } catch {
        TestRunner.assertTest(false, "scan() threw unexpected error: \(error)", testName: testName)
    }
}

// MARK: - Test 6: Mock Cline Scanner (Fixture Directory)

func testMockClineScanner() async {
    TestRunner.printSection("Test 6: Mock Cline Scanner (Fixture Directory)")
    let testName = "MockClineScan"

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_cline_scan")
    defer { try? fm.removeItem(at: tempDir) }

    TestRunner.printSubSection("Setting up Mock Cline Storage Structure")
    let tasksDir = tempDir.appendingPathComponent("tasks")
    let checkpointsDir = tempDir.appendingPathComponent("checkpoints")
    let stateDir = tempDir.appendingPathComponent("state")
    let cacheDir = tempDir.appendingPathComponent("cache")

    try? fm.createDirectory(at: tasksDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

    // Task 1: has ui_messages, task_metadata, api_conversation_history, and checkpoints
    let t1Id = "cline-task-001"
    let t1Dir = tasksDir.appendingPathComponent(t1Id)
    let t1CpDir = checkpointsDir.appendingPathComponent(t1Id)
    try? fm.createDirectory(at: t1Dir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: t1CpDir, withIntermediateDirectories: true)
    try? "checkpoint git commit data".write(to: t1CpDir.appendingPathComponent("commit.dat"), atomically: true, encoding: .utf8)

    let t1UiMessages = """
    [
      {"ts": 1789000000000, "type": "say", "say": "task", "text": "Refactor Swift Concurrency Actors"},
      {"ts": 1789000005000, "type": "say", "say": "text", "text": "Analyzing codebase actors..."},
      {"ts": 1789000010000, "type": "say", "say": "completion_result", "text": "Refactor completed."}
    ]
    """
    try? t1UiMessages.write(to: t1Dir.appendingPathComponent("ui_messages.json"), atomically: true, encoding: .utf8)

    let t1Metadata = """
    {
      "files_in_context": ["/Users/tester/actor-demo/Sources/Actor.swift"],
      "model_usage": [{"ts": 1789000000000, "model_id": "claude-3-5-sonnet", "mode": "act"}]
    }
    """
    try? t1Metadata.write(to: t1Dir.appendingPathComponent("task_metadata.json"), atomically: true, encoding: .utf8)

    let t1ApiHistory = """
    [
      {"role": "user", "content": "# Current Working Directory (/Users/tester/actor-demo) Files\\nRefactor actors"},
      {"role": "assistant", "content": "I will update Actor.swift"}
    ]
    """
    try? t1ApiHistory.write(to: t1Dir.appendingPathComponent("api_conversation_history.json"), atomically: true, encoding: .utf8)

    // Task 2: uses taskHistory.json for cwd and title
    let t2Id = "cline-task-002"
    let t2Dir = tasksDir.appendingPathComponent(t2Id)
    try? fm.createDirectory(at: t2Dir, withIntermediateDirectories: true)
    let t2UiMessages = """
    [
      {"ts": 1789100000000, "type": "say", "say": "task", "text": "Build REST API Client in Go"}
    ]
    """
    try? t2UiMessages.write(to: t2Dir.appendingPathComponent("ui_messages.json"), atomically: true, encoding: .utf8)

    // state/taskHistory.json
    let taskHistoryContent = """
    [
      {
        "id": "\(t1Id)",
        "task": "Refactor Swift Concurrency Actors",
        "cwdOnTaskInitialization": "/Users/tester/actor-demo",
        "ts": 1789000010000,
        "size": 500
      },
      {
        "id": "\(t2Id)",
        "task": "Build REST API Client in Go",
        "cwdOnTaskInitialization": "/Users/tester/go-api",
        "ts": 1789100000000,
        "size": 250
      }
    ]
    """
    try? taskHistoryContent.write(to: stateDir.appendingPathComponent("taskHistory.json"), atomically: true, encoding: .utf8)

    // Cache file
    try? "catalog data".write(to: cacheDir.appendingPathComponent("catalog.json"), atomically: true, encoding: .utf8)

    TestRunner.printSubSection("Executing Mock Cline Scanner")
    let scanner = ClineScanner(storageURL: tempDir)
    TestRunner.assertTest(scanner.isInstalled, "scanner.isInstalled is true for fixture directory", testName: testName)
    TestRunner.assertTest(scanner.category == .cline, "Category is .cline", testName: testName)

    do {
        var items = try await scanner.scan()
        TestRunner.assertTest(items.count == 2, "Detected exactly 2 Cline tasks (found \(items.count))", testName: testName)

        // Verify task 1
        if let item1 = items.first(where: { $0.sessionId == t1Id }) {
            TestRunner.assertTest(item1.title == "Refactor Swift Concurrency Actors", "Task 1 title matches prompt (\(item1.title))", testName: testName)
            TestRunner.assertTest(item1.projectPath == "/Users/tester/actor-demo", "Task 1 cwd matches /Users/tester/actor-demo", testName: testName)
            TestRunner.assertTest(item1.messageCount == 3, "Task 1 messageCount is 3", testName: testName)
            let canonPaths = Set(item1.associatedPaths.map { TestRunner.canonicalPath($0) })
            TestRunner.assertTest(canonPaths.contains(TestRunner.canonicalPath(t1Dir.path)), "Task 1 associatedPaths contains task directory", testName: testName)
            TestRunner.assertTest(canonPaths.contains(TestRunner.canonicalPath(t1CpDir.path)), "Task 1 associatedPaths contains checkpoint directory", testName: testName)
            let calculatedSize = FileSizeHelper.sizeOf(path: t1Dir.path) + FileSizeHelper.sizeOf(path: t1CpDir.path)
            TestRunner.assertTest(item1.sizeInBytes == calculatedSize, "Task 1 size matches sum of task dir + checkpoints (\(item1.sizeInBytes) == \(calculatedSize))", testName: testName)
        } else {
            TestRunner.assertTest(false, "Task 1 not found", testName: testName)
        }

        // Verify task 2
        if let item2 = items.first(where: { $0.sessionId == t2Id }) {
            TestRunner.assertTest(item2.title == "Build REST API Client in Go", "Task 2 title matches prompt (\(item2.title))", testName: testName)
            TestRunner.assertTest(item2.projectPath == "/Users/tester/go-api", "Task 2 cwd matches /Users/tester/go-api", testName: testName)
        } else {
            TestRunner.assertTest(false, "Task 2 not found", testName: testName)
        }

        // Deletion test: delete item 1
        print("  \u{001B}[34m[INFO] Deleting Cline Task 1...\u{001B}[0m")
        if let item1 = items.first(where: { $0.sessionId == t1Id }) {
            let freed = try await scanner.delete(items: [item1])
            TestRunner.assertTest(freed == item1.sizeInBytes, "Freed size (\(freed)) matches item 1 size (\(item1.sizeInBytes))", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: t1Dir.path), "Task 1 folder removed from disk", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: t1CpDir.path), "Task 1 checkpoint folder removed from disk", testName: testName)

            // Verify taskHistory.json updated
            let histFile = stateDir.appendingPathComponent("taskHistory.json")
            let histStr = (try? String(contentsOf: histFile, encoding: .utf8)) ?? ""
            TestRunner.assertTest(!histStr.contains(t1Id), "taskHistory.json no longer contains Task 1", testName: testName)
            TestRunner.assertTest(histStr.contains(t2Id), "taskHistory.json still contains Task 2", testName: testName)

            // Rescan shows 1 item
            items = try await scanner.scan()
            TestRunner.assertTest(items.count == 1 && items.first?.sessionId == t2Id, "Rescan shows 1 task remaining", testName: testName)
        }

        // Clean all test
        print("  \u{001B}[34m[INFO] Calling scanner.cleanAll()...\u{001B}[0m")
        let totalFreed = try await scanner.cleanAll()
        TestRunner.assertTest(totalFreed > 0, "cleanAll() returned freed bytes (\(totalFreed))", testName: testName)
        items = try await scanner.scan()
        TestRunner.assertTest(items.isEmpty, "Rescan after cleanAll returns 0 tasks", testName: testName)

    } catch {
        TestRunner.assertTest(false, "Mock Cline scan threw error: \(error)", testName: testName)
    }
}

// MARK: - Test 7: Mock Roo Code Scanner (Fixture Directory)

func testMockRooCodeScanner() async {
    TestRunner.printSection("Test 7: Mock Roo Code Scanner (Fixture Directory)")
    let testName = "MockRooCodeScan"

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_roocode_scan")
    defer { try? fm.removeItem(at: tempDir) }

    let tasksDir = tempDir.appendingPathComponent("tasks")
    let stateDir = tempDir.appendingPathComponent("state")
    let checkpointsDir = tempDir.appendingPathComponent("checkpoints")
    try? fm.createDirectory(at: tasksDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)

    let rooTaskId = "roo-task-001"
    let rooTaskDir = tasksDir.appendingPathComponent(rooTaskId)
    try? fm.createDirectory(at: rooTaskDir, withIntermediateDirectories: true)

    let uiMsg = """
    [
      {"ts": 1789200000000, "type": "say", "say": "task", "text": "Migrate database schema to PostgreSQL"},
      {"ts": 1789200005000, "type": "say", "say": "text", "text": "Generated migrations in # Current Working Directory (/Users/tester/data-store) Files"}
    ]
    """
    try? uiMsg.write(to: rooTaskDir.appendingPathComponent("ui_messages.json"), atomically: true, encoding: .utf8)

    let scanner = RooCodeScanner(storageURL: tempDir)
    TestRunner.assertTest(scanner.isInstalled, "RooCodeScanner.isInstalled is true for fixture", testName: testName)
    TestRunner.assertTest(scanner.category == .rooCode, "Category is .rooCode", testName: testName)

    do {
        let items = try await scanner.scan()
        TestRunner.assertTest(items.count == 1, "Detected 1 Roo Code task", testName: testName)
        if let item = items.first {
            TestRunner.assertTest(item.category == .rooCode, "Item category is .rooCode", testName: testName)
            TestRunner.assertTest(item.title == "Migrate database schema to PostgreSQL", "Title matches prompt (\(item.title))", testName: testName)
            TestRunner.assertTest(item.projectPath == "/Users/tester/data-store", "Extracted cwd matches /Users/tester/data-store", testName: testName)
            TestRunner.assertTest(item.messageCount == 2, "Message count is 2", testName: testName)
        }

        // Test delete
        let freed = try await scanner.delete(items: items)
        TestRunner.assertTest(freed > 0, "RooCodeScanner.delete freed bytes (\(freed))", testName: testName)
        let remaining = try await scanner.scan()
        TestRunner.assertTest(remaining.isEmpty, "Rescan after delete returns 0 items", testName: testName)
    } catch {
        TestRunner.assertTest(false, "Mock Roo Code scan threw error: \(error)", testName: testName)
    }
}

// MARK: - Test 8: Mock Continue.dev Scanner (Fixture Directory)

func testMockContinueScanner() async {
    TestRunner.printSection("Test 8: Mock Continue.dev Scanner (Fixture Directory)")
    let testName = "MockContinueScan"

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_continue_scan")
    defer { try? fm.removeItem(at: tempDir) }

    TestRunner.printSubSection("Setting up Mock ~/.continue Structure")
    let sessionsDir = tempDir.appendingPathComponent("sessions")
    let indexDir = tempDir.appendingPathComponent("index")
    let cacheDir = tempDir.appendingPathComponent("cache")
    try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: indexDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

    // User configuration file (must NOT be deleted by cleanAll!)
    let configFile = tempDir.appendingPathComponent("config.json")
    try? "{\"models\":[{\"title\":\"GPT-4o\"}]}".write(to: configFile, atomically: true, encoding: .utf8)

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
    try? s1Content.write(to: s1File, atomically: true, encoding: .utf8)

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
    try? s2Content.write(to: s2File, atomically: true, encoding: .utf8)

    // Index data
    try? "sqlite index data".write(to: indexDir.appendingPathComponent("index.db"), atomically: true, encoding: .utf8)

    TestRunner.printSubSection("Executing Mock Continue.dev Scanner")
    let scanner = ContinueScanner(storageURL: tempDir)
    TestRunner.assertTest(scanner.isInstalled, "ContinueScanner.isInstalled is true for fixture", testName: testName)
    TestRunner.assertTest(scanner.category == .continueDev, "Category is .continueDev", testName: testName)

    do {
        var items = try await scanner.scan()
        TestRunner.assertTest(items.count == 2, "Detected exactly 2 Continue sessions (found \(items.count))", testName: testName)

        // Verify session 1
        if let item1 = items.first(where: { $0.sessionId == s1Id }) {
            TestRunner.assertTest(item1.category == .continueDev, "Session 1 category is .continueDev", testName: testName)
            TestRunner.assertTest(item1.title == "Implement Redis Caching Layer", "Session 1 title matches explicit title (\(item1.title))", testName: testName)
            TestRunner.assertTest(item1.projectPath == "/Users/tester/api-gateway", "Session 1 workspace matches /Users/tester/api-gateway", testName: testName)
            TestRunner.assertTest(item1.messageCount == 2, "Session 1 message count is 2", testName: testName)
            TestRunner.assertTest(item1.sizeInBytes == FileSizeHelper.sizeOf(path: s1File.path), "Session 1 size matches file size", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 1 not found", testName: testName)
        }

        // Verify session 2
        if let item2 = items.first(where: { $0.sessionId == s2Id }) {
            TestRunner.assertTest(item2.title == "Create a responsive sidebar navigation with SwiftUI", "Session 2 title inferred from user prompt (\(item2.title))", testName: testName)
            TestRunner.assertTest(item2.projectPath == "/Users/tester/web-client", "Session 2 workspace matches /Users/tester/web-client", testName: testName)
            TestRunner.assertTest(item2.messageCount == 2, "Session 2 message count is 2", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 2 not found", testName: testName)
        }

        // Deletion test: delete item 1
        print("  \u{001B}[34m[INFO] Deleting Continue session 1...\u{001B}[0m")
        if let item1 = items.first(where: { $0.sessionId == s1Id }) {
            let freed = try await scanner.delete(items: [item1])
            TestRunner.assertTest(freed == item1.sizeInBytes, "Freed size (\(freed)) matches item 1 size (\(item1.sizeInBytes))", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: s1File.path), "Session 1 file removed from disk", testName: testName)
            TestRunner.assertTest(fm.fileExists(atPath: s2File.path), "Session 2 file still exists on disk", testName: testName)

            items = try await scanner.scan()
            TestRunner.assertTest(items.count == 1 && items.first?.sessionId == s2Id, "Rescan shows 1 session remaining", testName: testName)
        }

        // Clean all test
        print("  \u{001B}[34m[INFO] Calling Continue cleanAll()...\u{001B}[0m")
        let freedAll = try await scanner.cleanAll()
        TestRunner.assertTest(freedAll > 0, "cleanAll() returned freed bytes (\(freedAll))", testName: testName)

        // Verify sessions cleared
        items = try await scanner.scan()
        TestRunner.assertTest(items.isEmpty, "Rescan after cleanAll returns 0 sessions", testName: testName)

        // Verify config.json preserved!
        TestRunner.assertTest(fm.fileExists(atPath: configFile.path), "config.json was safely preserved and NOT deleted", testName: testName)

    } catch {
        TestRunner.assertTest(false, "Mock Continue scan threw error: \(error)", testName: testName)
    }
}

// MARK: - Test 9: Unified Multi-Agent Scan (5 Scanners)

func testUnifiedMultiAgentScan() async {
    TestRunner.printSection("Test 9: Unified Multi-Agent Scan (5 Scanners)")
    let testName = "UnifiedFiveAgents"

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
    try? fm.createDirectory(at: claudeP, withIntermediateDirectories: true)
    try? "{\"type\":\"user\",\"message\":{\"content\":\"Claude 6-agent test\"}}\n".write(to: claudeP.appendingPathComponent("s-claude.jsonl"), atomically: true, encoding: .utf8)

    // 2. Codex session
    let codexDay = tempCodex.appendingPathComponent("sessions/2026/09/20")
    try? fm.createDirectory(at: codexDay, withIntermediateDirectories: true)
    try? "{\"role\":\"user\",\"content\":\"Codex 6-agent test\"}\n".write(to: codexDay.appendingPathComponent("s-codex.jsonl"), atomically: true, encoding: .utf8)

    // 3. Cline session
    let clineTasks = tempCline.appendingPathComponent("tasks/s-cline")
    try? fm.createDirectory(at: clineTasks, withIntermediateDirectories: true)
    try? "[{\"ts\":1789000000000,\"type\":\"say\",\"say\":\"task\",\"text\":\"Cline 6-agent test\"}]".write(to: clineTasks.appendingPathComponent("ui_messages.json"), atomically: true, encoding: .utf8)

    // 4. Roo Code session
    let rooTasks = tempRoo.appendingPathComponent("tasks/s-roo")
    try? fm.createDirectory(at: rooTasks, withIntermediateDirectories: true)
    try? "[{\"ts\":1789000000000,\"type\":\"say\",\"say\":\"task\",\"text\":\"Roo Code 6-agent test\"}]".write(to: rooTasks.appendingPathComponent("ui_messages.json"), atomically: true, encoding: .utf8)

    // 5. Continue session
    let contSessions = tempContinue.appendingPathComponent("sessions")
    try? fm.createDirectory(at: contSessions, withIntermediateDirectories: true)
    let contJson = "{\"sessionId\":\"s-cont\",\"title\":\"Continue 6-agent test\",\"workspaceDirectory\":\"/Users/u5/cont\",\"dateCreated\":\"2026-09-20T10:00:00Z\",\"history\":[]}"
    try? contJson.write(to: contSessions.appendingPathComponent("s-cont.json"), atomically: true, encoding: .utf8)

    // 6. Pi Agent session
    let piProj = tempPi.appendingPathComponent("agent/sessions/--Users-u6-pi--")
    try? fm.createDirectory(at: piProj, withIntermediateDirectories: true)
    let piSid = "01a00000-0000-7000-8000-000000000099"
    let piJson = """
    {"type":"session","version":3,"id":"\(piSid)","timestamp":"2026-09-20T10:00:00.000Z","cwd":"/Users/u6/pi"}
    {"type":"message","id":"msg1","message":{"role":"user","content":[{"type":"text","text":"Pi Agent 6-agent test"}]}}
    """
    try? piJson.write(to: piProj.appendingPathComponent("2026-09-20T10-00-00-000Z_\(piSid).jsonl"), atomically: true, encoding: .utf8)

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
    TestRunner.assertTest(allItems.count == 6, "scanAll() detected 6 items across all 6 scanners (found \(allItems.count))", testName: testName)

    let categoriesFound = Set(allItems.map { $0.category })
    TestRunner.assertTest(categoriesFound.contains(.claudeCode), "Contains .claudeCode", testName: testName)
    TestRunner.assertTest(categoriesFound.contains(.codex), "Contains .codex", testName: testName)
    TestRunner.assertTest(categoriesFound.contains(.cline), "Contains .cline", testName: testName)
    TestRunner.assertTest(categoriesFound.contains(.rooCode), "Contains .rooCode", testName: testName)
    TestRunner.assertTest(categoriesFound.contains(.continueDev), "Contains .continueDev", testName: testName)
    TestRunner.assertTest(categoriesFound.contains(.piAgent), "Contains .piAgent", testName: testName)

    let infos = scanService.getAgentInfos(from: allItems)
    TestRunner.assertTest(infos.count == 6, "AgentScanService.getAgentInfos() returned 6 infos", testName: testName)
    for info in infos {
        TestRunner.assertTest(info.sessionCount == 1, "\(info.category.rawValue) shows exactly 1 session", testName: testName)
    }

    let totalExpectedSize = allItems.reduce(0) { $0 + $1.sizeInBytes }
    let freed = await scanService.delete(items: allItems)
    TestRunner.assertTest(freed == totalExpectedSize, "scanService.delete() freed all bytes (\(freed) == \(totalExpectedSize))", testName: testName)

    let remaining = await scanService.scanAll()
    TestRunner.assertTest(remaining.isEmpty, "Rescan after deleting all 6 returns 0 items", testName: testName)
}

// MARK: - Test: Real Local Pi Agent Scanner (READ-ONLY)

func testRealPiAgentScannerReadOnly() async {
    TestRunner.printSection("Test: Real Local ~/.pi Scanner (READ-ONLY)")

    let realScanner = PiAgentScanner()
    let testName = "RealPiReadOnly"

    TestRunner.printSubSection("Checking Installation and Storage URL")
    let homePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi").path
    TestRunner.assertTest(TestRunner.canonicalPath(realScanner.storageURL.path) == TestRunner.canonicalPath(homePath), "storageURL correctly points to ~/.pi", testName: testName)
    TestRunner.assertTest(realScanner.category == .piAgent, "Category is .piAgent", testName: testName)

    let isRealInstalled = FileManager.default.fileExists(atPath: realScanner.storageURL.path)
    TestRunner.assertTest(realScanner.isInstalled == isRealInstalled, "isInstalled matches filesystem check (\(isRealInstalled))", testName: testName)

    if !isRealInstalled {
        print("  \u{001B}[33m[INFO] ~/.pi not found on system. Skipping real file scan checks.\u{001B}[0m")
        return
    }

    TestRunner.printSubSection("Scanning Real Local ~/.pi Sessions (READ-ONLY)")
    do {
        let items = try await realScanner.scan()
        TestRunner.assertTest(true, "scan() executed without throwing an error", testName: testName)
        print("  \u{001B}[34m[INFO] Scanned \(items.count) sessions from real ~/.pi\u{001B}[0m")

        if !items.isEmpty {
            let totalBytes = items.reduce(0) { $0 + $1.sizeInBytes }
            let formattedTotal = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            print("  \u{001B}[34m[INFO] Total size of real Pi sessions: \(formattedTotal) (\(totalBytes) bytes)\u{001B}[0m")

            // Verify category
            let allArePi = items.allSatisfy { $0.category == .piAgent }
            TestRunner.assertTest(allArePi, "All items have category .piAgent", testName: testName)

            // Verify non-empty sessionIds
            let allHaveSessionId = items.allSatisfy { !$0.sessionId.isEmpty }
            TestRunner.assertTest(allHaveSessionId, "All items have valid non-empty sessionId", testName: testName)

            // Verify descending sort order by updatedAt
            var isSorted = true
            for i in 0..<(items.count - 1) {
                if items[i].updatedAt < items[i + 1].updatedAt {
                    isSorted = false
                    break
                }
            }
            TestRunner.assertTest(isSorted, "Items are sorted by updatedAt descending", testName: testName)

            // Verify title extraction
            let withTitle = items.filter { !$0.title.isEmpty }
            TestRunner.assertTest(withTitle.count == items.count, "All items have non-empty titles", testName: testName)

            // Verify messageCount > 0
            let validMsgCount = items.allSatisfy { $0.messageCount > 0 }
            TestRunner.assertTest(validMsgCount, "All items have messageCount > 0", testName: testName)

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
            TestRunner.assertTest(pathsValid, "Associated paths for sampled items exist on disk", testName: testName)

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
        TestRunner.assertTest(false, "scan() threw error: \(error)", testName: testName)
    }
}

// MARK: - Test: Mock Pi Agent Scanner & Cleanup

func testMockPiAgentScanner() async {
    TestRunner.printSection("Test: Mock Pi Agent Scanner & Cleanup")
    let testName = "MockPiAgent"

    let tempDir = TestRunner.createTempDirectory(prefix: "pi_mock")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fm = FileManager.default

    let projA = tempDir.appendingPathComponent("agent/sessions/--Users-mock-projectA--")
    let projB = tempDir.appendingPathComponent("agent/sessions/--Users-mock-projectB--")
    let tasksDir = tempDir.appendingPathComponent("tasks")
    let contextModeDir = tempDir.appendingPathComponent("context-mode")
    let webCacheDir = tempDir.appendingPathComponent("web-search-cache")

    try? fm.createDirectory(at: projA, withIntermediateDirectories: true)
    try? fm.createDirectory(at: projB, withIntermediateDirectories: true)
    try? fm.createDirectory(at: tasksDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: contextModeDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: webCacheDir, withIntermediateDirectories: true)

    // Session 1 in projA: with subfolder and matching task
    let sid1 = "01a00000-0000-7000-8000-000000000001"
    let fileBase1 = "2026-09-01T10-00-00-000Z_\(sid1)"
    let jsonl1 = projA.appendingPathComponent("\(fileBase1).jsonl")
    let subfolder1 = projA.appendingPathComponent(fileBase1)
    try? fm.createDirectory(at: subfolder1, withIntermediateDirectories: true)
    try? "subfolder-data-bytes-123456789".write(to: subfolder1.appendingPathComponent("subdata.txt"), atomically: true, encoding: .utf8)

    let session1Content = """
    {"type":"session","version":3,"id":"\(sid1)","timestamp":"2026-09-01T10:00:00.000Z","cwd":"/Users/mock/projectA"}
    {"type":"model_change","id":"m1","parentId":null,"timestamp":"2026-09-01T10:00:01.000Z","provider":"cli-proxy","modelId":"gemini"}
    {"type":"message","id":"msg1","parentId":"m1","timestamp":"2026-09-01T10:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"Implement Pi Agent Scanner feature"}]}}
    {"type":"message","id":"msg2","parentId":"msg1","timestamp":"2026-09-01T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Feature implemented."}]}}
    """
    try? session1Content.write(to: jsonl1, atomically: true, encoding: .utf8)

    // Task directory matching sid1: <sid1>-99999
    let task1Dir = tasksDir.appendingPathComponent("\(sid1)-99999")
    try? fm.createDirectory(at: task1Dir, withIntermediateDirectories: true)
    try? "{\"id\":\"t1\",\"status\":\"completed\"}".write(to: task1Dir.appendingPathComponent("task.json"), atomically: true, encoding: .utf8)

    // Session 2 in projB: no subfolder, no matching task
    let sid2 = "01a00000-0000-7000-8000-000000000002"
    let fileBase2 = "2026-09-02T12-00-00-000Z_\(sid2)"
    let jsonl2 = projB.appendingPathComponent("\(fileBase2).jsonl")
    let session2Content = """
    {"type":"session","version":3,"id":"\(sid2)","timestamp":"2026-09-02T12:00:00.000Z","cwd":"/Users/mock/projectB"}
    {"type":"message","id":"msg2_1","parentId":null,"timestamp":"2026-09-02T12:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"Fix bug in project B"}]}}
    """
    try? session2Content.write(to: jsonl2, atomically: true, encoding: .utf8)

    // Unmatched task
    let unmatchedTaskDir = tasksDir.appendingPathComponent("session-12345-12345")
    try? fm.createDirectory(at: unmatchedTaskDir, withIntermediateDirectories: true)
    try? "unmatched-task-content".write(to: unmatchedTaskDir.appendingPathComponent("out.txt"), atomically: true, encoding: .utf8)

    // Context mode DB
    try? "mock-sqlite-db".write(to: contextModeDir.appendingPathComponent("context.db"), atomically: true, encoding: .utf8)

    // Run history
    let runHistoryURL = tempDir.appendingPathComponent("agent/run-history.jsonl")
    try? "{\"agent\":\"worker\",\"status\":\"ok\"}\n".write(to: runHistoryURL, atomically: true, encoding: .utf8)

    let scanner = PiAgentScanner(storageURL: tempDir)
    TestRunner.assertTest(scanner.isInstalled, "Mock scanner isInstalled == true", testName: testName)

    do {
        let items = try await scanner.scan()
        TestRunner.assertTest(items.count == 2, "Mock scan detected 2 sessions (found \(items.count))", testName: testName)

        // Session 1 checks
        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            TestRunner.assertTest(item1.title == "Implement Pi Agent Scanner feature", "Session 1 title matches first user message", testName: testName)
            TestRunner.assertTest(item1.projectPath == "/Users/mock/projectA", "Session 1 projectPath matches", testName: testName)
            TestRunner.assertTest(item1.messageCount >= 2, "Session 1 messageCount is >= 2 (found: \(item1.messageCount))", testName: testName)
            TestRunner.assertTest(item1.associatedPaths.contains(jsonl1.path), "Session 1 associatedPaths includes .jsonl", testName: testName)
            TestRunner.assertTest(item1.associatedPaths.contains(subfolder1.path), "Session 1 associatedPaths includes subfolder", testName: testName)
            TestRunner.assertTest(item1.associatedPaths.contains(task1Dir.path), "Session 1 associatedPaths includes matching task dir", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 1 not found in scan results", testName: testName)
        }

        // Test selective deletion: delete item1
        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            let freed = try await scanner.delete(items: [item1])
            TestRunner.assertTest(freed == item1.sizeInBytes, "delete([item1]) freed item1.sizeInBytes", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: jsonl1.path), "jsonl1 removed from disk", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: subfolder1.path), "subfolder1 removed from disk", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: task1Dir.path), "task1Dir removed from disk", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: projA.path), "Empty projectA folder was removed", testName: testName)
            TestRunner.assertTest(fm.fileExists(atPath: projB.path), "projectB folder still exists", testName: testName)
        }

        // Test cleanAll: clears projectB, tasks, context-mode, web-search-cache
        let allFreed = try await scanner.cleanAll()
        TestRunner.assertTest(allFreed > 0, "cleanAll() returned freed bytes > 0 (\(allFreed))", testName: testName)
        let postScan = try await scanner.scan()
        TestRunner.assertTest(postScan.isEmpty, "scan() after cleanAll returns 0 items", testName: testName)
        TestRunner.assertTest(!fm.fileExists(atPath: jsonl2.path), "jsonl2 removed from disk", testName: testName)
        TestRunner.assertTest(!fm.fileExists(atPath: unmatchedTaskDir.path), "Unmatched task directory removed in cleanAll", testName: testName)
        TestRunner.assertTest(fm.fileExists(atPath: tasksDir.path), "tasksDir recreated as clean directory", testName: testName)
        TestRunner.assertTest(fm.fileExists(atPath: contextModeDir.path), "contextModeDir recreated as clean directory", testName: testName)
    } catch {
        TestRunner.assertTest(false, "Mock PiAgentScanner threw error: \(error)", testName: testName)
    }
}

// MARK: - Test: Real VS Code Chat Scanner (READ-ONLY)

func testRealVSCodeChatScannerReadOnly() async {
    TestRunner.printSection("Test: Real VS Code Chat Scanner (READ-ONLY)")
    let testName = "RealVSCodeReadOnly"

    let scanner = VSCodeChatScanner()
    TestRunner.assertTest(scanner.category == .copilotChat, "Category is .copilotChat", testName: testName)

    let homePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Code/User").path
    TestRunner.assertTest(TestRunner.canonicalPath(scanner.storageURL.path) == TestRunner.canonicalPath(homePath), "storageURL correctly points to Code/User directory", testName: testName)
    TestRunner.assertTest(scanner.isInstalled, "scanner.isInstalled is true on this Mac", testName: testName)

    do {
        let items = try await scanner.scan()
        TestRunner.assertTest(!items.isEmpty, "Detected real VS Code Chat sessions (count: \(items.count))", testName: testName)
        TestRunner.assertTest(items.count >= 44, "Detected at least 44 sessions (found: \(items.count))", testName: testName)

        let allCopilot = items.allSatisfy { $0.category == .copilotChat }
        TestRunner.assertTest(allCopilot, "All scanned items have category .copilotChat", testName: testName)

        // Find active session fc6c5632
        if let active = items.first(where: { $0.sessionId.contains("fc6c5632") }) {
            TestRunner.assertTest(active.title == "将这个文件改为中文。", "Session fc6c5632 title is '将这个文件改为中文。' (found: '\(active.title)')", testName: testName)
            TestRunner.assertTest(active.messageCount == 2, "Session fc6c5632 messageCount is 2 (found: \(active.messageCount))", testName: testName)
            TestRunner.assertTest(active.projectPath != nil && active.projectPath!.contains("video-play-frontend"), "Session fc6c5632 projectPath matches video-play-frontend (found: '\(active.projectPath ?? "nil")')", testName: testName)
            TestRunner.assertTest(active.associatedPaths.count >= 2, "Session fc6c5632 associatedPaths includes chatSessions and chatEditingSessions", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session fc6c5632 not found in real scan", testName: testName)
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
        TestRunner.assertTest(pathsExist, "Sampled sessions associated paths exist on disk", testName: testName)
    } catch {
        TestRunner.assertTest(false, "Real VS Code scan threw error: \(error)", testName: testName)
    }
}

// MARK: - Test: Mock VS Code Chat Scanner

func testMockVSCodeChatScanner() async {
    TestRunner.printSection("Test: Mock VS Code Chat Scanner (Fixture Directory)")
    let testName = "MockVSCodeChat"

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_vscode_chat")
    defer { try? fm.removeItem(at: tempDir) }

    let wsStorage = tempDir.appendingPathComponent("workspaceStorage")
    let globalStorage = tempDir.appendingPathComponent("globalStorage")
    let emptyWindow = globalStorage.appendingPathComponent("emptyWindowChatSessions")
    let wsA = wsStorage.appendingPathComponent("hashA123")
    let wsAChat = wsA.appendingPathComponent("chatSessions")
    let wsAEdit = wsA.appendingPathComponent("chatEditingSessions")

    try? fm.createDirectory(at: wsAChat, withIntermediateDirectories: true)
    try? fm.createDirectory(at: wsAEdit, withIntermediateDirectories: true)
    try? fm.createDirectory(at: emptyWindow, withIntermediateDirectories: true)

    // workspace.json with folder URI
    let wsJson = "{\"folder\":\"file:///Users/tester/mock-web-app\"}"
    try? wsJson.write(to: wsA.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)

    // Session 1 in workspace A: has prompt and matching editing session folder
    let sid1 = "session-vs-001"
    let s1File = wsAChat.appendingPathComponent("\(sid1).jsonl")
    let s1Content = """
    {"kind":0,"v":{"version":3,"creationDate":1789000000000,"sessionId":"\(sid1)","requests":[]}}
    {"kind":2,"k":["requests"],"v":[{"requestId":"r1","message":{"text":"Refactor SwiftUI navigation view"}}]}
    """
    try? s1Content.write(to: s1File, atomically: true, encoding: .utf8)

    let s1EditDir = wsAEdit.appendingPathComponent(sid1)
    try? fm.createDirectory(at: s1EditDir, withIntermediateDirectories: true)
    try? "state data".write(to: s1EditDir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

    // Session 2 in emptyWindow: empty session
    let sid2 = "session-vs-002"
    let s2File = emptyWindow.appendingPathComponent("\(sid2).jsonl")
    let s2Content = """
    {"kind":0,"v":{"version":3,"creationDate":1789100000000,"sessionId":"\(sid2)","requests":[]}}
    """
    try? s2Content.write(to: s2File, atomically: true, encoding: .utf8)

    let scanner = VSCodeChatScanner(baseURL: tempDir)
    TestRunner.assertTest(scanner.isInstalled, "scanner.isInstalled is true for fixture", testName: testName)
    TestRunner.assertTest(scanner.category == .copilotChat, "Category is .copilotChat", testName: testName)

    do {
        var items = try await scanner.scan()
        TestRunner.assertTest(items.count == 2, "Detected 2 mock sessions (found: \(items.count))", testName: testName)

        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            TestRunner.assertTest(item1.title == "Refactor SwiftUI navigation view", "Session 1 title matches prompt (\(item1.title))", testName: testName)
            TestRunner.assertTest(item1.projectPath == "/Users/tester/mock-web-app", "Session 1 projectPath matches workspace.json", testName: testName)
            TestRunner.assertTest(item1.messageCount == 1, "Session 1 messageCount is 1", testName: testName)
            TestRunner.assertTest(item1.associatedPaths.contains(s1File.path), "Session 1 associatedPaths contains jsonl", testName: testName)
            TestRunner.assertTest(item1.associatedPaths.contains(s1EditDir.path), "Session 1 associatedPaths contains editing folder", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 1 not found", testName: testName)
        }

        if let item2 = items.first(where: { $0.sessionId == sid2 }) {
            TestRunner.assertTest(item2.title == "GitHub Copilot 对话", "Session 2 has fallback title 'GitHub Copilot 对话'", testName: testName)
            TestRunner.assertTest(item2.projectPath == nil, "Session 2 has nil projectPath", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 2 not found", testName: testName)
        }

        // Test delete item1
        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            let freed = try await scanner.delete(items: [item1])
            TestRunner.assertTest(freed == item1.sizeInBytes, "Freed bytes matches item 1 size", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: s1File.path), "Session 1 jsonl removed from disk", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: s1EditDir.path), "Session 1 editing dir removed from disk", testName: testName)
            TestRunner.assertTest(fm.fileExists(atPath: s2File.path), "Session 2 jsonl still exists", testName: testName)
        }

        // Test cleanAll
        let allFreed = try await scanner.cleanAll()
        TestRunner.assertTest(allFreed > 0, "cleanAll freed bytes > 0", testName: testName)
        items = try await scanner.scan()
        TestRunner.assertTest(items.isEmpty, "Rescan after cleanAll returns 0 items", testName: testName)
    } catch {
        TestRunner.assertTest(false, "Mock VS Code Chat scan threw error: \(error)", testName: testName)
    }
}

// MARK: - Test: Mock Cursor Scanner

func testMockCursorScanner() async {
    TestRunner.printSection("Test: Mock Cursor Scanner (Fixture Directory)")
    let testName = "MockCursor"

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_cursor")
    defer { try? fm.removeItem(at: tempDir) }

    let userDir = tempDir.appendingPathComponent("User")
    let wsStorage = userDir.appendingPathComponent("workspaceStorage")
    let wsA = wsStorage.appendingPathComponent("wsCursor123")
    let wsAChat = wsA.appendingPathComponent("chatSessions")
    let dotCursor = tempDir.appendingPathComponent(".cursor")
    let dotChats = dotCursor.appendingPathComponent("chats")

    try? fm.createDirectory(at: wsAChat, withIntermediateDirectories: true)
    try? fm.createDirectory(at: dotChats, withIntermediateDirectories: true)

    // workspace.json
    try? "{\"folder\":\"file:///Users/tester/cursor-project\"}".write(to: wsA.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)

    // Session 1 in chatSessions/
    let cid1 = "cursor-chat-001"
    let c1File = wsAChat.appendingPathComponent("\(cid1).jsonl")
    let c1Content = """
    {"kind":0,"v":{"version":3,"creationDate":1789200000000,"sessionId":"\(cid1)","requests":[]}}
    {"kind":2,"k":["requests"],"v":[{"requestId":"r1","message":{"text":"Cursor compose prompt 1"}}]}
    """
    try? c1Content.write(to: c1File, atomically: true, encoding: .utf8)

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
    try? composerJson.write(to: stateDbURL, atomically: true, encoding: .utf8)

    // Session 3 in ~/.cursor/chats/
    let cid3 = "cursor-dot-001"
    let c3File = dotChats.appendingPathComponent("\(cid3).json")
    try? "{\"id\":\"\(cid3)\"}".write(to: c3File, atomically: true, encoding: .utf8)

    let scanner = CursorScanner(baseURL: tempDir)
    TestRunner.assertTest(scanner.isInstalled, "CursorScanner.isInstalled is true for fixture", testName: testName)
    TestRunner.assertTest(scanner.category == .cursor, "Category is .cursor", testName: testName)

    do {
        var items = try await scanner.scan()
        TestRunner.assertTest(items.count == 3, "Detected 3 Cursor sessions across workspace, state.vscdb, and .cursor (found: \(items.count))", testName: testName)

        if let item1 = items.first(where: { $0.sessionId == cid1 }) {
            TestRunner.assertTest(item1.title == "Cursor compose prompt 1", "Session 1 title matches prompt", testName: testName)
            TestRunner.assertTest(item1.projectPath == "/Users/tester/cursor-project", "Session 1 projectPath matches workspace.json", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 1 not found", testName: testName)
        }

        if let item2 = items.first(where: { $0.sessionId == "composer-001" }) {
            TestRunner.assertTest(item2.title == "Implement Cursor Composer Feature", "Composer session parsed from state.vscdb", testName: testName)
            TestRunner.assertTest(item2.projectPath == "/Users/tester/cursor-project", "Composer projectPath matches workspace.json", testName: testName)
        } else {
            TestRunner.assertTest(false, "Composer session not found", testName: testName)
        }

        // Delete item 1
        if let item1 = items.first(where: { $0.sessionId == cid1 }) {
            let freed = try await scanner.delete(items: [item1])
            TestRunner.assertTest(freed == item1.sizeInBytes, "Freed size matches item 1", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: c1File.path), "Session 1 file removed", testName: testName)
        }

        // cleanAll
        let allFreed = try await scanner.cleanAll()
        TestRunner.assertTest(allFreed > 0, "cleanAll freed bytes > 0", testName: testName)
        items = try await scanner.scan()
        TestRunner.assertTest(items.isEmpty, "Rescan after cleanAll returns 0 items", testName: testName)
    } catch {
        TestRunner.assertTest(false, "Mock Cursor scan threw error: \(error)", testName: testName)
    }
}

// MARK: - Test: Mock Windsurf Scanner

func testMockWindsurfScanner() async {
    TestRunner.printSection("Test: Mock Windsurf Scanner (Fixture Directory)")
    let testName = "MockWindsurf"

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_windsurf")
    defer { try? fm.removeItem(at: tempDir) }

    let userDir = tempDir.appendingPathComponent("User")
    let wsStorage = userDir.appendingPathComponent("workspaceStorage")
    let wsA = wsStorage.appendingPathComponent("wsWindsurf123")
    let wsAChat = wsA.appendingPathComponent("chatSessions")
    let codeiumWindsurf = tempDir.appendingPathComponent(".codeium/windsurf")
    let cascadesDir = codeiumWindsurf.appendingPathComponent("cascades")

    try? fm.createDirectory(at: wsAChat, withIntermediateDirectories: true)
    try? fm.createDirectory(at: cascadesDir, withIntermediateDirectories: true)

    // workspace.json
    try? "{\"folder\":\"file:///Users/tester/windsurf-app\"}".write(to: wsA.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)

    // Session 1 in workspaceStorage
    let wid1 = "windsurf-chat-001"
    let w1File = wsAChat.appendingPathComponent("\(wid1).jsonl")
    let w1Content = """
    {"kind":0,"v":{"version":3,"creationDate":1789400000000,"sessionId":"\(wid1)","requests":[]}}
    {"kind":2,"k":["requests"],"v":[{"requestId":"r1","message":{"text":"Generate Windsurf cascade rule"}}]}
    """
    try? w1Content.write(to: w1File, atomically: true, encoding: .utf8)

    // Session 2 in cascades/
    let cid2 = "cascade-session-002"
    let cascadeDir = cascadesDir.appendingPathComponent(cid2)
    try? fm.createDirectory(at: cascadeDir, withIntermediateDirectories: true)
    let metaContent = """
    {"title":"Optimize React components with memo","cwd":"/Users/tester/react-frontend"}
    """
    try? metaContent.write(to: cascadeDir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)

    let scanner = WindsurfScanner(baseURL: tempDir)
    TestRunner.assertTest(scanner.isInstalled, "WindsurfScanner.isInstalled is true for fixture", testName: testName)
    TestRunner.assertTest(scanner.category == .windsurf, "Category is .windsurf", testName: testName)

    do {
        var items = try await scanner.scan()
        TestRunner.assertTest(items.count == 2, "Detected 2 Windsurf sessions (found: \(items.count))", testName: testName)

        if let item1 = items.first(where: { $0.sessionId == wid1 }) {
            TestRunner.assertTest(item1.title == "Generate Windsurf cascade rule", "Session 1 title matches prompt", testName: testName)
            TestRunner.assertTest(item1.projectPath == "/Users/tester/windsurf-app", "Session 1 projectPath matches workspace.json", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 1 not found", testName: testName)
        }

        if let item2 = items.first(where: { $0.sessionId == cid2 }) {
            TestRunner.assertTest(item2.title == "Optimize React components with memo", "Cascade session title parsed from meta.json", testName: testName)
            TestRunner.assertTest(item2.projectPath == "/Users/tester/react-frontend", "Cascade session projectPath matches meta cwd", testName: testName)
        } else {
            TestRunner.assertTest(false, "Cascade session 2 not found", testName: testName)
        }

        // Delete item 1
        if let item1 = items.first(where: { $0.sessionId == wid1 }) {
            let freed = try await scanner.delete(items: [item1])
            TestRunner.assertTest(freed == item1.sizeInBytes, "Freed size matches item 1", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: w1File.path), "Session 1 file removed", testName: testName)
        }

        // cleanAll
        let allFreed = try await scanner.cleanAll()
        TestRunner.assertTest(allFreed > 0, "cleanAll freed bytes > 0", testName: testName)
        items = try await scanner.scan()
        TestRunner.assertTest(items.isEmpty, "Rescan after cleanAll returns 0 items", testName: testName)
    } catch {
        TestRunner.assertTest(false, "Mock Windsurf scan threw error: \(error)", testName: testName)
    }
}

// MARK: - Test: Mock Trae Scanner

func testMockTraeScanner() async {
    TestRunner.printSection("Test: Mock Trae Scanner (Fixture Directory)")
    let testName = "MockTrae"

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_trae")
    defer { try? fm.removeItem(at: tempDir) }

    let userDir = tempDir.appendingPathComponent("User")
    let wsStorage = userDir.appendingPathComponent("workspaceStorage")
    let wsA = wsStorage.appendingPathComponent("wsTrae123")
    let wsAChat = wsA.appendingPathComponent("chatSessions")
    let globalStorage = userDir.appendingPathComponent("globalStorage")
    let emptyWindow = globalStorage.appendingPathComponent("emptyWindowChatSessions")

    try? fm.createDirectory(at: wsAChat, withIntermediateDirectories: true)
    try? fm.createDirectory(at: emptyWindow, withIntermediateDirectories: true)

    // workspace.json
    try? "{\"folder\":\"file:///Users/tester/trae-project\"}".write(to: wsA.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)

    // Session 1 in workspace
    let tid1 = "trae-chat-001"
    let t1File = wsAChat.appendingPathComponent("\(tid1).jsonl")
    let t1Content = """
    {"kind":0,"v":{"version":3,"creationDate":1789500000000,"sessionId":"\(tid1)","requests":[]}}
    {"kind":2,"k":["requests"],"v":[{"requestId":"r1","message":{"text":"Trae create microservice"}},{"requestId":"r2","message":{"text":"Next prompt"}}]}
    """
    try? t1Content.write(to: t1File, atomically: true, encoding: .utf8)

    // Session 2 in emptyWindow
    let tid2 = "trae-empty-002"
    let t2File = emptyWindow.appendingPathComponent("\(tid2).jsonl")
    let t2Content = """
    {"kind":0,"v":{"version":3,"creationDate":1789600000000,"sessionId":"\(tid2)","requests":[]}}
    """
    try? t2Content.write(to: t2File, atomically: true, encoding: .utf8)

    let scanner = TraeScanner(baseURL: tempDir)
    TestRunner.assertTest(scanner.isInstalled, "TraeScanner.isInstalled is true for fixture", testName: testName)
    TestRunner.assertTest(scanner.category == .trae, "Category is .trae", testName: testName)

    do {
        var items = try await scanner.scan()
        TestRunner.assertTest(items.count == 2, "Detected 2 Trae sessions (found: \(items.count))", testName: testName)

        if let item1 = items.first(where: { $0.sessionId == tid1 }) {
            TestRunner.assertTest(item1.title == "Trae create microservice", "Session 1 title matches prompt", testName: testName)
            TestRunner.assertTest(item1.messageCount == 2, "Session 1 messageCount is 2", testName: testName)
            TestRunner.assertTest(item1.projectPath == "/Users/tester/trae-project", "Session 1 projectPath matches workspace.json", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 1 not found", testName: testName)
        }

        if let item2 = items.first(where: { $0.sessionId == tid2 }) {
            TestRunner.assertTest(item2.title == "Trae 对话", "Session 2 has fallback title 'Trae 对话'", testName: testName)
            TestRunner.assertTest(item2.projectPath == nil, "Session 2 has nil projectPath", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 2 not found", testName: testName)
        }

        // Delete item 1
        if let item1 = items.first(where: { $0.sessionId == tid1 }) {
            let freed = try await scanner.delete(items: [item1])
            TestRunner.assertTest(freed == item1.sizeInBytes, "Freed size matches item 1", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: t1File.path), "Session 1 file removed", testName: testName)
        }

        // cleanAll
        let allFreed = try await scanner.cleanAll()
        TestRunner.assertTest(allFreed > 0, "cleanAll freed bytes > 0", testName: testName)
        items = try await scanner.scan()
        TestRunner.assertTest(items.isEmpty, "Rescan after cleanAll returns 0 items", testName: testName)
    } catch {
        TestRunner.assertTest(false, "Mock Trae scan threw error: \(error)", testName: testName)
    }
}

// MARK: - Test: Real OpenViking Scanner (READ-ONLY)

func testRealOpenVikingScannerReadOnly() async {
    TestRunner.printSection("Test: Real Local ~/.openviking Scanner (READ-ONLY)")
    let testName = "RealOpenVikingReadOnly"

    let scanner = OpenVikingScanner()
    TestRunner.assertTest(scanner.category == .openViking, "Category is .openViking", testName: testName)

    let homePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openviking").path
    TestRunner.assertTest(TestRunner.canonicalPath(scanner.storageURL.path) == TestRunner.canonicalPath(homePath), "storageURL correctly points to ~/.openviking", testName: testName)
    TestRunner.assertTest(scanner.isInstalled, "scanner.isInstalled is true on this Mac", testName: testName)

    do {
        let items = try await scanner.scan()
        TestRunner.assertTest(!items.isEmpty, "Detected real OpenViking sessions (count: \(items.count))", testName: testName)
        TestRunner.assertTest(items.count == 28, "Detected exactly 28 sessions from 975 files (found: \(items.count))", testName: testName)

        let totalMessages = items.reduce(0) { $0 + $1.messageCount }
        TestRunner.assertTest(totalMessages == 975, "Total message count matches 975 files in pending/ (found: \(totalMessages))", testName: testName)

        let allOpenViking = items.allSatisfy { $0.category == .openViking }
        TestRunner.assertTest(allOpenViking, "All scanned items have category .openViking", testName: testName)

        let allHaveSessionId = items.allSatisfy { !$0.sessionId.isEmpty }
        TestRunner.assertTest(allHaveSessionId, "All items have non-empty sessionId", testName: testName)

        var isSorted = true
        for i in 0..<(items.count - 1) {
            if items[i].updatedAt < items[i + 1].updatedAt {
                isSorted = false
                break
            }
        }
        TestRunner.assertTest(isSorted, "Items are sorted by updatedAt descending", testName: testName)

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
        TestRunner.assertTest(false, "Real OpenViking scan threw error: \(error)", testName: testName)
    }
}

// MARK: - Test: Mock OpenViking Scanner

func testMockOpenVikingScanner() async {
    TestRunner.printSection("Test: Mock OpenViking Scanner (Fixture Directory)")
    let testName = "MockOpenViking"

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_openviking")
    defer { try? fm.removeItem(at: tempDir) }

    let pendingDir = tempDir.appendingPathComponent("pending")
    try? fm.createDirectory(at: pendingDir, withIntermediateDirectories: true)

    let sid1 = "dsh-session-test-0001"
    let sid2 = "dsh-session-test-0002"

    let f1Content = """
    {"type":"addMessage","sessionId":"\(sid1)","payload":{"role":"user","parts":[{"type":"text","text":"Optimize database queries"}],"peer_id":"-Users-tester-projects-backend"},"createdAt":1786888290000}
    """
    try? f1Content.write(to: pendingDir.appendingPathComponent("f1.json"), atomically: true, encoding: .utf8)

    let f2Content = """
    {"type":"addMessage","sessionId":"\(sid1)","payload":{"role":"assistant","parts":[{"type":"tool","tool_name":"bash"}]},"createdAt":1786888300000}
    """
    try? f2Content.write(to: pendingDir.appendingPathComponent("f2.json"), atomically: true, encoding: .utf8)

    let f3Content = """
    {"type":"commitSession","sessionId":"\(sid2)","payload":{"keep_recent_count":5},"createdAt":1786888400000}
    """
    try? f3Content.write(to: pendingDir.appendingPathComponent("f3.json"), atomically: true, encoding: .utf8)

    let scanner = OpenVikingScanner(storageURL: tempDir)
    TestRunner.assertTest(scanner.isInstalled, "Mock scanner isInstalled is true", testName: testName)

    do {
        var items = try await scanner.scan()
        TestRunner.assertTest(items.count == 2, "Detected 2 mock sessions (found: \(items.count))", testName: testName)

        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            TestRunner.assertTest(item1.title == "Optimize database queries", "Session 1 title matches user prompt", testName: testName)
            TestRunner.assertTest(item1.messageCount == 2, "Session 1 message count is 2", testName: testName)
            TestRunner.assertTest(item1.associatedPaths.count == 2, "Session 1 associatedPaths has 2 files", testName: testName)
            TestRunner.assertTest(item1.sizeInBytes > 0, "Session 1 size > 0", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 1 not found", testName: testName)
        }

        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            let freed = try await scanner.delete(items: [item1])
            TestRunner.assertTest(freed == item1.sizeInBytes, "Freed size matches item1 size", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: pendingDir.appendingPathComponent("f1.json").path), "f1.json removed", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: pendingDir.appendingPathComponent("f2.json").path), "f2.json removed", testName: testName)
            TestRunner.assertTest(fm.fileExists(atPath: pendingDir.appendingPathComponent("f3.json").path), "f3.json still exists", testName: testName)
        }

        let allFreed = try await scanner.cleanAll()
        TestRunner.assertTest(allFreed > 0, "cleanAll freed bytes > 0", testName: testName)
        items = try await scanner.scan()
        TestRunner.assertTest(items.isEmpty, "Rescan after cleanAll returns 0 items", testName: testName)
        TestRunner.assertTest(fm.fileExists(atPath: pendingDir.path), "pending/ folder recreated", testName: testName)
    } catch {
        TestRunner.assertTest(false, "Mock OpenViking test threw error: \(error)", testName: testName)
    }
}

// MARK: - Test: Real Aider Scanner (READ-ONLY)

func testRealAiderScannerReadOnly() async {
    TestRunner.printSection("Test: Real Local Aider Scanner (READ-ONLY)")
    let testName = "RealAiderReadOnly"

    let scanner = AiderScanner()
    TestRunner.assertTest(scanner.category == .aider, "Category is .aider", testName: testName)
    do {
        let items = try await scanner.scan()
        TestRunner.assertTest(true, "Aider scan() executed successfully without throwing error", testName: testName)
        print("  \u{001B}[34m[INFO] Scanned \(items.count) Aider sessions on current machine\u{001B}[0m")
    } catch {
        TestRunner.assertTest(false, "Real Aider scan threw error: \(error)", testName: testName)
    }
}

// MARK: - Test: Mock Aider Scanner

func testMockAiderScanner() async {
    TestRunner.printSection("Test: Mock Aider Scanner (Fixture Directory)")
    let testName = "MockAider"

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_aider")
    defer { try? fm.removeItem(at: tempDir) }

    let projDir = tempDir.appendingPathComponent("projects/my-web-app")
    try? fm.createDirectory(at: projDir, withIntermediateDirectories: true)

    let chatFile = projDir.appendingPathComponent(".aider.chat.history.md")
    let inputFile = projDir.appendingPathComponent(".aider.input.history")
    let tagsFile = projDir.appendingPathComponent(".aider.tags.cache.v3")
    let confFile = projDir.appendingPathComponent(".aider.conf.yml")
    let sourceCodeFile = projDir.appendingPathComponent("App.swift")

    let chatContent = """
    # aider chat started at 2026-09-20 10:00:00

    #### Add user authentication middleware with JWT tokens
    > Applied edit to Auth.swift
    """
    try? chatContent.write(to: chatFile, atomically: true, encoding: .utf8)
    try? "git status\nadd auth middleware\n".write(to: inputFile, atomically: true, encoding: .utf8)
    try? "ctags-cache-v3-binary-data".write(to: tagsFile, atomically: true, encoding: .utf8)
    try? "model: gpt-4o\nauto-commits: false\n".write(to: confFile, atomically: true, encoding: .utf8)
    try? "import SwiftUI\nstruct App {}\n".write(to: sourceCodeFile, atomically: true, encoding: .utf8)

    let scanner = AiderScanner(storageURL: tempDir)
    TestRunner.assertTest(scanner.isInstalled, "Mock scanner isInstalled is true", testName: testName)

    do {
        var items = try await scanner.scan()
        TestRunner.assertTest(!items.isEmpty, "Detected project Aider item", testName: testName)

        if let item = items.first(where: { $0.projectPath == projDir.path }) {
            TestRunner.assertTest(item.category == .aider, "Item category is .aider", testName: testName)
            TestRunner.assertTest(item.title.contains("Add user authentication middleware"), "Title parsed from chat history prompt (found: '\(item.title)')", testName: testName)
            TestRunner.assertTest(item.associatedPaths.contains(chatFile.path), "associatedPaths contains .aider.chat.history.md", testName: testName)
            TestRunner.assertTest(item.associatedPaths.contains(inputFile.path), "associatedPaths contains .aider.input.history", testName: testName)
            TestRunner.assertTest(item.associatedPaths.contains(tagsFile.path), "associatedPaths contains .aider.tags.cache.v3", testName: testName)
            TestRunner.assertTest(!item.associatedPaths.contains(confFile.path), "associatedPaths does NOT contain .aider.conf.yml", testName: testName)
            TestRunner.assertTest(!item.associatedPaths.contains(sourceCodeFile.path), "associatedPaths does NOT contain user source code", testName: testName)

            let freed = try await scanner.delete(items: [item])
            TestRunner.assertTest(freed == item.sizeInBytes, "Freed size matches item size", testName: testName)

            TestRunner.assertTest(!fm.fileExists(atPath: chatFile.path), ".aider.chat.history.md removed", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: inputFile.path), ".aider.input.history removed", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: tagsFile.path), ".aider.tags.cache.v3 removed", testName: testName)

            TestRunner.assertTest(fm.fileExists(atPath: confFile.path), "SAFETY PASS: .aider.conf.yml was PRESERVED", testName: testName)
            TestRunner.assertTest(fm.fileExists(atPath: sourceCodeFile.path), "SAFETY PASS: App.swift repository code was PRESERVED", testName: testName)
        } else {
            TestRunner.assertTest(false, "Project Aider item not found", testName: testName)
        }

        let allFreed = try await scanner.cleanAll()
        TestRunner.assertTest(allFreed >= 0, "cleanAll completed safely", testName: testName)
    } catch {
        TestRunner.assertTest(false, "Mock Aider test threw error: \(error)", testName: testName)
    }
}

// MARK: - Test: Real Zed Scanner (READ-ONLY)

func testRealZedScannerReadOnly() async {
    TestRunner.printSection("Test: Real Local Zed AI Scanner (READ-ONLY)")
    let testName = "RealZedReadOnly"

    let scanner = ZedScanner()
    TestRunner.assertTest(scanner.category == .zed, "Category is .zed", testName: testName)

    let homePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Zed").path
    TestRunner.assertTest(TestRunner.canonicalPath(scanner.storageURL.path) == TestRunner.canonicalPath(homePath), "storageURL correctly points to Zed directory", testName: testName)
    TestRunner.assertTest(scanner.isInstalled, "scanner.isInstalled is true on this Mac", testName: testName)

    do {
        let items = try await scanner.scan()
        TestRunner.assertTest(true, "Zed scan() executed without throwing error", testName: testName)
        print("  \u{001B}[34m[INFO] Scanned \(items.count) Zed items from real filesystem\u{001B}[0m")

        if let hangItem = items.first(where: { $0.sessionId == "zed-hang-traces" }) {
            TestRunner.assertTest(hangItem.category == .zed, "Hang traces item category is .zed", testName: testName)
            TestRunner.assertTest(hangItem.messageCount >= 4, "Detected at least 4 hang trace files on machine (found: \(hangItem.messageCount))", testName: testName)
            print("  \u{001B}[34m[INFO] Real Hang Traces: \(hangItem.title), Size: \(hangItem.formattedSize)\u{001B}[0m")
        }
    } catch {
        TestRunner.assertTest(false, "Real Zed scan threw error: \(error)", testName: testName)
    }
}

// MARK: - Test: Mock Zed Scanner

func testMockZedScanner() async {
    TestRunner.printSection("Test: Mock Zed Scanner (Fixture Directory)")
    let testName = "MockZed"

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_zed")
    defer { try? fm.removeItem(at: tempDir) }

    let threadsDir = tempDir.appendingPathComponent("threads")
    let convDir = tempDir.appendingPathComponent("conversations")
    let hangDir = tempDir.appendingPathComponent("hang_traces")

    try? fm.createDirectory(at: threadsDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: convDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: hangDir, withIntermediateDirectories: true)

    let dbURL = threadsDir.appendingPathComponent("threads.db")
    var db: OpaquePointer?
    if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK {
        let schema = """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            summary TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            data_type TEXT NOT NULL,
            data BLOB NOT NULL,
            parent_id TEXT,
            folder_paths TEXT,
            folder_paths_order TEXT,
            created_at TEXT
        );
        INSERT INTO threads (id, summary, updated_at, data_type, data, folder_paths, created_at)
        VALUES ('zed-th-001', 'Build AST Parser in Rust', '2026-09-26T17:00:00Z', 'text', 'dummyblob', '["/Users/tester/ast-parser"]', '2026-09-26T16:00:00Z');
        INSERT INTO threads (id, summary, updated_at, data_type, data, folder_paths, created_at)
        VALUES ('zed-th-002', 'Optimize Metal rendering backend', '2026-09-26T17:30:00Z', 'text', 'dummyblob2', '["/Users/tester/metal-engine"]', '2026-09-26T17:15:00Z');
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, schema, nil, nil, &errMsg)
        if let errMsg = errMsg { sqlite3_free(errMsg) }
        sqlite3_close(db)
    }

    let conv1 = convDir.appendingPathComponent("conv-001.json")
    try? "{\"id\":\"conv-001\",\"title\":\"Fix tree-sitter syntax highlighting\",\"messages\":[{},{}]}".write(to: conv1, atomically: true, encoding: .utf8)

    let hang1 = hangDir.appendingPathComponent("hang-2026-09-26_17-47-36.miniprof.json")
    try? "[{\"thread_name\":\"main\",\"timings\":[]}]".write(to: hang1, atomically: true, encoding: .utf8)

    let scanner = ZedScanner(storageURL: tempDir)
    TestRunner.assertTest(scanner.isInstalled, "Mock scanner isInstalled is true", testName: testName)

    do {
        var items = try await scanner.scan()
        TestRunner.assertTest(items.count == 4, "Detected exactly 4 Zed items (2 DB threads, 1 conv, 1 hang traces group, found: \(items.count))", testName: testName)

        if let th1 = items.first(where: { $0.sessionId == "zed-th-001" }) {
            TestRunner.assertTest(th1.title == "Build AST Parser in Rust", "Thread 1 title matches summary", testName: testName)
            TestRunner.assertTest(th1.projectPath == "/Users/tester/ast-parser", "Thread 1 projectPath matches folder_paths", testName: testName)
        } else {
            TestRunner.assertTest(false, "Thread zed-th-001 not found", testName: testName)
        }

        if let cItem = items.first(where: { $0.sessionId == "conv-001" }) {
            TestRunner.assertTest(cItem.title == "Fix tree-sitter syntax highlighting", "Conv title matches", testName: testName)
            TestRunner.assertTest(cItem.messageCount == 2, "Conv message count is 2", testName: testName)
        } else {
            TestRunner.assertTest(false, "Conversation conv-001 not found", testName: testName)
        }

        if let th1 = items.first(where: { $0.sessionId == "zed-th-001" }) {
            let freed = try await scanner.delete(items: [th1])
            TestRunner.assertTest(freed == th1.sizeInBytes, "Freed size matches th1 size", testName: testName)

            if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                var stmt: OpaquePointer?
                sqlite3_prepare_v2(db, "SELECT count(*) FROM threads WHERE id = 'zed-th-001';", -1, &stmt, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let count = sqlite3_column_int(stmt, 0)
                    TestRunner.assertTest(count == 0, "Thread zed-th-001 deleted from SQLite DB", testName: testName)
                }
                sqlite3_finalize(stmt)

                sqlite3_prepare_v2(db, "SELECT count(*) FROM threads WHERE id = 'zed-th-002';", -1, &stmt, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let count = sqlite3_column_int(stmt, 0)
                    TestRunner.assertTest(count == 1, "Thread zed-th-002 still preserved in DB", testName: testName)
                }
                sqlite3_finalize(stmt)
                sqlite3_close(db)
            }
        }

        let allFreed = try await scanner.cleanAll()
        TestRunner.assertTest(allFreed > 0, "cleanAll freed bytes > 0", testName: testName)
        items = try await scanner.scan()
        TestRunner.assertTest(items.isEmpty, "Rescan after cleanAll returns 0 items", testName: testName)
    } catch {
        TestRunner.assertTest(false, "Mock Zed test threw error: \(error)", testName: testName)
    }
}

// MARK: - Test: Real OpenHands Scanner (READ-ONLY)

func testRealOpenHandsScannerReadOnly() async {
    TestRunner.printSection("Test: Real Local OpenHands Scanner (READ-ONLY)")
    let testName = "RealOpenHandsReadOnly"

    let scanner = OpenHandsScanner()
    TestRunner.assertTest(scanner.category == .openHands, "Category is .openHands", testName: testName)
    do {
        let items = try await scanner.scan()
        TestRunner.assertTest(true, "OpenHands scan() executed without throwing error", testName: testName)
        print("  \u{001B}[34m[INFO] Scanned \(items.count) OpenHands items on current machine\u{001B}[0m")
    } catch {
        TestRunner.assertTest(false, "Real OpenHands scan threw error: \(error)", testName: testName)
    }
}

// MARK: - Test: Mock OpenHands Scanner

func testMockOpenHandsScanner() async {
    TestRunner.printSection("Test: Mock OpenHands Scanner (Fixture Directory)")
    let testName = "MockOpenHands"

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_openhands")
    defer { try? fm.removeItem(at: tempDir) }

    let sessionsDir = tempDir.appendingPathComponent("sessions")
    let logsDir = tempDir.appendingPathComponent("logs")
    let wsDir = tempDir.appendingPathComponent("workspace")

    try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: wsDir, withIntermediateDirectories: true)

    let sid1 = "session-oh-001"
    let s1Dir = sessionsDir.appendingPathComponent(sid1)
    try? fm.createDirectory(at: s1Dir, withIntermediateDirectories: true)

    let s1Meta = """
    {"session_id":"\(sid1)","title":"Implement Stripe webhook handler","directory":"/Users/tester/payment-api","created_at":"2026-09-20T10:00:00Z"}
    """
    try? s1Meta.write(to: s1Dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)

    let s1Events = """
    {"action":"message","args":{"content":"Please implement stripe webhook verification"},"timestamp":"2026-09-20T10:00:05Z"}
    {"action":"run","args":{"command":"go test ./..."},"timestamp":"2026-09-20T10:00:10Z"}
    """
    try? s1Events.write(to: s1Dir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)

    let s1Log = logsDir.appendingPathComponent("\(sid1).log")
    try? "session log entry line 1\nline 2\n".write(to: s1Log, atomically: true, encoding: .utf8)

    let s1Ws = wsDir.appendingPathComponent(sid1)
    try? fm.createDirectory(at: s1Ws, withIntermediateDirectories: true)
    try? "package main".write(to: s1Ws.appendingPathComponent("webhook.go"), atomically: true, encoding: .utf8)

    let sid2 = "session-oh-002"
    let s2File = sessionsDir.appendingPathComponent("\(sid2).json")
    let s2Json = """
    {"session_id":"\(sid2)","title":"Fix CSS grid responsiveness","events":[{},{},{}]}
    """
    try? s2Json.write(to: s2File, atomically: true, encoding: .utf8)

    let serverLog = logsDir.appendingPathComponent("openhands-server.log")
    try? "server starting on :3000\nready\n".write(to: serverLog, atomically: true, encoding: .utf8)

    let scanner = OpenHandsScanner(storageURL: tempDir)
    TestRunner.assertTest(scanner.isInstalled, "Mock scanner isInstalled is true", testName: testName)

    do {
        var items = try await scanner.scan()
        TestRunner.assertTest(items.count == 3, "Detected 3 items (2 sessions + 1 orphaned log group, found: \(items.count))", testName: testName)

        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            TestRunner.assertTest(item1.title == "Implement Stripe webhook handler", "Session 1 title matches metadata", testName: testName)
            TestRunner.assertTest(item1.projectPath == "/Users/tester/payment-api", "Session 1 projectPath matches metadata", testName: testName)
            TestRunner.assertTest(item1.messageCount == 2, "Session 1 messageCount is 2", testName: testName)
            TestRunner.assertTest(item1.associatedPaths.contains(s1Dir.path), "Session 1 associatedPaths contains session dir", testName: testName)
            TestRunner.assertTest(item1.associatedPaths.contains(s1Log.path), "Session 1 associatedPaths contains log file", testName: testName)
            TestRunner.assertTest(item1.associatedPaths.contains(s1Ws.path), "Session 1 associatedPaths contains workspace dir", testName: testName)
        } else {
            TestRunner.assertTest(false, "Session 1 not found", testName: testName)
        }

        if let logItem = items.first(where: { $0.sessionId.hasPrefix("openhands-logs") }) {
            TestRunner.assertTest(logItem.associatedPaths.contains(serverLog.path), "Orphaned log group contains server log", testName: testName)
        } else {
            TestRunner.assertTest(false, "Orphaned log item not found", testName: testName)
        }

        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            let freed = try await scanner.delete(items: [item1])
            TestRunner.assertTest(freed == item1.sizeInBytes, "Freed size matches item1 size", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: s1Dir.path), "Session 1 dir removed", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: s1Log.path), "Session 1 log removed", testName: testName)
            TestRunner.assertTest(!fm.fileExists(atPath: s1Ws.path), "Session 1 workspace removed", testName: testName)
            TestRunner.assertTest(fm.fileExists(atPath: s2File.path), "Session 2 file still exists", testName: testName)
            TestRunner.assertTest(fm.fileExists(atPath: serverLog.path), "server.log still exists", testName: testName)
        }

        let allFreed = try await scanner.cleanAll()
        TestRunner.assertTest(allFreed > 0, "cleanAll freed bytes > 0", testName: testName)
        items = try await scanner.scan()
        TestRunner.assertTest(items.isEmpty, "Rescan after cleanAll returns 0 items", testName: testName)
    } catch {
        TestRunner.assertTest(false, "Mock OpenHands test threw error: \(error)", testName: testName)
    }
}

// MARK: - Main Runner

@main
struct Main {
    static func main() async {
        print("\n\u{001B}[1;35m==================================================================")
        print("  CONVERSATION CLEAN: AGENT SCANNER VERIFICATION SUITE")
        print("==================================================================\u{001B}[0m")

        let startTime = Date()

        await testRealClaudeCodeScannerReadOnly()
        await testMockClaudeCodeScanner()
        await testMockCodexScanner()
        await testMockDeletion()
        await testRealClineScannerReadOnly()
        await testMockClineScanner()
        await testMockRooCodeScanner()
        await testMockContinueScanner()
        await testRealPiAgentScannerReadOnly()
        await testMockPiAgentScanner()
        await testUnifiedMultiAgentScan()

        // 4 IDE Agent Scanners
        await testRealVSCodeChatScannerReadOnly()
        await testMockVSCodeChatScanner()
        await testMockCursorScanner()
        await testMockWindsurfScanner()
        await testMockTraeScanner()

        // 4 New Agent Scanners (OpenViking, Aider, Zed, OpenHands)
        await testRealOpenVikingScannerReadOnly()
        await testMockOpenVikingScanner()
        await testRealAiderScannerReadOnly()
        await testMockAiderScanner()
        await testRealZedScannerReadOnly()
        await testMockZedScanner()
        await testRealOpenHandsScannerReadOnly()
        await testMockOpenHandsScanner()

        let elapsed = Date().timeIntervalSince(startTime)

        print("\n\u{001B}[1;35m==================================================================")
        print("  VERIFICATION SUMMARY")
        print("==================================================================\u{001B}[0m")
        print("Total Passed: \u{001B}[32m\(TestRunner.passedCount)\u{001B}[0m")
        print("Total Failed: \(TestRunner.failedCount > 0 ? "\u{001B}[31m\(TestRunner.failedCount)\u{001B}[0m" : "\u{001B}[32m0\u{001B}[0m")")
        print(String(format: "Execution Time: %.2f seconds", elapsed))

        if !TestRunner.failures.isEmpty {
            print("\n\u{001B}[1;31mFailed Assertions:\u{001B}[0m")
            for failure in TestRunner.failures {
                print("  \u{001B}[31m• \(failure)\u{001B}[0m")
            }
            exit(1)
        } else {
            print("\n\u{001B}[1;32m>>> ALL AGENT SCANNER TESTS PASSED SUCCESSFULLY! <<<\u{001B}[0m\n")
            exit(0)
        }
    }
}


