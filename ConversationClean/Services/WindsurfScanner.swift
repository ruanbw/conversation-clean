import Foundation

final class WindsurfScanner: AgentScanner, @unchecked Sendable {
    let category: ConversationCategory = .windsurf
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
        } else if let env = ProcessInfo.processInfo.environment["WINDSURF_HOME"], !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Windsurf")
        }
        return (try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? base.standardized
    }

    var userDirectoryURL: URL {
        let directUser = storageURL.appendingPathComponent("User")
        let directWS = storageURL.appendingPathComponent("workspaceStorage")
        let fm = FileManager.default
        if fm.fileExists(atPath: directUser.path) {
            return directUser
        } else if fm.fileExists(atPath: directWS.path) {
            return storageURL
        }
        return directUser
    }

    var codeiumWindsurfURL: URL {
        if let custom = customStorageURL {
            let candidate1 = custom.appendingPathComponent(".codeium/windsurf")
            if FileManager.default.fileExists(atPath: candidate1.path) {
                return candidate1
            }
            let candidate2 = custom.appendingPathComponent("codeium/windsurf")
            if FileManager.default.fileExists(atPath: candidate2.path) {
                return candidate2
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codeium/windsurf")
    }

    var isInstalled: Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: storageURL.path) {
            return true
        }
        if customStorageURL != nil {
            return false
        }
        let dotCodeium = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codeium/windsurf")
        return fm.fileExists(atPath: dotCodeium.path)
    }

    // MARK: - Scan

    private struct ScanTarget: Sendable {
        let fileURL: URL
        let projectPath: String?
        let editingDirURL: URL?
    }

    func scan() async throws -> [ConversationItem] {
        guard isInstalled else { return [] }

        let fileManager = FileManager.default
        var items: [ConversationItem] = []

        let userDir = userDirectoryURL
        let workspaceStorageDir = userDir.appendingPathComponent("workspaceStorage")

        // 1. Scan User/workspaceStorage/*/
        if fileManager.fileExists(atPath: workspaceStorageDir.path),
           let wsEntries = try? fileManager.contentsOfDirectory(
               at: workspaceStorageDir,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            var jsonlTargets: [ScanTarget] = []

            for wsDir in wsEntries {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: wsDir.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }

                let wsJsonURL = wsDir.appendingPathComponent("workspace.json")
                let projectPath = Self.extractProjectPath(from: wsJsonURL)

                let chatSessionsDir = wsDir.appendingPathComponent("chatSessions")
                let chatEditingDir = wsDir.appendingPathComponent("chatEditingSessions")

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

                        jsonlTargets.append(ScanTarget(
                            fileURL: sessionFile,
                            projectPath: projectPath,
                            editingDirURL: matchingEdit
                        ))
                    }
                }
            }

            let parsedJsonl: [ConversationItem] = await withTaskGroup(of: ConversationItem?.self) { group in
                for target in jsonlTargets {
                    group.addTask {
                        return self.parseJsonlSession(target: target)
                    }
                }

                var collected: [ConversationItem] = []
                for await item in group {
                    if let item = item {
                        collected.append(item)
                    }
                }
                return collected
            }
            items.append(contentsOf: parsedJsonl)
        }

        // 2. Scan User/globalStorage/
        let globalStorageDir = userDir.appendingPathComponent("globalStorage")
        let emptyWindowDir = globalStorageDir.appendingPathComponent("emptyWindowChatSessions")
        if fileManager.fileExists(atPath: emptyWindowDir.path),
           let emptyFiles = try? fileManager.contentsOfDirectory(
               at: emptyWindowDir,
               includingPropertiesForKeys: [.isRegularFileKey],
               options: [.skipsHiddenFiles]
           ) {
            for sessionFile in emptyFiles where sessionFile.pathExtension.lowercased() == "jsonl" {
                if let item = parseJsonlSession(target: ScanTarget(fileURL: sessionFile, projectPath: nil, editingDirURL: nil)) {
                    items.append(item)
                }
            }
        }

        // 3. Scan ~/.codeium/windsurf/
        let codeiumDir = codeiumWindsurfURL
        if fileManager.fileExists(atPath: codeiumDir.path) {
            let cascadeItems = scanCodeiumWindsurfDirectory(codeiumDir: codeiumDir)
            items.append(contentsOf: cascadeItems)
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

        cleanEmptyWorkspaceStorageDirs()

        return totalFreed
    }

    func cleanAll() async throws -> Int64 {
        let items = try await scan()
        var freed = try await delete(items: items)

        let fileManager = FileManager.default
        let userDir = userDirectoryURL
        let workspaceStorageDir = userDir.appendingPathComponent("workspaceStorage")

        // Clean workspaceStorage chatSessions & chatEditingSessions
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
            }
        }

        // Clean emptyWindowChatSessions
        let globalStorageDir = userDir.appendingPathComponent("globalStorage")
        let emptyWindowDir = globalStorageDir.appendingPathComponent("emptyWindowChatSessions")
        if fileManager.fileExists(atPath: emptyWindowDir.path) {
            let sz = FileSizeHelper.sizeOf(path: emptyWindowDir.path)
            if FileSizeHelper.removeIfExists(path: emptyWindowDir.path) {
                freed += sz
                try? fileManager.createDirectory(at: emptyWindowDir, withIntermediateDirectories: true)
            }
        }

        // Clean ~/.codeium/windsurf cascades, chats, memories
        let codeiumDir = codeiumWindsurfURL
        let dirsToClean = ["cascades", "chats", "memories", "cascade"]
        for sub in dirsToClean {
            let subURL = codeiumDir.appendingPathComponent(sub)
            if fileManager.fileExists(atPath: subURL.path) {
                let sz = FileSizeHelper.sizeOf(path: subURL.path)
                if FileSizeHelper.removeIfExists(path: subURL.path) {
                    freed += sz
                    try? fileManager.createDirectory(at: subURL, withIntermediateDirectories: true)
                }
            }
        }

        cleanEmptyWorkspaceStorageDirs()

        return freed
    }

    // MARK: - JSONL Parsing

    private func parseJsonlSession(target: ScanTarget) -> ConversationItem? {
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
                } else if kind == 1 {
                    if let kFirst = k?.first as? String {
                        if kFirst == "customTitle", let str = v as? String, !str.isEmpty {
                            detectedCustomTitle = str
                        } else if kFirst == "sessionId", let str = v as? String, !str.isEmpty {
                            detectedSessionId = str
                        }
                    }
                } else if kind == 2 {
                    if let k = k, k.count == 1, let kFirst = k.first as? String, kFirst == "requests", let reqs = v as? [[String: Any]] {
                        requestCount += reqs.count
                        for req in reqs {
                            if firstUserPrompt == nil {
                                firstUserPrompt = Self.extractPromptText(from: req)
                            }
                        }
                    }
                }

                if detectedSessionId == nil, let sid = json["sessionId"] as? String, !sid.isEmpty {
                    detectedSessionId = sid
                }
                if detectedCreationDateMs == nil, let cd = json["creationDate"] as? NSNumber {
                    detectedCreationDateMs = cd.doubleValue
                }
            }
        }

        let sessionId = detectedSessionId ?? fallbackBaseName

        let finalTitle: String
        if let prompt = firstUserPrompt, !prompt.isEmpty {
            let singleLine = prompt.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? prompt
            finalTitle = singleLine.isEmpty ? "Windsurf 对话" : String(singleLine.prefix(80))
        } else if let custom = detectedCustomTitle, !custom.isEmpty {
            let singleLine = custom.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? custom
            finalTitle = singleLine.isEmpty ? "Windsurf 对话" : String(singleLine.prefix(80))
        } else {
            finalTitle = "Windsurf 对话"
        }

        let snippet: String
        if let prompt = firstUserPrompt, !prompt.isEmpty {
            let singleLine = prompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            snippet = String(singleLine.prefix(160))
        } else {
            snippet = finalTitle
        }

        let updatedDate: Date
        if let ms = detectedCreationDateMs, ms > 0 {
            updatedDate = Date(timeIntervalSince1970: ms / 1000.0)
        } else if let modDate = fileAttrs?[.modificationDate] as? Date {
            updatedDate = modDate
        } else {
            updatedDate = Date()
        }

        var associatedPaths: [String] = [fileURL.path]
        var totalSize = mainFileSize

        if let editingDir = target.editingDirURL, fileManager.fileExists(atPath: editingDir.path) {
            associatedPaths.append(editingDir.path)
            totalSize += FileSizeHelper.sizeOf(path: editingDir.path)
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

    // MARK: - Codeium Windsurf Scans

    private func scanCodeiumWindsurfDirectory(codeiumDir: URL) -> [ConversationItem] {
        let fm = FileManager.default
        var items: [ConversationItem] = []

        // Cascades folder
        let cascadeFolders = ["cascades", "cascade", "chats"]
        for sub in cascadeFolders {
            let subDir = codeiumDir.appendingPathComponent(sub)
            guard fm.fileExists(atPath: subDir.path),
                  let entries = try? fm.contentsOfDirectory(at: subDir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
                continue
            }

            for entry in entries {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDir) else { continue }

                let sid = entry.deletingPathExtension().lastPathComponent
                guard !sid.isEmpty, !sid.hasPrefix(".") else { continue }

                let size = FileSizeHelper.sizeOf(path: entry.path)
                let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

                // Check for metadata or json
                var promptTitle: String?
                var projectPath: String?

                if isDir.boolValue {
                    let metaCandidates = ["meta.json", "cascade.json", "session.json"]
                    for metaName in metaCandidates {
                        let metaFile = entry.appendingPathComponent(metaName)
                        if fm.fileExists(atPath: metaFile.path),
                           let data = try? Data(contentsOf: metaFile),
                           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                            promptTitle = json["title"] as? String ?? json["prompt"] as? String ?? json["name"] as? String
                            projectPath = json["cwd"] as? String ?? json["projectPath"] as? String ?? json["workspace"] as? String
                            break
                        }
                    }
                } else if entry.pathExtension.lowercased() == "json" {
                    if let data = try? Data(contentsOf: entry),
                       let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        promptTitle = json["title"] as? String ?? json["prompt"] as? String
                        projectPath = json["cwd"] as? String ?? json["projectPath"] as? String
                    }
                }

                let finalTitle: String
                if let pt = promptTitle, !pt.isEmpty {
                    let singleLine = pt.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? pt
                    finalTitle = String(singleLine.prefix(80))
                } else {
                    finalTitle = "Windsurf Cascade 会话 \(sid.prefix(8))"
                }

                items.append(ConversationItem(
                    id: UUID(),
                    sessionId: sid,
                    title: finalTitle,
                    category: self.category,
                    projectPath: projectPath,
                    gitBranch: nil,
                    messageCount: 1,
                    sizeInBytes: size,
                    updatedAt: date,
                    isSelected: false,
                    snippet: finalTitle,
                    associatedPaths: [entry.path]
                ))
            }
        }

        return items
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
        let workspaceStorageDir = userDirectoryURL.appendingPathComponent("workspaceStorage")
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
