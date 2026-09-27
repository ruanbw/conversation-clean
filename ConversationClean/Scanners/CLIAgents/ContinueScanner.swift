import Foundation

final class ContinueScanner: AgentScanner, @unchecked Sendable {
    let category: ConversationCategory = .continueDev
    let customStorageURL: URL?

    init(storageURL: URL? = nil) {
        self.customStorageURL = storageURL
    }

    var storageURL: URL {
        let base: URL
        if let custom = customStorageURL {
            base = custom
        } else if let env = ProcessInfo.processInfo.environment["CONTINUE_HOME"], !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".continue")
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
        let sessionsDir = storageURL.appendingPathComponent("sessions")
        guard fileManager.fileExists(atPath: sessionsDir.path) else { return [] }

        let sessionFiles = findSessionFiles(in: sessionsDir)
        guard !sessionFiles.isEmpty else { return [] }

        let items: [ConversationItem] = await withTaskGroup(of: ConversationItem?.self) { group in
            for fileURL in sessionFiles {
                group.addTask {
                    return self.parseSessionFile(fileURL: fileURL)
                }
            }

            var collected: [ConversationItem] = []
            collected.reserveCapacity(sessionFiles.count)
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

        var totalBytesFreed: Int64 = 0

        for item in items {
            totalBytesFreed += CleanPrefs.freedBytes(reported: item.sizeInBytes, for: item)

            for path in CleanPrefs.deletionPaths(for: item) {
                _ = FileSizeHelper.removeIfExists(path: path)
            }
        }

        DirectoryCleaner.cleanEmptyDirectories(in: storageURL.appendingPathComponent("sessions"))

        return totalBytesFreed
    }

    func cleanAll() async throws -> Int64 {
        let items = try await scan()
        var freed = try await delete(items: items)

        let fileManager = FileManager.default

        // Clean index / cache folder at ~/.continue/index/
        let indexDir = storageURL.appendingPathComponent("index")
        if fileManager.fileExists(atPath: indexDir.path) {
            let indexSize = FileSizeHelper.sizeOf(path: indexDir.path)
            if FileSizeHelper.removeIfExists(path: indexDir.path) {
                freed += indexSize
                try? fileManager.createDirectory(at: indexDir, withIntermediateDirectories: true)
            }
        }

        // Clean cache folder if present at ~/.continue/cache/
        let cacheDir = storageURL.appendingPathComponent("cache")
        if fileManager.fileExists(atPath: cacheDir.path) {
            let cacheSize = FileSizeHelper.sizeOf(path: cacheDir.path)
            if FileSizeHelper.removeIfExists(path: cacheDir.path) {
                freed += cacheSize
                try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            }
        }

        return freed
    }

    // MARK: - File Discovery

    private func findSessionFiles(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        var result: [URL] = []

        if let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            while let fileURL = enumerator.nextObject() as? URL {
                if fileURL.pathExtension.lowercased() == "json" {
                    result.append(fileURL)
                }
            }
        }

        return result
    }

    // MARK: - Parsing Session File

    private func parseSessionFile(fileURL: URL) -> ConversationItem? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let sessionId = dict["sessionId"] as? String ?? baseName
        let rawTitle = dict["title"] as? String
        let workspaceDir = dict["workspaceDirectory"] as? String
            ?? dict["workspace"] as? String
            ?? dict["cwd"] as? String

        let history = dict["history"] as? [[String: Any]] ?? []
        var messageCount = dict["messageCount"] as? Int ?? history.count
        if messageCount == 0 && !history.isEmpty {
            messageCount = history.count
        }

        // Extract first user prompt and snippet from history
        var extractedPrompt: String?
        var snippet: String = ""

        for item in history {
            // Check item["message"] or direct item
            let msgObj = (item["message"] as? [String: Any]) ?? item
            let role = msgObj["role"] as? String

            let contentStr: String?
            if let str = msgObj["content"] as? String {
                contentStr = str
            } else if let parts = msgObj["content"] as? [[String: Any]] {
                contentStr = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
            } else {
                contentStr = nil
            }

            guard let content = contentStr?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
                continue
            }

            if role == "user" || role == nil {
                if extractedPrompt == nil {
                    extractedPrompt = content
                }
                if snippet.isEmpty {
                    snippet = String(content.prefix(200))
                }
                break
            }
        }

        // Final title determination
        let finalTitle: String
        if let t = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            let singleLine = t.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? t
            finalTitle = singleLine.isEmpty ? (extractedPrompt ?? sessionId) : singleLine
        } else if let p = extractedPrompt, !p.isEmpty {
            let singleLine = p.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? p
            finalTitle = singleLine.isEmpty ? sessionId : singleLine
        } else {
            finalTitle = sessionId
        }

        if snippet.isEmpty {
            snippet = finalTitle
        }

        // Parse dateCreated
        let updatedDate: Date
        if let dateCreated = dict["dateCreated"] {
            if let dateStr = dateCreated as? String, let parsed = Self.parseISO8601Date(dateStr) {
                updatedDate = parsed
            } else if let num = dateCreated as? NSNumber {
                let val = num.doubleValue
                if val > 1_000_000_000_000 { // Milliseconds
                    updatedDate = Date(timeIntervalSince1970: val / 1000.0)
                } else if val > 0 { // Seconds
                    updatedDate = Date(timeIntervalSince1970: val)
                } else {
                    updatedDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                }
            } else if let str = dateCreated as? String, let val = Double(str) {
                if val > 1_000_000_000_000 {
                    updatedDate = Date(timeIntervalSince1970: val / 1000.0)
                } else {
                    updatedDate = Date(timeIntervalSince1970: val)
                }
            } else {
                updatedDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            }
        } else {
            updatedDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        }

        // Associated paths: session file + any session-specific directory
        var associatedPaths: [String] = [fileURL.path]
        let sessionSpecificDir = fileURL.deletingPathExtension()
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: sessionSpecificDir.path, isDirectory: &isDir), isDir.boolValue {
            associatedPaths.append(sessionSpecificDir.path)
        }

        // Size calculation
        var totalSize: Int64 = 0
        for path in associatedPaths {
            totalSize += FileSizeHelper.sizeOf(path: path)
        }

        return ConversationItem(
            id: UUID(),
            sessionId: sessionId,
            title: finalTitle,
            category: self.category,
            projectPath: workspaceDir,
            gitBranch: nil,
            messageCount: messageCount,
            sizeInBytes: totalSize,
            updatedAt: updatedDate,
            isSelected: false,
            snippet: snippet,
            associatedPaths: associatedPaths
        )
    }

    private static func parseISO8601Date(_ str: String) -> Date? {
        if let date = ISODate.parse(str) {
            return date
        }
        // Custom format fallback: yyyy-MM-dd'T'HH:mm:ss
        let customFormatter = DateFormatter()
        customFormatter.locale = Locale(identifier: "en_US_POSIX")
        customFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        if let d = customFormatter.date(from: str) {
            return d
        }
        customFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return customFormatter.date(from: str)
    }
}
