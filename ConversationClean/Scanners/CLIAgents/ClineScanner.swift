import Foundation

class ClineScanner: AgentScanner, @unchecked Sendable {
    var category: ConversationCategory { .cline }
    let customStorageURL: URL?

    init(storageURL: URL? = nil) {
        self.customStorageURL = storageURL
    }

    var envVarName: String { "CLINE_HOME" }
    var defaultStorageRelativePath: String {
        "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"
    }

    var storageURL: URL {
        let base: URL
        if let custom = customStorageURL {
            base = custom
        } else if let env = ProcessInfo.processInfo.environment[envVarName], !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(defaultStorageRelativePath)
        }
        return (try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? base.standardized
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: storageURL.path)
    }

    // MARK: - Scan

    func scan() async throws -> [ConversationItem] {
        guard isInstalled else { return [] }

        let fileManager = FileManager.default
        let tasksDir = storageURL.appendingPathComponent("tasks")
        guard fileManager.fileExists(atPath: tasksDir.path) else { return [] }

        let taskDirs = (try? fileManager.contentsOfDirectory(
            at: tasksDir,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var targetTaskIds: [(taskId: String, taskDirURL: URL)] = []
        for dirURL in taskDirs {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue {
                let taskId = dirURL.lastPathComponent
                if !taskId.isEmpty && !taskId.hasPrefix(".") {
                    targetTaskIds.append((taskId: taskId, taskDirURL: dirURL))
                }
            }
        }

        guard !targetTaskIds.isEmpty else { return [] }

        // Preload task history index from state/taskHistory.json if available
        let taskHistoryMap = loadTaskHistory()
        let checkpointsDir = storageURL.appendingPathComponent("checkpoints")

        let items: [ConversationItem] = await withTaskGroup(of: ConversationItem?.self) { group in
            for target in targetTaskIds {
                group.addTask {
                    return self.parseTask(
                        taskId: target.taskId,
                        taskDirURL: target.taskDirURL,
                        checkpointsDirURL: checkpointsDir,
                        historyEntry: taskHistoryMap[target.taskId]
                    )
                }
            }

            var collected: [ConversationItem] = []
            collected.reserveCapacity(targetTaskIds.count)
            for await item in group {
                if let item = item {
                    collected.append(item)
                }
            }
            return collected
        }

        return items.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    // MARK: - Deletion

    func delete(items: [ConversationItem]) async throws -> Int64 {
        guard !items.isEmpty else { return 0 }

        var totalBytesFreed: Int64 = 0
        var deletedSessionIds = Set<String>()

        for item in items {
            totalBytesFreed += CleanPrefs.freedBytes(reported: item.sizeInBytes, for: item)
            deletedSessionIds.insert(item.sessionId)

            for path in CleanPrefs.deletionPaths(for: item) {
                _ = FileSizeHelper.removeIfExists(path: path)
            }
        }

        // Clean taskHistory.json
        cleanTaskHistory(excludingTaskIds: deletedSessionIds)

        // Clean empty directories in tasks directory
        cleanEmptyTaskDirectories()

        return totalBytesFreed
    }

    func cleanAll() async throws -> Int64 {
        let items = try await scan()
        var freed = try await delete(items: items)

        let fileManager = FileManager.default

        // Clean checkpoints folder completely
        // checkpoints/<taskId> 就是 Cline / Roo 的文件改动快照，开关关掉时整目录保留。
        let checkpointsDir = storageURL.appendingPathComponent("checkpoints")
        if CleanPrefs.cleanFileHistorySnapshots,
           fileManager.fileExists(atPath: checkpointsDir.path) {
            let cpSize = FileSizeHelper.sizeOf(path: checkpointsDir.path)
            if FileSizeHelper.removeIfExists(path: checkpointsDir.path) {
                freed += cpSize
                try? fileManager.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
            }
        }

        // Clean cache folder completely
        let cacheDir = storageURL.appendingPathComponent("cache")
        if fileManager.fileExists(atPath: cacheDir.path) {
            let cacheSize = FileSizeHelper.sizeOf(path: cacheDir.path)
            if FileSizeHelper.removeIfExists(path: cacheDir.path) {
                freed += cacheSize
                try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            }
        }

        // Reset state/taskHistory.json
        resetTaskHistory()

        return freed
    }

    // MARK: - Parsing Task

    private struct TaskHistoryEntry: Sendable {
        let id: String
        let task: String?
        let cwd: String?
        let ts: Double?
        let size: Int64?
    }

    private func loadTaskHistory() -> [String: TaskHistoryEntry] {
        let historyFile = storageURL.appendingPathComponent("state/taskHistory.json")
        guard FileManager.default.fileExists(atPath: historyFile.path),
              let data = try? Data(contentsOf: historyFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }

        var map: [String: TaskHistoryEntry] = [:]
        for entry in json {
            guard let id = entry["id"] as? String ?? (entry["id"] as? NSNumber)?.stringValue else { continue }
            let task = entry["task"] as? String
            let cwd = entry["cwdOnTaskInitialization"] as? String ?? entry["cwd"] as? String
            let ts = (entry["ts"] as? NSNumber)?.doubleValue
            let size = (entry["size"] as? NSNumber)?.int64Value
            map[id] = TaskHistoryEntry(id: id, task: task, cwd: cwd, ts: ts, size: size)
        }
        return map
    }

    private func parseTask(
        taskId: String,
        taskDirURL: URL,
        checkpointsDirURL: URL,
        historyEntry: TaskHistoryEntry?
    ) -> ConversationItem {
        let fileManager = FileManager.default
        let uiMessagesFile = taskDirURL.appendingPathComponent("ui_messages.json")
        let apiHistoryFile = taskDirURL.appendingPathComponent("api_conversation_history.json")
        let metadataFile = taskDirURL.appendingPathComponent("task_metadata.json")

        var title: String? = historyEntry?.task
        var projectPath: String? = historyEntry?.cwd
        var snippet: String = ""
        var messageCount: Int = 0
        var latestTimestampMs: Double? = historyEntry?.ts

        // 1. Parse ui_messages.json
        if fileManager.fileExists(atPath: uiMessagesFile.path),
           let data = try? Data(contentsOf: uiMessagesFile),
           let messages = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {

            messageCount = messages.count

            for msg in messages {
                // Track latest timestamp
                if let ts = (msg["ts"] as? NSNumber)?.doubleValue {
                    if latestTimestampMs == nil || ts > latestTimestampMs! {
                        latestTimestampMs = ts
                    }
                }

                // Extract task title from message with say == "task"
                if title == nil || title!.isEmpty {
                    let say = msg["say"] as? String
                    if say == "task", let text = msg["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }

                // Extract first snippet
                if snippet.isEmpty {
                    if let text = msg["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        snippet = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                    }
                }

                // Extract cwd / workspace from message properties or text
                if projectPath == nil || projectPath!.isEmpty {
                    if let directCwd = msg["cwd"] as? String, !directCwd.isEmpty {
                        projectPath = directCwd
                    } else if let directWs = msg["workspace"] as? String, !directWs.isEmpty {
                        projectPath = directWs
                    } else if let text = msg["text"] as? String {
                        if let extracted = Self.extractCwdFromText(text) {
                            projectPath = extracted
                        }
                    }
                }
            }

            // Fallback for title: first message text
            if title == nil || title!.isEmpty {
                for msg in messages {
                    if let text = msg["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
            }
        }

        // 2. Parse api_conversation_history.json if needed
        if fileManager.fileExists(atPath: apiHistoryFile.path),
           let data = try? Data(contentsOf: apiHistoryFile),
           let apiMsgs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            if messageCount == 0 {
                messageCount = apiMsgs.count
            }

            if projectPath == nil || projectPath!.isEmpty {
                for m in apiMsgs {
                    if let content = m["content"] as? String, let extracted = Self.extractCwdFromText(content) {
                        projectPath = extracted
                        break
                    } else if let contentArr = m["content"] as? [[String: Any]] {
                        for part in contentArr {
                            if let text = part["text"] as? String, let extracted = Self.extractCwdFromText(text) {
                                projectPath = extracted
                                break
                            }
                        }
                        if projectPath != nil { break }
                    }
                }
            }
        }

        // 3. Parse task_metadata.json if projectPath or title still missing
        if fileManager.fileExists(atPath: metadataFile.path),
           let data = try? Data(contentsOf: metadataFile),
           let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if projectPath == nil || projectPath!.isEmpty {
                if let files = meta["files_in_context"] as? [String], let firstFile = files.first, firstFile.hasPrefix("/") {
                    projectPath = (firstFile as NSString).deletingLastPathComponent
                }
            }
        }

        // Final fallbacks
        let finalTitle: String
        if let t = title, !t.isEmpty {
            let singleLine = t.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? t
            finalTitle = singleLine.isEmpty ? taskId : singleLine
        } else {
            finalTitle = taskId
        }

        if snippet.isEmpty {
            snippet = finalTitle
        }

        // Date determination
        let updatedDate: Date
        if let tsMs = latestTimestampMs, tsMs > 0 {
            updatedDate = Date(timeIntervalSince1970: tsMs / 1000.0)
        } else if let attrs = try? fileManager.attributesOfItem(atPath: taskDirURL.path),
                  let modDate = attrs[.modificationDate] as? Date {
            updatedDate = modDate
        } else {
            updatedDate = Date()
        }

        // Associated paths: task directory + checkpoints directory if exists
        var associatedPaths: [String] = [taskDirURL.path]
        let checkpointTaskDir = checkpointsDirURL.appendingPathComponent(taskId)
        if fileManager.fileExists(atPath: checkpointTaskDir.path) {
            associatedPaths.append(checkpointTaskDir.path)
        }

        // Size calculation
        var totalSize: Int64 = 0
        for path in associatedPaths {
            totalSize += FileSizeHelper.sizeOf(path: path)
        }
        if totalSize == 0, let historySize = historyEntry?.size, historySize > 0 {
            totalSize = historySize
        }

        return ConversationItem(
            id: UUID(),
            sessionId: taskId,
            title: finalTitle,
            category: self.category,
            projectPath: projectPath,
            gitBranch: nil,
            messageCount: messageCount,
            sizeInBytes: totalSize,
            updatedAt: updatedDate,
            isSelected: false,
            snippet: snippet,
            associatedPaths: associatedPaths
        )
    }

    // MARK: - Regex / Text Utilities

    private static func extractCwdFromText(_ text: String) -> String? {
        // Pattern 1: # Current Working Directory (/path/to/project) Files
        if let regex = try? NSRegularExpression(pattern: #"Current Working Directory \(([^)]+)\)"#, options: []) {
            let nsText = text as NSString
            let range = NSRange(location: 0, length: min(nsText.length, 10000))
            if let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 {
                let extracted = nsText.substring(with: match.range(at: 1))
                if !extracted.isEmpty { return extracted }
            }
        }

        // Pattern 2: "cwd"\s*:\s*"([^"]+)"
        if let regex = try? NSRegularExpression(pattern: #""cwd"\s*:\s*"([^"]+)""#, options: []) {
            let nsText = text as NSString
            let range = NSRange(location: 0, length: min(nsText.length, 10000))
            if let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 {
                let extracted = nsText.substring(with: match.range(at: 1))
                if !extracted.isEmpty { return extracted }
            }
        }

        return nil
    }

    // MARK: - Task History Maintenance

    private func cleanTaskHistory(excludingTaskIds: Set<String>) {
        let historyFile = storageURL.appendingPathComponent("state/taskHistory.json")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: historyFile.path),
              let data = try? Data(contentsOf: historyFile),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return
        }

        json.removeAll { entry in
            guard let id = entry["id"] as? String ?? (entry["id"] as? NSNumber)?.stringValue else { return false }
            return excludingTaskIds.contains(id)
        }

        if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? updatedData.write(to: historyFile, options: .atomic)
        }
    }

    private func resetTaskHistory() {
        let historyFile = storageURL.appendingPathComponent("state/taskHistory.json")
        if FileManager.default.fileExists(atPath: historyFile.path) {
            let emptyData = "[]\n".data(using: .utf8) ?? Data()
            try? emptyData.write(to: historyFile, options: .atomic)
        }
    }

    private func cleanEmptyTaskDirectories() {
        let tasksDir = storageURL.appendingPathComponent("tasks")
        FileSizeHelper.removeIfEmptyDirectory(path: tasksDir.path)
    }
}
