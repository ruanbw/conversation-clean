import Foundation

final class PiAgentScanner: AgentScanner, @unchecked Sendable {
    let category: ConversationCategory = .piAgent
    let customStorageURL: URL?

    init(storageURL: URL? = nil) {
        self.customStorageURL = storageURL
    }

    var storageURL: URL {
        let base: URL
        if let custom = customStorageURL {
            base = custom
        } else if let env = ProcessInfo.processInfo.environment["PI_HOME"], !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi")
        }
        return (try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? base.standardized
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: storageURL.path)
    }

    private struct SessionTarget: Sendable {
        let fileURL: URL
        let projectDirURL: URL
        let baseName: String
        let fileSessionId: String
    }

    private struct TaskArtifacts: Sendable {
        var pathsBySessionId: [String: [String]] = [:]
        var sizeBySessionId: [String: Int64] = [:]
    }

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackIsoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func scan() async throws -> [ConversationItem] {
        guard isInstalled else { return [] }

        let fileManager = FileManager.default
        let sessionsURL = storageURL.appendingPathComponent("agent").appendingPathComponent("sessions")
        guard fileManager.fileExists(atPath: sessionsURL.path) else { return [] }

        let projectDirs = (try? fileManager.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var targets: [SessionTarget] = []

        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let entries = (try? fileManager.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries where entry.pathExtension == "jsonl" {
                let baseName = entry.deletingPathExtension().lastPathComponent
                guard !baseName.isEmpty else { continue }

                let fileSessionId: String
                if let lastUnderscore = baseName.range(of: "_", options: .backwards) {
                    fileSessionId = String(baseName[lastUnderscore.upperBound...])
                } else {
                    fileSessionId = baseName
                }

                targets.append(SessionTarget(
                    fileURL: entry,
                    projectDirURL: projectDir,
                    baseName: baseName,
                    fileSessionId: fileSessionId
                ))
            }
        }

        guard !targets.isEmpty else { return [] }

        let taskArtifacts = preIndexTasks()

        let items: [ConversationItem] = await withTaskGroup(of: ConversationItem.self) { group in
            for target in targets {
                group.addTask {
                    return self.parseSession(target: target, taskArtifacts: taskArtifacts)
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

        for item in items {
            totalBytesFreed += item.sizeInBytes
            for path in item.associatedPaths {
                _ = FileSizeHelper.removeIfExists(path: path)
            }
        }

        cleanEmptyProjectDirectories()

        return totalBytesFreed
    }

    func cleanAll() async throws -> Int64 {
        let items = try await scan()
        var freed = try await delete(items: items)

        let extraDirsToRecreate = [
            storageURL.appendingPathComponent("agent").appendingPathComponent("sessions"),
            storageURL.appendingPathComponent("tasks"),
            storageURL.appendingPathComponent("context-mode"),
            storageURL.appendingPathComponent("web-search-cache"),
            storageURL.appendingPathComponent("agent").appendingPathComponent("web-search-cache")
        ]

        for dirURL in extraDirsToRecreate {
            let path = dirURL.path
            if FileManager.default.fileExists(atPath: path) {
                let size = FileSizeHelper.sizeOf(path: path)
                if FileSizeHelper.removeIfExists(path: path) {
                    freed += size
                    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                }
            }
        }

        let runHistoryURL = storageURL.appendingPathComponent("agent").appendingPathComponent("run-history.jsonl")
        if FileManager.default.fileExists(atPath: runHistoryURL.path) {
            let size = FileSizeHelper.sizeOf(path: runHistoryURL.path)
            if FileSizeHelper.removeIfExists(path: runHistoryURL.path) {
                freed += size
            }
        }

        return freed
    }

    // MARK: - Pre-Indexing Tasks

    private func preIndexTasks() -> TaskArtifacts {
        var artifacts = TaskArtifacts()
        let tasksURL = storageURL.appendingPathComponent("tasks")
        let fm = FileManager.default
        guard fm.fileExists(atPath: tasksURL.path),
              let entries = try? fm.contentsOfDirectory(at: tasksURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return artifacts
        }

        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let dirName = entry.lastPathComponent
            guard dirName.count >= 36 else { continue }

            let prefix = String(dirName.prefix(36))
            if dirName == prefix || dirName.hasPrefix(prefix + "-") {
                let path = entry.path
                let size = FileSizeHelper.sizeOf(path: path)
                artifacts.pathsBySessionId[prefix, default: []].append(path)
                artifacts.sizeBySessionId[prefix, default: 0] += size
            }
        }

        return artifacts
    }

    // MARK: - Parsing

    private func parseSession(target: SessionTarget, taskArtifacts: TaskArtifacts) -> ConversationItem {
        let fileManager = FileManager.default
        let fileAttrs = try? fileManager.attributesOfItem(atPath: target.fileURL.path)
        let mainFileSize = (fileAttrs?[.size] as? NSNumber)?.int64Value ?? FileSizeHelper.sizeOf(path: target.fileURL.path)

        var detectedSessionId = target.fileSessionId
        var detectedCwd: String?
        var detectedTimestamp: Date?
        var firstUserPrompt: String?
        var messageCount = 0
        var totalLineCount = 0

        if let fileHandle = try? FileHandle(forReadingFrom: target.fileURL) {
            defer { try? fileHandle.close() }
            let headerData = fileHandle.readData(ofLength: 512 * 1024)
            let headerString = String(decoding: headerData, as: UTF8.self)

            headerString.enumerateLines { line, _ in
                totalLineCount += 1
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    return
                }

                let type = json["type"] as? String

                if type == "session" {
                    if let sid = json["id"] as? String, !sid.isEmpty {
                        detectedSessionId = sid
                    }
                    if let cwd = json["cwd"] as? String, !cwd.isEmpty {
                        detectedCwd = cwd
                    }
                    if let tsStr = json["timestamp"] as? String {
                        detectedTimestamp = Self.isoDateFormatter.date(from: tsStr) ?? Self.fallbackIsoDateFormatter.date(from: tsStr)
                    }
                } else if type == "message" {
                    messageCount += 1
                    if firstUserPrompt == nil,
                       let msg = json["message"] as? [String: Any],
                       let role = msg["role"] as? String, role == "user" {
                        if let prompt = Self.extractText(from: msg["content"]) {
                            firstUserPrompt = prompt
                        }
                    }
                }
            }

            // If file is larger than 512KB, stream-count remaining newlines
            if mainFileSize > 512 * 1024 {
                while autoreleasepool(invoking: {
                    let chunk = fileHandle.readData(ofLength: 256 * 1024)
                    if chunk.isEmpty { return false }
                    let newlines = chunk.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
                    messageCount += newlines
                    return true
                }) {}
            }
        }

        if messageCount == 0 {
            messageCount = max(1, totalLineCount)
        }

        // Fallback for cwd based on project directory name (--Users-ruanbw-projects-bennett--)
        if detectedCwd == nil || detectedCwd?.isEmpty == true {
            let dirName = target.projectDirURL.lastPathComponent
            if dirName.hasPrefix("--") && dirName.hasSuffix("--") {
                let inner = String(dirName.dropFirst(2).dropLast(2))
                if inner.isEmpty {
                    detectedCwd = "/"
                } else {
                    detectedCwd = "/" + inner.replacingOccurrences(of: "-", with: "/")
                }
            }
        }

        let modDate = (fileAttrs?[.modificationDate] as? Date) ?? detectedTimestamp ?? Date()

        let title: String
        if let prompt = firstUserPrompt, !prompt.isEmpty {
            title = prompt.prefix(80).replacingOccurrences(of: "\n", with: " ")
        } else {
            title = "Pi 会话 \(detectedSessionId.prefix(8))"
        }

        let snippet: String
        if let prompt = firstUserPrompt, !prompt.isEmpty {
            snippet = prompt.prefix(120).replacingOccurrences(of: "\n", with: " ")
        } else {
            snippet = "项目: \(detectedCwd ?? "未知")"
        }

        var associatedPaths: [String] = [target.fileURL.path]
        var totalBytes = mainFileSize

        // 1. Session subfolder by baseName (e.g. 2026-09-14T..._<sid>)
        let subfolderByBase = target.projectDirURL.appendingPathComponent(target.baseName)
        var visitedDirs = Set<String>()
        var isDir: ObjCBool = false

        if fileManager.fileExists(atPath: subfolderByBase.path, isDirectory: &isDir), isDir.boolValue {
            associatedPaths.append(subfolderByBase.path)
            visitedDirs.insert(subfolderByBase.path)
            totalBytes += FileSizeHelper.sizeOf(path: subfolderByBase.path)
        }

        // 2. Session subfolder by sessionId (if different and exists)
        let subfolderBySid = target.projectDirURL.appendingPathComponent(detectedSessionId)
        if !visitedDirs.contains(subfolderBySid.path),
           fileManager.fileExists(atPath: subfolderBySid.path, isDirectory: &isDir), isDir.boolValue {
            associatedPaths.append(subfolderBySid.path)
            visitedDirs.insert(subfolderBySid.path)
            totalBytes += FileSizeHelper.sizeOf(path: subfolderBySid.path)
        }

        // 3. Matching tasks in tasks/
        var matchedTaskPaths = Set<String>()
        if let taskPaths = taskArtifacts.pathsBySessionId[detectedSessionId] {
            for path in taskPaths {
                if !matchedTaskPaths.contains(path) {
                    matchedTaskPaths.insert(path)
                    associatedPaths.append(path)
                }
            }
            totalBytes += taskArtifacts.sizeBySessionId[detectedSessionId] ?? 0
        }

        if target.fileSessionId != detectedSessionId,
           let taskPaths = taskArtifacts.pathsBySessionId[target.fileSessionId] {
            for path in taskPaths {
                if !matchedTaskPaths.contains(path) {
                    matchedTaskPaths.insert(path)
                    associatedPaths.append(path)
                    totalBytes += FileSizeHelper.sizeOf(path: path)
                }
            }
        }

        return ConversationItem(
            id: UUID(),
            sessionId: detectedSessionId,
            title: title,
            category: .piAgent,
            projectPath: detectedCwd,
            gitBranch: nil,
            messageCount: messageCount,
            sizeInBytes: totalBytes,
            updatedAt: modDate,
            isSelected: false,
            snippet: snippet,
            associatedPaths: associatedPaths
        )
    }

    private static func extractText(from content: Any?) -> String? {
        if let str = content as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let array = content as? [[String: Any]] {
            var texts: [String] = []
            for item in array {
                if let text = item["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        texts.append(trimmed)
                    }
                }
            }
            if !texts.isEmpty {
                return texts.joined(separator: " ")
            }
        }
        return nil
    }

    private func cleanEmptyProjectDirectories() {
        let sessionsURL = storageURL.appendingPathComponent("agent").appendingPathComponent("sessions")
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsURL.path),
              let projectDirs = try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return
        }

        for dir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            if let contents = try? fm.contentsOfDirectory(atPath: dir.path) {
                let sessionFiles = contents.filter { $0.hasSuffix(".jsonl") }
                if sessionFiles.isEmpty {
                    try? fm.removeItem(at: dir)
                }
            }
        }
    }
}
