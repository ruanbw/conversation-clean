import Foundation

final class VSCodeChatScanner: AgentScanner, @unchecked Sendable {
    let category: ConversationCategory = .copilotChat
    let customStorageURL: URL?

    init(baseURL: URL? = nil) {
        self.customStorageURL = baseURL
    }

    convenience init(storageURL: URL) {
        self.init(baseURL: storageURL)
    }

    var storageURL: URL {
        let base: URL
        if let custom = customStorageURL {
            base = custom
        } else if let env = ProcessInfo.processInfo.environment["VSCODE_USER_DATA"], !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Code/User")
        }
        return (try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? base.standardized
    }

    var isInstalled: Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: storageURL.path) {
            return true
        }
        if customStorageURL != nil {
            return false
        }
        let codeBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code")
        return fm.fileExists(atPath: codeBase.path)
    }

    // MARK: - Scan

    private struct ScanTarget: Sendable {
        let fileURL: URL
        let projectPath: String?
        let editingDirURL: URL?
        let extraPaths: [String]
    }

    func scan() async throws -> [ConversationItem] {
        guard isInstalled else { return [] }

        let fileManager = FileManager.default
        var targets: [ScanTarget] = []

        // 1. Scan workspaceStorage/<hash>/chatSessions/*.jsonl
        let workspaceStorageDir = storageURL.appendingPathComponent("workspaceStorage")
        if fileManager.fileExists(atPath: workspaceStorageDir.path),
           let wsEntries = try? fileManager.contentsOfDirectory(
               at: workspaceStorageDir,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            for wsDir in wsEntries {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: wsDir.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }

                // Parse project path from workspace.json
                let wsJsonURL = wsDir.appendingPathComponent("workspace.json")
                let projectPath = Self.extractProjectPath(from: wsJsonURL)

                let chatSessionsDir = wsDir.appendingPathComponent("chatSessions")
                let chatEditingDir = wsDir.appendingPathComponent("chatEditingSessions")
                let copilotTranscriptsDir = wsDir.appendingPathComponent("GitHub.copilot-chat/transcripts")
                let copilotDebugDir = wsDir.appendingPathComponent("GitHub.copilot-chat/debug-logs")

                if fileManager.fileExists(atPath: chatSessionsDir.path),
                   let sessionFiles = try? fileManager.contentsOfDirectory(
                       at: chatSessionsDir,
                       includingPropertiesForKeys: [.isRegularFileKey],
                       options: [.skipsHiddenFiles]
                   ) {
                    for sessionFile in sessionFiles where sessionFile.pathExtension.lowercased() == "jsonl" {
                        let sid = sessionFile.deletingPathExtension().lastPathComponent
                        let editingURL = chatEditingDir.appendingPathComponent(sid)
                        let matchingEdit = fileManager.fileExists(atPath: editingURL.path) ? editingURL : nil

                        var extra: [String] = []
                        let transcriptFile = copilotTranscriptsDir.appendingPathComponent("\(sid).jsonl")
                        if fileManager.fileExists(atPath: transcriptFile.path) {
                            extra.append(transcriptFile.path)
                        }
                        let debugDir = copilotDebugDir.appendingPathComponent(sid)
                        if fileManager.fileExists(atPath: debugDir.path) {
                            extra.append(debugDir.path)
                        }

                        targets.append(ScanTarget(
                            fileURL: sessionFile,
                            projectPath: projectPath,
                            editingDirURL: matchingEdit,
                            extraPaths: extra
                        ))
                    }
                }
            }
        }

        // 2. Scan globalStorage/emptyWindowChatSessions/*.jsonl
        let emptyWindowDir = storageURL.appendingPathComponent("globalStorage/emptyWindowChatSessions")
        if fileManager.fileExists(atPath: emptyWindowDir.path),
           let emptyFiles = try? fileManager.contentsOfDirectory(
               at: emptyWindowDir,
               includingPropertiesForKeys: [.isRegularFileKey],
               options: [.skipsHiddenFiles]
           ) {
            for sessionFile in emptyFiles where sessionFile.pathExtension.lowercased() == "jsonl" {
                targets.append(ScanTarget(
                    fileURL: sessionFile,
                    projectPath: nil,
                    editingDirURL: nil,
                    extraPaths: []
                ))
            }
        }

        guard !targets.isEmpty else { return [] }

        // Process sessions concurrently
        let items: [ConversationItem] = await withTaskGroup(of: ConversationItem?.self) { group in
            for target in targets {
                group.addTask {
                    return self.parseSession(target: target)
                }
            }

            var collected: [ConversationItem] = []
            collected.reserveCapacity(targets.count)
            for await item in group {
                if let item = item {
                    collected.append(item)
                }
            }
            return collected
        }

        return items.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    // MARK: - Delete & Clean

    func delete(items: [ConversationItem]) async throws -> Int64 {
        guard !items.isEmpty else { return 0 }

        var totalFreed: Int64 = 0

        for item in items {
            totalFreed += item.sizeInBytes
            for path in item.associatedPaths {
                _ = FileSizeHelper.removeIfExists(path: path)
            }
        }

        // Clean empty directories in workspaceStorage
        cleanEmptyWorkspaceStorageDirs()

        return totalFreed
    }

    func cleanAll() async throws -> Int64 {
        let items = try await scan()
        var freed = try await delete(items: items)

        let fileManager = FileManager.default

        // Clean any remaining chatSessions in workspaceStorage
        let workspaceStorageDir = storageURL.appendingPathComponent("workspaceStorage")
        if fileManager.fileExists(atPath: workspaceStorageDir.path),
           let wsEntries = try? fileManager.contentsOfDirectory(
               at: workspaceStorageDir,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            for wsDir in wsEntries {
                let chatDir = wsDir.appendingPathComponent("chatSessions")
                if fileManager.fileExists(atPath: chatDir.path) {
                    let sz = FileSizeHelper.sizeOf(path: chatDir.path)
                    if FileSizeHelper.removeIfExists(path: chatDir.path) {
                        freed += sz
                    }
                }
                let editDir = wsDir.appendingPathComponent("chatEditingSessions")
                if fileManager.fileExists(atPath: editDir.path) {
                    let sz = FileSizeHelper.sizeOf(path: editDir.path)
                    if FileSizeHelper.removeIfExists(path: editDir.path) {
                        freed += sz
                    }
                }
                let copilotDir = wsDir.appendingPathComponent("GitHub.copilot-chat")
                if fileManager.fileExists(atPath: copilotDir.path) {
                    let sz = FileSizeHelper.sizeOf(path: copilotDir.path)
                    if FileSizeHelper.removeIfExists(path: copilotDir.path) {
                        freed += sz
                    }
                }
            }
        }

        // Clean emptyWindowChatSessions
        let emptyWindowDir = storageURL.appendingPathComponent("globalStorage/emptyWindowChatSessions")
        if fileManager.fileExists(atPath: emptyWindowDir.path) {
            let sz = FileSizeHelper.sizeOf(path: emptyWindowDir.path)
            if FileSizeHelper.removeIfExists(path: emptyWindowDir.path) {
                freed += sz
                try? fileManager.createDirectory(at: emptyWindowDir, withIntermediateDirectories: true)
            }
        }

        // Clean globalStorage/github.copilot-chat session-store and caches
        let copilotGlobalCandidates = [
            storageURL.appendingPathComponent("globalStorage/github.copilot-chat"),
            storageURL.appendingPathComponent("globalStorage/GitHub.copilot-chat")
        ]

        for copilotGlobal in copilotGlobalCandidates {
            guard fileManager.fileExists(atPath: copilotGlobal.path) else { continue }

            // Target session-store databases
            let dbFiles = [
                copilotGlobal.appendingPathComponent("session-store.db"),
                copilotGlobal.appendingPathComponent("session-store.db-shm"),
                copilotGlobal.appendingPathComponent("session-store.db-wal"),
                copilotGlobal.appendingPathComponent("toolEmbeddingsCache.bin")
            ]
            for dbFile in dbFiles where fileManager.fileExists(atPath: dbFile.path) {
                let sz = FileSizeHelper.sizeOf(path: dbFile.path)
                if FileSizeHelper.removeIfExists(path: dbFile.path) {
                    freed += sz
                }
            }

            // Target vscode-sessions-* directories
            if let entries = try? fileManager.contentsOfDirectory(
                at: copilotGlobal,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for entry in entries {
                    let name = entry.lastPathComponent
                    if name.hasPrefix("vscode-sessions-") || name == "copilot-cli-images" {
                        let sz = FileSizeHelper.sizeOf(path: entry.path)
                        if FileSizeHelper.removeIfExists(path: entry.path) {
                            freed += sz
                        }
                    }
                }
            }
        }

        cleanEmptyWorkspaceStorageDirs()

        return freed
    }

    // MARK: - Parsing

    private func parseSession(target: ScanTarget) -> ConversationItem? {
        let fileManager = FileManager.default
        let fileURL = target.fileURL
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        let fileAttrs = try? fileManager.attributesOfItem(atPath: fileURL.path)
        let mainFileSize = (fileAttrs?[.size] as? NSNumber)?.int64Value ?? FileSizeHelper.sizeOf(path: fileURL.path)
        let fallbackBaseName = fileURL.deletingPathExtension().lastPathComponent

        var detectedSessionId: String?
        var detectedCreationDateMs: Double?
        var detectedCustomTitle: String?
        var firstUserPrompt: String?
        var requestCount = 0

        if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
            content.enumerateLines { line, _ in
                guard !line.isEmpty,
                      let data = line.data(using: .utf8),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return
                }

                let kind = json["kind"] as? Int
                let k = json["k"] as? [Any]
                let v = json["v"]

                // 1. Initial snapshot / state: kind == 0
                if kind == 0, let vDict = v as? [String: Any] {
                    if let sid = vDict["sessionId"] as? String, !sid.isEmpty {
                        detectedSessionId = sid
                    }
                    if let cd = vDict["creationDate"] as? NSNumber {
                        detectedCreationDateMs = cd.doubleValue
                    }
                    if let ct = vDict["customTitle"] as? String, !ct.isEmpty {
                        detectedCustomTitle = ct
                    }
                    if let reqs = vDict["requests"] as? [[String: Any]] {
                        requestCount += reqs.count
                        for req in reqs {
                            if firstUserPrompt == nil {
                                firstUserPrompt = Self.extractPromptText(from: req)
                            }
                        }
                    }
                }
                // 2. Property update: kind == 1
                else if kind == 1 {
                    if let kFirst = k?.first as? String {
                        if kFirst == "customTitle", let str = v as? String, !str.isEmpty {
                            detectedCustomTitle = str
                        } else if kFirst == "sessionId", let str = v as? String, !str.isEmpty {
                            detectedSessionId = str
                        }
                    }
                }
                // 3. Array append: kind == 2
                else if kind == 2 {
                    if let k = k, k.count == 1, let kFirst = k.first as? String, kFirst == "requests", let reqs = v as? [[String: Any]] {
                        requestCount += reqs.count
                        for req in reqs {
                            if firstUserPrompt == nil {
                                firstUserPrompt = Self.extractPromptText(from: req)
                            }
                        }
                    }
                }

                // Fallback for non-delta format
                if detectedSessionId == nil, let sid = json["sessionId"] as? String, !sid.isEmpty {
                    detectedSessionId = sid
                }
                if detectedCreationDateMs == nil, let cd = json["creationDate"] as? NSNumber {
                    detectedCreationDateMs = cd.doubleValue
                }
                if firstUserPrompt == nil, let reqs = json["requests"] as? [[String: Any]] {
                    for req in reqs {
                        if firstUserPrompt == nil {
                            firstUserPrompt = Self.extractPromptText(from: req)
                        }
                    }
                }
            }
        }

        let sessionId = detectedSessionId ?? fallbackBaseName

        // Title resolution: first request prompt text (truncate to 80 chars, fallback to 'GitHub Copilot 对话')
        let finalTitle: String
        if let prompt = firstUserPrompt, !prompt.isEmpty {
            let singleLine = prompt.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? prompt
            finalTitle = singleLine.isEmpty ? "GitHub Copilot 对话" : String(singleLine.prefix(80))
        } else if let custom = detectedCustomTitle, !custom.isEmpty {
            let singleLine = custom.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? custom
            finalTitle = singleLine.isEmpty ? "GitHub Copilot 对话" : String(singleLine.prefix(80))
        } else {
            finalTitle = "GitHub Copilot 对话"
        }

        let snippet: String
        if let prompt = firstUserPrompt, !prompt.isEmpty {
            let singleLine = prompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            snippet = String(singleLine.prefix(160))
        } else {
            snippet = finalTitle
        }

        // Date calculation
        let updatedDate: Date
        if let ms = detectedCreationDateMs, ms > 0 {
            updatedDate = Date(timeIntervalSince1970: ms / 1000.0)
        } else if let modDate = fileAttrs?[.modificationDate] as? Date {
            updatedDate = modDate
        } else {
            updatedDate = Date()
        }

        // Associated paths: the .jsonl file and matching chatEditingSessions/<sessionId> folder
        var associatedPaths: [String] = [fileURL.path]
        var totalSize = mainFileSize

        if let editingDir = target.editingDirURL, fileManager.fileExists(atPath: editingDir.path) {
            associatedPaths.append(editingDir.path)
            totalSize += FileSizeHelper.sizeOf(path: editingDir.path)
        }

        for extraPath in target.extraPaths where fileManager.fileExists(atPath: extraPath) {
            associatedPaths.append(extraPath)
            totalSize += FileSizeHelper.sizeOf(path: extraPath)
        }

        return ConversationItem(
            id: UUID(),
            sessionId: sessionId,
            title: finalTitle,
            category: self.category,
            projectPath: target.projectPath,
            gitBranch: nil,
            messageCount: requestCount,
            sizeInBytes: totalSize,
            updatedAt: updatedDate,
            isSelected: false,
            snippet: snippet,
            associatedPaths: associatedPaths
        )
    }

    // MARK: - Helpers

    private static func extractPromptText(from req: [String: Any]) -> String? {
        if let msg = req["message"] as? [String: Any] {
            if let text = msg["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let parts = msg["parts"] as? [[String: Any]] {
                var combined = ""
                for part in parts {
                    if let text = part["text"] as? String {
                        combined += text
                    }
                }
                let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        } else if let msgStr = req["message"] as? String {
            let trimmed = msgStr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        } else if let text = req["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        } else if let prompt = req["prompt"] as? String {
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func extractProjectPath(from workspaceJSONURL: URL) -> String? {
        guard let data = try? Data(contentsOf: workspaceJSONURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        guard let uriString = json["folder"] as? String ?? json["workspace"] as? String else {
            return nil
        }
        if uriString.hasPrefix("file://") {
            if let url = URL(string: uriString) {
                return url.path
            }
            let stripped = String(uriString.dropFirst(7))
            return stripped.removingPercentEncoding ?? stripped
        }
        return uriString
    }

    private func cleanEmptyWorkspaceStorageDirs() {
        let fileManager = FileManager.default
        let workspaceStorageDir = storageURL.appendingPathComponent("workspaceStorage")
        guard fileManager.fileExists(atPath: workspaceStorageDir.path),
              let wsEntries = try? fileManager.contentsOfDirectory(
                  at: workspaceStorageDir,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else { return }

        for wsDir in wsEntries {
            let chatDir = wsDir.appendingPathComponent("chatSessions")
            FileSizeHelper.removeIfEmptyDirectory(path: chatDir.path)

            let editDir = wsDir.appendingPathComponent("chatEditingSessions")
            FileSizeHelper.removeIfEmptyDirectory(path: editDir.path)
        }
    }
}
