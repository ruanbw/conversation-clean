import Foundation

final class CodexScanner: AgentScanner {
    let category: ConversationCategory = .codex
    var customStorageURL: URL?

    init(storageURL: URL? = nil) {
        self.customStorageURL = storageURL
    }

    var storageURL: URL {
        let base: URL
        if let custom = customStorageURL {
            base = custom
        } else if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }
        return (try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? base.standardized
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: storageURL.path)
    }

    func scan() async throws -> [ConversationItem] {
        guard isInstalled else { return [] }

        let indexMap = loadSessionIndex()
        var items: [ConversationItem] = []
        let fileManager = FileManager.default

        // Directories to check for sessions
        let sessionDirs = [
            storageURL.appendingPathComponent("sessions"),
            storageURL.appendingPathComponent("archived_sessions")
        ]

        for sessionDir in sessionDirs {
            guard fileManager.fileExists(atPath: sessionDir.path) else { continue }

            let enumerator = fileManager.enumerator(
                at: sessionDir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            while let fileURL = enumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "jsonl" else { continue }

                let baseName = fileURL.deletingPathExtension().lastPathComponent
                let info = indexMap[fileURL.lastPathComponent] ?? indexMap[baseName]
                let item = parseCodexSession(fileURL: fileURL, indexInfo: info)
                items.append(item)
            }
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

        // Clean deleted sessions from session_index.jsonl if present
        cleanSessionIndex(excludingSessionIds: deletedSessionIds)

        // Clean empty directories in ~/.codex/sessions
        cleanEmptyDirectories(in: storageURL.appendingPathComponent("sessions"))
        cleanEmptyDirectories(in: storageURL.appendingPathComponent("archived_sessions"))

        return totalBytesFreed
    }

    func cleanAll() async throws -> Int64 {
        let items = try await scan()
        var freed = try await delete(items: items)

        // Also clean history.jsonl and temp caches if present
        let extraPaths = [
            storageURL.appendingPathComponent("history.jsonl").path,
            storageURL.appendingPathComponent("cache").path,
            storageURL.appendingPathComponent("tmp").path
        ]

        for path in extraPaths {
            let size = FileSizeHelper.sizeOf(path: path)
            if FileSizeHelper.removeIfExists(path: path) {
                freed += size
            }
        }

        return freed
    }

    // MARK: - Private Helpers

    private struct CodexIndexInfo {
        let id: String
        let title: String?
        let cwd: String?
        let updatedAt: Date?
    }

    private func loadSessionIndex() -> [String: CodexIndexInfo] {
        let indexURL = storageURL.appendingPathComponent("session_index.jsonl")
        guard FileManager.default.fileExists(atPath: indexURL.path),
              let content = try? String(contentsOf: indexURL, encoding: .utf8) else {
            return [:]
        }

        var map: [String: CodexIndexInfo] = [:]
        content.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = (json["id"] ?? json["sessionId"] ?? json["session_id"]) as? String else {
                return
            }

            let title = json["title"] as? String
            let cwd = (json["cwd"] ?? json["project"]) as? String
            var updatedAt: Date?
            if let ts = json["updated_at"] as? Double ?? json["timestamp"] as? Double {
                updatedAt = Date(timeIntervalSince1970: ts > 1_000_000_000_000 ? ts / 1000.0 : ts)
            }

            let rawFilename = json["filename"] as? String ?? "\(id).jsonl"
            let fileBase = URL(fileURLWithPath: rawFilename).lastPathComponent
            let info = CodexIndexInfo(id: id, title: title, cwd: cwd, updatedAt: updatedAt)
            map[fileBase] = info
            map[rawFilename] = info
            map[id] = info
        }

        return map
    }

    private func parseCodexSession(fileURL: URL, indexInfo: CodexIndexInfo?) -> ConversationItem {
        let fileManager = FileManager.default
        let fileName = fileURL.lastPathComponent
        let defaultId = fileURL.deletingPathExtension().lastPathComponent
        let sessionId = indexInfo?.id ?? defaultId

        let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? FileSizeHelper.sizeOf(path: fileURL.path)
        let modDate = indexInfo?.updatedAt ?? (attrs?[.modificationDate] as? Date) ?? Date()

        let detectedTitle: String? = indexInfo?.title
        var detectedCwd: String? = indexInfo?.cwd
        var firstPrompt: String?
        var messageCount: Int = 0

        if let fileHandle = try? FileHandle(forReadingFrom: fileURL) {
            defer { try? fileHandle.close() }
            let headerData = fileHandle.readData(ofLength: 64 * 1024)
            if let headerString = String(data: headerData, encoding: .utf8) {
                var lineCount = 0
                headerString.enumerateLines { line, stop in
                    lineCount += 1
                    guard let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                        return
                    }

                    if detectedCwd == nil {
                        detectedCwd = (json["cwd"] ?? json["project"] ?? json["working_directory"]) as? String
                    }

                    // Extract user message or prompt
                    if firstPrompt == nil {
                        if let role = json["role"] as? String, role == "user", let text = json["content"] as? String {
                            firstPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if let prompt = (json["prompt"] ?? json["display"]) as? String {
                            firstPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if let messages = json["messages"] as? [[String: Any]] {
                            for msg in messages {
                                if let role = msg["role"] as? String, role == "user", let content = msg["content"] as? String {
                                    firstPrompt = content.trimmingCharacters(in: .whitespacesAndNewlines)
                                    break
                                }
                            }
                        }
                    }

                    if lineCount > 40 {
                        stop = true
                    }
                }
                messageCount = lineCount
            }
        }

        let title: String
        if let t = detectedTitle, !t.isEmpty {
            title = t
        } else if let prompt = firstPrompt, !prompt.isEmpty {
            title = prompt.prefix(80).replacingOccurrences(of: "\n", with: " ")
        } else {
            title = "Codex 会话 \(sessionId.prefix(8))"
        }

        let snippet: String
        if let prompt = firstPrompt, !prompt.isEmpty {
            snippet = prompt.prefix(120).replacingOccurrences(of: "\n", with: " ")
        } else if let cwd = detectedCwd {
            snippet = "项目: \(cwd)"
        } else {
            snippet = fileName
        }

        return ConversationItem(
            id: UUID(),
            sessionId: sessionId,
            title: title,
            category: .codex,
            projectPath: detectedCwd,
            gitBranch: nil,
            messageCount: max(1, messageCount),
            sizeInBytes: fileSize,
            updatedAt: modDate,
            isSelected: false,
            snippet: snippet,
            associatedPaths: [fileURL.path]
        )
    }

    private func cleanSessionIndex(excludingSessionIds: Set<String>) {
        let indexURL = storageURL.appendingPathComponent("session_index.jsonl")
        guard FileManager.default.fileExists(atPath: indexURL.path),
              let content = try? String(contentsOf: indexURL, encoding: .utf8) else {
            return
        }

        var retainedLines: [String] = []
        content.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = (json["id"] ?? json["sessionId"] ?? json["session_id"]) as? String else {
                retainedLines.append(line)
                return
            }

            var isExcluded = excludingSessionIds.contains(sid)
            if !isExcluded, let rawFn = json["filename"] as? String {
                let base = URL(fileURLWithPath: rawFn).deletingPathExtension().lastPathComponent
                if excludingSessionIds.contains(base) {
                    isExcluded = true
                }
            }

            if !isExcluded {
                retainedLines.append(line)
            }
        }

        let newContent = retainedLines.joined(separator: "\n") + (retainedLines.isEmpty ? "" : "\n")
        try? newContent.write(to: indexURL, atomically: true, encoding: .utf8)
    }

    private func cleanEmptyDirectories(in rootURL: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return
        }

        var dirs: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                dirs.append(url)
            }
        }

        // Remove from deepest to shallowest
        for dir in dirs.reversed() {
            FileSizeHelper.removeIfEmptyDirectory(path: dir.path)
        }
    }
}
