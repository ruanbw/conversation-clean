import Foundation

final class ClaudeCodeScanner: AgentScanner, @unchecked Sendable {
    let category: ConversationCategory = .claudeCode
    let customStorageURL: URL?

    init(storageURL: URL? = nil) {
        self.customStorageURL = storageURL
    }

    var storageURL: URL {
        let base: URL
        if let custom = customStorageURL {
            base = custom
        } else if let env = ProcessInfo.processInfo.environment["CLAUDE_HOME"], !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        }
        return (try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? base.standardized
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: storageURL.path)
    }

    private struct SessionTarget: Sendable {
        let fileURL: URL
        let sessionId: String
        let projectDirURL: URL
    }

    func scan() async throws -> [ConversationItem] {
        guard isInstalled else { return [] }

        let fileManager = FileManager.default
        var targets: [SessionTarget] = []
        var seenSessionIds = Set<String>()

        let projectsURL = storageURL.appendingPathComponent("projects")
        if fileManager.fileExists(atPath: projectsURL.path) {
            let projectDirs = (try? fileManager.contentsOfDirectory(at: projectsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

            for projectDir in projectDirs {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: projectDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }

                let entries = (try? fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
                for entry in entries where entry.pathExtension == "jsonl" {
                    let sessionId = entry.deletingPathExtension().lastPathComponent
                    guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
                    seenSessionIds.insert(sessionId)
                    targets.append(SessionTarget(fileURL: entry, sessionId: sessionId, projectDirURL: projectDir))
                }
            }
        }

        // Also check ~/.claude/sessions/ if any direct sessions exist there
        let directSessionsURL = storageURL.appendingPathComponent("sessions")
        if fileManager.fileExists(atPath: directSessionsURL.path) {
            let entries = (try? fileManager.contentsOfDirectory(at: directSessionsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for entry in entries where entry.pathExtension == "jsonl" {
                let sessionId = entry.deletingPathExtension().lastPathComponent
                guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
                seenSessionIds.insert(sessionId)
                targets.append(SessionTarget(fileURL: entry, sessionId: sessionId, projectDirURL: directSessionsURL))
            }
        }

        guard !targets.isEmpty else { return [] }

        let historyMap = loadHistory()
        let associatedArtifacts = preIndexAssociatedDirectories()

        // Concurrent multi-core parsing using TaskGroup
        let items: [ConversationItem] = await withTaskGroup(of: ConversationItem.self) { group in
            for target in targets {
                group.addTask {
                    return self.parseSession(
                        fileURL: target.fileURL,
                        sessionId: target.sessionId,
                        projectDirURL: target.projectDirURL,
                        history: historyMap[target.sessionId],
                        associatedArtifacts: associatedArtifacts
                    )
                }
            }

            var collected: [ConversationItem] = []
            collected.reserveCapacity(targets.count)
            for await item in group {
                collected.append(item)
            }
            return collected
        }

        return items.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    func delete(items: [ConversationItem]) async throws -> Int64 {
        guard !items.isEmpty else { return 0 }

        var totalBytesFreed: Int64 = 0
        var deletedSessionIds = Set<String>()

        for item in items {
            totalBytesFreed += item.sizeInBytes
            deletedSessionIds.insert(item.sessionId)

            for path in item.associatedPaths {
                _ = FileSizeHelper.removeIfExists(path: path)
            }
        }

        cleanHistory(excludingSessionIds: deletedSessionIds)
        cleanEmptyProjectDirectories()

        return totalBytesFreed
    }

    func cleanAll() async throws -> Int64 {
        let items = try await scan()
        var freed = try await delete(items: items)

        let extraPaths = [
            storageURL.appendingPathComponent("cache").path,
            storageURL.appendingPathComponent("backups").path,
            storageURL.appendingPathComponent("shell-snapshots").path
        ]

        for path in extraPaths {
            let size = FileSizeHelper.sizeOf(path: path)
            if FileSizeHelper.removeIfExists(path: path) {
                freed += size
                try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
        }

        return freed
    }

    // MARK: - Pre-indexing & Parsing

    private struct AssociatedArtifacts: Sendable {
        var pathsBySessionId: [String: [String]] = [:]
        var sizeBySessionId: [String: Int64] = [:]
    }

    private func preIndexAssociatedDirectories() -> AssociatedArtifacts {
        var artifacts = AssociatedArtifacts()
        let fileManager = FileManager.default
        let dirsToIndex = ["file-history", "plans", "session-env"]

        for dirName in dirsToIndex {
            let targetDir = storageURL.appendingPathComponent(dirName)
            guard fileManager.fileExists(atPath: targetDir.path),
                  let entries = try? fileManager.contentsOfDirectory(at: targetDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                continue
            }

            for entry in entries {
                let sid = entry.lastPathComponent
                guard !sid.isEmpty else { continue }
                let path = entry.path
                let size = FileSizeHelper.sizeOf(path: path)
                artifacts.pathsBySessionId[sid, default: []].append(path)
                artifacts.sizeBySessionId[sid, default: 0] += size
            }
        }
        return artifacts
    }

    private struct HistoryRecord: Sendable {
        let displays: [String]
        let project: String?
        let timestamp: Date?
    }

    private func loadHistory() -> [String: HistoryRecord] {
        let historyURL = storageURL.appendingPathComponent("history.jsonl")
        guard FileManager.default.fileExists(atPath: historyURL.path),
              let content = try? String(contentsOf: historyURL, encoding: .utf8) else {
            return [:]
        }

        var map: [String: (displays: [String], project: String?, timestamp: Date?)] = [:]

        content.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = json["sessionId"] as? String else {
                return
            }

            let display = json["display"] as? String ?? ""
            let project = json["project"] as? String
            var date: Date?
            if let ts = json["timestamp"] as? Double {
                date = Date(timeIntervalSince1970: ts / 1000.0)
            }

            if var existing = map[sessionId] {
                if !display.isEmpty {
                    existing.displays.append(display)
                }
                if existing.project == nil && project != nil {
                    existing.project = project
                }
                if let date = date {
                    existing.timestamp = date
                }
                map[sessionId] = existing
            } else {
                map[sessionId] = (
                    displays: display.isEmpty ? [] : [display],
                    project: project,
                    timestamp: date
                )
            }
        }

        return map.mapValues { HistoryRecord(displays: $0.displays, project: $0.project, timestamp: $0.timestamp) }
    }

    private func parseSession(
        fileURL: URL,
        sessionId: String,
        projectDirURL: URL,
        history: HistoryRecord?,
        associatedArtifacts: AssociatedArtifacts
    ) -> ConversationItem {
        let fileManager = FileManager.default
        var associatedPaths: [String] = [fileURL.path]

        // Check for session folder in project dir (e.g. <sessionId>/ for subagents)
        let sessionDirURL = projectDirURL.appendingPathComponent(sessionId)
        var subagentDirSize: Int64 = 0
        if fileManager.fileExists(atPath: sessionDirURL.path) {
            associatedPaths.append(sessionDirURL.path)
            subagentDirSize = FileSizeHelper.sizeOf(path: sessionDirURL.path)
        }

        // Add pre-indexed paths and sizes (file-history, plans, session-env) without repeated disk probes
        if let prePaths = associatedArtifacts.pathsBySessionId[sessionId] {
            associatedPaths.append(contentsOf: prePaths)
        }
        let preIndexedSize = associatedArtifacts.sizeBySessionId[sessionId] ?? 0

        // File size of main jsonl
        let mainFileSize = FileSizeHelper.sizeOf(path: fileURL.path)
        let totalBytes = mainFileSize + subagentDirSize + preIndexedSize

        // File date
        let fileAttrs = try? fileManager.attributesOfItem(atPath: fileURL.path)
        let modDate = (fileAttrs?[.modificationDate] as? Date) ?? history?.timestamp ?? Date()

        // Read session header and content metadata
        var detectedCwd: String? = history?.project
        var detectedBranch: String?
        var detectedSlug: String?
        var firstUserPrompt: String? = history?.displays.first
        var messageCount: Int = history?.displays.count ?? 0

        // Parse beginning of JSONL using UTF-8 safe decoding
        if let fileHandle = try? FileHandle(forReadingFrom: fileURL) {
            defer { try? fileHandle.close() }
            let headerData = fileHandle.readData(ofLength: 64 * 1024)
            let headerString = String(decoding: headerData, as: UTF8.self)
            var lineIdx = 0
            headerString.enumerateLines { line, stop in
                lineIdx += 1
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    return
                }

                if detectedCwd == nil, let cwd = json["cwd"] as? String {
                    detectedCwd = cwd
                }
                if detectedBranch == nil, let branch = json["gitBranch"] as? String {
                    detectedBranch = branch
                }
                if detectedSlug == nil, let slug = json["slug"] as? String {
                    detectedSlug = slug
                }

                if firstUserPrompt == nil || firstUserPrompt?.isEmpty == true {
                    if let type = json["type"] as? String, type == "user" {
                        if let msg = json["message"] as? [String: Any] {
                            if let text = msg["content"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                firstUserPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            } else if let arr = msg["content"] as? [[String: Any]] {
                                for item in arr {
                                    if let txt = item["text"] as? String, !txt.isEmpty {
                                        firstUserPrompt = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                                        break
                                    }
                                }
                            }
                        }
                    }
                }

                if lineIdx > 50 {
                    stop = true
                }
            }
        }

        // Fallback for project path based on directory name if cwd not in json
        if detectedCwd == nil {
            let dirName = projectDirURL.lastPathComponent
            if dirName.hasPrefix("-") {
                detectedCwd = "/" + dirName.dropFirst().replacingOccurrences(of: "-", with: "/")
            }
        }

        let title: String
        if let prompt = firstUserPrompt, !prompt.isEmpty {
            title = prompt.prefix(80).replacingOccurrences(of: "\n", with: " ")
        } else if let slug = detectedSlug, !slug.isEmpty {
            title = slug
        } else {
            title = "会话 \(sessionId.prefix(8))"
        }

        let snippet: String
        if let latest = history?.displays.last, latest != title {
            snippet = latest.prefix(120).replacingOccurrences(of: "\n", with: " ")
        } else if let prompt = firstUserPrompt {
            snippet = prompt.prefix(120).replacingOccurrences(of: "\n", with: " ")
        } else {
            snippet = "项目: \(detectedCwd ?? "未知")"
        }

        if messageCount == 0 {
            messageCount = max(1, Int(totalBytes / 1024 / 20))
        }

        return ConversationItem(
            id: UUID(),
            sessionId: sessionId,
            title: title,
            category: .claudeCode,
            projectPath: detectedCwd,
            gitBranch: detectedBranch,
            messageCount: messageCount,
            sizeInBytes: totalBytes,
            updatedAt: modDate,
            isSelected: false,
            snippet: snippet,
            associatedPaths: associatedPaths
        )
    }

    private func cleanHistory(excludingSessionIds: Set<String>) {
        let historyURL = storageURL.appendingPathComponent("history.jsonl")
        guard FileManager.default.fileExists(atPath: historyURL.path),
              let content = try? String(contentsOf: historyURL, encoding: .utf8) else {
            return
        }

        var retainedLines: [String] = []
        content.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = json["sessionId"] as? String else {
                retainedLines.append(line)
                return
            }

            if !excludingSessionIds.contains(sid) {
                retainedLines.append(line)
            }
        }

        let newContent = retainedLines.joined(separator: "\n") + (retainedLines.isEmpty ? "" : "\n")
        try? newContent.write(to: historyURL, atomically: true, encoding: .utf8)
    }

    private func cleanEmptyProjectDirectories() {
        let projectsURL = storageURL.appendingPathComponent("projects")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: projectsURL.path),
              let projectDirs = try? fileManager.contentsOfDirectory(at: projectsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return
        }

        for dir in projectDirs {
            if let contents = try? fileManager.contentsOfDirectory(atPath: dir.path) {
                let remaining = contents.filter { $0 != "memory" && !$0.hasPrefix(".") }
                if remaining.isEmpty {
                    try? fileManager.removeItem(at: dir)
                }
            }
        }
    }
}
