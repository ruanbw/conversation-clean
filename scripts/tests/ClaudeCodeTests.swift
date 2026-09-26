import Foundation
import SQLite3

func testRealClaudeCodeScannerReadOnly() async {
    let t = TestCase("RealClaudeReadOnly", section: "Test 1: Real Local ~/.claude Scanner (READ-ONLY)")

    let realScanner = ClaudeCodeScanner()

    t.sub("Checking Installation and Storage URL")
    let homePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
    t.assert(TestRunner.canonicalPath(realScanner.storageURL.path) == TestRunner.canonicalPath(homePath), "storageURL correctly points to ~/.claude")
    t.assert(realScanner.category == .claudeCode, "Category is .claudeCode")

    let isRealInstalled = FileManager.default.fileExists(atPath: realScanner.storageURL.path)
    t.assert(realScanner.isInstalled == isRealInstalled, "isInstalled matches filesystem check (\(isRealInstalled))")

    if !isRealInstalled {
        print("  \u{001B}[33m[INFO] ~/.claude not found on system. Skipping real file scan checks.\u{001B}[0m")
        return
    }

    t.sub("Scanning Real Local ~/.claude (READ-ONLY)")
    do {
        let items = try await realScanner.scan()
        t.assert(true, "scan() executed without throwing an error")
        print("  \u{001B}[34m[INFO] Scanned \(items.count) sessions from real ~/.claude\u{001B}[0m")

        if !items.isEmpty {
            let totalBytes = items.reduce(0) { $0 + $1.sizeInBytes }
            let formattedTotal = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            print("  \u{001B}[34m[INFO] Total size of real sessions: \(formattedTotal) (\(totalBytes) bytes)\u{001B}[0m")

            // Verify category
            let allAreClaude = items.allSatisfy { $0.category == .claudeCode }
            t.assert(allAreClaude, "All items have category .claudeCode")

            // Verify non-empty sessionIds
            let allHaveSessionId = items.allSatisfy { !$0.sessionId.isEmpty }
            t.assert(allHaveSessionId, "All items have valid non-empty sessionId")

            // Verify descending sort order by updatedAt
            var isSorted = true
            for i in 0..<(items.count - 1) {
                if items[i].updatedAt < items[i + 1].updatedAt {
                    isSorted = false
                    break
                }
            }
            t.assert(isSorted, "Items are sorted by updatedAt descending")

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
            t.assert(associatedPathsValid, "All associatedPaths exist on the real filesystem")

            // Sample first 3 items
            print("  \u{001B}[34m[INFO] Sample real sessions:\u{001B}[0m")
            for (idx, item) in items.prefix(3).enumerated() {
                print("    [\(idx + 1)] ID: \(item.shortSessionId)... | Size: \(item.formattedSize) | Title: \(item.title.prefix(50)) | Project: \(item.displayProjectPath)")
            }
        }
    } catch {
        t.assert(false, "scan() threw unexpected error: \(error)")
    }
}

func testMockClaudeCodeScanner() async {
    let t = TestCase("MockClaudeScan", section: "Test 2: Mock Claude Code Scanner (Fixture Directory)")

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_claude_scan")

    defer {
        try? fm.removeItem(at: tempDir)
    }

    t.sub("Setting up Mock ~/.claude Structure")
    let projectsDir = tempDir.appendingPathComponent("projects")
    let projectADir = projectsDir.appendingPathComponent("-Users-tester-projectA")
    let projectBDir = projectsDir.appendingPathComponent("-Users-tester-projectB")
    let directSessionsDir = tempDir.appendingPathComponent("sessions")
    let fileHistoryDir = tempDir.appendingPathComponent("file-history")
    let plansDir = tempDir.appendingPathComponent("plans")
    let sessionEnvDir = tempDir.appendingPathComponent("session-env")

    Fixture.dir(projectADir)
    Fixture.dir(projectBDir)
    Fixture.dir(directSessionsDir)
    Fixture.dir(fileHistoryDir)
    Fixture.dir(plansDir)
    Fixture.dir(sessionEnvDir)

    // Session 1 in projectA: has subagent dir, file-history, plan, session-env
    let sid1 = "claude-session-001"
    let s1File = projectADir.appendingPathComponent("\(sid1).jsonl")
    let s1Content = """
    {"cwd":"/Users/tester/projectA","gitBranch":"feature/auth","slug":"auth-system","type":"user","message":{"content":"Build authentication system with OAuth2"}}
    {"type":"assistant","message":{"content":"I will help you implement OAuth2."}}
    """
    Fixture.write(s1Content, to: s1File)

    // Subagent directory for s1
    let s1SubagentDir = projectADir.appendingPathComponent(sid1)
    Fixture.dir(s1SubagentDir)
    Fixture.write("subagent log data", to: s1SubagentDir.appendingPathComponent("subagent-1.jsonl"))

    // Associated file-history for s1
    let s1FileHistDir = fileHistoryDir.appendingPathComponent(sid1)
    Fixture.dir(s1FileHistDir)
    Fixture.write("history backup content", to: s1FileHistDir.appendingPathComponent("App.swift"))

    // Associated plan for s1
    let s1PlanDir = plansDir.appendingPathComponent(sid1)
    Fixture.dir(s1PlanDir)
    Fixture.write("# OAuth Plan", to: s1PlanDir.appendingPathComponent("plan.md"))

    // Associated session-env for s1
    let s1EnvDir = sessionEnvDir.appendingPathComponent(sid1)
    Fixture.dir(s1EnvDir)
    Fixture.write("{\"NODE_ENV\":\"test\"}", to: s1EnvDir.appendingPathComponent("env.json"))

    // Session 2 in projectB: normal session with memory folder alongside
    let sid2 = "claude-session-002"
    let s2File = projectBDir.appendingPathComponent("\(sid2).jsonl")
    let s2Content = """
    {"cwd":"/Users/tester/projectB","gitBranch":"main","type":"user","message":{"content":[{"text":"Fix payment retry logic in checkout"}]}}
    {"type":"assistant","message":{"content":"Checking retry parameters."}}
    """
    Fixture.write(s2Content, to: s2File)
    let memoryDir = projectBDir.appendingPathComponent("memory")
    Fixture.dir(memoryDir)
    Fixture.write("Project memory data", to: memoryDir.appendingPathComponent("notes.md"))

    // Session 3 in direct sessions/
    let sid3 = "claude-session-003"
    let s3File = directSessionsDir.appendingPathComponent("\(sid3).jsonl")
    let s3Content = """
    {"type":"user","message":{"content":"Quick explanation of Swift Concurrency"}}
    """
    Fixture.write(s3Content, to: s3File)

    // history.jsonl
    let historyFile = tempDir.appendingPathComponent("history.jsonl")
    let historyContent = """
    {"sessionId":"\(sid1)","display":"Build authentication system with OAuth2","project":"/Users/tester/projectA","timestamp":1700000000000}
    {"sessionId":"\(sid1)","display":"Add refresh token support","project":"/Users/tester/projectA","timestamp":1700000050000}
    {"sessionId":"\(sid2)","display":"Fix payment retry logic in checkout","project":"/Users/tester/projectB","timestamp":1700001000000}
    {"sessionId":"\(sid3)","display":"Quick explanation of Swift Concurrency","project":null,"timestamp":1700002000000}
    """
    Fixture.write(historyContent, to: historyFile)

    t.sub("Executing Mock Claude Code Scanner")
    let scanner = ClaudeCodeScanner(storageURL: tempDir)
    t.assert(scanner.isInstalled, "scanner.isInstalled is true for fixture directory")

    do {
        let items = try await scanner.scan()
        t.assert(items.count == 3, "Detected exactly 3 Claude Code sessions (found \(items.count))")

        // Find session 1
        if let item1 = items.first(where: { $0.sessionId == sid1 }) {
            t.assert(item1.projectPath == "/Users/tester/projectA", "Session 1 projectPath matches /Users/tester/projectA")
            t.assert(item1.gitBranch == "feature/auth", "Session 1 gitBranch matches feature/auth")
            t.assert(item1.title.contains("Build authentication system"), "Session 1 title parsed correctly (\(item1.title))")
            t.assert(item1.messageCount == 2, "Session 1 messageCount matches history displays (2)")

            // Verify associated paths for session 1
            let canonAssociated = Set(item1.associatedPaths.map { TestRunner.canonicalPath($0) })
            let hasSessionFile = canonAssociated.contains(TestRunner.canonicalPath(s1File.path))
            let hasSubagent = canonAssociated.contains(TestRunner.canonicalPath(s1SubagentDir.path))
            let hasFileHist = canonAssociated.contains(TestRunner.canonicalPath(s1FileHistDir.path))
            let hasPlan = canonAssociated.contains(TestRunner.canonicalPath(s1PlanDir.path))
            let hasEnv = canonAssociated.contains(TestRunner.canonicalPath(s1EnvDir.path))
            t.assert(hasSessionFile && hasSubagent && hasFileHist && hasPlan && hasEnv,
                                  "Session 1 associatedPaths includes session file, subagent dir, file-history, plan, and session-env")

            // Verify calculated size matches sum of associated paths
            var calculatedExpected: Int64 = 0
            for p in item1.associatedPaths {
                calculatedExpected += FileSizeHelper.sizeOf(path: p)
            }
            t.assert(item1.sizeInBytes == calculatedExpected,
                                  "Session 1 sizeInBytes (\(item1.sizeInBytes)) matches sum of all associated paths (\(calculatedExpected))")
        } else {
            t.assert(false, "Session 1 (\(sid1)) not found in scanned items")
        }

        // Find session 2
        if let item2 = items.first(where: { $0.sessionId == sid2 }) {
            t.assert(item2.projectPath == "/Users/tester/projectB", "Session 2 projectPath matches /Users/tester/projectB")
            t.assert(item2.gitBranch == "main", "Session 2 gitBranch matches main")
            t.assert(item2.title.contains("Fix payment retry logic"), "Session 2 title parsed from user message array (\(item2.title))")
        } else {
            t.assert(false, "Session 2 (\(sid2)) not found in scanned items")
        }

        // Find session 3
        if let item3 = items.first(where: { $0.sessionId == sid3 }) {
            t.assert(item3.title.contains("Swift Concurrency"), "Session 3 title parsed from direct session (\(item3.title))")
        } else {
            t.assert(false, "Session 3 (\(sid3)) not found in scanned items")
        }

    } catch {
        t.assert(false, "Mock Claude scan threw error: \(error)")
    }
}
