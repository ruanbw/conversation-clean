import Foundation
import SQLite3

func testRealClineScannerReadOnly() async {
    let t = TestCase("RealClineReadOnly", section: "Test 5: Real Local Cline Scanner (READ-ONLY)")

    let realScanner = ClineScanner()

    t.sub("Checking Installation and Storage URL")
    let homePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev").path
    t.assert(TestRunner.canonicalPath(realScanner.storageURL.path) == TestRunner.canonicalPath(homePath), "storageURL correctly points to Cline directory")
    t.assert(realScanner.category == .cline, "Category is .cline")

    let isRealInstalled = FileManager.default.fileExists(atPath: realScanner.storageURL.path)
    t.assert(realScanner.isInstalled == isRealInstalled, "isInstalled matches filesystem check (\(isRealInstalled))")

    if !isRealInstalled {
        print("  \u{001B}[33m[INFO] Cline storage not found on system. Skipping real file scan checks.\u{001B}[0m")
        return
    }

    t.sub("Scanning Real Local Cline Tasks (READ-ONLY)")
    do {
        let items = try await realScanner.scan()
        t.assert(true, "scan() executed without throwing an error")
        print("  \u{001B}[34m[INFO] Scanned \(items.count) sessions from real Cline\u{001B}[0m")

        if !items.isEmpty {
            let totalBytes = items.reduce(0) { $0 + $1.sizeInBytes }
            let formattedTotal = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            print("  \u{001B}[34m[INFO] Total size of real Cline sessions: \(formattedTotal) (\(totalBytes) bytes)\u{001B}[0m")

            // Verify task 1790252321985
            if let task = items.first(where: { $0.sessionId == "1790252321985" }) {
                t.assert(task.title == "hello", "Task 1790252321985 title is 'hello' (found: '\(task.title)')")
                t.assert(task.projectPath == "/Users/ruanbw/projects/bennett-usage", "Task 1790252321985 cwd is '/Users/ruanbw/projects/bennett-usage' (found: '\(task.projectPath ?? "nil")')")
                t.assert(task.messageCount == 10, "Task 1790252321985 messageCount is 10 (found: \(task.messageCount))")
                t.assert(task.sizeInBytes > 0, "Task 1790252321985 sizeInBytes > 0 (\(task.sizeInBytes) bytes)")
                t.assert(task.category == .cline, "Task category is .cline")
                let calendar = Calendar.current
                let year = calendar.component(.year, from: task.updatedAt)
                t.assert(year >= 2024, "Task updatedAt has valid recent year (\(year))")
            } else {
                t.assert(false, "Did not find expected task 1790252321985 in real Cline scan")
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
            t.assert(associatedPathsValid, "All associatedPaths exist on the real filesystem")

            // Print sample info
            for item in items {
                print("    ID: \(item.sessionId) | Title: \(item.title) | Cwd: \(item.displayProjectPath) | Msgs: \(item.messageCount) | Size: \(item.formattedSize) | Date: \(item.formattedDate)")
            }
        }
    } catch {
        t.assert(false, "scan() threw unexpected error: \(error)")
    }
}

func testMockClineScanner() async {
    let t = TestCase("MockClineScan", section: "Test 6: Mock Cline Scanner (Fixture Directory)")

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_cline_scan")
    defer { try? fm.removeItem(at: tempDir) }

    t.sub("Setting up Mock Cline Storage Structure")
    let tasksDir = tempDir.appendingPathComponent("tasks")
    let checkpointsDir = tempDir.appendingPathComponent("checkpoints")
    let stateDir = tempDir.appendingPathComponent("state")
    let cacheDir = tempDir.appendingPathComponent("cache")

    Fixture.dir(tasksDir)
    Fixture.dir(checkpointsDir)
    Fixture.dir(stateDir)
    Fixture.dir(cacheDir)

    // Task 1: has ui_messages, task_metadata, api_conversation_history, and checkpoints
    let t1Id = "cline-task-001"
    let t1Dir = tasksDir.appendingPathComponent(t1Id)
    let t1CpDir = checkpointsDir.appendingPathComponent(t1Id)
    Fixture.dir(t1Dir)
    Fixture.dir(t1CpDir)
    Fixture.write("checkpoint git commit data", to: t1CpDir.appendingPathComponent("commit.dat"))

    let t1UiMessages = """
    [
      {"ts": 1789000000000, "type": "say", "say": "task", "text": "Refactor Swift Concurrency Actors"},
      {"ts": 1789000005000, "type": "say", "say": "text", "text": "Analyzing codebase actors..."},
      {"ts": 1789000010000, "type": "say", "say": "completion_result", "text": "Refactor completed."}
    ]
    """
    Fixture.write(t1UiMessages, to: t1Dir.appendingPathComponent("ui_messages.json"))

    let t1Metadata = """
    {
      "files_in_context": ["/Users/tester/actor-demo/Sources/Actor.swift"],
      "model_usage": [{"ts": 1789000000000, "model_id": "claude-3-5-sonnet", "mode": "act"}]
    }
    """
    Fixture.write(t1Metadata, to: t1Dir.appendingPathComponent("task_metadata.json"))

    let t1ApiHistory = """
    [
      {"role": "user", "content": "# Current Working Directory (/Users/tester/actor-demo) Files\\nRefactor actors"},
      {"role": "assistant", "content": "I will update Actor.swift"}
    ]
    """
    Fixture.write(t1ApiHistory, to: t1Dir.appendingPathComponent("api_conversation_history.json"))

    // Task 2: uses taskHistory.json for cwd and title
    let t2Id = "cline-task-002"
    let t2Dir = tasksDir.appendingPathComponent(t2Id)
    Fixture.dir(t2Dir)
    let t2UiMessages = """
    [
      {"ts": 1789100000000, "type": "say", "say": "task", "text": "Build REST API Client in Go"}
    ]
    """
    Fixture.write(t2UiMessages, to: t2Dir.appendingPathComponent("ui_messages.json"))

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
    Fixture.write(taskHistoryContent, to: stateDir.appendingPathComponent("taskHistory.json"))

    // Cache file
    Fixture.write("catalog data", to: cacheDir.appendingPathComponent("catalog.json"))

    t.sub("Executing Mock Cline Scanner")
    let scanner = ClineScanner(storageURL: tempDir)
    t.assert(scanner.isInstalled, "scanner.isInstalled is true for fixture directory")
    t.assert(scanner.category == .cline, "Category is .cline")

    do {
        var items = try await scanner.scan()
        t.assert(items.count == 2, "Detected exactly 2 Cline tasks (found \(items.count))")

        // Verify task 1
        if let item1 = items.first(where: { $0.sessionId == t1Id }) {
            t.assert(item1.title == "Refactor Swift Concurrency Actors", "Task 1 title matches prompt (\(item1.title))")
            t.assert(item1.projectPath == "/Users/tester/actor-demo", "Task 1 cwd matches /Users/tester/actor-demo")
            t.assert(item1.messageCount == 3, "Task 1 messageCount is 3")
            let canonPaths = Set(item1.associatedPaths.map { TestRunner.canonicalPath($0) })
            t.assert(canonPaths.contains(TestRunner.canonicalPath(t1Dir.path)), "Task 1 associatedPaths contains task directory")
            t.assert(canonPaths.contains(TestRunner.canonicalPath(t1CpDir.path)), "Task 1 associatedPaths contains checkpoint directory")
            let calculatedSize = FileSizeHelper.sizeOf(path: t1Dir.path) + FileSizeHelper.sizeOf(path: t1CpDir.path)
            t.assert(item1.sizeInBytes == calculatedSize, "Task 1 size matches sum of task dir + checkpoints (\(item1.sizeInBytes) == \(calculatedSize))")
        } else {
            t.assert(false, "Task 1 not found")
        }

        // Verify task 2
        if let item2 = items.first(where: { $0.sessionId == t2Id }) {
            t.assert(item2.title == "Build REST API Client in Go", "Task 2 title matches prompt (\(item2.title))")
            t.assert(item2.projectPath == "/Users/tester/go-api", "Task 2 cwd matches /Users/tester/go-api")
        } else {
            t.assert(false, "Task 2 not found")
        }

        // Deletion test: delete item 1
        print("  \u{001B}[34m[INFO] Deleting Cline Task 1...\u{001B}[0m")
        if let item1 = items.first(where: { $0.sessionId == t1Id }) {
            let freed = try await scanner.delete(items: [item1])
            t.assert(freed == item1.sizeInBytes, "Freed size (\(freed)) matches item 1 size (\(item1.sizeInBytes))")
            t.assert(!fm.fileExists(atPath: t1Dir.path), "Task 1 folder removed from disk")
            t.assert(!fm.fileExists(atPath: t1CpDir.path), "Task 1 checkpoint folder removed from disk")

            // Verify taskHistory.json updated
            let histFile = stateDir.appendingPathComponent("taskHistory.json")
            let histStr = (try? String(contentsOf: histFile, encoding: .utf8)) ?? ""
            t.assert(!histStr.contains(t1Id), "taskHistory.json no longer contains Task 1")
            t.assert(histStr.contains(t2Id), "taskHistory.json still contains Task 2")

            // Rescan shows 1 item
            items = try await scanner.scan()
            t.assert(items.count == 1 && items.first?.sessionId == t2Id, "Rescan shows 1 task remaining")
        }

        // Clean all test
        print("  \u{001B}[34m[INFO] Calling scanner.cleanAll()...\u{001B}[0m")
        let totalFreed = try await scanner.cleanAll()
        t.assert(totalFreed > 0, "cleanAll() returned freed bytes (\(totalFreed))")
        items = try await scanner.scan()
        t.assert(items.isEmpty, "Rescan after cleanAll returns 0 tasks")

    } catch {
        t.assert(false, "Mock Cline scan threw error: \(error)")
    }
}
