import Foundation

final class OpenHandsScanner: AgentScanner, @unchecked Sendable {
    let category: ConversationCategory = .openHands
    let customStorageURL: URL?

    init(storageURL: URL? = nil) {
        self.customStorageURL = storageURL
    }

    convenience init(baseURL: URL?) {
        self.init(storageURL: baseURL)
    }

    var storageURL: URL {
        if let custom = customStorageURL {
            return (try? custom.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? custom.standardized
        }
        if let env = ProcessInfo.processInfo.environment["OPENHANDS_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultPath = home.appendingPathComponent(".openhands")
        if FileManager.default.fileExists(atPath: defaultPath.path) {
            return defaultPath
        }
        let fallback = home.appendingPathComponent(".open-devin")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return defaultPath
    }

    var fallbackURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".open-devin")
    }

    var isInstalled: Bool {
        if let custom = customStorageURL {
            return FileManager.default.fileExists(atPath: custom.path)
        }
        let fm = FileManager.default
        return fm.fileExists(atPath: storageURL.path) || fm.fileExists(atPath: fallbackURL.path)
    }

    private var targetRoots: [URL] {
        if let custom = customStorageURL { return [custom] }
        var roots: [URL] = []
        let fm = FileManager.default
        if fm.fileExists(atPath: storageURL.path) {
            roots.append(storageURL)
        }
        if fallbackURL.path != storageURL.path && fm.fileExists(atPath: fallbackURL.path) {
            roots.append(fallbackURL)
        }
        if roots.isEmpty {
            roots.append(storageURL)
        }
        return roots
    }

    // MARK: - Scan

    func scan() async throws -> [ConversationItem] {
        guard isInstalled else { return [] }

        var allItems: [ConversationItem] = []
        let fm = FileManager.default

        for root in targetRoots {
            guard fm.fileExists(atPath: root.path) else { continue }

            var sessionItems: [ConversationItem] = []
            var sessionIds = Set<String>()

            // 1. Scan sessions/
            let sessionsDir = root.appendingPathComponent("sessions")
            if fm.fileExists(atPath: sessionsDir.path) {
                let entries = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])) ?? []

                for entry in entries {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: entry.path, isDirectory: &isDir) {
                        if isDir.boolValue {
                            if let item = parseSessionDirectory(dirURL: entry) {
                                sessionItems.append(item)
                                sessionIds.insert(item.sessionId)
                            }
                        } else if entry.pathExtension.lowercased() == "json" || entry.pathExtension.lowercased() == "jsonl" {
                            if let item = parseSessionFile(fileURL: entry) {
                                sessionItems.append(item)
                                sessionIds.insert(item.sessionId)
                            }
                        }
                    }
                }
            }

            // 2. Scan logs/ and correlate with sessions or collect system logs
            let logsDir = root.appendingPathComponent("logs")
            var orphanedLogs: [String] = []
            var orphanedLogsSize: Int64 = 0
            var latestLogDate = Date.distantPast

            if fm.fileExists(atPath: logsDir.path) {
                let logFiles = (try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []

                for logFile in logFiles {
                    let logPath = logFile.path
                    let logSize = FileSizeHelper.sizeOf(path: logPath)
                    let baseName = logFile.deletingPathExtension().lastPathComponent

                    let modDate = (try? fm.attributesOfItem(atPath: logPath)[.modificationDate] as? Date) ?? Date()
                    if modDate > latestLogDate {
                        latestLogDate = modDate
                    }

                    // Check if this log file matches a known session
                    var matched = false
                    for i in 0..<sessionItems.count {
                        let sid = sessionItems[i].sessionId
                        if baseName == sid || baseName.contains(sid) || sid.contains(baseName) {
                            if !sessionItems[i].associatedPaths.contains(logPath) {
                                sessionItems[i].associatedPaths.append(logPath)
                                sessionItems[i].sizeInBytes += logSize
                            }
                            matched = true
                            break
                        }
                    }

                    if !matched {
                        orphanedLogs.append(logPath)
                        orphanedLogsSize += logSize
                    }
                }
            }

            // 3. Scan workspace/ and correlate with sessions
            let workspaceDir = root.appendingPathComponent("workspace")
            if fm.fileExists(atPath: workspaceDir.path) {
                let wsEntries = (try? fm.contentsOfDirectory(at: workspaceDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

                for wsEntry in wsEntries {
                    let wsName = wsEntry.lastPathComponent
                    let wsPath = wsEntry.path
                    let wsSize = FileSizeHelper.sizeOf(path: wsPath)

                    for i in 0..<sessionItems.count {
                        let sid = sessionItems[i].sessionId
                        if wsName == sid || wsName.contains(sid) || sid.contains(wsName) {
                            if !sessionItems[i].associatedPaths.contains(wsPath) {
                                sessionItems[i].associatedPaths.append(wsPath)
                                sessionItems[i].sizeInBytes += wsSize
                            }
                            break
                        }
                    }
                }
            }

            allItems.append(contentsOf: sessionItems)

            // If there are orphaned/system logs, group into an item
            if !orphanedLogs.isEmpty && orphanedLogsSize > 0 {
                let date = latestLogDate == Date.distantPast ? Date() : latestLogDate
                let rootName = root.lastPathComponent
                allItems.append(ConversationItem(
                    id: UUID(),
                    sessionId: "openhands-logs-\(rootName)",
                    title: "OpenHands 运行与调用日志 (\(orphanedLogs.count) 个文件)",
                    category: .openHands,
                    projectPath: logsDir.path,
                    gitBranch: nil,
                    messageCount: orphanedLogs.count,
                    sizeInBytes: orphanedLogsSize,
                    updatedAt: date,
                    isSelected: false,
                    snippet: "OpenHands 系统运行、LLM API 调用及诊断日志",
                    associatedPaths: orphanedLogs
                ))
            }
        }

        return allItems.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    // MARK: - Deletion & Clean

    func delete(items: [ConversationItem]) async throws -> Int64 {
        guard !items.isEmpty else { return 0 }

        var totalBytesFreed: Int64 = 0

        for item in items {
            totalBytesFreed += item.sizeInBytes
            for path in item.associatedPaths {
                guard isSafeToDelete(path: path) else { continue }
                _ = FileSizeHelper.removeIfExists(path: path)
            }
        }

        return totalBytesFreed
    }

    func cleanAll() async throws -> Int64 {
        let items = try await scan()
        var totalFreed = try await delete(items: items)

        let fm = FileManager.default

        for root in targetRoots {
            guard fm.fileExists(atPath: root.path) else { continue }

            let subdirs = ["sessions", "logs", "workspace"]
            for subdir in subdirs {
                let dirURL = root.appendingPathComponent(subdir)
                if fm.fileExists(atPath: dirURL.path) {
                    let size = FileSizeHelper.sizeOf(path: dirURL.path)
                    if FileSizeHelper.removeIfExists(path: dirURL.path) {
                        totalFreed += size
                        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
                    }
                }
            }
        }

        return totalFreed
    }

    // MARK: - Parsing Helpers

    private func parseSessionDirectory(dirURL: URL) -> ConversationItem? {
        let fm = FileManager.default
        let sessionId = dirURL.lastPathComponent
        guard !sessionId.isEmpty, !sessionId.hasPrefix(".") else { return nil }

        let size = FileSizeHelper.sizeOf(path: dirURL.path)
        let attrs = try? fm.attributesOfItem(atPath: dirURL.path)
        var modDate = (attrs?[.modificationDate] as? Date) ?? Date()

        var title: String?
        var snippet: String?
        var projectPath: String?
        var messageCount = 0

        // 1. Check metadata.json
        let metadataURL = dirURL.appendingPathComponent("metadata.json")
        if let data = try? Data(contentsOf: metadataURL),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            title = extractTitle(from: json)
            snippet = extractSnippet(from: json)
            projectPath = extractProjectPath(from: json)

            if let dateStr = json["created_at"] as? String ?? json["updated_at"] as? String,
               let parsed = parseDate(dateStr) {
                modDate = parsed
            }
        }

        // 2. Check events.jsonl or events.json
        let eventsJsonl = dirURL.appendingPathComponent("events.jsonl")
        let eventsJson = dirURL.appendingPathComponent("events.json")

        if fm.fileExists(atPath: eventsJsonl.path) {
            let (eventTitle, count) = parseEventsJsonl(fileURL: eventsJsonl)
            if title == nil || title?.isEmpty == true {
                title = eventTitle
            }
            messageCount = count
        } else if fm.fileExists(atPath: eventsJson.path) {
            let (eventTitle, count) = parseEventsJson(fileURL: eventsJson)
            if title == nil || title?.isEmpty == true {
                title = eventTitle
            }
            messageCount = count
        }

        let finalTitle = title ?? "OpenHands 会话 \(sessionId.prefix(8))"
        let finalSnippet = snippet ?? title ?? "OpenHands 任务会话"

        return ConversationItem(
            id: UUID(),
            sessionId: sessionId,
            title: String(finalTitle.prefix(80)).replacingOccurrences(of: "\n", with: " "),
            category: .openHands,
            projectPath: projectPath,
            gitBranch: nil,
            messageCount: max(1, messageCount),
            sizeInBytes: size,
            updatedAt: modDate,
            isSelected: false,
            snippet: String(finalSnippet.prefix(120)).replacingOccurrences(of: "\n", with: " "),
            associatedPaths: [dirURL.path]
        )
    }

    private func parseSessionFile(fileURL: URL) -> ConversationItem? {
        let fm = FileManager.default
        let sessionId = fileURL.deletingPathExtension().lastPathComponent
        guard !sessionId.isEmpty, !sessionId.hasPrefix(".") else { return nil }

        let size = FileSizeHelper.sizeOf(path: fileURL.path)
        let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
        var modDate = (attrs?[.modificationDate] as? Date) ?? Date()

        var title: String?
        var snippet: String?
        var projectPath: String?
        var messageCount = 1

        if fileURL.pathExtension.lowercased() == "json",
           let data = try? Data(contentsOf: fileURL),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            title = extractTitle(from: json)
            snippet = extractSnippet(from: json)
            projectPath = extractProjectPath(from: json)

            if let dateStr = json["created_at"] as? String ?? json["updated_at"] as? String,
               let parsed = parseDate(dateStr) {
                modDate = parsed
            }

            if let events = json["events"] as? [Any] {
                messageCount = events.count
            } else if let messages = json["messages"] as? [Any] {
                messageCount = messages.count
            }
        } else if fileURL.pathExtension.lowercased() == "jsonl" {
            let (eventTitle, count) = parseEventsJsonl(fileURL: fileURL)
            title = eventTitle
            messageCount = count
        }

        let finalTitle = title ?? "OpenHands 会话 \(sessionId.prefix(8))"
        let finalSnippet = snippet ?? title ?? "OpenHands 任务会话"

        return ConversationItem(
            id: UUID(),
            sessionId: sessionId,
            title: String(finalTitle.prefix(80)).replacingOccurrences(of: "\n", with: " "),
            category: .openHands,
            projectPath: projectPath,
            gitBranch: nil,
            messageCount: max(1, messageCount),
            sizeInBytes: size,
            updatedAt: modDate,
            isSelected: false,
            snippet: String(finalSnippet.prefix(120)).replacingOccurrences(of: "\n", with: " "),
            associatedPaths: [fileURL.path]
        )
    }

    private func parseEventsJsonl(fileURL: URL) -> (title: String?, count: Int) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return (nil, 1) }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 64 * 1024)
        let text = String(decoding: data, as: UTF8.self)

        var firstUserPrompt: String?
        var count = 0

        text.enumerateLines { line, stop in
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return
            }
            count += 1

            if firstUserPrompt == nil {
                let action = json["action"] as? String
                let source = json["source"] as? String
                if action == "message" || source == "user" {
                    if let args = json["args"] as? [String: Any],
                       let content = args["content"] as? String,
                       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        firstUserPrompt = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }

        return (firstUserPrompt, max(1, count))
    }

    private func parseEventsJson(fileURL: URL) -> (title: String?, count: Int) {
        guard let data = try? Data(contentsOf: fileURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return (nil, 1)
        }

        var firstPrompt: String?
        for event in json {
            let action = event["action"] as? String
            let source = event["source"] as? String
            if action == "message" || source == "user" {
                if let args = event["args"] as? [String: Any],
                   let content = args["content"] as? String,
                   !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    firstPrompt = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }

        return (firstPrompt, max(1, json.count))
    }

    private func extractTitle(from json: [String: Any]) -> String? {
        let keys = ["title", "initial_prompt", "task", "instructions", "prompt"]
        for key in keys {
            if let val = json[key] as? String, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func extractSnippet(from json: [String: Any]) -> String? {
        let keys = ["initial_prompt", "task", "instructions", "title", "prompt"]
        for key in keys {
            if let val = json[key] as? String, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func extractProjectPath(from json: [String: Any]) -> String? {
        let keys = ["directory", "project_dir", "workspace", "cwd", "selected_repository"]
        for key in keys {
            if let val = json[key] as? String, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func parseDate(_ string: String) -> Date? {
        ISODate.parse(string)
    }

    private func isSafeToDelete(path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardized
        for root in targetRoots {
            if url.path.hasPrefix(root.standardized.path) {
                return true
            }
        }
        return false
    }
}
