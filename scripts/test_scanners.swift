import Foundation

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
